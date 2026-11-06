#!/usr/bin/env bash
# 微课生产管线最小闭环（spec §8）：capture → layers → tts → compose → validate。
# 产出 e49 的一个 3 秒真片段作为管线贯通证据（五关视频的占位升级路径）。
#
# 用法（Git Bash）：bash tools/production/run_all.sh
# Godot 捕获在 Windows 侧（要窗口渲染），图层/配音/合成/校验在 WSL python 侧。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EP="${EP:-e49}"
FPS=25
DURATION=3

# Git Bash 的 /d/foo → WSL 的 /mnt/d/foo（按实际盘符转）
wsl_root() {
  local p="$1"
  case "$p" in
    /?/*) echo "/mnt/${p:1:1}/${p:3}" ;;
    *) echo "$p" ;;
  esac
}
WROOT="$(wsl_root "$(cd "$ROOT" && pwd)")"

T_TOTAL0=$(date +%s.%N)
step_time() { # 打印一步耗时
  local name="$1" t0="$2"
  awk "BEGIN{printf \"%s 用时 %.1fs\n\", \"$name\", $(date +%s.%N) - $t0}"
}

echo "=== 1/5 studio.capture：conc_task_board iso idle ${DURATION}s（alpha PNG 序列）==="
T0=$(date +%s.%N)
bash "$ROOT/tools/production/capture.sh" conc_task_board iso idle "$DURATION" \
  -- --task-text=任务 L1：给它接第一件活
step_time "capture" "$T0"

echo
echo "=== 2/5 图层渲染：layers/$EP（HTML → 透明 PNG）==="
T0=$(date +%s.%N)
wsl -e bash -c "cd '$WROOT' && python3 tools/production/render_layers.py --episode $EP"
step_time "layers" "$T0"

echo
echo "=== 3/5 配音：edge-tts 一句开场白 → layers/$EP/voiceover.mp3 ==="
T0=$(date +%s.%N)
wsl -e bash -c "cd '$WROOT' && bash tools/production/tts.sh '$EP' '${TTS_TEXT:-}'"
step_time "tts" "$T0"

echo
echo "=== 4/5 合成：compose/$EP/clip_task_board_intro.mp4（1080p/25fps/H.264）==="
T0=$(date +%s.%N)
wsl -e bash -c "cd '$WROOT' && python3 tools/production/compose_clip.py \
  --frames assets/conc_task_board/iso_idle \
  --layer layers/$EP/title.png --layer layers/$EP/progress.png \
  --layer layers/$EP/subtitle.png:0.5 \
  --audio layers/$EP/voiceover.mp3 --audio-delay 0.2 \
  --out compose/$EP/clip_task_board_intro.mp4 --duration $DURATION"
step_time "compose" "$T0"

echo
echo "=== 5/5 校验：五份集元数据 ==="
T0=$(date +%s.%N)
wsl -e bash -c "cd '$WROOT' && python3 tools/validate_episodes.py"
step_time "validate" "$T0"

echo
awk "BEGIN{printf \"全链总耗时 %.1fs（含 Godot 启动）\n\", $(date +%s.%N) - $T_TOTAL0}"
echo "产物："
ls -l "$ROOT/compose/$EP/clip_task_board_intro.mp4" | awk '{print "  mp4  " $5 " B  " $NF}'
echo "  PNG  $(ls "$ROOT/assets/conc_task_board/iso_idle/"frame*.png | wc -l) 帧 → assets/conc_task_board/iso_idle/"
