#!/usr/bin/env python3
"""校验三层资产库（前两层 base_/mach_）的资产记录与配套文件（spec §3.3/§3.4/§4.3/§8）。

检查项：
1. assets/ 下每个资产目录都有 asset.yaml，schema 字段齐全且无未知字段
   （assetId/kind/blockTypes/conceptIds/footprint/anchor/ports/defaults/shots）；
2. assetId 与目录名一致、层前缀合法；kind ∈ {parametric, exhibit}；
3. blockTypes 只取 12 种白名单（家族一 code_block + 家族二 11 种前缀）；
4. conceptIds 规则：base_/mach_ 通用件允许空数组；conc_/展示件必须 ≥1
   （纯装饰资产不得进入微课，spec §4.6）；
5. ports：每项恰含 {id, kind, dir}，kind ∈ {BOOL, ANALOG}、dir ∈ {in, out, io}、
   id 唯一；
6. defaults：非空映射，键为合法参数名，值为标量；
7. shots：机位词表 {iso, front, top, close, vista}、动作词表
   {idle, run, open, close, fail}（spec §3.4）；至少声明 idle 与 run 各一条；
   输出路径恰为 assets/{assetId}/{机位}_{动作}/；(机位, 动作) 不重复；
8. 主索引 assets/assets.yaml 与单件记录一一对应（数量、字段、端口数逐一比对）；
9. 每件资产存在对应场景：asset.yaml 可选字段 scene 给出显式 tscn 路径
   （相对仓库根）；缺省仍查 game/scenes/assets/{assetId}.tscn。

用法（WSL，仓库根目录）：python3 tools/validate_assets.py
退出码：0 通过，1 失败。
"""

import re
import sys
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[1]
ASSETS_ROOT = REPO / "assets"
INDEX_PATH = ASSETS_ROOT / "assets.yaml"
SCENES_DIR = REPO / "game" / "scenes" / "assets"

REQUIRED_FIELDS = ["assetId", "kind", "blockTypes", "conceptIds", "footprint",
                   "anchor", "ports", "defaults", "shots"]
OPTIONAL_FIELDS = ["scene"]              # 显式 tscn 路径（相对仓库根）
LAYER_PREFIXES = ["base_", "mach_", "conc_",
                  "chart_", "table_", "flow_", "text_", "concept_", "formula_",
                  "timeline_", "dialogue_", "output_", "player_", "fallback_",
                  "l2_"]   # 关卡作用域件：l2_flow 以运行时 id 注册（防漂移落库）
GENERIC_PREFIXES = ["base_", "mach_"]          # 通用件：conceptIds 可为空
DISPLAY_PREFIXES = LAYER_PREFIXES[3:]           # 展示件：conceptIds 必须 ≥1
BLOCK_TYPES = ["code_block",
               "chart_", "table_", "flow_", "text_", "concept_", "formula_",
               "timeline_", "dialogue_", "output_", "player_", "fallback_"]
SHOTS = ["iso", "front", "top", "close", "vista"]
ACTIONS = ["idle", "run", "open", "close", "fail"]
PORT_KINDS = ["BOOL", "ANALOG"]
PORT_DIRS = ["in", "out", "io"]
INDEX_FIELDS = ["assetId", "kind", "blockTypes", "footprint", "ports"]
ID_PREFIX_PAT = re.compile(r"^[a-z][a-z0-9_]*$")
PARAM_KEY_PAT = re.compile(r"^[a-z][a-z0-9_]*$")


def check_asset(asset_dir: Path, errors: list) -> dict:
    """校验单个资产目录，返回解析后的记录（失败返回空 dict）。"""
    label = asset_dir.name
    yaml_path = asset_dir / "asset.yaml"
    if not yaml_path.exists():
        errors.append(f"{label}: 缺少 asset.yaml")
        return {}
    try:
        data = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        errors.append(f"{label}: asset.yaml 不是合法 YAML（{exc}）")
        return {}
    if not isinstance(data, dict):
        errors.append(f"{label}: asset.yaml 顶层必须是映射")
        return {}

    for field in REQUIRED_FIELDS:
        if field not in data:
            errors.append(f"{label}: 缺字段 {field}")
    extra = [k for k in data if k not in REQUIRED_FIELDS + OPTIONAL_FIELDS]
    if extra:
        errors.append(f"{label}: 未知字段 {extra}")

    asset_id = data.get("assetId")
    if asset_id != label:
        errors.append(f"{label}: assetId {asset_id!r} 与目录名不一致")
    if not isinstance(asset_id, str) or not ID_PREFIX_PAT.match(asset_id):
        errors.append(f"{label}: assetId 命名非法（小写蛇形）")
    elif not any(asset_id.startswith(p) for p in LAYER_PREFIXES):
        errors.append(f"{label}: assetId 层前缀不在 §3.3 词表内")

    if data.get("kind") not in ("parametric", "exhibit"):
        errors.append(f"{label}: kind 必须是 parametric|exhibit，实际 {data.get('kind')!r}")

    block_types = data.get("blockTypes")
    if not isinstance(block_types, list) or not block_types:
        errors.append(f"{label}: blockTypes 必须是非空列表")
    else:
        bad = [t for t in block_types if t not in BLOCK_TYPES]
        if bad:
            errors.append(f"{label}: blockTypes 超出 12 种白名单：{bad}")

    concept_ids = data.get("conceptIds")
    if not isinstance(concept_ids, list):
        errors.append(f"{label}: conceptIds 必须是列表")
    else:
        # 通用件（base_/mach_）允许空；conc_ 概念装置与展示件必须声明服务的概念
        is_generic = isinstance(asset_id, str) and asset_id.startswith(tuple(GENERIC_PREFIXES))
        if not is_generic and len(concept_ids) < 1:
            errors.append(f"{label}: conc_/展示件必须声明 ≥1 个 conceptId（纯装饰不得进微课）")

    footprint = data.get("footprint")
    ok_fp = (isinstance(footprint, list) and len(footprint) == 2
             and all(isinstance(v, int) and v > 0 for v in footprint))
    if not ok_fp:
        errors.append(f"{label}: footprint 必须是两个正整数（占地格数），实际 {footprint!r}")

    anchor = data.get("anchor")
    if not isinstance(anchor, str) or not anchor.strip():
        errors.append(f"{label}: anchor 必须是非空字符串")

    ports = data.get("ports")
    seen_port_ids = set()
    if not isinstance(ports, list):
        errors.append(f"{label}: ports 必须是列表")
        ports = []
    for p in ports:
        if not isinstance(p, dict) or set(p.keys()) != {"id", "kind", "dir"}:
            errors.append(f"{label}: 端口必须恰含 id/kind/dir，实际 {p!r}")
            continue
        pid = p["id"]
        if pid in seen_port_ids:
            errors.append(f"{label}: 端口 id 重复：{pid}")
        seen_port_ids.add(pid)
        if p["kind"] not in PORT_KINDS:
            errors.append(f"{label}: 端口 {pid} kind 非法（{p['kind']!r}）")
        if p["dir"] not in PORT_DIRS:
            errors.append(f"{label}: 端口 {pid} dir 非法（{p['dir']!r}）")

    defaults = data.get("defaults")
    if not isinstance(defaults, dict) or not defaults:
        errors.append(f"{label}: defaults 必须是非空映射（出厂参数唯一来源）")
    else:
        for key, value in defaults.items():
            if not PARAM_KEY_PAT.match(str(key)):
                errors.append(f"{label}: defaults 键名非法：{key!r}")
            if not isinstance(value, (str, int, float, bool)):
                errors.append(f"{label}: defaults[{key}] 必须是标量，实际 {value!r}")

    shots = data.get("shots")
    if not isinstance(shots, list) or not shots:
        errors.append(f"{label}: shots 必须是非空列表")
        shots = []
    actions_seen = set()
    pairs_seen = set()
    for shot in shots:
        if not isinstance(shot, dict) or set(shot.keys()) != {"shot", "action", "duration", "output"}:
            errors.append(f"{label}: shot 必须恰含 shot/action/duration/output，实际 {shot!r}")
            continue
        if shot["shot"] not in SHOTS:
            errors.append(f"{label}: 机位 {shot['shot']!r} 不在词表 {SHOTS}")
        if shot["action"] not in ACTIONS:
            errors.append(f"{label}: 动作 {shot['action']!r} 不在词表 {ACTIONS}")
        duration = shot["duration"]
        if isinstance(duration, bool) or not isinstance(duration, (int, float)) or duration <= 0:
            errors.append(f"{label}: duration 必须为正数，实际 {duration!r}")
        expected_out = f"assets/{label}/{shot['shot']}_{shot['action']}/"
        if shot["output"] != expected_out:
            errors.append(f"{label}: 输出路径应为 {expected_out}，实际 {shot['output']!r}")
        pair = (shot["shot"], shot["action"])
        if pair in pairs_seen:
            errors.append(f"{label}: (机位, 动作) {pair} 重复声明")
        pairs_seen.add(pair)
        actions_seen.add(shot["action"])
    for required_action in ("idle", "run"):
        if required_action not in actions_seen:
            errors.append(f"{label}: shots 至少声明一条 {required_action}")

    scene_field = data.get("scene")
    if scene_field is None:
        scene_path = SCENES_DIR / f"{label}.tscn"
    elif not isinstance(scene_field, str) or not scene_field.strip():
        errors.append(f"{label}: scene 必须是非空字符串（相对仓库根的 tscn 路径）")
        scene_path = None
    else:
        scene_path = REPO / scene_field
    if scene_path is not None and not scene_path.exists():
        errors.append(f"{label}: 缺场景 {scene_path.relative_to(REPO)}")

    return data if isinstance(data, dict) else {}


def check_index(asset_dirs: list, records: dict, errors: list) -> None:
    """主索引 assets/assets.yaml 与单件记录对账。"""
    if not INDEX_PATH.exists():
        errors.append(f"主索引缺失：{INDEX_PATH.relative_to(REPO)}")
        return
    try:
        index = yaml.safe_load(INDEX_PATH.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        errors.append(f"主索引不是合法 YAML（{exc}）")
        return
    if not isinstance(index, dict) or not isinstance(index.get("assets"), list):
        errors.append("主索引顶层应为 assets: 列表")
        return

    entries = index["assets"]
    index_ids = [e.get("assetId") for e in entries]
    dir_ids = [d.name for d in asset_dirs]
    if sorted(index_ids) != sorted(dir_ids):
        only_index = sorted(set(index_ids) - set(dir_ids))
        only_dir = sorted(set(dir_ids) - set(index_ids))
        errors.append(f"主索引与资产目录不一一对应（索引多出 {only_index}，目录多出 {only_dir}）")
    if len(index_ids) != len(set(index_ids)):
        errors.append("主索引存在重复 assetId")

    for entry in entries:
        asset_id = entry.get("assetId")
        if not isinstance(entry, dict) or set(entry.keys()) != set(INDEX_FIELDS):
            errors.append(f"主索引 {asset_id}: 条目必须恰含 {INDEX_FIELDS}，实际 {sorted(entry.keys())}")
            continue
        record = records.get(asset_id)
        if record is None:
            continue   # 单件已报错，不重复
        for field in ("kind", "blockTypes", "footprint"):
            if entry.get(field) != record.get(field):
                errors.append(
                    f"主索引 {asset_id}: {field} 与单件不一致"
                    f"（索引 {entry.get(field)!r} vs 单件 {record.get(field)!r}）")
        port_count = len(record.get("ports") or [])
        if entry.get("ports") != port_count:
            errors.append(
                f"主索引 {asset_id}: ports 数应为 {port_count}，实际 {entry.get('ports')!r}")


def main() -> int:
    errors: list = []
    if not ASSETS_ROOT.is_dir():
        print(f"validate_assets: FAIL - {ASSETS_ROOT} 不存在", file=sys.stderr)
        return 1

    asset_dirs = sorted(d for d in ASSETS_ROOT.iterdir() if d.is_dir())
    records: dict = {}
    for asset_dir in asset_dirs:
        record = check_asset(asset_dir, errors)
        if record:
            records[asset_dir.name] = record
    check_index(asset_dirs, records, errors)

    if errors:
        for err in errors:
            print(f"validate_assets: FAIL - {err}")
        print(f"validate_assets: {len(asset_dirs)} 件资产，{len(errors)} 处问题")
        return 1
    print(f"validate_assets: PASS - {len(asset_dirs)} 件资产（yaml schema/白名单/词表/索引/tscn 全部一致）")
    return 0


if __name__ == "__main__":
    sys.exit(main())
