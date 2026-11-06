#!/usr/bin/env bash
# 第一课段1+段2 样片 v3（高中档语体 + 抓出式画面）：八镜台词整体换新稿重配，
# 镜 2 弃工坊全景、改「报告面板＋结果文件卡」纯 HTML 道具抓出，镜 5 改四件组件
# 透明底插图依次飞入落位一行舞台。产物 compose/w01/pilot_v3.mp4，
# **不覆盖** 旧 compose/w01/pilot.mp4 / pilot_v2.mp4。
#
# 与 build_w01_v2.sh 的差别：
#   - 八镜台词全改 → 配音不做 --only（全量重合成，词级 cue 一并刷新）；
#   - 3D 素材沿用 v2 已捕获的 spin/iso 序列（game/shots/production/w01/ 下的
#     *_spin/ 与 *_iso/ raw 目录），本脚本不重拍——prep_plates.py 从 raw 目录
#     可再生 plate/ 产物；若 raw 目录已被清理，先重跑 build_w01_v2.sh 的步骤 ①。
#
# 用法（Git Bash）：bash tools/production/build_w01_v3.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Git Bash 的 /d/foo → WSL 的 /mnt/d/foo（按实际盘符转）
wsl_root() { case "$1" in /?/*) echo "/mnt/${1:1:1}/${1:3}" ;; *) echo "$1" ;; esac; }
WROOT="$(wsl_root "$ROOT")"

echo "=== 1/3 prep_plates：并集裁边 + 抽帧缩图 → game/shots/production/w01/plate/ ==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/prep_plates.py --episode w01"

echo
echo "=== 2/3 build_narration：八镜台词全量重合成（v3 新稿，无 --only）==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/build_narration.py --episode w01"

echo
echo "=== 3/3 render_frames：段1+段2 → compose/w01/pilot_v3.mp4 ==="
wsl -e bash -c "cd '$WROOT' && python3 tools/production/render_frames.py --episode w01 \
  --encode compose/w01/pilot_v3.mp4 --audio layers/w01/narration.wav"

echo
echo "产物：compose/w01/pilot_v3.mp4（旧 pilot.mp4 / pilot_v2.mp4 未动）"
ls -l "$ROOT/compose/w01/"*.mp4 | awk '{print "  " $5 " B  " $NF}'
