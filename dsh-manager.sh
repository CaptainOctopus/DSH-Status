#!/usr/bin/env bash
# =============================================================================
# dsh-manager.sh — DSH / 本地模型后端统一管理脚本
#
# 设计前提（与你的机器一致）:
#   - oMLX 是“一启全载”的整体服务（:8000），内部 9B/4B/Hermes-14B 无法单独卸载，
#     只能整服务启停。
#   - llama.cpp 每个 GGUF = 一个独立 llama-server 实例，各自端口，可单独启停。
#   - DSH Web UI 是独立的 node 进程（默认 :3080，用户以 'dsh web' 启动）。
#
# 用法:
#   ./dsh-manager.sh start                 # 全拉起: oMLX + 默认 GGUF + DSH Web
#   ./dsh-manager.sh start --no-models     # 只起 DSH Web（后端手动 load）
#   ./dsh-manager.sh stop                  # 停掉全部（Web + 所有后端）
#   ./dsh-manager.sh load  <name>          # 加载/启动指定模型
#   ./dsh-manager.sh unload <name>          # 停用/停掉指定模型
#   ./dsh-manager.sh status [--watch]      # 模型状态 + 内存占用（--watch 实时刷新）
#   ./dsh-manager.sh mem                   # 仅内存占用
#   ./dsh-manager.sh models                # 列出已注册模型
#   ./dsh-manager.sh config-harness [model_id]   # 把本地模型配置为 DeepSeekHarness(DSH Web)默认模型
#   ./dsh-manager.sh config-workbuddy [model_id]   # 生成可粘贴到 WorkBuddy「添加模型」的配置文本
#   ./dsh-manager.sh help                  # 本帮助
#
# 要求: macOS, bash 3.2+（系统自带即可）, curl, llama-server, omlx, node。
# =============================================================================

# ----------------------------- 可配置项 --------------------------------------
# 自包含部署：脚本位置即资源根（打包进 app 后为 Contents/Resources）。
# 允许用环境变量覆盖，便于在完整工作区里独立使用时指向真实路径。
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="${WORKSPACE:-$SCRIPT_DIR}"
OMLX_BIN="${OMLX_BIN:-$HOME/.workbuddy/binaries/python/envs/omlx/bin/omlx}"
# 模型目录允许多个候选：打包后的 app 默认不带模型，优先使用用户实际放置模型的目录。
# oMLX 模型目录：目录存在且里面至少有一个权重文件才算有效。
OMLX_MODELS_DIR="${OMLX_MODELS_DIR:-$(
  found=""
  for d in "$WORKSPACE/mlx-agent-lab/models" \
           "$HOME/WorkBuddy/2026-08-28-23-12-48/mlx-agent-lab/models" \
           "$HOME/.dsh/models/omlx"; do
    if [ -d "$d" ] && find "$d" -maxdepth 2 \( -name '*.safetensors' -o -name '*.npz' -o -name '*.bin' \) | head -1 | grep -q .; then
      found="$d"; break
    fi
  done
  echo "${found:-${WORKSPACE}/mlx-agent-lab/models}"
)}"
OMLX_CACHE="${OMLX_CACHE:-$HOME/.omlx/paged_cache}"

DSH_BIN="$HOME/.dsh/profiles/node_modules/@deepseek-ai/dsh/lib/bin.js"
DSH_PROFILE="web"
DSH_WEB_PORT=3080        # DSH Web 默认端口；用户 `dsh web` 即起在此端口
# DSH Web 有两种常见启动命令行，启停/检测都必须同时覆盖，否则匹配不到、杀不掉:
#   1) 用户手敲 'dsh web'（默认端口 3080）
#   2) 本脚本 start: 'bin.js --profile web --port 3080'
DSH_WEB_PATS=("dsh web" "bin.js --profile $DSH_PROFILE")

LLAMA_BIN="/opt/homebrew/bin/llama-server"
# llama.cpp GGUF 目录：目录存在且里面至少有一个 .gguf 文件才算有效。
GGUF_DIR="${GGUF_DIR:-$(
  found=""
  for d in "$WORKSPACE/llamacpp-models" \
           "$HOME/WorkBuddy/2026-08-28-23-12-48/llamacpp-models" \
           "$HOME/.dsh/models/gguf"; do
    if [ -d "$d" ] && find "$d" -maxdepth 1 -name '*.gguf' | head -1 | grep -q .; then
      found="$d"; break
    fi
  done
  echo "${found:-${WORKSPACE}/llamacpp-models}"
)}"
DEFAULT_LLAMA="qwen3-8b-ablit"   # start 时自动拉起的 GGUF 模型

PAGE_SIZE=16384
LLAMA_CTX=8192
LLAMA_GPU_LAYERS=99

# ----------------------------- 模型注册表 ------------------------------------
# 每个模型 = 一个独立服务实例。omlx 是整体服务（其子模型不可单独卸载）。
MODELS=(omlx qwen3-8b-ablit qwen3-14b-ablit)

mt_type() { case "$1" in
  omlx)            echo omlx;;
  qwen3-8b-ablit)  echo llamacpp;;
  qwen3-14b-ablit) echo llamacpp;;
esac; }

mt_port() { case "$1" in
  omlx)            echo 8000;;
  qwen3-8b-ablit)  echo 8001;;
  qwen3-14b-ablit) echo 8002;;
esac; }

mt_gguf() { case "$1" in
  qwen3-8b-ablit)  echo "Huihui-Qwen3-8B-abliterated-v2.Q4_K_M.gguf";;
  qwen3-14b-ablit) echo "Qwen3-14B-abliterated.Q4_K_M.gguf";;
esac; }

mt_desc() { case "$1" in
  omlx)            echo "oMLX 本地推理 (9B/4B/Hermes-14B)";;
  qwen3-8b-ablit)  echo "Qwen3-8B abliterated (GGUF Q4_K_M, 4.7G)";;
  qwen3-14b-ablit) echo "Qwen3-14B abliterated (GGUF Q4_K_M, 8.4G)";;
esac; }

# ----------------------------- 小工具 ----------------------------------------
is_registered() {
  local m; for m in "${MODELS[@]}"; do [ "$m" = "$1" ] && return 0; done
  return 1
}

# 返回模型主进程 PID，找不到则空
model_pid() {
  local name="$1" port pid
  case "$(mt_type "$name")" in
    omlx)
      pid=$(pgrep -f "omlx-server" 2>/dev/null | head -1)
      [ -n "$pid" ] && { echo "$pid"; return; }
      pid=$(pgrep -f "omlx serve" 2>/dev/null | head -1)
      [ -n "$pid" ] && { echo "$pid"; return; }
      # 兜底：按端口 8000 反查 PID（某些环境下 pgrep -f 读不到完整命令行）
      pid=$(lsof -iTCP:8000 -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR==2{print $2}')
      [ -n "$pid" ] && { echo "$pid"; return; }
      ;;
    llamacpp)
      port=$(mt_port "$name")
      pid=$(pgrep -f "llama-server.*--port $port" 2>/dev/null | head -1)
      [ -n "$pid" ] && { echo "$pid"; return; }
      pid=$(lsof -iTCP:"$port" -sTCP:LISTEN -n -P 2>/dev/null | awk 'NR==2{print $2}')
      [ -n "$pid" ] && { echo "$pid"; return; }
      ;;
  esac
}

# HTTP 状态码（--max-time 防卡死；连不上返回 000）
http_code() {
  curl -s --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$1/v1/models" 2>/dev/null || echo 000
}

# 状态机: running / loading / disabled
model_state() {
  local name="$1" port code pid
  port=$(mt_port "$name")
  code=$(http_code "$port")
  if [ "$code" = "200" ]; then echo running; return; fi
  pid=$(model_pid "$name")
  if [ -n "$pid" ]; then echo loading; else echo disabled; fi
}

# 进程常驻内存 RSS（KB），取不到返回 0
model_rss_kb() {
  local pid; pid=$(model_pid "$1")
  [ -z "$pid" ] && { echo 0; return; }
  local rss; rss=$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')
  echo "${rss:-0}"
}

# ----------------------------- 颜色 ------------------------------------------
if [ -z "${NO_COLOR:-}" ]; then
  C_RUN=$'\033[32m'; C_LOAD=$'\033[33m'; C_OFF=$'\033[31m'; C_RST=$'\033[0m'
else
  C_RUN=""; C_LOAD=""; C_OFF=""; C_RST=""
fi

# 人类可读字节
hr_bytes() {
  local b=$1
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB",u," "); i=1;
    while(b>=1024 && i<5){b/=1024;i++}
    if(i==1) printf "%.0f %s", b, u[i];
    else     printf "%.1f %s", b, u[i];
  }'
}

# ----------------------------- 启停动作 --------------------------------------
start_omlx() {
  if [ "$(model_state omlx)" = "running" ]; then echo "  oMLX 已在运行 (:8000)"; return 0; fi
  if [ ! -d "$OMLX_MODELS_DIR" ]; then
    echo "  ✗ 找不到 oMLX 模型目录: $OMLX_MODELS_DIR"
    echo "     请把模型放到以下任一路径，或设置 OMLX_MODELS_DIR 环境变量:"
    echo "       ${WORKSPACE}/mlx-agent-lab/models"
    echo "       $HOME/WorkBuddy/2026-08-28-23-12-48/mlx-agent-lab/models"
    echo "       $HOME/.dsh/models/omlx"
    return 1
  fi
  mkdir -p "$OMLX_CACHE"
  echo "  启动 oMLX (:8000) ..."
  echo "    模型目录: $OMLX_MODELS_DIR"
  nohup "$OMLX_BIN" serve \
    --model-dir "$OMLX_MODELS_DIR" \
    --port 8000 \
    --memory-guard safe --memory-guard-gb 10 \
    --max-concurrent-requests 2 \
    --paged-ssd-cache-dir "$OMLX_CACHE" \
    --hot-cache-max-size 2GB \
    --log-level info > /tmp/omlx_server.log 2>&1 &
  echo "    PID=$!"
}

start_llamacpp() {
  local name="$1" port gguf log
  port=$(mt_port "$name"); gguf=$(mt_gguf "$name"); log="/tmp/llamacpp_${name}.log"
  if [ "$(model_state "$name")" = "running" ]; then echo "  $name 已在运行 (:${port})"; return 0; fi
  if [ ! -d "$GGUF_DIR" ]; then
    echo "  ✗ 找不到 GGUF 目录: $GGUF_DIR"
    echo "     请把 GGUF 放到以下任一路径，或设置 GGUF_DIR 环境变量:"
    echo "       ${WORKSPACE}/llamacpp-models"
    echo "       $HOME/WorkBuddy/2026-08-28-23-12-48/llamacpp-models"
    echo "       $HOME/.dsh/models/gguf"
    return 1
  fi
  if [ ! -f "$GGUF_DIR/$gguf" ]; then
    echo "  ✗ 找不到模型文件: $GGUF_DIR/$gguf"
    echo "     该目录现有文件:"
    ls -1 "$GGUF_DIR" 2>/dev/null | sed 's/^/       - /'
    return 1
  fi
  echo "  启动 $name (llama.cpp :${port}) ..."
  nohup env no_proxy='*' http_proxy='' https_proxy='' "$LLAMA_BIN" \
    --model "$GGUF_DIR/$gguf" \
    --host 127.0.0.1 --port "$port" \
    --ctx-size "$LLAMA_CTX" --gpu-layers "$LLAMA_GPU_LAYERS" > "$log" 2>&1 &
  echo "    PID=$!"
}

stop_model() {
  local name="$1"
  case "$(mt_type "$name")" in
    omlx)
      # oMLX 进程名随版本/启动方式可能为 'omlx-server'、'omlx serve' 或 python wrapper。
      # 这里用多重模式 + 端口反查 PID 兜底，确保能停干净。
      local any=0
      pgrep -f "omlx-server" >/dev/null 2>&1 && any=1
      pgrep -f "omlx serve"  >/dev/null 2>&1 && any=1
      pgrep -f "$OMLX_BIN"   >/dev/null 2>&1 && any=1
      lsof -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1 && any=1
      if [ "$any" -eq 1 ]; then
        echo "  停用 $name ..."
        pkill -f "omlx-server" 2>/dev/null
        pkill -f "omlx serve"  2>/dev/null
        pkill -f "$OMLX_BIN"   2>/dev/null
        sleep 1
        pgrep -f "omlx-server" >/dev/null 2>&1 && pkill -9 -f "omlx-server" 2>/dev/null
        pgrep -f "omlx serve"  >/dev/null 2>&1 && pkill -9 -f "omlx serve"  2>/dev/null
        pgrep -f "$OMLX_BIN"   >/dev/null 2>&1 && pkill -9 -f "$OMLX_BIN"   2>/dev/null
        # 最后兜底：用 model_pid 端口反查再杀一次
        local pid; pid=$(model_pid omlx)
        [ -n "$pid" ] && { kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; }
      else
        echo "  $name 本就未运行"
      fi
      ;;
    llamacpp)
      local port pat
      port=$(mt_port "$name")
      pat="llama-server.*--port $port"
      if pgrep -f "$pat" >/dev/null 2>&1 || lsof -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
        echo "  停用 $name ..."
        pkill -f "$pat" 2>/dev/null
        sleep 1
        pgrep -f "$pat" >/dev/null 2>&1 && pkill -9 -f "$pat" 2>/dev/null
        # 兜底：端口反查 PID
        local pid; pid=$(model_pid "$name")
        [ -n "$pid" ] && { kill "$pid" 2>/dev/null; sleep 1; kill -9 "$pid" 2>/dev/null; }
      else
        echo "  $name 本就未运行"
      fi
      ;;
  esac
}

# DSH Web 是否在运行：两种启动命令行任一命中即算（用户 'dsh web' 或本脚本 start）
dsh_web_running() {
  local pat
  for pat in "${DSH_WEB_PATS[@]}"; do
    pgrep -f "$pat" >/dev/null 2>&1 && return 0
  done
  return 1
}

# 探测 DSH Web 实际监听端口（用户要求“先检查 DSH 装到哪个端口”）。
# 优先匹配进程命令行，再回退到常见端口的 LISTEN 探测。
detect_dsh_port() {
  dsh_web_running && { echo "$DSH_WEB_PORT"; return; }
  local p
  for p in 3080 3081 3082 3083 8080 8888; do
    if lsof -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "$p"; return; fi
  done
  echo ""
}

# 定位可用的 python3（自带 PyYAML）：优先 bundle 内联，其次 managed，最后系统。
pybin() {
  local b
  b="$SCRIPT_DIR/python/bin/python3"; [ -x "$b" ] && { echo "$b"; return; }
  b="$HOME/.workbuddy/binaries/python/versions/3.13.12/bin/python3"; [ -x "$b" ] && { echo "$b"; return; }
  echo python3
}

start_dsh() {
  if dsh_web_running; then
    echo "  DSH Web 已在运行 (:${DSH_WEB_PORT})"; return 0
  fi
  echo "  启动 DSH Web (:${DSH_WEB_PORT}) ..."
  nohup env no_proxy='*' http_proxy='' https_proxy='' \
    node "$DSH_BIN" --profile "$DSH_PROFILE" --host 127.0.0.1 --port "$DSH_WEB_PORT" --no-open \
    > /tmp/dsh-web.log 2>&1 &
  echo "    PID=$!"
}

stop_dsh() {
  if dsh_web_running; then
    echo "  停止 DSH Web ..."
    local pat
    for pat in "${DSH_WEB_PATS[@]}"; do pkill -f "$pat" 2>/dev/null; done
    sleep 1
    # 仍未退出的强杀
    for pat in "${DSH_WEB_PATS[@]}"; do
      pgrep -f "$pat" >/dev/null 2>&1 && pkill -9 -f "$pat" 2>/dev/null
    done
  else
    echo "  DSH Web 本就未运行"
  fi
}

# 加载后轮询直到 running 或超时
wait_running() {
  local name="$1" port i
  port=$(mt_port "$name")
  for i in $(seq 1 30); do
    [ "$(model_state "$name")" = "running" ] && { echo "  ✓ $name 就绪 (:${port})"; return 0; }
    sleep 3
  done
  local st; st=$(model_state "$name")
  if [ "$st" = "loading" ]; then echo "  … $name 仍在加载（后台进行中，用 status 查看）"; return 0; fi
  echo "  ✗ $name 启动失败，看日志: /tmp/llamacpp_${name}.log 或 /tmp/omlx_server.log"; return 1
}

# ----------------------------- 展示 ------------------------------------------
# 与 macOS 活动监视器 / 系统监视器对齐：
#   已用 = active + speculative + wired + compressed(压缩后实际占用)
#   可用 = total - 已用
# 注意："Pages stored in compressor" 是压缩前数据量，不是真实内存占用；
# 真实压缩占用是 "Pages occupied by compressor"。
print_mem() {
  local total page vs free cached compressed available used used_pct
  total=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
  vs=$(vm_stat 2>/dev/null)
  page=$(printf '%s\n' "$vs" | sed -n 's/.*page size of \([0-9]*\) bytes.*/\1/p')
  [ -z "$page" ] && page=$PAGE_SIZE
  # 取 vm_stat 指定项的页数（行首匹配，去掉末尾句点与非数字）
  gp() { printf '%s\n' "$vs" | awk -F: -v k="$1" 'index($0,k)==1{gsub(/[^0-9]/,"",$2); print $2+0; exit}'; }
  local pf pi pp pa ps pw pc
  pf=$(gp "Pages free");                    [ -z "$pf" ] && pf=0
  pi=$(gp "Pages inactive");                [ -z "$pi" ] && pi=0
  pp=$(gp "Pages purgeable");               [ -z "$pp" ] && pp=0
  pa=$(gp "Pages active");                  [ -z "$pa" ] && pa=0
  ps=$(gp "Pages speculative");             [ -z "$ps" ] && ps=0
  pw=$(gp "Pages wired down");              [ -z "$pw" ] && pw=0
  pc=$(gp "Pages occupied by compressor");  [ -z "$pc" ] && pc=0
  free=$(( pf * page ))
  cached=$(( (pi + pp) * page ))
  compressed=$(( pc * page ))
  used=$(( (pa + ps + pw + pc) * page ))
  [ "$used" -lt 0 ] && used=0
  [ "$used" -gt "$total" ] && used=$total
  available=$(( total - used ))
  [ "$total" -gt 0 ] && used_pct=$(( used * 100 / total )) || used_pct=0
  printf "内存 总=%s  已用=%s (%s%%)  可用=%s\n" \
    "$(hr_bytes "$total")" "$(hr_bytes "$used")" "$used_pct" "$(hr_bytes "$available")"
  printf "  细分: 空闲 %s · 可回收缓存 %s · 被压缩 %s\n" \
    "$(hr_bytes "$free")" "$(hr_bytes "$cached")" "$(hr_bytes "$compressed")"
}

print_status() {
  printf "%-18s %-9s %-6s %-10s %-12s %-6s\n" "MODEL" "TYPE" "PORT" "STATE" "RSS" "%MEM"
  printf "%-18s %-9s %-6s %-10s %-12s %-6s\n" "-----" "----" "----" "-----" "---" "----"
  local total=0 pfree rss_kb rss_b pct
  total=$(sysctl -n hw.memsize 2>/dev/null || echo 1)
  local name typ port st rss_col pct_col color
  for name in "${MODELS[@]}"; do
    typ=$(mt_type "$name"); port=$(mt_port "$name"); st=$(model_state "$name")
    rss_kb=$(model_rss_kb "$name"); rss_b=$(( rss_kb * 1024 ))
    [ "$total" -gt 0 ] && pct=$(( rss_b * 100 / total )) || pct=0
    rss_col=$(hr_bytes "$rss_b"); pct_col="${pct}%"
    case "$st" in
      running)  color=$C_RUN ;;
      loading)  color=$C_LOAD ;;
      *)        color=$C_OFF ;;
    esac
    printf "%-18s %-9s %-6s ${color}%-10s${C_RST} %-12s %-6s\n" \
      "$name" "$typ" "$port" "$st" "$rss_col" "$pct_col"
    # oMLX 在运行时，展开其内部模型
    if [ "$name" = "omlx" ] && [ "$st" = "running" ]; then
      local ids; ids=$(curl -s --noproxy '*' --max-time 3 http://127.0.0.1:8000/v1/models 2>/dev/null \
        | grep -o '"id":"[^"]*"' | sed 's/"id":"//;s/"//')
      local id; for id in $ids; do printf "    └ %s\n" "$id"; done
    fi
  done
  echo
  print_mem
}

# ----------------------------- 命令分发 --------------------------------------
cmd_start() {
  local no_models=0
  [ "${1:-}" = "--no-models" ] && no_models=1
  echo "==> 启动 DSH 全套服务"
  # --no-models = 只起 DSH Web，不拉任何模型后端（省内存）
  # （旧实现里 oMLX 是无条件启动的，导致"轻量模式"照样拉起 5GB 的 oMLX，与文档不符）
  if [ "$no_models" -eq 0 ]; then
    start_omlx
    start_llamacpp "$DEFAULT_LLAMA"
  fi
  start_dsh
  echo "==> 等待就绪 ..."
  if [ "$no_models" -eq 0 ]; then
    wait_running omlx
    wait_running "$DEFAULT_LLAMA"
  fi
  sleep 2
  if dsh_web_running; then
    echo "  ✓ DSH Web 就绪 (http://127.0.0.1:${DSH_WEB_PORT})"
  else
    echo "  ✗ DSH Web 未起来，看 /tmp/dsh-web.log"
  fi
  echo "==> 当前状态:"; print_status
}

cmd_stop() {
  echo "==> 停止全部"
  stop_dsh
  local name; for name in "${MODELS[@]}"; do stop_model "$name"; done
  echo "==> 完成"
}

cmd_load() {
  local name="${1:-}" rc=0
  is_registered "$name" || { echo "✗ 未知模型: $name（用 'models' 查看）"; exit 1; }
  echo "==> 加载 $name"
  case "$(mt_type "$name")" in
    omlx)     start_omlx || rc=1 ;;
    llamacpp) start_llamacpp "$name" || rc=1 ;;
  esac
  if [ "$rc" -ne 0 ]; then
    echo "==> 加载 $name 失败"
    return 1
  fi
  wait_running "$name"
  echo "==> 当前状态:"; print_status
}

cmd_unload() {
  local name="${1:-}"
  is_registered "$name" || { echo "✗ 未知模型: $name（用 'models' 查看）"; exit 1; }
  echo "==> 停用 $name"
  stop_model "$name"
  echo "==> 当前状态:"; print_status
}

cmd_status() {
  if [ "${1:-}" = "--watch" ]; then
    while true; do
      clear; print_status; echo "[Ctrl-C 退出]"; sleep 4
    done
  else
    print_status
  fi
}

cmd_models() {
  echo "已注册模型:"
  local name; for name in "${MODELS[@]}"; do
    printf "  %-18s %-9s :%-5s %s\n" "$name" "$(mt_type "$name")" "$(mt_port "$name")" "$(mt_desc "$name")"
  done
  echo; echo "默认随 start 拉起的 GGUF: $DEFAULT_LLAMA"
}

# 单独启停 DSH Web（不碰任何模型后端）
# 供菜单栏应用 / 需要精确控制的场景调用；此前只有 stop 会连带停掉所有模型。
cmd_web() {
  case "${1:-}" in
    start)
      echo "==> 启动 DSH Web (:${DSH_WEB_PORT})"
      start_dsh
      sleep 2
      if dsh_web_running; then
        echo "  ✓ DSH Web 就绪 (http://127.0.0.1:${DSH_WEB_PORT})"
      else
        echo "  ✗ DSH Web 未起来，看 /tmp/dsh-web.log"
        return 1
      fi ;;
    stop)
      echo "==> 停止 DSH Web"
      stop_dsh ;;
    *)
      echo "用法: $0 web start|stop"
      exit 1 ;;
  esac
}

# 输出 oMLX 当前真正常驻在内存里的模型。
# 注意：/v1/models 只回「可服务清单」（目录里有哪些模型），并非「常驻清单」；
# 这里解析 oMLX 引擎池的 Loaded/Unloaded 配对事件，反推此刻谁在 RAM 里。
cmd_omlx_resident() {
  local log="/tmp/omlx_server.log"
  [ -f "$log" ] || { echo none; return 0; }
  awk '
    /Loaded model: / {
      s = $0; sub(/.*Loaded model: /, "", s); sub(/ \(.*/, "", s); st[s] = "loaded"
    }
    /Unloaded model: / {
      s = $0; sub(/.*Unloaded model: /, "", s); sub(/,.*/, "", s); st[s] = "unloaded"
    }
    END {
      any = 0
      for (m in st) if (st[m] == "loaded") { print m; any = 1 }
      if (any == 0) print "none"
    }
  ' "$log"
}

# 扫描 oMLX 模型目录，输出「模型名|权重GB」。
# 目的：模型清单不再写死——增删模型后自动反映；
#      权重大小是实测磁盘文件（.safetensors/.npz/.bin），不靠名字猜。
# 注意：这是权重下限，加载后实际常驻还会叠加 KV cache / 运行时开销。
cmd_omlx_scan() {
  local dir="$OMLX_MODELS_DIR"
  [ -d "$dir" ] || return 0
  for d in "$dir"/*/; do
    [ -d "$d" ] || continue
    local name; name=$(basename "$d")
    local bytes
    bytes=$(find "$d" -type f \( -name "*.safetensors" -o -name "*.npz" -o -name "*.bin" \) \
          -exec stat -f%z {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
    [ "${bytes:-0}" -gt 0 ] 2>/dev/null || continue
    awk -v n="$name" -v b="$bytes" 'BEGIN {printf "%s|%.2f\n", n, b/1073741824}'
  done
}

# 输出所有注册模型的权重大小（name|GB）。
# 包括 llamacpp 的 GGUF 和 oMLX 子模型目录；增删文件后自动更新。
cmd_model_weights() {
  local name gguf bytes
  # llamacpp GGUF
  for name in qwen3-8b-ablit qwen3-14b-ablit; do
    gguf=$(mt_gguf "$name")
    if [ -f "$GGUF_DIR/$gguf" ]; then
      bytes=$(stat -f%z "$GGUF_DIR/$gguf" 2>/dev/null)
      if [ "${bytes:-0}" -gt 0 ] 2>/dev/null; then
        awk -v n="$name" -v b="$bytes" 'BEGIN {printf "%s|%.2f\n", n, b/1073741824}'
      fi
    fi
  done
  # oMLX 子模型
  cmd_omlx_scan
}

# 把指定本地模型配置为 DeepSeekHarness(DSH Web) 的默认模型。
# 步骤：先探测 DSH Web 端口（确认服务装在哪）→ 解析模型所属 provider →
#       行级改写 settings.yaml 的 agent-default-model（保留注释，不整体 dump）。
# 模型需已在 llm-pi-ai.providers 中注册；本命令只负责“设为默认/切换”。
cmd_config_harness() {
  local model_id="${1:-}"
  local py; py="$(pybin)"
  # 1) 探测 DSH Web 端口
  local port; port="$(detect_dsh_port)"
  if [ -n "$port" ]; then
    echo "  ✓ DSH Web 监听在 :$port"
  else
    echo "  ⚠ 未探测到 DSH Web 监听端口（配置仍会写入，但 Harness 需先启动才生效）"
    port="$DSH_WEB_PORT"
  fi
  # 2) 解析目标模型（未指定则用 oMLX 当前常驻，再退化到 9B）
  if [ -z "$model_id" ]; then
    model_id="$(cmd_omlx_resident | head -1)"
    [ -z "$model_id" ] || [ "$model_id" = "none" ] && model_id="Qwen3.5-9B-MLX-4bit"
  fi
  echo "  目标模型: $model_id"
  local settings="$HOME/.dsh/settings.yaml"
  [ -f "$settings" ] || { echo "✗ 找不到 $settings"; exit 1; }
  # 3) 行级改写 agent-default-model（保留其余注释/结构）
  "$py" - "$settings" "$model_id" <<'PYEOF'
import sys, yaml, re
path, model_id = sys.argv[1], sys.argv[2]
text = open(path, encoding='utf-8').read()
doc = yaml.safe_load(text)
prov_root = (doc.get('llm-pi-ai') or {}).get('providers', {}) or {}
# 解析目标：先精确匹配 model id，再退化为子串模糊匹配（忽略大小写），
# 这样网页传 'qwen3-14b-ablit' 也能命中 settings 里的 'Qwen3-14B-abliterated.Q4_K_M'。
target_prov, target_id, low = None, None, model_id.lower()
for prov, cfg in prov_root.items():
    for m in (cfg.get('models') or []):
        mid = m.get('id', '')
        if mid == model_id or low in mid.lower() or low in (m.get('name', '') or '').lower():
            target_prov, target_id = prov, mid
            break
    if target_prov:
        break
if not target_prov:
    avail = [m['id'] for p in prov_root.values() for m in (p.get('models') or [])]
    print("✗ 模型 %s 未在 settings.yaml 任何 provider 注册" % model_id)
    print("  已注册:", avail)
    sys.exit(2)
print("  所属 provider:", target_prov, " model:", target_id)
lines = text.split('\n')
out, replaced = [], False
i = 0
while i < len(lines):
    line = lines[i]
    if line.strip().startswith('agent-default-model:'):
        out.append(line)
        if i + 1 < len(lines) and 'provider:' in lines[i + 1]:
            out.append(re.sub(r'provider:.*', 'provider: %s' % target_prov, lines[i + 1]))
            i += 2
            if i < len(lines) and 'model:' in lines[i]:
                out.append(re.sub(r'model:.*', 'model: %s' % target_id, lines[i]))
                i += 1
            replaced = True
            continue
    out.append(line)
    i += 1
if not replaced:
    print("✗ 未找到 agent-default-model 块"); sys.exit(3)
open(path, 'w', encoding='utf-8').write('\n'.join(out))
print("  ✓ 已将 %s 设为 DeepSeekHarness 默认模型 (provider=%s)" % (target_id, target_prov))
PYEOF
}

# 把指定本地模型生成一份可直接复制到 WorkBuddy「添加模型」对话框的文本。
# WorkBuddy 不把这些配置落盘成可写文件，所以做成「生成→复制→粘贴」半自动。
cmd_config_workbuddy() {
  local model_id="${1:-}"
  local py; py="$(pybin)"
  if [ -z "$model_id" ]; then
    model_id="$(cmd_omlx_resident | head -1)"
    [ -z "$model_id" ] || [ "$model_id" = "none" ] && model_id="Qwen3.5-9B-MLX-4bit"
  fi
  echo "  目标模型: $model_id"
  local settings="$HOME/.dsh/settings.yaml"
  [ -f "$settings" ] || { echo "✗ 找不到 $settings"; exit 1; }
  "$py" - "$settings" "$model_id" <<'PYEOF'
import sys, yaml
path, model_id = sys.argv[1], sys.argv[2]
doc = yaml.safe_load(open(path, encoding='utf-8'))
prov_root = (doc.get('llm-pi-ai') or {}).get('providers', {}) or {}
low = model_id.lower()
target_id, endpoint = None, None
# 1) 优先从 settings.yaml 读取 base_url + model id
for prov, cfg in prov_root.items():
    url = cfg.get('base_url') or cfg.get('baseURL') or ''
    for m in (cfg.get('models') or []):
        mid = m.get('id', '')
        if mid == model_id or low in mid.lower() or low in (m.get('name', '') or '').lower():
            target_id, endpoint = mid, url.rstrip('/') + '/chat/completions'
            break
    if target_id:
        break
# 2) 兜底：用已知的本地端口与模型名
if not target_id:
    def fallback(e, m):
        global target_id, endpoint
        target_id, endpoint = m, e
    if 'qwen3-14b' in low or low == 'qwen3-14b-ablit':
        fallback('http://127.0.0.1:8002/v1/chat/completions', 'Qwen3-14B-abliterated.Q4_K_M')
    elif 'qwen3-8b' in low or low == 'qwen3-8b-ablit':
        fallback('http://127.0.0.1:8001/v1/chat/completions', 'Qwen3-8B-abliterated-v2.Q4_K_M')
    elif 'hermes' in low:
        fallback('http://127.0.0.1:8000/v1/chat/completions', 'Hermes-4-14B-4bit')
    elif '4b' in low:
        fallback('http://127.0.0.1:8000/v1/chat/completions', 'Qwen3.5-4B-MLX-4bit')
    else:
        fallback('http://127.0.0.1:8000/v1/chat/completions', 'Qwen3.5-9B-MLX-4bit')
print("""WorkBuddy 本地模型配置（自定义 / Custom）
========================================
提供商：自定义 / Custom
接口地址：%s
API Key：local（本地无需鉴权）
模型名称：%s
工具调用：✅
图片输入：☐
推理模式：☐
========================================
复制后打开 WorkBuddy → 设置 → 模型 → 添加模型 → 自定义，粘贴保存即可。
""" % (endpoint, target_id))
PYEOF
}

cmd_help() {
  awk 'NR<3{next} /可配置项/{exit} {sub(/^# ?/,""); print}' "$0"
}

# ----------------------------- 入口 ------------------------------------------
case "${1:-help}" in
  start)   shift; cmd_start "$@" ;;
  stop)    cmd_stop ;;
  web)     shift; cmd_web "$@" ;;
  load)    shift; cmd_load "$@" ;;
  unload)  shift; cmd_unload "$@" ;;
  status)  shift; cmd_status "$@" ;;
  mem)     print_mem ;;
  models)  cmd_models ;;
  omlx_resident) cmd_omlx_resident ;;
  omlx_scan) cmd_omlx_scan ;;
  model_weights) cmd_model_weights ;;
  config-harness) shift; cmd_config_harness "$@" ;;
  config-workbuddy) shift; cmd_config_workbuddy "$@" ;;
  help|-h|--help) cmd_help ;;
  *) echo "未知命令: $1"; echo "运行 '$0 help' 查看用法"; exit 1 ;;
esac
