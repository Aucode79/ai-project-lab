#!/usr/bin/env python3
"""从 research/lmcc/教学大纲-青少年组.md 生成 outline_index.json（conceptId 权威清单）。

推导规则（id 不自造，全部从大纲原文解析）：
- 条目清单与编号：附录 A「大纲 77 条目 → 集号映射」。conceptId = c{章号}.{章内序号}，
  章号由条目「章节-条目」里的中文数字（一~十二）转阿拉伯数字，
  章内序号 = 附录 A 行在该章内的出现顺序（附录照抄官方大纲原文顺序）。
- 集-条目链接 = 附录 A「集号」列 ∪ §3 各集「考纲」行引用 ∪ 材料题二跳推导：
  某集考纲写「例卷材料题 N」时，经 §1.2 材料题表的「对应知识点」列展开
  （如 E60 考纲"例卷材料题 1、2" → T1 十-智能体工具使用、T2 八-提示学习-检索增强）。
- episodes 数组：§3 的 `#### E{NN} 标题` 与 `### U{n} 单元名` 逐字解析，共 63 集。
- 「全」（模考集）不展开为条目链接；材料题知识点无法唯一对应附录条目的
  （如 T3 的"九-长思维链"、"十一-评测"）记入 parseNotes，不强行匹配。

输出幂等：不含时间戳，键序与数组序确定，重复运行字节级一致。
用法（WSL，仓库根目录）：python3 tools/build_outline_index.py
"""

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
MD_PATH = REPO / "research" / "lmcc" / "教学大纲-青少年组.md"
OUT_PATH = REPO / "research" / "lmcc" / "outline_index.json"

FIVE_KEY_EPISODES = ["e49", "e51", "e50", "e40", "e60"]  # demo 五关视频集

# 中文章号（大纲只到十二）
CN_NUM = {"一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6,
          "七": 7, "八": 8, "九": 9, "十": 10, "十一": 11, "十二": 12}
CHAPTER_PAT = re.compile(r"^(十一|十二|十|[一二三四五六七八九])-")

# 附录 A 行：| # | 章节-条目 | 集号 | 难度 | 考核方式 | 标记 |
APPENDIX_ROW_PAT = re.compile(r"^\|\s*\d+\s*\|")


def fail(msg: str) -> None:
    print(f"build_outline_index: FAIL - {msg}", file=sys.stderr)
    sys.exit(1)


def split_pipe_row(line: str):
    cells = [c.strip() for c in line.strip().split("|")]
    return cells[1:-1]


def iter_section(lines, start_heading: str):
    """从匹配 start_heading 的标题行之后迭代，直到下一个同级或更高级标题。

    如 start_heading="## §3"：节内继续产出 ### / #### 行，遇到下一个 ## 才停。
    """
    start_level = len(start_heading) - len(start_heading.lstrip("#"))
    started = False
    for line in lines:
        if not started:
            if line.startswith(start_heading):
                started = True
            continue
        m = re.match(r"^(#{1,6})\s", line)
        if m and len(m.group(1)) <= start_level:
            return
        yield line
    return


def episode_sort_key(eid: str):
    return int(eid[1:])


def parse_episodes(lines, parse_notes):
    """解析 §3：63 集（id/title/unit/marker/syllabusRef）+ 各集考纲引用。"""
    episodes = []
    refs = {}  # eid -> dict(direct=[条目全称], materials=[材料题号], special=str|None)
    unit = None
    cur = None
    for line in iter_section(lines, "## §3"):
        m = re.match(r"^### (U\d+\s+.+)$", line)
        if m:
            unit = m.group(1).strip()
            continue
        m = re.match(r"^#### E(\d{2})\s+(.+)$", line)
        if m:
            cur = {"id": f"e{m.group(1)}", "title": m.group(2).strip(),
                   "unit": unit, "marker": None, "syllabusRef": None}
            episodes.append(cur)
            refs[cur["id"]] = {"direct": [], "materials": [], "special": None}
            continue
        if cur is not None and "**考纲**" in line:
            fields = {}
            for part in line.split("｜"):
                fm = re.match(r"^\s*-?\s*\*\*(.+?)\*\*\s*(.*)$", part.strip())
                if fm:
                    fields[fm.group(1)] = fm.group(2).strip()
            cur["marker"] = fields.get("标记")
            raw = fields.get("考纲", "")
            cur["syllabusRef"] = raw
            direct, materials, special, unmatched = parse_syllabus_ref(raw)
            refs[cur["id"]]["direct"].extend(direct)
            refs[cur["id"]]["materials"].extend(materials)
            refs[cur["id"]]["special"] = special
            for token in unmatched:
                parse_notes.append({
                    "episode": cur["id"], "raw": token,
                    "reason": "§3 考纲 token 无法解析为「条目【难度】」形态",
                })
    return episodes, refs


def parse_syllabus_ref(raw: str):
    """把「考纲」单元拆成：可直接匹配附录条目的引用 / 材料题号 / 特殊值 / 未匹配 token。"""
    raw = raw.strip()
    if raw in ("无", ""):
        return [], [], None, []
    if raw == "全":
        return [], [], "全", []
    if raw.startswith("例卷材料题"):
        return [], re.findall(r"\d+", raw), None, []
    direct, unmatched = [], []
    for token in raw.split("；"):
        token = token.strip()
        if not token:
            continue
        m = re.match(r"^(.+?)【[123]】", token)
        if m:
            direct.append(m.group(1).strip())
        else:
            unmatched.append(token)
    return direct, [], None, unmatched


def parse_appendix_a(lines):
    """解析附录 A：77 行（#、章节-条目、集号、难度、考核方式、标记）。"""
    rows = []
    for line in iter_section(lines, "## 附录 A"):
        if not APPENDIX_ROW_PAT.match(line):
            continue
        cells = split_pipe_row(line)
        if len(cells) != 6 or not cells[0].isdigit():
            continue
        label = cells[1]
        eps = [f"e{n}" for n in re.findall(r"E(\d{2})", cells[2])]
        difficulty = int(re.sub(r"[【】]", "", cells[3]))
        rows.append({
            "globalNo": int(cells[0]),
            "label": label,
            "episodes": eps,
            "difficulty": difficulty,
            "examTypes": [t.strip() for t in cells[4].split("、") if t.strip()],
            "marker": cells[5],
        })
    return rows


def parse_summary_ranges(lines):
    """解析 §2 总表「覆盖大纲条目」列（如 `一 1–4`）得到每章条目数期望值。"""
    expect = {}
    for line in iter_section(lines, "## §2"):
        cells = split_pipe_row(line)
        if len(cells) < 5:
            continue
        m = re.match(r"^(十一|十二|十|[一二三四五六七八九])\s*(\d+)\s*[–-]\s*(\d+)$", cells[4])
        if m:
            ch = CN_NUM[m.group(1)]
            expect[ch] = int(m.group(3)) - int(m.group(2)) + 1
    return expect


def parse_material_map(lines):
    """解析 §1.2 材料题表的「对应知识点」列：T{N} -> 知识点串。"""
    materials = {}
    for line in iter_section(lines, "### 1.2"):
        cells = split_pipe_row(line)
        if len(cells) == 4 and re.match(r"^T\d$", cells[0]):
            materials[cells[0][1:]] = cells[3]
    return materials


def build():
    lines = MD_PATH.read_text(encoding="utf-8").splitlines()

    parse_notes = []
    episodes, ep_refs = parse_episodes(lines, parse_notes)
    rows = parse_appendix_a(lines)
    expect_counts = parse_summary_ranges(lines)
    materials = parse_material_map(lines)

    # --- 基本完整性 ---
    if len(episodes) != 63:
        fail(f"§3 解析出 {len(episodes)} 集，应为 63")
    ids = [e["id"] for e in episodes]
    if ids != [f"e{n:02d}" for n in range(1, 64)]:
        fail(f"集号不连续或有缺号：{ids[:5]}...{ids[-5:]}")
    id_set = set(ids)
    if len(rows) != 77:
        fail(f"附录 A 解析出 {len(rows)} 条，应为 77")

    # --- 章内编号：c{章}.{章内序号} ---
    chapter_label_of = {}
    counters = {}
    for row in rows:
        m = CHAPTER_PAT.match(row["label"])
        if not m:
            fail(f"附录 A 条目无法识别章号：{row['label']}")
        ch_label = m.group(1)
        ch = CN_NUM[ch_label]
        counters[ch] = counters.get(ch, 0) + 1
        row["chapter"] = ch
        row["chapterLabel"] = ch_label
        row["item"] = row["label"][m.end():]
        row["conceptId"] = f"c{ch}.{counters[ch]}"
        chapter_label_of[ch] = ch_label

    # 与 §2 总表的每章条目数对账
    actual_counts = {}
    for row in rows:
        actual_counts[row["chapter"]] = actual_counts.get(row["chapter"], 0) + 1
    if actual_counts != expect_counts:
        fail(f"每章条目数与 §2 总表不符：附录 {actual_counts} vs 总表 {expect_counts}")

    # 附录 A 全局序号在章内应连续（= §2 的 1–4/5–9/… 区间）
    per_ch_no = {}
    for row in rows:
        per_ch_no.setdefault(row["chapter"], []).append(row["globalNo"])
    for ch, nos in per_ch_no.items():
        if nos != list(range(nos[0], nos[0] + len(nos))):
            fail(f"第 {ch} 章附录全局序号不连续：{nos}")

    # --- 章名（供材料题知识点去掉章节中缀用）：U1..U12 单元名 == 章名 ---
    chapter_name = {}
    for e in episodes:
        m = re.match(r"^U(\d+)\s+(.+)$", e["unit"] or "")
        if m and 1 <= int(m.group(1)) <= 12:
            chapter_name[int(m.group(1))] = m.group(2).strip()

    by_label = {row["label"]: row for row in rows}
    by_id = {row["conceptId"]: row for row in rows}
    for row in rows:
        row["ep"] = set(row["episodes"])
        for eid in row["episodes"]:
            if eid not in id_set:
                fail(f"附录 A 条目 {row['label']} 指向不存在的集号 {eid}")

    # --- §3 考纲行引用并入 ---
    for eid, ref in ep_refs.items():
        for label in ref["direct"]:
            if label in by_label:
                by_label[label]["ep"].add(eid)
            else:
                parse_notes.append({
                    "episode": eid, "raw": label,
                    "reason": "§3 考纲引用未在附录 A 中找到同名条目",
                })

    # --- 材料题二跳推导（E60/E61 一类专项集）---
    derived_links = []

    def resolve_material_token(token, eid, q):
        token = token.strip()
        if not token:
            return
        if token in by_label:
            target = by_label[token]
        else:
            m = CHAPTER_PAT.match(token)
            target = None
            if m:
                ch = CN_NUM[m.group(1)]
                rest = token[m.end():]
                name = chapter_name.get(ch)
                if name and rest.startswith(name + "-"):
                    item = rest[len(name) + 1:]
                    hits = [r for r in rows if r["chapter"] == ch and r["item"] == item]
                    if len(hits) == 1:
                        target = hits[0]
        if target is not None:
            target["ep"].add(eid)
            derived_links.append({
                "episode": eid, "conceptId": target["conceptId"],
                "materialQuestion": f"T{q}", "knowledgePoint": token,
            })
        else:
            parse_notes.append({
                "episode": eid, "raw": token,
                "reason": "材料题知识点无法唯一对应附录 A 条目，未强行匹配",
            })

    for eid, ref in ep_refs.items():
        for q in ref["materials"]:
            if q not in materials:
                parse_notes.append({
                    "episode": eid, "raw": f"例卷材料题 {q}",
                    "reason": "§1.2 材料题表未找到该材料题",
                })
                continue
            for token in materials[q].split("；"):
                resolve_material_token(token, eid, q)
        if ref["special"] == "全":
            parse_notes.append({
                "episode": eid, "raw": "全",
                "reason": "模考集覆盖全部条目，不展开为条目链接",
            })

    # --- 组装 concepts ---
    concepts = []
    for row in sorted(rows, key=lambda r: r["globalNo"]):
        eps = sorted(row["ep"], key=episode_sort_key)
        if not eps:
            fail(f"条目 {row['label']} 没有任何集链接")
        concepts.append({
            "conceptId": row["conceptId"],
            "label": row["label"],
            "chapter": row["chapter"],
            "chapterLabel": row["chapterLabel"],
            "item": row["item"],
            "globalNo": row["globalNo"],
            "marker": row["marker"],
            "difficulty": row["difficulty"],
            "examTypes": row["examTypes"],
            "episode": eps[0],
            "episodes": eps,
        })

    # --- 锚点断言（任务样例，id 不自造的底线检查）---
    anchors = {
        "c3.1": ("三-注意力机制", None),
        "c4.5": (None, "四-优化设置"),
    }
    for cid, (exact, prefix) in anchors.items():
        if cid not in by_id:
            fail(f"锚点 {cid} 不存在")
        label = by_id[cid]["label"]
        if exact and label != exact:
            fail(f"锚点 {cid} 应为「{exact}」，实际「{label}」")
        if prefix and not label.startswith(prefix):
            fail(f"锚点 {cid} 应以「{prefix}」开头，实际「{label}」")

    # --- 五关视频集必须有条目 ---
    link_count = 0
    per_ep_concepts = {e["id"]: [] for e in episodes}
    for c in concepts:
        for eid in c["episodes"]:
            per_ep_concepts[eid].append(c["conceptId"])
            link_count += 1
    for eid in FIVE_KEY_EPISODES:
        if not per_ep_concepts[eid]:
            fail(f"五关视频集 {eid} 没有任何条目链接")

    # --- 组装 episodes ---
    ep_records = [{
        "id": e["id"],
        "title": e["title"],
        "unit": e["unit"],
        "marker": e["marker"],
        "syllabusRef": e["syllabusRef"],
    } for e in episodes]

    data = {
        "version": 1,
        "source": "research/lmcc/教学大纲-青少年组.md",
        "generator": "tools/build_outline_index.py",
        "conceptIdRule": "c{章号}.{章内序号}：章号=附录 A 条目「章节-条目」的中文章号；"
                         "章内序号=附录 A 行在该章内的出现顺序（照抄官方大纲原文顺序）",
        "counts": {
            "episodes": len(ep_records),
            "concepts": len(concepts),
            "episodeConceptLinks": link_count,
        },
        "episodes": ep_records,
        "concepts": concepts,
        "derivedEpisodeLinks": sorted(
            derived_links,
            key=lambda d: (d["episode"], d["conceptId"], d["materialQuestion"])),
        "parseNotes": sorted(
            parse_notes, key=lambda n: (n["episode"], n["raw"])),
    }

    OUT_PATH.write_text(
        json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(f"OK 写入 {OUT_PATH.relative_to(REPO)}")
    print(f"  集：{len(ep_records)}（e01–e63）；条目：{len(concepts)}（c1.1–c12.3）")
    print(f"  集-条目链接：{link_count}；材料题推导链接：{len(derived_links)}；"
          f"解析备注：{len(parse_notes)}")
    for eid in FIVE_KEY_EPISODES:
        print(f"  {eid}: {len(per_ep_concepts[eid])} 条 "
              f"({', '.join(per_ep_concepts[eid])})")


if __name__ == "__main__":
    build()
