#!/usr/bin/env bash
# 一键把刚克隆的仓库弄到"能跑"：引擎 → voxel GDExtension → 登记扩展 → 冒烟自检。
#
# 为什么需要它：`tools/godot/`（引擎，约 173M）与 `game/addons/zylann.voxel/bin/`
# （插件二进制，约 129M）都不入库，所以干净克隆后没有任何东西能跑。本脚本把它们补齐。
#
# 特性：**幂等**——已就绪的步骤会跳过，可反复跑；每步失败都给出下一步怎么办。
# 用法：
#   tools/bootstrap.sh                # 全部四步
#   GODOT_DIR=/tmp/g tools/bootstrap.sh   # 换引擎落地目录（测试用）
#   tools/bootstrap.sh --check-only       # 只做冒烟自检
#
# 平台：Windows + Git Bash（引擎取 win64 构建）。Linux 见文末提示。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_DIR="${GODOT_DIR:-$ROOT/tools/godot}"
GODOT_VER="4.7.2-stable"
GODOT_EXE="$GODOT_DIR/Godot_v${GODOT_VER}_win64_console.exe"
GODOT_URL="https://github.com/godotengine/godot/releases/download/${GODOT_VER}/Godot_v${GODOT_VER}_win64.exe.zip"
VOXEL_BIN="$ROOT/game/addons/zylann.voxel/bin"

CHECK_ONLY=0
[[ "${1:-}" == "--check-only" ]] && CHECK_ONLY=1

# Windows 形式工程路径给 godot（--check-only 时失败提示里也要用，故提前算）
GAME_WIN="$(cd "$ROOT/game" && pwd -W)"

say()  { printf '\n== %s\n' "$*"; }
ok()   { printf '   OK   %s\n' "$*"; }
warn() { printf '   注意 %s\n' "$*"; }
die()  { printf '\n!! %s\n' "$*" >&2; exit 1; }

if [[ "$(uname -s)" == Linux* ]]; then
  die "本脚本按 Windows 分发（win64 构建）。Linux 下请自取 Godot ${GODOT_VER} linux 版，
   设 GODOT=/path/to/godot 后跑 bash tools/check.sh 验证。"
fi

say "0/4 工作区自检"
[[ -f "$ROOT/game/project.godot" ]] || die "找不到 game/project.godot——请在仓库根跑本脚本。"
ok "仓库根 = $ROOT"

if [[ $CHECK_ONLY -eq 0 ]]; then
  say "1/4 Godot 引擎（${GODOT_VER} win64）"
  if [[ -f "$GODOT_EXE" ]]; then
    ok "已就绪：${GODOT_EXE#$ROOT/}"
    ok "版本：$("$GODOT_EXE" --version 2>/dev/null | head -1)"
  else
    command -v curl >/dev/null || die "缺 curl，无法下载引擎；手动下载 $GODOT_URL 解压到 $GODOT_DIR 后重跑。"
    mkdir -p "$GODOT_DIR" || die "建不了目录 $GODOT_DIR"
    TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
    echo "   下载 $GODOT_URL"
    curl -L --max-time 900 --retry 2 -o "$TMP/godot.zip" "$GODOT_URL" \
      || die "下载失败（网络/代理）。手动下载 $GODOT_URL 解压到 $GODOT_DIR 后重跑。"
    python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" \
      "$TMP/godot.zip" "$GODOT_DIR" || die "解压失败：$TMP/godot.zip"
    rm -rf "$TMP"; trap - EXIT
    [[ -f "$GODOT_EXE" ]] || die "解压后没找到 $GODOT_EXE（zip 结构变了？解压内容在 $GODOT_DIR）"
    ok "已装：${GODOT_EXE#$ROOT/}（约 173M，已在 .gitignore 内）"
  fi

  say "2/4 voxel GDExtension 二进制"
  if [[ -d "$VOXEL_BIN" ]]; then
    ok "已就绪：game/addons/zylann.voxel/bin/（约 129M）"
  else
    warn "缺 $VOXEL_BIN，交给 tools/install_voxel.sh"
    bash "$ROOT/tools/install_voxel.sh" || die "插件安装失败；重跑 tools/install_voxel.sh 看它的输出。"
    [[ -d "$VOXEL_BIN" ]] || die "装完仍无 bin/，检查 install_voxel.sh 的输出"
    ok "已装 voxel 插件"
  fi

  say "3/4 让编辑器登记扩展（--import）"
  # 扩展不登记，以 --script 直跑时类不存在（见 tools/install_voxel.sh 的注释）。
  if [[ -f "$ROOT/game/.godot/extension_list.cfg" ]] \
     && grep -q 'zylann.voxel' "$ROOT/game/.godot/extension_list.cfg" 2>/dev/null; then
    ok "已登记过（game/.godot/extension_list.cfg 含 zylann.voxel）"
  else
    echo "   跑 --import（首次约 10–30 s）"
    "$GODOT_EXE" --headless --path "$GAME_WIN" --import >/dev/null 2>&1
    if [[ -f "$ROOT/game/.godot/extension_list.cfg" ]] \
       && grep -q 'zylann.voxel' "$ROOT/game/.godot/extension_list.cfg" 2>/dev/null; then
      ok "扩展已登记"
    else
      warn "没看到 extension_list.cfg 里的 zylann.voxel——若下一步冒烟失败，手动重跑：
      \"$GODOT_EXE\" --headless --path \"$GAME_WIN\" --import"
    fi
  fi
fi

say "4/4 冒烟自检（tools/check.sh：体素管线 + 明亮配方）"
bash "$ROOT/tools/check.sh"
rc=$?
if [[ $rc -ne 0 ]]; then
  cat <<EOF

!! 冒烟失败（退出码 $rc）。按顺序排查：
   1) 引擎与插件是否就位：ls -l "$GODOT_DIR" "$VOXEL_BIN"
   2) 扩展是否登记：grep -n zylann.voxel game/.godot/extension_list.cfg
   3) 重跑登记：\"$GODOT_EXE\" --headless --path \"$GAME_WIN\" --import
   4) 仍失败：bash tools/run_tests.sh 看哪一环先挂
EOF
  exit $rc
fi

cat <<EOF

环境就绪。接下来常用三条：
  # 跑某一关（窗口，--demo 自演示；--shot 出预览图）
  "$GODOT_EXE" --path game scenes/levels/l1/l1.tscn --resolution 1920x1080 -- --demo
  # 改完代码只跑相关套件（自动映射，不用查表）
  bash tools/run_tests.sh --changed
  # 收尾全量（18 套件 288 条断言 + 三校验器 + 冒烟，约 65 s）
  bash tools/run_tests.sh
EOF
