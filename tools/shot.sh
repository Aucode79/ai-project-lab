#!/usr/bin/env bash
# 截图：渲染若干帧后把画面存到 game/shots/world.png。
# 会短暂弹出窗口——图形管线（SDFGI / 体积雾 / Glow）在无头模式下不出图，必须真渲染。
# 用法：tools/shot.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe}"

if [[ ! -f "$GODOT" ]]; then
  echo "找不到 Godot 引擎：$GODOT" >&2
  exit 2
fi

if [[ "$(uname -s)" == Linux* ]]; then
  GAME_WIN="$(wslpath -w "$ROOT/game")"    # WSL bash
else
  GAME_WIN="$(cd "$ROOT/game" && pwd -W)"  # Git Bash / MSYS：直接给 Windows 形式路径
fi
"$GODOT" --path "$GAME_WIN" -- --shot

SHOT="$ROOT/game/shots/world.png"
if [[ -f "$SHOT" ]]; then
  echo "OK  $SHOT  ($(stat -c%s "$SHOT") bytes)"
else
  echo "FAIL 没有产出截图" >&2
  exit 1
fi
