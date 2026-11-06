#!/usr/bin/env bash
# 第一课段1+段2 样片 v2（拉出特写版）：把镜 6/7/8 从 iso 静态插图换成
# 「组件透明底慢旋特写 + 右侧名字卡」，台词改为分镜稿 v4。产物 compose/w01/pilot_v2.mp4，
# **不覆盖** 旧 compose/w01/pilot.mp4。
#
# 五步固化本样片当时的散步骤（可整段重跑；每步都可单独跑，见 tools/production/README.md）：
#   ① 4 件工坊件 close spin 8 → game/shots/production/w01/<id>_spin/（Windows，弹窗）
#      ＋工坊全景 --shot 静帧重拍（工坊显示名已改 v4，旧静帧上的字牌是改名前的）
#   ② prep_plates.py 并集裁边 + 抽帧缩图 → game/shots/production/w01/plate/spin/<id>/
#   ③ build_narration.py --only s2,s5,s6,s7,s8（只重合成台词改过的镜，其余复用旧 mp3）
#   ④ render_frames.py HTML 逐帧 → compose/w01/pilot_v2.mp4
#
# 用法（Git Bash）：bash tools/production/build_w01_v2.sh
# 环境开关：SKIP_CAPTURE=1 跳过 ①（已有 spin 序列时）；ONLY=s2,s5,s6,s7,s8 覆盖 ③ 的重合成镜。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EPSHOT="game/shots/production/w01"
ASSETS=(agent_model_well agent_execution_table agent_tool_rack agent_observation_tray)
# 工坊件 close 取景会把工具架底部切出画面，故只给它多放一圈留白（其余件默认机位不切）
declare -A MARGIN=( [agent_tool_rack]=1.3 )
ONLY="${ONLY:-s2,s5,s6,s7,s8}"

# Git Bash 的 /d/foo → WSL 的 /mnt/d/foo（按实际盘符转）；→ Windows 的 D:/foo（给 Godot 壳）
wsl_root() { case "$1" in /?/*) echo "/mnt/${1:1:1}/${1:3}" ;; *) echo "$1" ;; esac; }
win_root() { case "$1" in /?/*) echo "${1:1:1^^}:/${1:3}" ;; *) echo "$1" ;; esac; }
WROOT="$(wsl_root "$(cd "$ROOT" && pwd)")"
WROOT_WIN="$(win_root "$(cd "$ROOT" && pwd)")"

if [[ "${SKIP_CAPTURE:-0}" != "1" ]]; then
  echo "=== 1/4 studio.capture：4 件 close spin 8（透明底慢旋，Windows 弹窗）==="
  for id in "${ASSETS[@]}"; do
    extra=()
    [[ -n "${MARGIN[$id]:-}" ]] && extra=(-- "--margin=${MARGIN[$id]}")
    OUT_ROOT="$WROOT_WIN/$EPSHOT/${id}_spin" \
      bash "$ROOT/tools/production/capture.sh" "$id" close spin 8 "${extra[@]}"
  done
  echo "--- 工坊全景静帧（镜 2/5 底片）---"
  "$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe" --path "$WROOT_WIN/game" --resolution 2560x1440 \
    -- --shot --out=res://shots/production/w01/studio_page0.png
else
  echo "=== 1/4 跳过 capture（SKIP_CAPTURE=1）==="
fi

echo
echo "=== 2/4 prep_plates：并集裁边 + 抽帧缩图 → $EPSHOT/plate/spin/ ==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/prep_plates.py --episode w01"

echo
echo "=== 3/4 build_narration：--only $ONLY（其余镜复用旧 mp3 + 词级 cue）==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/build_narration.py --episode w01 --only '$ONLY'"

echo
echo "=== 4/4 render_frames：① 段1+段2 → compose/w01/pilot_v2.mp4 ==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/render_frames.py --episode w01 \
  --encode compose/w01/pilot_v2.mp4 --audio layers/w01/narration.wav"

echo
echo "产物：compose/w01/pilot_v2.mp4（旧 compose/w01/pilot.mp4 未动）"
ls -l "$ROOT/compose/w01/"*.mp4 | awk '{print "  " $5 " B  " $NF}'
