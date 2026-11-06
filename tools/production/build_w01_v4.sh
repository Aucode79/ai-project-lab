#!/usr/bin/env bash
# 第一课样片 v4（开头重制：不介绍四件组件，只讲 Agent 总体）：八镜台词全新、配音全量重合成，
# 画面 scenes/w01_intro/index.html 重做镜 2–8（课题卡沿用 v3），产物 compose/w01/pilot_v4.mp4，
# **不覆盖** 旧 compose/w01/pilot.mp4 / pilot_v2.mp4 / pilot_v3.mp4。
#
# 与 build_w01_v3.sh 的差别：
#   - 台词换 v4 新稿（见 data/w01_shots.json 的 line，本文件为逐字真源）→ 配音不做 --only，全量重合成；
#   - 画面重做：镜 2「给目标 + 三能力图标点亮」、镜 3「只会说 vs 还会动手」、镜 4「四件组件拼整机 +
#     循环箭头」（组件无名牌）、镜 5/6 沿用 v3 的 report.txt/out.txt 抓出实现、镜 7/8 行动卡与「想 ≠ 做」；
#   - 3D 素材沿用 game/shots/production/w01/plate/ 既有底板（镜 4 用四件组件 iso 插图），本脚本不重拍。
#     若 raw 目录（game/shots/production/w01/*_iso/）已被清理，先重跑 build_w01_v2.sh 的步骤 ① 再 prep_plates.py。
#
# 用法（Git Bash）：bash tools/production/build_w01_v4.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Git Bash 的 /d/foo → WSL 的 /mnt/d/foo（按实际盘符转）
wsl_root() { case "$1" in /?/*) echo "/mnt/${1:1:1}/${1:3}" ;; *) echo "$1" ;; esac; }
WROOT="$(wsl_root "$ROOT")"

echo "=== 1/2 build_narration：八镜 v4 新稿全量重合成（无 --only）==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/build_narration.py --episode w01"

echo
echo "=== 2/2 render_frames：段1 八镜 → compose/w01/pilot_v4.mp4 ==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/render_frames.py --episode w01 \
  --encode compose/w01/pilot_v4.mp4 --audio layers/w01/narration.wav"

echo
echo "产物：compose/w01/pilot_v4.mp4（旧 pilot.mp4 / pilot_v2.mp4 / pilot_v3.mp4 未动）"
ls -l "$ROOT/compose/w01/"*.mp4 | awk '{print "  " $5 " B  " $NF}'
