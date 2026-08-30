#!/usr/bin/env python3
# =============================================================================
# dsh-web-control.py — DSH 本地管理控制台后端
#
# 纯标准库实现（零额外依赖）。监听 127.0.0.1:8899，提供：
#   GET /                 -> 控制台页面 (dsh-control.html)
#   GET /api/status       -> 模型状态 + 内存 JSON
#   GET /api/mem          -> 仅内存 JSON
#   GET /api/action?cmd=..&name=..  -> 执行 dsh-manager.sh 启停动作，返回输出
#
# action 通过 subprocess 调用已有的 dsh-manager.sh（其启停逻辑成熟），
# 状态/内存探测由本服务用 Python 重新实现（产出干净 JSON 供前端渲染）。
# 仅本机可访问，不暴露到网络。
# =============================================================================
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

SCRIPT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dsh-manager.sh")
PORT = 8899
PAGE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "dsh-control.html")
PAGE_SIZE = 16384
DSH_WEB_PORT = 3080  # DSH Web 默认端口（用户 `dsh web` 起在此端口）
# DSH Web 两种启动命令行，探测必须同时覆盖，否则匹配不到
DSH_WEB_PATS = ("dsh web", "bin.js --profile web")

# (name, type, port)
MODELS = [
    ("omlx", "omlx", 8000),
    ("qwen3-8b-ablit", "llamacpp", 8001),
    ("qwen3-14b-ablit", "llamacpp", 8002),
]


def run(cmd, name=None, timeout=150):
    """调用 dsh-manager.sh 执行动作，返回合并输出文本。"""
    args = ["bash", SCRIPT, cmd]
    if name:
        args.append(name)
    try:
        r = subprocess.run(args, capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return f"(后台仍在执行，已超过 {timeout}s 轮询上限；用 status 查看进度) cmd={cmd} name={name}"


def run_config_harness(model_id=None, timeout=150):
    """把指定本地模型配置为 DeepSeekHarness 默认模型。"""
    args = ["bash", SCRIPT, "config-harness"]
    if model_id:
        args.append(model_id)
    try:
        r = subprocess.run(args, capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return "(配置超时) cmd=config-harness"


def run_config_workbuddy(model_id=None, timeout=150):
    """把指定本地模型直接写入 WorkBuddy 自定义模型库（~/.workbuddy/models.json）。"""
    args = ["bash", SCRIPT, "config-workbuddy"]
    if model_id:
        args.append(model_id)
    try:
        r = subprocess.run(args, capture_output=True, encoding="utf-8", errors="replace", timeout=timeout)
        return (r.stdout + r.stderr).strip()
    except subprocess.TimeoutExpired:
        return "(配置超时) cmd=config-workbuddy"


def http_code(port):
    try:
        out = subprocess.run(
            ["curl", "-s", "--noproxy", "*", "--max-time", "3", "-o", "/dev/null",
             "-w", "%{http_code}", f"http://127.0.0.1:{port}/v1/models"],
            capture_output=True, text=True)
        return out.stdout.strip() or "000"
    except Exception:
        return "000"


def pgrep_pid(pattern, comm=None):
    """按命令行模式找 PID。

    comm 非空时只接受可执行名为 comm 的进程，用于过滤 shell 包装进程：
    例如 `zsh -c 'node ... --profile web'` 或 `nohup ... &` 的父进程，
    其命令行里同样含有目标字符串，直接用 pgrep -f 会把已退出的服务误判为"仍在加载"。

    macOS 注意：对 homebrew symlink 启动的进程，`ps -o comm=` 可能为空，
    此时回退到检查 `ps -o args=` 是否包含目标名，避免误判服务未运行。
    """
    try:
        out = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True)
        pids = [p for p in out.stdout.strip().split("\n") if p]
    except Exception:
        return ""
    if not comm:
        return pids[0] if pids else ""
    for pid in pids:
        try:
            c = subprocess.run(["ps", "-o", "comm=", "-p", pid],
                               capture_output=True, text=True).stdout.strip()
        except Exception:
            c = ""
        if c == comm:
            return pid
        # macOS 回退：comm 为空时检查完整命令行
        if not c:
            try:
                args = subprocess.run(["ps", "-o", "args=", "-p", pid],
                                      capture_output=True, text=True).stdout.strip()
            except Exception:
                args = ""
            if comm in args:
                return pid
    return ""


def model_pid(name, typ, port):
    # oMLX 真正运行后进程名改写为 Rust 二进制 'omlx-server'，故匹配该名
    if typ == "omlx":
        return pgrep_pid("omlx-server", comm="omlx-server")
    # llama.cpp 的 pgrep 模式已精确到二进制路径 + port，无需再用 ps comm 校验。
    # 去掉 comm 是因为 macOS 对 homebrew symlink 进程的 ps -o comm= 可能为空。
    return pgrep_pid(f"llama-server.*--port {port}")


def model_rss(pid):
    if not pid:
        return 0
    try:
        out = subprocess.run(["ps", "-o", "rss=", "-p", pid], capture_output=True, text=True)
        v = out.stdout.strip()
        return int(v) * 1024 if v.isdigit() else 0
    except Exception:
        return 0


_MODEL_WEIGHTS = {}


def model_weights(refresh=False):
    """返回所有注册模型的权重大小（GB）。

    结果来自脚本 `dsh-manager.sh model_weights`，实测 GGUF / safetensors 文件大小；
    增删模型后自动更新。本函数缓存一次，避免每次 /api/status 都起子进程。
    """
    global _MODEL_WEIGHTS
    if not refresh and _MODEL_WEIGHTS:
        return _MODEL_WEIGHTS
    w = {}
    try:
        out = subprocess.run([SCRIPT, "model_weights"], capture_output=True, text=True)
        for line in out.stdout.strip().split("\n"):
            line = line.strip()
            if "|" not in line:
                continue
            name, gb = line.split("|", 1)
            if name and gb:
                w[name] = gb
    except Exception:
        pass
    _MODEL_WEIGHTS = w
    return w


_OMLX_SCAN = {}


def omlx_scan(refresh=False):
    """返回 oMLX 子模型清单 {name: GB}。

    磁盘扫描结果会被缓存——模型目录不会频繁变动，没必要每次轮询都扫。
    需要更新时调 /api/rescan 或传 refresh=True。
    """
    global _OMLX_SCAN
    if not refresh and _OMLX_SCAN:
        return _OMLX_SCAN
    d = {}
    try:
        out = subprocess.run([SCRIPT, "omlx_scan"], capture_output=True, text=True).stdout
        for line in out.strip().split("\n"):
            if "|" in line:
                n, g = line.split("|", 1)
                if n and g:
                    d[n] = g
    except Exception:
        pass
    _OMLX_SCAN = d
    return d


_RESIDENT_CACHE = {"ts": 0.0, "set": set()}


def omlx_resident(ttl=5.0):
    """返回当前真正常驻 RAM 的 oMLX 子模型集合。

    结果来自引擎池日志解析；带 TTL 缓存，避免高频轮询反复起子进程。
    """
    import time
    now = time.time()
    if now - _RESIDENT_CACHE["ts"] < ttl:
        return _RESIDENT_CACHE["set"]
    s = set()
    try:
        out = subprocess.run([SCRIPT, "omlx_resident"], capture_output=True, text=True).stdout
        for line in out.strip().split("\n"):
            line = line.strip()
            if line and line != "none":
                s.add(line)
    except Exception:
        pass
    _RESIDENT_CACHE["set"] = s
    _RESIDENT_CACHE["ts"] = now
    return s


def model_state(name, typ, port):
    if http_code(port) == "200":
        return "running"
    return "loading" if model_pid(name, typ, port) else "disabled"


def hr(b):
    units = ["B", "KB", "MB", "GB", "TB"]
    i = 0
    while b >= 1024 and i < 4:
        b /= 1024
        i += 1
    return f"{b:.1f} {units[i]}" if i > 0 else f"{b:.0f} B"


def dsh_web_state(port=DSH_WEB_PORT):
    """DSH Web 状态: running / loading / disabled。"""
    try:
        out = subprocess.run(
            ["curl", "-s", "--noproxy", "*", "--max-time", "3", "-o", "/dev/null",
             "-w", "%{http_code}", f"http://127.0.0.1:{port}/"],
            capture_output=True, text=True).stdout.strip()
    except Exception:
        out = ""
    if out == "200":
        return "running"
    # comm="node" 过滤掉 zsh/bash 包装进程，否则服务停掉后会被误判为 loading
    for pat in DSH_WEB_PATS:
        if pgrep_pid(pat, comm="node"):
            return "loading"
    return "disabled"


def probe_status():
    total = 0
    try:
        total = int(subprocess.run(["sysctl", "-n", "hw.memsize"],
                                   capture_output=True, text=True).stdout.strip() or 0)
    except Exception:
        pass
    # 与 macOS 活动监视器 / 系统监视器对齐：
    #   已用 = active + speculative + wired + compressed(压缩后实际占用)
    #   可用 = total - 已用
    # 注意：不要把 "Pages stored in compressor"（压缩前）当成可用，
    # 它是数据量；真正占内存的是 "Pages occupied by compressor"（压缩后）。
    page = PAGE_SIZE
    pg = {"free": 0, "inactive": 0, "purgeable": 0, "active": 0,
          "speculative": 0, "wired": 0, "compressed": 0}
    try:
        vs = subprocess.run(["vm_stat"], capture_output=True, text=True).stdout
        m = re.search(r"page size of (\d+) bytes", vs)
        if m:
            page = int(m.group(1))

        def grab(key):
            mm = re.search(rf"{key}:\s+(\d+)", vs)
            return int(mm.group(1)) if mm else 0

        pg = {
            "free": grab("Pages free"),
            "inactive": grab("Pages inactive"),
            "purgeable": grab("Pages purgeable"),
            "active": grab("Pages active"),
            "speculative": grab("Pages speculative"),
            "wired": grab("Pages wired down"),
            "compressed": grab("Pages occupied by compressor"),
        }
    except Exception:
        pass
    free = pg["free"] * page
    cached = (pg["inactive"] + pg["purgeable"]) * page
    compressed = pg["compressed"] * page
    used = (pg["active"] + pg["speculative"] + pg["wired"] + pg["compressed"]) * page
    used = max(0, min(used, total)) if total else 0
    available = max(total - used, 0) if total else 0
    used_pct = int(used * 100 / total) if total else 0

    weights = model_weights()
    models = []
    for name, typ, port in MODELS:
        st = model_state(name, typ, port)
        pid = model_pid(name, typ, port)
        rss = model_rss(pid)
        pct = int(rss * 100 / total) if total else 0
        sub = []
        if name == "omlx":
            # 子模型层级：清单与权重来自磁盘扫描（缓存），常驻状态来自 omlx_resident。
            # 服务未运行时也照样给出清单，只是状态均为「未加载」。
            resident = omlx_resident()
            for mid, gb in omlx_scan().items():
                sub.append({"name": mid, "weight": gb,
                            "resident": mid in resident})
        models.append({
            "name": name, "type": typ, "port": port, "state": st,
            "rss": hr(rss), "pct": pct, "sub": sub,
            "weight": weights.get(name, ""),
        })
    return {
        "models": models,
        "weights": weights,
        "services": [{"name": "DSH Web", "port": DSH_WEB_PORT,
                      "state": dsh_web_state(DSH_WEB_PORT)}],
        "mem": {
            "total": total, "used": used, "available": available, "free": free,
            "cached": cached, "compressed": compressed, "used_pct": used_pct,
            "total_h": hr(total), "used_h": hr(used), "available_h": hr(available),
            "free_h": hr(free), "cached_h": hr(cached), "compressed_h": hr(compressed),
        },
    }


class H(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json"):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body.encode("utf-8"))

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            try:
                with open(PAGE, encoding="utf-8") as f:
                    self._send(200, f.read(), "text/html; charset=utf-8")
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}, ensure_ascii=False))
            return
        if path == "/api/status":
            self._send(200, json.dumps(probe_status(), ensure_ascii=False))
            return
        if path == "/api/mem":
            self._send(200, json.dumps(probe_status()["mem"], ensure_ascii=False))
            return
        if path == "/api/rescan":
            # 手动触发磁盘扫描：清缓存后重新扫描模型目录与权重大小。
            # 常态轮询不再扫描，避免每 5 秒起子进程遍历磁盘。
            try:
                model_weights(refresh=True)
                omlx_scan(refresh=True)
                _RESIDENT_CACHE["ts"] = 0.0
                self._send(200, json.dumps(
                    {"ok": True, "weights": model_weights(), "omlx": omlx_scan()},
                    ensure_ascii=False))
            except Exception as e:
                self._send(500, json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
            return
        if path == "/api/action":
            try:
                q = parse_qs(urlparse(self.path).query)
                cmd = q.get("cmd", [""])[0]
                name = q.get("name", [""])[0]
                if cmd not in ("start", "stop", "load", "unload", "config-harness", "config-workbuddy"):
                    self._send(400, json.dumps({"ok": False, "error": f"bad cmd: {cmd}"}))
                    return
                if cmd == "config-harness":
                    out = run_config_harness(name)
                elif cmd == "config-workbuddy":
                    out = run_config_workbuddy(name)
                else:
                    out = run(cmd, name or None)
                self._send(200, json.dumps(
                    {"ok": True, "cmd": cmd, "name": name, "output": out}, ensure_ascii=False))
            except Exception as e:
                self._send(500, json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False))
            return
        self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, *a):
        pass


if __name__ == "__main__":
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"DSH Web Control 运行中: http://127.0.0.1:{PORT}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        srv.shutdown()
