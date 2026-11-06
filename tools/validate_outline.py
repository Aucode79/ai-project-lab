#!/usr/bin/env python3
"""校验 research/lmcc/outline_index.json（outline 索引的完整性检查）。

检查项：
1. conceptId 格式合法（c{1..12}.{序}）且无重复；
2. episodes 恰为 63 集，e01–e63 无缺号；
3. demo 五关视频集 e49/e51/e50/e40/e60 在 episodes 中存在，且各自条目 ≥1、label 非空；
4. 全部条目 label 非空、集链接合法（episode == episodes[0]、全部指向存在的集）。

用法（WSL，仓库根目录）：python3 tools/validate_outline.py
退出码：0 通过，1 失败。
"""

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
INDEX_PATH = REPO / "research" / "lmcc" / "outline_index.json"

FIVE_KEY_EPISODES = ["e49", "e51", "e50", "e40", "e60"]  # demo 五关视频集（L1–L5）
CONCEPT_ID_PAT = re.compile(r"^c(1[0-2]|[1-9])\.\d+$")


def main() -> int:
    errors = []
    if not INDEX_PATH.exists():
        print(f"validate_outline: FAIL - {INDEX_PATH} 不存在，先跑 tools/build_outline_index.py",
              file=sys.stderr)
        return 1
    data = json.loads(INDEX_PATH.read_text(encoding="utf-8"))

    episodes = data.get("episodes", [])
    concepts = data.get("concepts", [])

    # --- episodes：63 集无缺号 ---
    ep_ids = [e.get("id") for e in episodes]
    expected = [f"e{n:02d}" for n in range(1, 64)]
    if len(episodes) != 63 or ep_ids != expected:
        errors.append(f"episodes 应为 63 集 e01–e63，实际 {len(episodes)} 集")
    for e in episodes:
        if not e.get("title"):
            errors.append(f"{e.get('id')} title 为空")
        if not e.get("unit"):
            errors.append(f"{e.get('id')} unit 为空")
    ep_id_set = set(ep_ids)

    # --- concepts：id 格式、无重复、label 非空、链接合法 ---
    seen = {}
    for c in concepts:
        cid = c.get("conceptId", "")
        if not CONCEPT_ID_PAT.match(cid):
            errors.append(f"conceptId 格式非法：{cid!r}")
        if cid in seen:
            errors.append(f"conceptId 重复：{cid}（{seen[cid]} 与 {c.get('label')}）")
        seen[cid] = c.get("label")
        if not c.get("label"):
            errors.append(f"{cid} label 为空")
        eps = c.get("episodes") or []
        if not eps:
            errors.append(f"{cid}（{c.get('label')}）episodes 为空")
        bad = [e for e in eps if e not in ep_id_set]
        if bad:
            errors.append(f"{cid}（{c.get('label')}）指向不存在的集：{bad}")
        if eps and c.get("episode") != eps[0]:
            errors.append(f"{cid}（{c.get('label')}）episode 应为 episodes[0]，"
                          f"实际 {c.get('episode')!r} vs {eps[0]!r}")

    # --- 五关视频集：存在且各自条目 ≥1 ---
    per_ep = {eid: [] for eid in ep_ids}
    for c in concepts:
        for eid in c.get("episodes") or []:
            per_ep.setdefault(eid, []).append(c)
    for eid in FIVE_KEY_EPISODES:
        if eid not in ep_id_set:
            errors.append(f"五关视频集 {eid} 不在 episodes 中")
            continue
        hits = per_ep.get(eid, [])
        if not hits:
            errors.append(f"五关视频集 {eid} 没有任何条目")
            continue
        for c in hits:
            if not c.get("label"):
                errors.append(f"{eid} 的条目 {c.get('conceptId')} label 为空")

    # --- 汇总 ---
    print(f"outline_index 校验：{'PASS' if not errors else 'FAIL'}")
    print(f"  总条目数（concepts）：{len(concepts)}")
    print(f"  总集数（episodes）：{len(episodes)}")
    print(f"  集-条目链接总数：{sum(len(c.get('episodes') or []) for c in concepts)}")
    five_stats = "，".join(
        f"{eid}={len(per_ep.get(eid, []))} 条" for eid in FIVE_KEY_EPISODES)
    print(f"  五关视频集条目数：{five_stats}")
    markers = {}
    for c in concepts:
        markers[c.get("marker")] = markers.get(c.get("marker"), 0) + 1
    print(f"  三级标记分布：{markers}")
    if errors:
        print(f"  共 {len(errors)} 个问题：", file=sys.stderr)
        for msg in errors:
            print(f"    - {msg}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
