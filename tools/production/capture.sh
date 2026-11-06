#!/usr/bin/env bash
# studio.capture 壳：调 Godot Movie Maker 把资产出成 25fps alpha PNG 序列（spec §3.4）。
#
# 用法：
#   tools/production/capture.sh <assetId> <机位> <动作> [时长秒] [-- 附加参数]
# 例：
#   tools/production/capture.sh conc_task_board iso idle 3.0
#   tools/production/capture.sh agent_model_well close spin 8.0   # 慢速旋转展示（转满一圈）
#   tools/production/capture.sh conc_task_board iso run 5.0 -- --task-text=任务 L1：给它接第一件活
#
# 产物：assets/<assetId>/<机位>_<动作>/frame00000.png ...（1920×1080，带 alpha）
# 需要 windowed 跑（headless 是 dummy 渲染器，出不了 PNG）；会短暂弹窗。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GODOT="${GODOT:-$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe}"

if [[ ! -f "$GODOT" ]]; then
  echo "找不到 Godot 引擎：$GODOT" >&2
  exit 2
fi

# POSIX 路径 /d/foo/bar -> D:/foo/bar（Git Bash）；Windows 形式原样通过。
# （不用 wslpath/cygpath：本机 wslpath 指向 Anaconda 的坏 cygpath，见 run_bench.sh）
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

ASSET="${1:?用法: capture.sh <assetId> <机位> <动作> [时长秒]}"
SHOT="${2:?缺机位（iso/front/top/close/vista）}"
ACTION="${3:?缺动作（idle/run/open/close/fail/spin）}"
DURATION="${4:-3.0}"
shift 3 || true
if (( $# > 0 )); then shift; fi   # 丢掉时长参数，剩余作为附加参数透传
EXTRA=()
for a in "$@"; do [[ "$a" == "--" ]] || EXTRA+=("$a"); done   # 剥掉多余的分隔符

# 产物索引目录：默认 assets/<assetId>/<机位>_<动作>/（PNG 已 gitignore）。
# 非资产库件（如 component_catalog 现搭的工坊件）用 OUT_ROOT 改道到
# game/shots/ 下，免得在 assets/ 里留下 validate_assets.py 要的 asset.yaml 缺项。
GAME="$(win_path "$ROOT/game")"
OUT="${OUT_ROOT:-$ROOT/assets/$ASSET/${SHOT}_${ACTION}}"
mkdir -p "$OUT"
rm -f "$OUT"/frame*.png "$OUT"/*.wav   # Movie Writer 会写空音轨 wav，一并清掉

# project.godot 是 1280×720 且不许改；用 Godot 标准 override.cfg 临时钉成
# 1920×1080 + 逐像素透明（Forward+ 下窗口无透明面时 alpha 通道会全 255），
# 跑完立刻删（trap 兜底），不碰 project.godot 本体（做法与 run_bench.sh 5b 一致）。
OVERRIDE="$ROOT/game/override.cfg"
cleanup() { rm -f "$OVERRIDE"; }
trap cleanup EXIT
{
  printf '[display]\n\n'
  printf 'window/size/viewport_width=1920\n'
  printf 'window/size/viewport_height=1080\n'
  printf 'window/per_pixel_transparency/allowed=true\n'
  printf '\n[rendering]\n\n'
  printf 'viewport/transparent_background=true\n'
} > "$OVERRIDE"

START=$(date +%s.%N)
"$GODOT" --path "$GAME" --resolution 1920x1080 --fixed-fps 25 \
  --write-movie "$(win_path "$OUT/frame.png")" \
  -s res://scripts/studio/capture.gd -- \
  --asset="$ASSET" --shot="$SHOT" --action="$ACTION" --duration="$DURATION" "${EXTRA[@]}"
cleanup
trap - EXIT
rm -f "$OUT"/*.wav   # Movie Writer 退出时写空音轨 wav，跑完清掉
END=$(date +%s.%N)

FILES=("$OUT"/frame*.png)
if (( ${#FILES[@]} == 0 )); then
  echo "FAIL：$OUT 没有产出 PNG" >&2
  exit 1
fi
BYTES=$(du -cb "${FILES[@]}" | tail -1 | cut -f1)
echo "CAPTURE 壳：${#FILES[@]} 帧 / $BYTES B / $(awk "BEGIN{printf \"%.1f\", $END-$START}")s → $OUT"
