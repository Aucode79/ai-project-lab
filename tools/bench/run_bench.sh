#!/usr/bin/env bash
# 一键复跑四个测量（docs/20-验收/测量结果.md 的数字来源，全部可复跑）。
#
# 用法：
#   bash tools/bench/run_bench.sh                # 全部（渲染测量会短暂弹窗，1920×1080）
#   bash tools/bench/run_bench.sh --skip-render  # 跳过慢的渲染测量（headless，约 1.5 分钟）
#
# 注意：不能用 wslpath/cygpath——本机 Git Bash 里的 wslpath 指向 Anaconda 的坏 cygpath。
# 路径统一自己转成 D:/ 正斜杠形式，Windows exe 直接认。

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe}"

# POSIX 路径 /d/foo/bar -> D:/foo/bar（单字符盘符）；Windows 形式原样通过
win_path() {
  local p="$1"
  case "$p" in
    [A-Za-z]:/*) echo "$p" ;;
    /?/*)
      local drive="${p:1:1}"
      echo "${drive^^}:/${p:3}"
      ;;
    *) echo "$p" ;;
  esac
}

if [[ ! -f "$GODOT" ]]; then
  echo "找不到 Godot 引擎：$GODOT" >&2
  echo "从 https://godotengine.org/download/windows/ 下载 4.7.2 标准版，解压到 tools/godot/。" >&2
  exit 2
fi

GAME="$(win_path "$ROOT/game")"
OUT="$ROOT/game/bench/out"
MOVIE="$OUT/movie"

step() { echo; echo "=== $1 ==="; }

expect_file() {
  if [[ ! -e "$1" ]]; then
    echo "FAIL 缺少产物：$1" >&2
    exit 1
  fi
}

prune_movie_samples() {
  # 场景无声音，Movie Writer 仍会写一个空音轨 wav，删掉
  rm -f "$MOVIE"/*.wav
  # PNG 序列只留样本（每 25 帧一帧 + 首尾帧），完整序列随时可重新生成
  local files=("$MOVIE"/*.png)
  if (( ${#files[@]} == 0 )); then
    echo "FAIL movie 目录没有 PNG 产出" >&2
    exit 1
  fi
  echo "Movie PNG 共 ${#files[@]} 帧（1920×1080），抽样保留每 25 帧与首尾帧（其余删除）"
  local i=0
  local n=${#files[@]}
  for f in "${files[@]}"; do
    i=$((i + 1))
    if (( (i - 1) % 25 == 0 || i == n )); then
      continue
    fi
    rm -f "$f"
  done
}

step "0/5 生成基准场景 tscn（工具脚本产出，不手写 uid）"
"$GODOT" --headless --path "$GAME" -s res://bench/gen_scene.gd
expect_file "$ROOT/game/bench/scenes/bench_world.tscn"

step "1/5 smoke（基准场景完整性自检）"
"$GODOT" --headless --path "$GAME" -s res://bench/bench_main.gd -- --mode=smoke

step "2/5 数四 · 物理引擎现状（默认引擎，50 刚体）"
"$GODOT" --headless --path "$GAME" -s res://bench/bench_main.gd -- --mode=physics
expect_file "$OUT/physics_report.json"

step "3/5 数二 · 烘焙耗时 + 轨道体积（studio.bake 最小原型）"
"$GODOT" --headless --path "$GAME" -s res://bench/bench_main.gd -- --mode=bake
expect_file "$OUT/bake_report.json"
if ! ls "$OUT/motion/"*.bin >/dev/null 2>&1; then
  echo "FAIL motion 目录没有 .bin 产出" >&2
  exit 1
fi

step "4/5 数三 · 落点前推预测成本（虚影）"
"$GODOT" --headless --path "$GAME" -s res://bench/bench_main.gd -- --mode=predict
expect_file "$OUT/predict_report.json"

if [[ "${1:-}" == "--skip-render" ]]; then
  echo
  echo "=== 5/5 渲染测量被 --skip-render 跳过（复跑请去掉该参数）==="
else
  step "5a/5 数一 · 纯渲染单帧耗时（1920×1080，关垂直同步，无写盘）"
  "$GODOT" --path "$GAME" --resolution 1920x1080 \
    res://bench/scenes/bench_world.tscn -- --mode=render-pure
  expect_file "$OUT/render_pure.json"

  step "5b/5 数一 · Movie Maker 单帧耗时（--write-movie PNG 序列，--fixed-fps 25，含写盘）"
  mkdir -p "$MOVIE"
  # Movie Writer 按 project 的 viewport 尺寸出片；project.godot 现为 1280×720 且不许改
  # （另一任务在编辑它）。用 Godot 标准的 override.cfg 机制临时改成 1920×1080，
  # 跑完立刻删（trap 兜底），不碰 project.godot 本体。
  OVERRIDE="$ROOT/game/override.cfg"
  cleanup_override() { rm -f "$OVERRIDE"; }
  trap cleanup_override EXIT
  printf '[display]\n\nwindow/size/viewport_width=1920\nwindow/size/viewport_height=1080\n' > "$OVERRIDE"
  "$GODOT" --path "$GAME" --resolution 1920x1080 --fixed-fps 25 \
    --write-movie "$(win_path "$MOVIE/bench.png")" \
    res://bench/scenes/bench_world.tscn -- --mode=render
  cleanup_override
  trap - EXIT
  expect_file "$OUT/render_movie.json"
  prune_movie_samples
fi

step "汇总（完整数字见以上 JSON；解读与判定见 docs/20-验收/测量结果.md）"
for f in "$OUT"/*.json; do
  echo "--- $f"
  cat "$f"
  echo
done
echo "OK 四个测量全部完成。"
