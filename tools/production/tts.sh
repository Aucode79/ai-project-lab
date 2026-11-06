#!/usr/bin/env bash
# 配音（spec §8 管线第四步）：edge-tts 出一句固定文案 → layers/<集号>/voiceover.mp3。
#
# 文案：E49 开场白，从大纲 E49 标题起一句、30 字内
#（research/lmcc/教学大纲-青少年组.md E49 条目；同文案存 data/e49_profiles.json voiceover_line）。
# 大纲 §7.4 技术栈建议：edge-tts 批量生成，便于改稿后重录。
#
# 用法（WSL）：
#   bash tools/production/tts.sh                    # e49 默认文案
#   bash tools/production/tts.sh e51 "自定义文案"     # 其他集
#
# 装不上 edge-tts 时：记录原因并以静音轨退出 0（compose_clip.py 会自动补静音）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
EP="${1:-e49}"
TEXT="${2:-第 49 集，智能体身份与角色 profile。}"
VOICE="${VOICE:-zh-CN-XiaoxiaoNeural}"
if [[ "$EP" != "e49" && -z "$TEXT" ]]; then
  echo "tts：$EP 没有默认文案（只有 e49 的开场白落了库），请传入文案参数" >&2
  exit 2
fi
OUT="$ROOT/layers/$EP"
mkdir -p "$OUT"

if ! python3 -c "import edge_tts" 2>/dev/null; then
  echo "tts：安装 edge-tts（清华源）..."
  if ! pip3 install --user --break-system-packages \
      -i https://pypi.tuna.tsinghua.edu.cn/simple edge-tts >/dev/null 2>&1; then
    echo "tts：SKIP——edge-tts 装不上，合成将用静音轨（见 compose_clip.py --audio 可省略）" >&2
    exit 0
  fi
fi

printf '%s\n' "$TEXT" > "$OUT/voiceover.txt"
START=$(date +%s.%N)
python3 -m edge_tts --voice "$VOICE" --text "$TEXT" --write-media "$OUT/voiceover.mp3"
END=$(date +%s.%N)

BYTES=$(stat -c %s "$OUT/voiceover.mp3")
echo "tts：$OUT/voiceover.mp3  $BYTES B  $(awk "BEGIN{printf \"%.1f\", $END-$START}")s  文案：$TEXT"
