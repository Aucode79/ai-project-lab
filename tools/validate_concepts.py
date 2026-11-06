#!/usr/bin/env python3
"""校验概念映射 concepts.yaml（spec docs/10-契约/specs/2026-09-13-sandbox-as-studio-design.md §4；
knob/observe/fail/examType 的语义权威在原 spec §5.1，§4.4 的结构化 observe 是强制项）。

检查项：
1. 顶层只含 planned_assets/concepts；planned_assets 为不重复的字符串列表；
   concept 记录 13 字段齐全且无未知字段；conceptId 文件内唯一；
2. conceptId 必须存在于 research/lmcc/outline_index.json（不自造 id），label 与
   outline 官方全称一致（错误）；episodes 与 outline 的 episodes 完全一致（防漂移）；
3. assetIds 非空且每项 ∈ assets/assets.yaml ∪ 本文件 planned_assets：引用
   planned 资产输出一行 PLANNED 提示（不失败），两边都不在 = 错误；
4. kind ∈ {operable, exhibit}；operable ⇒ knob/observe/fail 均非空（§4.2「knob
   非空且能写出 observe/fail」）；exhibit ⇒ knob 为空、fail 为空、contrast 非空
   （陈列概念不挂假旋钮，fail 由 contrast 替代）；
5. knobBinding 的 key ⊆ 本记录 knob 的 key；绑定值恰含 {assetId, paramKey} 且
   assetId ∈ 本记录 assetIds；
6. observe 结构化（§4.4）：每项恰含 observeId/targetRef/kind/expect；kind ∈
   {value, shape, state, motion}；targetRef 形如 {assetId} 或 {assetId}:{portId}，
   资产段 ∈ 本记录 assetIds；observeId 本概念内唯一；
7. fail 每项恰含 failId/condition/symptom；failId 必须是 {conceptId}:{n}（n 从 1
   起连续）且全局唯一；
8. examType ∈ {概念辨析, 计算, 程序填空, 程序阅读, 论文阅读} 或空；caption 非空
   （图层渲染器的默认字幕数据源）；
9. 五关视频集（spec §9.1.1）e49/e51/e50/e40/e60 每集至少被一条记录的 episodes
   引用（覆盖检查，输出里逐集可见）。

用法（WSL，仓库根目录）：python3 tools/validate_concepts.py [concepts.yaml 路径]
缺省校验仓库根 concepts.yaml；显式路径供负向自证（拷 /tmp 改坏后跑）。
退出码：0 通过，1 失败。
"""

import json
import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[1]
DEFAULT_CONCEPTS_PATH = REPO / "concepts.yaml"
OUTLINE_PATH = REPO / "research" / "lmcc" / "outline_index.json"
ASSETS_INDEX_PATH = REPO / "assets" / "assets.yaml"

CONCEPT_FIELDS = ["conceptId", "label", "episodes", "kind", "examType", "knob",
                  "assetIds", "knobBinding", "observe", "fail", "contrast",
                  "caption", "formulaRef"]
KINDS = ("operable", "exhibit")
EXAM_TYPES = ("概念辨析", "计算", "程序填空", "程序阅读", "论文阅读")
OBSERVE_KINDS = ("value", "shape", "state", "motion")
FIVE_EPISODES = ("e49", "e51", "e50", "e40", "e60")
TARGET_REF_PAT = re.compile(r"^([a-z][a-z0-9_]*)(?::([a-z][a-z0-9_]*))?$")


def load_outline(errors: list) -> dict:
    try:
        outline = json.loads(OUTLINE_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"outline_index.json 读不了：{exc}")
        return {}
    return {c["conceptId"]: c for c in outline.get("concepts", [])
            if isinstance(c, dict) and c.get("conceptId")}


def load_known_assets(errors: list) -> dict:
    try:
        index = yaml.safe_load(ASSETS_INDEX_PATH.read_text(encoding="utf-8"))
    except OSError:
        errors.append(f"主索引缺失：{ASSETS_INDEX_PATH.relative_to(REPO)}")
        return set()
    except yaml.YAMLError as exc:
        errors.append(f"主索引不是合法 YAML（{exc}）")
        return set()
    if not isinstance(index, dict) or not isinstance(index.get("assets"), list):
        errors.append("主索引顶层应为 assets: 列表")
        return set()
    known = {}
    for entry in index["assets"]:
        if isinstance(entry, dict) and isinstance(entry.get("assetId"), str):
            known[entry["assetId"]] = entry.get("kind", "")
    return known


def check_record(rec, outline_by_id: dict, known_assets: dict, planned: list,
                 seen_cids: set, seen_fail_ids: set, planned_refs: set,
                 episode_refs: dict, errors: list, warns: list) -> None:
    if not isinstance(rec, dict):
        errors.append(f"concept 记录必须是映射，实际 {rec!r}")
        return
    missing = [f for f in CONCEPT_FIELDS if f not in rec]
    extra = [k for k in rec if k not in CONCEPT_FIELDS]
    for f in missing:
        errors.append(f"concept 记录: 缺字段 {f}")
    if extra:
        errors.append(f"concept 记录: 未知字段 {extra}")

    cid = rec.get("conceptId")
    if not isinstance(cid, str) or not cid:
        errors.append(f"conceptId 必须是非空字符串，实际 {cid!r}")
        return
    if cid in seen_cids:
        errors.append(f"{cid}: conceptId 文件内重复")
    seen_cids.add(cid)

    oc = outline_by_id.get(cid)
    if oc is None:
        errors.append(f"{cid}: conceptId 不在 outline_index.json（不自造 id）")
    else:
        if rec.get("label") != oc.get("label"):
            errors.append(f"{cid}: label 与 outline 官方全称不一致"
                          f"（{rec.get('label')!r} vs {oc.get('label')!r}）")
        outline_eps = sorted(oc.get("episodes") or [])
        my_eps = rec.get("episodes")
        if not isinstance(my_eps, list) or not my_eps:
            errors.append(f"{cid}: episodes 必须是非空列表")
        else:
            if sorted(my_eps) != outline_eps:
                errors.append(f"{cid}: episodes 与 outline 不一致"
                              f"（{sorted(my_eps)} vs {outline_eps}）")
            for ep in my_eps:
                episode_refs.setdefault(ep, []).append(cid)

    kind = rec.get("kind")
    if kind not in KINDS:
        errors.append(f"{cid}: kind 必须是 {'|'.join(KINDS)}，实际 {kind!r}")

    exam = rec.get("examType")
    if exam not in (None, "") and exam not in EXAM_TYPES:
        errors.append(f"{cid}: examType 非法（{exam!r}），词表 {list(EXAM_TYPES)}")

    knob = rec.get("knob")
    knob_keys = []
    if not isinstance(knob, list):
        errors.append(f"{cid}: knob 必须是列表")
    else:
        for k in knob:
            if not isinstance(k, dict) or set(k.keys()) != {"key", "range"}:
                errors.append(f"{cid}: knob 项必须恰含 key/range，实际 {k!r}")
                continue
            if not isinstance(k["key"], str) or not k["key"]:
                errors.append(f"{cid}: knob key 必须是非空字符串")
                continue
            if k["key"] in knob_keys:
                errors.append(f"{cid}: knob key 重复：{k['key']}")
            knob_keys.append(k["key"])

    asset_ids = rec.get("assetIds")
    my_assets = set()
    if not isinstance(asset_ids, list) or not asset_ids:
        errors.append(f"{cid}: assetIds 必须是非空列表（指向 asset 记录 1..N）")
    else:
        for aid in asset_ids:
            if not isinstance(aid, str):
                errors.append(f"{cid}: assetId 必须是字符串：{aid!r}")
                continue
            if aid in known_assets:
                my_assets.add(aid)
                if rec.get("kind") == "exhibit" and known_assets[aid] == "parametric":
                    warns.append(f"{cid}: 陈列概念引用了 parametric 资产 {aid}"
                                 f"（过渡期允许；专用陈列资产落库时应改绑）")
            elif aid in planned:
                my_assets.add(aid)
                planned_refs.add(aid)
            else:
                errors.append(f"{cid}: assetId {aid} 既不在 assets/assets.yaml，"
                              f"也不在 planned_assets")

    binding = rec.get("knobBinding")
    if not isinstance(binding, dict):
        errors.append(f"{cid}: knobBinding 必须是映射")
    else:
        for bkey, bval in binding.items():
            if bkey not in knob_keys:
                errors.append(f"{cid}: knobBinding 键 {bkey!r} "
                              f"不在本记录 knob 键集 {knob_keys}")
            if (not isinstance(bval, dict)
                    or set(bval.keys()) != {"assetId", "paramKey"}):
                errors.append(f"{cid}: knobBinding[{bkey}] 必须恰含 assetId/paramKey，"
                              f"实际 {bval!r}")
                continue
            if bval["assetId"] not in my_assets:
                errors.append(f"{cid}: knobBinding[{bkey}].assetId {bval['assetId']!r} "
                              f"不在本记录 assetIds")

    observe = rec.get("observe")
    seen_oids = set()
    if not isinstance(observe, list):
        errors.append(f"{cid}: observe 必须是列表")
    else:
        for ob in observe:
            if (not isinstance(ob, dict)
                    or set(ob.keys()) != {"observeId", "targetRef", "kind", "expect"}):
                errors.append(f"{cid}: observe 项必须恰含 "
                              f"observeId/targetRef/kind/expect，实际 {ob!r}")
                continue
            oid = ob["observeId"]
            if oid in seen_oids:
                errors.append(f"{cid}: observeId 重复：{oid}")
            seen_oids.add(oid)
            if ob["kind"] not in OBSERVE_KINDS:
                errors.append(f"{cid}: observe {oid} kind 非法（{ob['kind']!r}），"
                              f"词表 {list(OBSERVE_KINDS)}")
            tr = ob["targetRef"]
            m = TARGET_REF_PAT.match(tr) if isinstance(tr, str) else None
            if not m:
                errors.append(f"{cid}: observe {oid} targetRef 形如 {{assetId}} 或 "
                              f"{{assetId}}:{{portId}}，实际 {tr!r}")
            elif m.group(1) not in my_assets:
                errors.append(f"{cid}: observe {oid} targetRef 资产段 "
                              f"{m.group(1)!r} 不在本记录 assetIds")
            if not isinstance(ob["expect"], str) or not ob["expect"].strip():
                errors.append(f"{cid}: observe {oid} expect 必须是非空字符串")

    fail = rec.get("fail")
    if not isinstance(fail, list):
        errors.append(f"{cid}: fail 必须是列表")
    else:
        for n, f in enumerate(fail, start=1):
            if (not isinstance(f, dict)
                    or set(f.keys()) != {"failId", "condition", "symptom"}):
                errors.append(f"{cid}: fail 项必须恰含 failId/condition/symptom，"
                              f"实际 {f!r}")
                continue
            expected_id = f"{cid}:{n}"
            if f["failId"] != expected_id:
                errors.append(f"{cid}: 第 {n} 条 failId 应为 {expected_id}，"
                              f"实际 {f['failId']!r}（命名 {{conceptId}}:{{n}}）")
            if f["failId"] in seen_fail_ids:
                errors.append(f"failId 全局重复：{f['failId']}")
            seen_fail_ids.add(f["failId"])

    if kind == "operable":
        if not knob:
            errors.append(f"{cid}: operable 概念 knob 不得为空（否则按陈列处理）")
        if not observe:
            errors.append(f"{cid}: operable 概念 observe 不得为空")
        if isinstance(fail, list) and not fail:
            errors.append(f"{cid}: operable 概念 fail 不得为空")
    elif kind == "exhibit":
        if isinstance(knob, list) and knob:
            errors.append(f"{cid}: 陈列概念不得挂假旋钮（knob 须为空）")
        if isinstance(fail, list) and fail:
            errors.append(f"{cid}: 陈列概念 fail 由 contrast 替代（fail 须为空）")
        contrast = rec.get("contrast")
        if not isinstance(contrast, str) or not contrast.strip():
            errors.append(f"{cid}: 陈列概念必须有 contrast（易混边界）")

    caption = rec.get("caption")
    if not isinstance(caption, str) or not caption.strip():
        errors.append(f"{cid}: caption 必须是非空字符串（默认字幕）")


def main(argv: list) -> int:
    errors: list = []
    concepts_path = Path(argv[1]) if len(argv) > 1 else DEFAULT_CONCEPTS_PATH

    outline_by_id = load_outline(errors)
    known_assets = load_known_assets(errors)

    planned: list = []
    records: list = []
    try:
        data = yaml.safe_load(concepts_path.read_text(encoding="utf-8"))
    except OSError:
        print(f"validate_concepts: FAIL - concepts.yaml 缺失：{concepts_path}",
              file=sys.stderr)
        return 1
    except yaml.YAMLError as exc:
        print(f"validate_concepts: FAIL - concepts.yaml 不是合法 YAML（{exc}）")
        return 1
    if not isinstance(data, dict):
        errors.append("concepts.yaml 顶层必须是映射（planned_assets + concepts）")
    else:
        extra_top = [k for k in data if k not in ("planned_assets", "concepts")]
        if extra_top:
            errors.append(f"顶层未知字段 {extra_top}（只允许 planned_assets/concepts）")
        planned = data.get("planned_assets")
        if planned is None:
            planned = []
        if not isinstance(planned, list) or not all(isinstance(p, str) for p in planned):
            errors.append("planned_assets 必须是字符串列表")
            planned = [p for p in planned if isinstance(p, str)]
        if len(planned) != len(set(planned)):
            errors.append("planned_assets 存在重复项")
        records = data.get("concepts")
        if not isinstance(records, list) or not records:
            errors.append("concepts 必须是非空列表")
            records = []

    seen_cids: set = set()
    seen_fail_ids: set = set()
    planned_refs: set = set()
    episode_refs: dict = {}
    warns: list = []
    for rec in records:
        check_record(rec, outline_by_id, known_assets, planned, seen_cids,
                     seen_fail_ids, planned_refs, episode_refs, errors, warns)

    for ep in FIVE_EPISODES:
        if not episode_refs.get(ep):
            errors.append(f"五关视频集覆盖缺口：{ep} 未被任何 concept 记录引用")

    for aid in sorted(planned_refs):
        print(f"validate_concepts: PLANNED - {aid}（计划中资产，planned_assets 放行）")
    if planned_refs:
        print(f"validate_concepts: {len(planned_refs)} 个计划中资产被引用（不阻塞）")
    for w in warns:
        print(f"validate_concepts: WARN - {w}")
    for ep in FIVE_EPISODES:
        cids = ",".join(episode_refs.get(ep, [])) or "-"
        print(f"validate_concepts: coverage {ep} <- {cids}")

    if errors:
        for err in errors:
            print(f"validate_concepts: FAIL - {err}")
        print(f"validate_concepts: {len(records)} 条记录，{len(errors)} 处问题")
        return 1
    print(f"validate_concepts: PASS - {len(records)} 条 concept 记录"
          f"（outline 对账/资产引用/旋钮绑定/observe 结构/fail 编号/五关覆盖 全部通过）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
