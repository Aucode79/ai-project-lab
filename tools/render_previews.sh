#!/usr/bin/env bash
# 渲染量化版预览：五关 + 沙盒各出一张 1920x1080 PNG（会短暂弹窗，图形管线需真渲染）。
# 用法：tools/render_previews.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe}"
[[ -f "$GODOT" ]] || { echo "找不到 Godot：$GODOT" >&2; exit 2; }
GAME_WIN="$(cd "$ROOT/game" && pwd -W)"
for s in l1 l2 l3 l4 l5; do
  "$GODOT" --path "$GAME_WIN" scenes/levels/$s/$s.tscn --resolution 1920x1080 -- --shot
  echo "OK  game/tests/levels/$s/${s}_preview.png"
done
"$GODOT" --path "$GAME_WIN" scenes/sandbox/sandbox.tscn --resolution 1920x1080 -- --shot
echo "OK  game/tests/sandbox/sandbox_preview.png"
