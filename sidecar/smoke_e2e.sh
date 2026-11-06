#!/usr/bin/env bash
# 端到端冒烟：headless Godot（McpBridge 监听 7310）+ MCP sidecar + 裸 JSON-RPC 客户端。
#
#   Godot(Windows) <--TCP 7310-- sidecar server <--stdio MCP-- smoke_client.py
#
# 在 WSL 里跑：bash sidecar/smoke_e2e.sh   （退出码 0 = 冒烟通过）
#
# 网络坑位：WSL2 NAT 模式下 WSL -> Windows 的 127.0.0.1 入站被防火墙拦。
# 脚本先探测 WSL 直连是否可行（mirrored 网络的机器可以）；
# 不行则整套 python 链路（客户端 + sidecar server）退到 Windows 侧的
# sidecar/.venv-win 跑（按需创建并装 mcp），TCP 走 Windows 本机回环。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIDECAR="$ROOT/sidecar"
GODOT="${GODOT:-$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe}"
BRIDGE_PORT="${GODOT_BRIDGE_PORT:-7310}"
WIN_PY="/mnt/c/ProgramData/Anaconda3/python.exe"
VENV_WIN="$SIDECAR/.venv-win"
VENV_WIN_PY="$VENV_WIN/Scripts/python.exe"
PIP_MIRROR="-i https://pypi.tuna.tsinghua.edu.cn/simple"

log() { echo "[smoke] $*"; }
die() { echo "[smoke] FAIL: $*" >&2; exit 1; }

if [[ ! -f "$GODOT" ]]; then
  die "找不到 Godot：$GODOT"
fi
mkdir -p "$SIDECAR/workspace"

# ---------- 清理 ----------

GODOT_PID=""
cleanup() {
  if [[ -n "$GODOT_PID" ]]; then
    kill "$GODOT_PID" 2>/dev/null || true
    sleep 1
  fi
  # 控制台 exe 可能留下真正的引擎子进程：按端口精确清（不碰别的 Godot 实例）
  for port in "$BRIDGE_PORT" 7395; do
    local winpid
    winpid="$(netstat.exe -ano 2>/dev/null | awk -v p=":$port" '$2 ~ p"$" && $4 == "LISTENING" {print $5; exit}')" || true
    if [[ -n "${winpid:-}" ]]; then
      taskkill.exe //F //T //PID "$winpid" >/dev/null 2>&1 || true
    fi
  done
}
trap cleanup EXIT

# ---------- 1. 起 headless Godot（McpBridge autoload 监听 7310，被占退 7395） ----------

GAME_WIN="$(wslpath -w "$ROOT/game")"
log "启动 headless Godot（桥监听 127.0.0.1:$BRIDGE_PORT）..."
"$GODOT" --headless --path "$GAME_WIN" >/tmp/smoke_godot.log 2>&1 &
GODOT_PID=$!

# ---------- 2. 等桥端口可达（Windows 回环侧探测） ----------

wait_port_windows() {
  local port="$1" tries="${2:-120}"
  "$WIN_PY" - "$port" "$tries" <<'PYEOF'
import socket, sys, time
port, tries = int(sys.argv[1]), int(sys.argv[2])
for _ in range(tries):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1.0):
            print("open"); sys.exit(0)
    except OSError:
        time.sleep(1.0)
sys.exit(1)
PYEOF
}

if ! wait_port_windows "$BRIDGE_PORT" 120; then
  if ! wait_port_windows 7395 10; then
    die "Godot 桥 120s 内没监听（日志见 /tmp/smoke_godot.log）"
  fi
  BRIDGE_PORT=7395
  log "7310 被占，桥退到备用口 $BRIDGE_PORT"
fi
log "桥端口 $BRIDGE_PORT 已监听"

# ---------- 3. 选 python 链路：WSL 直连可行就用 WSL venv，否则 Windows venv ----------

PY_PROBE="$(python3 - "$BRIDGE_PORT" <<'PYEOF'
import socket, sys
try:
    with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=1.5):
        print("wsl")
except OSError:
    print("win")
PYEOF
)"

if [[ ! -x "$SIDECAR/.venv/bin/python" ]]; then
  log "sidecar/.venv 不存在，先建（WSL venv，冒烟客户端/服务端之一）..."
  python3 -m venv "$SIDECAR/.venv"
  "$SIDECAR/.venv/bin/python" -m pip install -q $PIP_MIRROR -r "$SIDECAR/requirements.txt"
fi

if [[ "$PY_PROBE" == "wsl" ]]; then
  RUN_PY="$SIDECAR/.venv/bin/python"
  RUN_CWD="$SIDECAR"
  RUN_WS="$SIDECAR/workspace"
  SERVER_PY="$SIDECAR/.venv/bin/python"
  CLIENT_SCRIPT="$SIDECAR/smoke_client.py"
  log "WSL -> Windows 127.0.0.1 可达：整套链路用 WSL venv"
else
  log "WSL -> Windows 127.0.0.1 不通（NAT 防火墙）：链路退到 Windows venv"
  if [[ ! -f "$VENV_WIN_PY" ]]; then
    log "创建 Windows venv（.venv-win）..."
    "$WIN_PY" -m venv "$(wslpath -w "$VENV_WIN")"
  fi
  if ! "$VENV_WIN_PY" -c "import mcp" >/dev/null 2>&1; then
    log "给 Windows venv 装 mcp（清华源，一次性）..."
    "$VENV_WIN_PY" -m pip install -q $PIP_MIRROR "mcp>=1.2.0" \
      || die "Windows venv 装依赖失败（网络？）"
  fi
  RUN_PY="$VENV_WIN_PY"
  RUN_CWD="$(wslpath -w "$SIDECAR")"
  RUN_WS="$(wslpath -w "$SIDECAR/workspace")"
  SERVER_PY="$(wslpath -w "$VENV_WIN_PY")"
  CLIENT_SCRIPT="$(wslpath -w "$SIDECAR/smoke_client.py")"
fi

# ---------- 4. 跑客户端（stdio MCP -> sidecar -> TCP 桥 -> Godot） ----------

log "python 链路：client=$RUN_PY server=$SERVER_PY port=$BRIDGE_PORT"
"$RUN_PY" "$CLIENT_SCRIPT" \
  --server-python "$SERVER_PY" \
  --cwd "$RUN_CWD" \
  --workspace "$RUN_WS" \
  --port "$BRIDGE_PORT"

# 冒烟产物即弃（证据已在日志里；workspace 不留杂物）
rm -f "$SIDECAR/workspace/smoke.txt"

log "SMOKE PASS"
