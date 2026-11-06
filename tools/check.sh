#!/usr/bin/env bash
# 无头自检：验证视觉 spike 场景能完整搭起来。退出码 0 = PASS。
# 用法：tools/check.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe}"

if [[ ! -f "$GODOT" ]]; then
  echo "找不到 Godot 引擎：$GODOT" >&2
  echo "从 https://godotengine.org/download/windows/ 下载 4.7.2 标准版，解压到 tools/godot/ 即可。" >&2
  exit 2
fi

if [[ "$(uname -s)" == Linux* ]]; then
  GAME_WIN="$(wslpath -w "$ROOT/game")"    # WSL bash
else
  GAME_WIN="$(cd "$ROOT/game" && pwd -W)"  # Git Bash / MSYS：直接给 Windows 形式路径
fi
"$GODOT" --headless --path "$GAME_WIN" scenes/main.tscn -- --check
