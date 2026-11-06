#!/usr/bin/env bash
# 安装 zylann.voxel 的 GDExtension 包（约 51MB，不入库）。
# 用法：tools/install_voxel.sh [tag]     默认 v1.7x
#
# 装完后必须让编辑器登记一次扩展，否则以 --script 直跑时类不存在：
#   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game --import
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TAG="${1:-v1.7x}"
URL="https://github.com/Zylann/godot_voxel/releases/download/${TAG}/GodotVoxelExtension.zip"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "下载 $URL"
curl -sL --max-time 600 -o "$TMP/voxel.zip" "$URL"
python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$TMP/voxel.zip" "$ROOT/game"

echo "已解压到 game/addons/zylann.voxel/（tag=$TAG）"
echo
echo "下一步（只做一次）：让编辑器登记扩展"
echo "  \"\$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe\" --headless --path game --import"
echo
echo "之后跑一次无头自检确认可用（体素管线 + 明亮配方）："
echo "  bash \"\$ROOT/tools/check.sh\""
