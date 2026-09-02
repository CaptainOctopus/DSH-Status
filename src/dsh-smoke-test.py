#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DSH 三件套冒烟测试 (smoke test)
================================

用途:
    快速验证 DSH 管理工具链的核心契约没有被改坏。覆盖三件套:
      1. dsh-manager.sh  —— 命令行管理脚本
      2. dsh-web-control.py —— 网页控制台 (:8899)
      3. DSHStatus.m      —— 菜单栏原生 app 源码/二进制

设计原则 (非侵入):
    - 只读类命令 (help / omlx_scan / model_weights / mem / status) 不改变任何状态。
    - 网页控制台仅在「未运行」时拉起一个临时实例做探针，跑完保持运行(用户本就想要它常驻)。
    - /api/action 只对一个「当前已停止」的模型发 unload，等于 no-op，绝不误杀真实在跑的模型。
    - 不触碰 :3080(DSH Web) / :8000(oMLX) / :8001/:8002(llamacpp) 的启停。

用法:
    python3 dsh-smoke-test.py            # 全量跑, 退出码 0=全过, 非0=有失败
    python3 dsh-smoke-test.py --quiet    # 只打印 FAIL 与汇总

model-less 降级:
    本机若无模型权重, omlx_scan / model_weights / /api/rescan 三项的「权重完整性」
    断言自动跳过, 只校验命令与接口能正常返回 —— 与工具在纯监控机器上的定位一致。
    模型目录可用环境变量 DSH_MODELS_DIR 覆盖。

依赖: curl (系统自带), clang (Command Line Tools, 用于菜单栏源码语法检查)。
"""

import subprocess
import sys
import os
import re
import json
import shutil
import time

# ----------------------------- 路径 -----------------------------
# 源码一律相对本文件定位（本文件位于 src/ 下），工作区可整体搬迁。
BASE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(BASE, "dsh-manager.sh")
WEB = os.path.join(BASE, "dsh-web-control.py")
APP_M = os.path.join(BASE, "dsh-menubar", "DSHStatus.m")
APP_BIN = os.path.expanduser("~/Applications/DSH Status.app/Contents/MacOS/DSHStatus")

# 模型权重属于数据、不随源码分发，需单独指定（可用 DSH_MODELS_DIR 覆盖）。
# 默认沿用机器学习权重实际存放处；model-less 机器上相关检查会自动降级为跳过。
MODELS_DIR = os.environ.get(
    "DSH_MODELS_DIR",
    os.path.expanduser("~/WorkBuddy/2026-08-28-23-12-48/mlx-agent-lab/models"),
)
PY = os.environ.get("DSH_PY", sys.executable)
WEB_PORT = 8899

# model-less 机器（本机未放模型权重）上，权重相关的「完整性」断言自动降级：
# 只校验命令/接口能正常返回，不强求扫到模型。与「跨机只看内存与状态」的设计一致。
try:
    HAS_MODELS = os.path.isdir(MODELS_DIR) and any(
        os.path.isdir(os.path.join(MODELS_DIR, d)) for d in os.listdir(MODELS_DIR)
    )
except OSError:
    HAS_MODELS = False

QUIET = "--quiet" in sys.argv

results = []


def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    if QUIET and ok:
        return
    mark = "PASS" if ok else "FAIL"
    line = "[%s] %s" % (mark, name)
    if detail:
        line += "  -- " + detail
    print(line)
    sys.stdout.flush()


def sh(cmd, timeout=None):
    """shell=True 执行, 返回 CompletedProcess 风格对象(带 .rc/.out/.err 简写)。"""
    try:
        p = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        class R:
            pass
        r = R()
        r.returncode = p.returncode
        r.stdout = p.stdout or ""
        r.stderr = p.stderr or ""
        return r
    except subprocess.TimeoutExpired as e:
        class R:
            pass
        r = R()
        r.returncode = 124
        r.stdout = getattr(e, "stdout", "") or ""
        r.stderr = "timeout"
        return r


def curl_get(path, timeout=8):
    return sh('curl -s --noproxy \'*\' --max-time %d http://127.0.0.1:%d%s' % (timeout, WEB_PORT, path))


def curl_post(path, data=None, timeout=12):
    if data is None:
        return sh('curl -s --noproxy \'*\' --max-time %d -X POST http://127.0.0.1:%d%s' % (timeout, WEB_PORT, path))
    j = json.dumps(data)
    return sh('curl -s --noproxy \'*\' --max-time %d -X POST -H "Content-Type: application/json" -d %s http://127.0.0.1:%d%s'
              % (timeout, sh_quote(j), WEB_PORT, path))


def sh_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


def gb_num(s):
    """'5.5 GB' / '16.0 GB' -> 5.5 (float); 失败返回 None。"""
    m = re.match(r"([\d.]+)\s*(GB|MB|KB|B)?", s.strip())
    if not m:
        return None
    v = float(m.group(1))
    return v


# ============================ T1: help ============================
r = sh('bash %s help' % sh_quote(SCRIPT))
check("dsh-manager.sh help: 退出码0且非空",
      r.returncode == 0 and len(r.stdout.strip()) > 0,
      "rc=%d" % r.returncode)

# ===================== T2: omlx_scan 格式+完整性 =====================
r = sh('bash %s omlx_scan' % sh_quote(SCRIPT))
parsed = []
ok = r.returncode == 0
for line in r.stdout.strip().splitlines():
    line = line.strip()
    if not line:
        continue
    m = re.match(r"^(.+)\|([\d.]+)$", line)
    if m:
        parsed.append((m.group(1), float(m.group(2))))
if HAS_MODELS:
    ok = ok and len(parsed) > 0 and all(gb > 0 for _, gb in parsed)
# 完整性: 磁盘上存在的模型目录都应出现在扫描结果里
disk_models = []
if os.path.isdir(MODELS_DIR):
    disk_models = [d for d in os.listdir(MODELS_DIR)
                   if os.path.isdir(os.path.join(MODELS_DIR, d))]
missing = [d for d in disk_models if d not in [n for n, _ in parsed]]
ok = ok and not missing
detail2 = "解析%d个; 磁盘缺失=%s" % (len(parsed), missing or "无")
if not HAS_MODELS:
    detail2 += " [model-less: 跳过权重完整性]"
check("omlx_scan: 每行 name|GB 且 GB>0, 且覆盖磁盘目录", ok, detail2)

# ===================== T3: model_weights 格式+关键模型 =====================
r = sh('bash %s model_weights' % sh_quote(SCRIPT))
parsed3 = []
ok3 = r.returncode == 0
for line in r.stdout.strip().splitlines():
    line = line.strip()
    if not line:
        continue
    m = re.match(r"^(.+)\|([\d.]+)$", line)
    if m:
        parsed3.append((m.group(1), float(m.group(2))))
names3 = [n for n, _ in parsed3]
# 关键模型断言动态化：期望清单 = GGUF 目录实扫（与 manager 的 GGUF_DIR 候选顺序一致）
GGUF_DIR = os.environ.get("DSH_GGUF_DIR")
if not GGUF_DIR:
    for cand in (os.path.join(BASE, "llamacpp-models"),
                 os.path.expanduser("~/WorkBuddy/2026-08-28-23-12-48/llamacpp-models"),
                 os.path.expanduser("~/.dsh/models/gguf"),
                 os.path.expanduser("~/models")):
        if os.path.isdir(cand) and any(f.endswith(".gguf") for f in os.listdir(cand)):
            GGUF_DIR = cand
            break
need = [os.path.basename(f)[:-5] for f in (sorted(os.listdir(GGUF_DIR))
         if GGUF_DIR and os.path.isdir(GGUF_DIR) else []) if f.endswith(".gguf")]
if HAS_MODELS:
    ok3 = ok3 and len(parsed3) > 0 and all(gb > 0 for _, gb in parsed3)
if need:
    ok3 = ok3 and all(n in names3 for n in need)
# 磁盘上的 oMLX 子模型也应出现
for d in disk_models:
    if d not in names3:
        ok3 = False
detail3 = "解析%d个; 期望GGUF=%s; 缺失=%s" % (
    len(parsed3), need or "无", [n for n in need if n not in names3] or "无")
if not HAS_MODELS and not need:
    detail3 += " [model-less: 跳过关键模型断言]"
check("model_weights: 覆盖磁盘 GGUF 与 oMLX 子模型", ok3, detail3)

# ===================== T4: mem 口径合理性 =====================
r = sh('bash %s mem' % sh_quote(SCRIPT))
ok4 = False
detail4 = ""
if r.returncode == 0:
    txt = r.stdout
    m_total = re.search(r"总=([\d.]+ \w+)", txt)
    m_used = re.search(r"已用=([\d.]+ \w+) \(([\d]+)%\)", txt)
    if m_total and m_used:
        total_gb = gb_num(m_total.group(1)) or 0
        used_gb = gb_num(m_used.group(1)) or 0
        pct = int(m_used.group(2))
        ok4 = (0 <= pct <= 100) and used_gb > 0 and total_gb > 0
        detail4 = "总%.1fGB 已用%.1fGB (%d%%)" % (total_gb, used_gb, pct)
check("mem: 已用%在0-100且总/已用>0(与活动监视器口径一致)",
      ok4, detail4)

# ===================== T5: status 退出码 =====================
r = sh('bash %s status' % sh_quote(SCRIPT))
check("dsh-manager.sh status: 退出码0", r.returncode == 0, "rc=%d" % r.returncode)

# ===================== T6: 网页控制台 /api/status 结构 =====================
code = curl_get("/api/status").stdout
# 若未运行, 拉起一个临时实例
if "200" not in sh('curl -s --noproxy \'*\' --max-time 2 -o /dev/null -w "%%{http_code}" http://127.0.0.1:%d/' % WEB_PORT).stdout:
    sh("pkill -f dsh-web-control.py")
    time.sleep(0.5)
    try:
        subprocess.Popen([PY, WEB], stdout=open("/tmp/dsh-web-control.log", "a"),
                         stderr=subprocess.STDOUT)
    except Exception as e:
        check("网页控制台: 启动失败", False, str(e))
    time.sleep(3)

st = curl_get("/api/status")
ok6 = False
detail6 = ""
if st.returncode == 0 and st.stdout.strip():
    try:
        d = json.loads(st.stdout)
        models = d.get("models", [])
        keys_ok = models and all(
            all(k in m for k in ("name", "type", "port", "state", "weight"))
            for m in models)
        omlx = [m for m in models if m["name"] == "omlx"]
        sub_ok = bool(omlx) and isinstance(omlx[0].get("sub"), list) \
            and all(all(k in s for k in ("name", "weight", "resident")) for s in omlx[0]["sub"])
        ok6 = keys_ok and sub_ok
        detail6 = "models=%d, omlx子模型=%d" % (len(models), len(omlx[0]["sub"]) if omlx else 0)
    except Exception as e:
        detail6 = "json解析失败: %s" % e
else:
    detail6 = "无法获取 /api/status (rc=%d)" % st.returncode
check("网页控制台 /api/status: 结构与 oMLX 层级", ok6, detail6)

# ===================== T7: /api/rescan 返回 weights =====================
rc = curl_get("/api/rescan")
ok7 = False
detail7 = ""
if rc.returncode == 0 and rc.stdout.strip():
    try:
        d = json.loads(rc.stdout)
        w = d.get("weights", {})
        # model-less 时允许空字典：接口契约（返回 dict）成立即可
        ok7 = isinstance(w, dict) and (len(w) > 0 if HAS_MODELS else True)
        detail7 = "weights键数=%d" % len(w)
        if not HAS_MODELS:
            detail7 += " [model-less: 允许空]"
    except Exception as e:
        detail7 = "json失败: %s" % e
else:
    detail7 = "无法 POST /api/rescan"
check("网页控制台 /api/rescan: 返回 weights 字典", ok7, detail7)

# ===================== T8: /api/action 安全探测 =====================
# 选一个「当前已停止」的模型做 unload(no-op), 避免误杀在跑的模型
target = None
try:
    d = json.loads(curl_get("/api/status").stdout)
    for m in d.get("models", []):
        if m.get("state") in ("stopped", "error"):
            target = m["name"]
            break
except Exception:
    pass
if not target:
    check("网页控制台 /api/action: 安全探测(跳过, 无已停止模型可测)", True,
          "所有模型均运行中, 为避免误杀跳过")
else:
    ac = curl_post("/api/action", {"action": "unload", "model": target})
    ok8 = False
    detail8 = ""
    if ac.returncode == 0 and ac.stdout.strip():
        try:
            d = json.loads(ac.stdout)
            ok8 = ("ok" in d) or ("error" in d)
            detail8 = "对 %s -> %s" % (target, d)
        except Exception as e:
            detail8 = "json失败: %s" % e
    else:
        detail8 = "请求失败 rc=%d" % ac.returncode
    check("网页控制台 /api/action: 安全探测(unload 已停止的 %s)" % target, ok8, detail8[:160])

# ===================== T9: 菜单栏源码语法检查 =====================
clang = shutil.which("clang") or "/usr/bin/clang"
syn = sh('%s -fsyntax-only -framework Cocoa -ObjC %s' % (sh_quote(clang), sh_quote(APP_M)), timeout=60)
ok9 = syn.returncode == 0
check("DSHStatus.m: clang 语法检查通过",
      ok9, (syn.stderr.strip()[:240] if not ok9 else "compile-ok"))

# ===================== T10: 菜单栏二进制存在 + 已签名 =====================
bin_ok = os.path.exists(APP_BIN)
detail10 = APP_BIN if bin_ok else "未找到"
cs = sh('codesign -v %s' % sh_quote(os.path.expanduser("~/Applications/DSH Status.app")))
cs_ok = cs.returncode == 0
check("菜单栏 app: 二进制存在且已签名",
      bin_ok and cs_ok, detail10 + (" | 签名有效" if cs_ok else " | 签名无效 rc=%d" % cs.returncode))

# ===================== T11: scan_report 结构与路径真实性 =====================
# scan_report 是网页流式扫描与菜单栏弹窗的共同数据源。模型名/端口只是展示，
# 路径必须真实存在于磁盘——否则前端就是在给用户看不存在的东西。
r = sh('bash %s scan_report' % sh_quote(SCRIPT))
lines = [l.strip() for l in r.stdout.strip().splitlines() if l.strip()]
dirs = [l for l in lines if l.startswith("dir|")]
models = [l for l in lines if l.startswith("model|")]
ends = [l for l in lines if l.startswith("done|")]
ok11 = r.returncode == 0 and len(ends) == 1 and len(dirs) == 2
bad_paths = []
for l in models:
    p = l.split("|")
    if len(p) < 6:
        ok11 = False
        continue
    path = "|".join(p[5:])          # 路径本身可能含 '|'
    if not os.path.exists(path):
        bad_paths.append(path)
ok11 = ok11 and not bad_paths
declared = ends[0].split("|")[1] if ends else None
ok11 = ok11 and (declared == str(len(models)))
if HAS_MODELS and len(models) == 0:
    ok11 = False
detail11 = "dir行=%d model行=%d done声明=%s; 路径无效=%s" % (
    len(dirs), len(models), declared, bad_paths or "无")
if HAS_MODELS and len(models) == 0:
    detail11 += " (有模型目录却扫出 0 个)"
check("scan_report: dir/model/done 结构完整, 模型路径真实存在", ok11, detail11)

# ============================ 汇总 ============================
fails = [r for r in results if not r[1]]
print("\n==== 冒烟测试汇总 ====")
print("总计 %d 项, 通过 %d, 失败 %d" % (len(results), len(results) - len(fails), len(fails)))
if fails:
    print("失败项:")
    for n, _, d in fails:
        print("  - %s: %s" % (n, d))
    sys.exit(1)
print("全部通过 ✅")
sys.exit(0)
