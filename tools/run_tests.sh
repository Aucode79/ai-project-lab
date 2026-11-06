#!/usr/bin/env bash
# 一键全量验证：自动发现 Godot 测试套件 + 三校验器（WSL python3）+ check.sh 冒烟。
# 任一环节失败 → 退出码非 0。
#
# 用法：
#   tools/run_tests.sh                 # 全量
#   tools/run_tests.sh --suite l2      # 只跑套件名（正则匹配）含 l2 的
#   tools/run_tests.sh --changed       # 只跑与 git 改动相关的套件（映射见 map_suites）
#   tools/run_tests.sh --changed=HEAD~3  # 同上，指定比较基线（缺省：工作区 vs HEAD，干净则 HEAD~1）
#   tools/run_tests.sh --list          # 列出全部套件名
#   tools/run_tests.sh --no-validators # 跳过 WSL 校验器（无 WSL 环境时）
#   GODOT=/path/to/godot tools/run_tests.sh
#
# 注意：godot 输出落临时文件而不接管道（管道会吃掉退出码，见 AGENTS.md 已知坑位）。
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT:-$ROOT/tools/godot/Godot_v4.7.2-stable_win64_console.exe}"

FILTER=""
LIST_ONLY=0
RUN_VALIDATORS=1
CHANGED_MODE=0
CHANGED_BASE=""
RUN_SUITES=1
RUN_CHECK=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --suite)         FILTER="${2:-}"; shift 2 ;;
    --suite=*)       FILTER="${1#*=}"; shift ;;
    --changed)       CHANGED_MODE=1; shift ;;
    --changed=*)     CHANGED_MODE=1; CHANGED_BASE="${1#*=}"; shift ;;
    --list)          LIST_ONLY=1; shift ;;
    --no-validators) RUN_VALIDATORS=0; shift ;;
    -h|--help)       sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "未知参数：$1" >&2; exit 2 ;;
  esac
done

if [[ $CHANGED_MODE -eq 1 && -n "$FILTER" ]]; then
  echo "--suite 与 --changed 不能同时用（前者是手动过滤，后者是自动映射）" >&2
  exit 2
fi

# ---- 收集套件 ----
# res_path[i] 形如 res://tests/levels/l2/run_l2_tests.gd
# key[i]      形如 levels/l2；同目录多套件时展开成 levels/l1/l1_wiring
REL=()
RES_PATH=()
while IFS= read -r f; do
  REL+=("${f#game/tests/}")
  RES_PATH+=("res://${f#game/}")
done < <(find "$ROOT/game/tests" -name 'run_*_tests.gd' | sort | sed "s|$ROOT/||")

if [[ ${#REL[@]} -eq 0 ]]; then
  echo "未找到任何测试套件（game/tests/**/run_*_tests.gd）" >&2
  exit 2
fi

declare -A DIR_COUNT=()
for rel in "${REL[@]}"; do
  d="${rel%/*}"
  DIR_COUNT[$d]=$(( ${DIR_COUNT[$d]:-0} + 1 ))
done

KEYS=()
for rel in "${REL[@]}"; do
  d="${rel%/*}"
  stem="${rel##*/run_}"; stem="${stem%_tests.gd}"
  if [[ ${DIR_COUNT[$d]} -eq 1 || "$stem" == "${d##*/}" ]]; then
    KEYS+=("$d")
  else
    KEYS+=("$d/$stem")
  fi
done

if [[ $LIST_ONLY -eq 1 ]]; then
  printf '%s\n' "${KEYS[@]}"
  exit 0
fi

# ---- --changed：路径 → 套件映射 ----
# 与 AGENTS.md §2「模块↔测试映射」同源。改一处代码不必去读那张表，交给这里。
# 输出该路径影响的套件正则；"*" 表示"无法判定，回退全量"；空串表示"不涉及套件"。
map_suites() {
  local p="$1" d n
  case "$p" in
    game/tests/*)                          # 测试自身改动 → 跑它所在的套件
      d="${p#game/tests/}"; d="${d%/*}"
      echo "${d##*/}" ;;
    game/scripts/core/*|game/scripts/autoload/*)   echo 'world|interaction|mcp' ;;
    game/scripts/compiler/*)               echo 'compiler|agent_lab' ;;
    tools/lesson/*|game/scripts/lessons/*|game/scripts/interaction/module_editor.gd|game/scenes/lessons/*)
                                           echo 'agent_lab' ;;
    game/scripts/integration/*)            echo 'integration' ;;
    game/scripts/scene/*)                  echo 'l1|l2|l3|l4|l5|sandbox|bright_loop' ;;
    game/scripts/levels/flow_base.gd|game/scripts/levels/level_assets.gd)
                                           echo 'l1|l2|l3|l4|l5|scoring|mcp|agent_demo' ;;
    game/scripts/levels/l[1-5]/*)          n="${p#game/scripts/levels/l}"; echo "l${n%%/*}"
                                           echo 'scoring|mcp|agent_demo' ;;
    game/scripts/asset_lib/*|assets/*|concepts.yaml)
                                           echo 'assets|bright_loop|sandbox' ;;
    game/scripts/scoring/*)                echo 'scoring' ;;
    game/scripts/help/*)                   echo 'help' ;;
    game/scripts/persistence/*)            echo 'persistence' ;;
    game/scripts/interaction/*)            echo 'interaction|bright_loop' ;;
    game/scripts/agent_demo/*)             echo 'agent_demo' ;;
    game/scripts/sandbox/*|game/scenes/sandbox/*)  echo 'sandbox' ;;
    game/scripts/main.gd|game/scripts/terrain_generator.gd|\
    game/bench/*)                          echo 'check' ;;
    game/scenes/levels/l[1-5]/*)           n="${p#game/scenes/levels/l}"; echo "l${n%%/*}" ;;
    game/scenes/*)                         echo 'l1|l2|l3|l4|l5|sandbox|bright_loop' ;;
    tools/validate_*.py|research/lmcc/*|episodes/*)
                                           echo 'validators' ;;
    sidecar/*)                             echo 'sidecar' ;;
    tools/*|docs/*|AGENTS.md|README.md|.gitattributes|.gitignore)
                                           : ;;   # 工具/文档改动不影响 godot 套件
    *)                                     echo '*' ;;   # 认不出来 → 回退全量，宁可多跑
  esac
}

if [[ $CHANGED_MODE -eq 1 ]]; then
  # core.quotepath=false：否则非 ASCII 路径会被 git 转义成 "\345\..." 带引号，
  # 下面的 case 通配就匹配不上（中文目录名在 docs/ 里是常态）。
  GIT="git -C $ROOT -c core.quotepath=false"
  if [[ -n "$CHANGED_BASE" ]]; then
    git -C "$ROOT" rev-parse --verify --quiet "$CHANGED_BASE" >/dev/null \
      || { echo "比较基线不存在：$CHANGED_BASE" >&2; exit 2; }
    BASE="$CHANGED_BASE"
    CHANGED="$($GIT diff --name-only "$BASE")"
    echo "改动来源：$BASE..工作区"
  else
    CHANGED="$($GIT diff --name-only HEAD; $GIT ls-files --others --exclude-standard)"
    BASE="HEAD"
    if [[ -z "$CHANGED" ]]; then
      CHANGED="$($GIT diff --name-only HEAD~1)"
      BASE="HEAD~1"
      echo "工作区干净，改看最近一次提交：$BASE..HEAD"
    else
      echo "改动来源：$BASE..工作区"
    fi
  fi
  CHANGED="$(printf '%s\n' "$CHANGED" | sed '/^$/d' | sort -u)"

  if [[ -z "$CHANGED" ]]; then
    echo "没有任何改动（含与 $BASE 比较、含未跟踪文件）" >&2
    exit 0
  fi

  NEED=''
  FALLBACK=0
  RUN_CHECK=0
  validators=0
  sidecar=0
  while IFS= read -r p; do
    r="$(map_suites "$p")"
    while IFS= read -r one; do
      case "$one" in
        '')            ;;
        '*')           FALLBACK=1 ;;
        check)         RUN_CHECK=1 ;;   # 基准场景 → 跑 check.sh 冒烟（不是套件，不能进 FILTER）
        validators)    validators=1 ;;
        sidecar)       sidecar=1 ;;
        *)             NEED="${NEED:+$NEED|}${one}" ;;
      esac
    done <<< "$r"
  done <<< "$CHANGED"

  echo "改动文件：$(printf '%s\n' "$CHANGED" | wc -l) 个"
  printf '%s\n' "$CHANGED" | sed 's/^/  /'

  if [[ $FALLBACK -eq 1 ]]; then
    echo "有路径无法归类 → 回退全量（宁可多跑）"
  elif [[ -z "$NEED" && $RUN_CHECK -eq 1 ]]; then
    RUN_SUITES=0
    echo "本次改动只涉及基准场景（main.gd / terrain_generator / bench）→ 只跑 check.sh 冒烟"
  elif [[ -z "$NEED" ]]; then
    if [[ $validators -eq 1 ]]; then
      RUN_SUITES=0
      echo "本次改动只涉及数据校验器 → 只跑三校验器，跳过 godot 套件与 check.sh"
    elif [[ $sidecar -eq 1 ]]; then
      echo "本次改动只涉及 sidecar（不在本 runner 内）→ 跑："
      echo "  wsl -e bash -lc 'cd /mnt/d/ai-project-lab/sidecar && ./.venv/bin/python -m pytest tests/ -q'"
      exit 0
    else
      echo "本次改动不涉及任何 godot 套件（文档/工具类）→ 无需跑测试"
      exit 0
    fi
  else
    FILTER="$NEED"
    echo "自动映射到套件：$FILTER"
    [[ $RUN_CHECK -eq 1 ]] && echo "（另含基准场景改动 → 还会跑 check.sh 冒烟）"
  fi
fi

if [[ ! -f "$GODOT" ]]; then
  echo "找不到 Godot 引擎：$GODOT" >&2
  echo "设 GODOT 环境变量，或解压 4.7.2 标准版到 tools/godot/。" >&2
  exit 2
fi

# Windows 形式工程路径给 godot
if [[ "$(uname -s)" == Linux* ]]; then
  GAME_WIN="$(wslpath -w "$ROOT/game")"
else
  GAME_WIN="$(cd "$ROOT/game" && pwd -W)"
fi

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

PASS=0
FAIL=0
SKIP=0
FAILED=()

# 跑一条命令，成功打印 PASS、失败打印 FAIL 并回显末尾日志。参数：显示名 + 命令…
step() {
  local name="$1"; shift
  printf '%-24s ' "$name"
  "$@" >"$TMP" 2>&1
  local rc=$?
  if [[ $rc -eq 0 ]]; then
    echo "PASS"
    PASS=$((PASS + 1))
  else
    echo "FAIL (exit $rc)"
    FAIL=$((FAIL + 1))
    FAILED+=("$name")
    tail -25 "$TMP" | sed 's/^/    | /'
  fi
}

if [[ $RUN_SUITES -eq 1 ]]; then
  echo "===== godot 测试套件 ====="
  for i in "${!RES_PATH[@]}"; do
    key="${KEYS[$i]}"
    if [[ -n "$FILTER" ]] && ! [[ "$key" =~ $FILTER ]]; then continue; fi
    step "$key" "$GODOT" --headless --path "$GAME_WIN" -s "${RES_PATH[$i]}"
  done
fi

# ---- 三校验器（WSL python3）----
if [[ $RUN_VALIDATORS -eq 1 ]]; then
  echo "===== 数据校验器（WSL python3）====="
  if command -v wsl >/dev/null 2>&1 && wsl -e bash -lc 'python3 --version' >/dev/null 2>&1; then
    if [[ "$(uname -s)" == Linux* ]]; then
      REPO_WSL="$ROOT"
    else
      # Git Bash 的 /d/ai-project-lab → WSL 的 /mnt/d/ai-project-lab
      REPO_WSL="$(printf '%s' "$ROOT" | sed 's|^/\([a-zA-Z]\)/|/mnt/\L\1/|')"
    fi
    for v in validate_assets validate_concepts validate_episodes; do
      step "$v" wsl -e bash -lc "cd '$REPO_WSL' && python3 tools/$v.py"
    done
  else
    echo "SKIP —— 无 WSL/python3（用 --no-validators 可显式跳过）"
    SKIP=$((SKIP + 1))
  fi
fi

# ---- check.sh 冒烟（--suite 手动过滤时跳过；--changed 映射到基准场景时专门跑它）----
if [[ $RUN_CHECK -eq 1 || ( -z "$FILTER" && $RUN_SUITES -eq 1 ) ]]; then
  echo "===== tools/check.sh 冒烟 ====="
  step "check.sh" bash "$ROOT/tools/check.sh"
fi

echo "===== 汇总 ====="
echo "PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
if [[ $FAIL -gt 0 ]]; then
  printf '失败项：%s\n' "${FAILED[*]}"
  exit 1
fi
exit 0
