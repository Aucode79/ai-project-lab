#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""集元数据校验器：episodes/e{集号}.json（spec §8 十字段 + 新五字段，共十五键）。

检查项：
  1. 十五键齐全（id/title/duration/marks/outlineRefs/examRefs/scenes/data/
     voiceover/quiz/assets/runs/motion/layers/timeline；额外只允许 demo_stub 注记键）
  2. id 与文件名一致；duration>0
  3. clipRef 格式 {assetId}#{机位}:{动作}，机位/动作取 spec §3.4 词表，
     且 assets/{assetId}/{机位}_{动作}/ 目录存在
  4. 路径存在性（分两档）：
     硬失败——scenes 目录（.gitkeep 锚定入库）、layers 各文件的父目录、
       voiceover.script、data 各文件（均为入库源数据）；字段在 demo_stub 里则跳过
     警告——PNG 序列目录、layers 单文件、voiceover.audio（可再生产物，
       .gitignore 掉，重生成命令见 tools/production/README.md）
  5. timeline 时间码单调不减，条目形如 {t, track, ref}

用法（WSL 或任何 python3）：python3 tools/validate_episodes.py
退出码 0 = 全部通过。
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
REQUIRED_KEYS = [
    "id", "title", "duration", "marks", "outlineRefs", "examRefs",
    "scenes", "data", "voiceover", "quiz",
    "assets", "runs", "motion", "layers", "timeline",
]
SHOT_WORDS = {"iso", "front", "top", "close", "vista"}
ACTION_WORDS = {"idle", "run", "open", "close", "fail"}
CLIPREF_RE = re.compile(r"^[a-z][a-z0-9_]*#([a-z]+):([a-z]+)$")

errors: list[str] = []
warns: list[str] = []


def err(ep: str, msg: str) -> None:
    errors.append(f"{ep}: {msg}")


def warn(ep: str, msg: str) -> None:
    warns.append(f"{ep}: {msg}")


def check_episode(path: Path) -> None:
    ep = path.stem
    try:
        meta = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        err(ep, f"无法解析：{exc}")
        return
    if not isinstance(meta, dict):
        err(ep, "顶层不是对象")
        return

    stub = meta.get("demo_stub", [])
    if not isinstance(stub, list):
        err(ep, "demo_stub 必须是数组")
        stub = []

    missing = [k for k in REQUIRED_KEYS if k not in meta]
    if missing:
        err(ep, f"缺字段：{missing}")
    extra = [k for k in meta if k not in REQUIRED_KEYS + ["demo_stub"]]
    if extra:
        err(ep, f"多出字段：{extra}（只允许 demo_stub 注记键）")

    if meta.get("id") != ep:
        err(ep, f"id={meta.get('id')!r} 与文件名不符")
    if not isinstance(meta.get("duration"), (int, float)) or meta.get("duration", 0) <= 0:
        err(ep, f"duration 非法：{meta.get('duration')!r}")
    for key in ("marks", "outlineRefs", "examRefs", "data", "assets", "runs", "motion", "layers", "timeline"):
        if key in meta and not isinstance(meta[key], list):
            err(ep, f"{key} 必须是数组")

    # scenes：指 compose/e{集号}/（spec §8 重定向），目录须存在（stub 除外）
    scenes = meta.get("scenes")
    if isinstance(scenes, str):
        if "scenes" not in stub and not (REPO / scenes).is_dir():
            err(ep, f"scenes 目录不存在：{scenes}")
    else:
        err(ep, f"scenes 必须是字符串路径：{scenes!r}")

    # data：图层数值文件（stub 除外）
    for d in meta.get("data") or []:
        if "data" in stub:
            break
        if not (REPO / d).is_file():
            err(ep, f"data 文件不存在：{d}")

    # voiceover：值为 {script, audio} 两条路径。script 是入库源数据（缺=FAIL）；
    # audio 是可再生产物（.gitignore 掉，缺=WARN，tts.sh 重生成）
    vo = meta.get("voiceover")
    if not (isinstance(vo, dict) and set(vo) == {"script", "audio"}):
        err(ep, f"voiceover 必须是 {{script, audio}}：{vo!r}")
    else:
        if "voiceover" not in stub:
            if not (REPO / vo["script"]).is_file():
                err(ep, f"voiceover.script 文件不存在：{vo['script']}")
            if not (REPO / vo["audio"]).is_file():
                warn(ep, f"voiceover.audio 待再生成（tts.sh）：{vo['audio']}")

    # assets：片段清单，clipRef 格式 + 索引目录存在
    for i, a in enumerate(meta.get("assets") or []):
        if not (isinstance(a, dict) and {"clipRef", "duration", "reused"} <= set(a)):
            err(ep, f"assets[{i}] 缺 clipRef/duration/reused：{a!r}")
            continue
        ref = a["clipRef"]
        m = CLIPREF_RE.match(ref)
        if not m:
            err(ep, f"assets[{i}].clipRef 格式应为 {{assetId}}#{{机位}}:{{动作}}：{ref}")
            continue
        shot, action = m.group(1), m.group(2)
        if shot not in SHOT_WORDS:
            err(ep, f"assets[{i}].clipRef 机位 {shot} 不在词表 {sorted(SHOT_WORDS)}")
        if action not in ACTION_WORDS:
            err(ep, f"assets[{i}].clipRef 动作 {action} 不在词表 {sorted(ACTION_WORDS)}")
        if "assets" not in stub:
            idx = REPO / "assets" / ref.split("#")[0] / f"{shot}_{action}"
            if not idx.is_dir():
                # PNG 序列是中间产物（.gitignore 掉，README 记录清理与再生成）→ WARN
                warn(ep, f"assets[{i}] 片段目录待再生成（capture.sh）：{idx.relative_to(REPO)}")

    # layers：父目录须存在；文件缺失降为 WARN（PNG 属可再生产物，gitignore 掉）
    for p in meta.get("layers") or []:
        if "layers" in stub:
            break
        parent = (REPO / p).parent
        if not parent.is_dir():
            err(ep, f"layers 父目录不存在：{parent.relative_to(REPO)}")
        elif not (REPO / p).is_file():
            warn(ep, f"layers 文件待再生成：{p}")

    # timeline：{t, track, ref}，时间码单调不减
    last_t = None
    for i, item in enumerate(meta.get("timeline") or []):
        if not (isinstance(item, dict) and {"t", "track", "ref"} <= set(item)):
            err(ep, f"timeline[{i}] 缺 t/track/ref：{item!r}")
            continue
        if not isinstance(item["t"], (int, float)):
            err(ep, f"timeline[{i}].t 非数值：{item['t']!r}")
            continue
        if last_t is not None and item["t"] < last_t:
            err(ep, f"timeline[{i}].t={item['t']} 比上一条 {last_t} 小（时间码须单调不减）")
        last_t = item["t"]
        if not item["track"] or not item["ref"]:
            err(ep, f"timeline[{i}].track/ref 不能为空")

    # quiz：可空（大纲"片尾题不设"的集），有值须是对象且带 source
    quiz = meta.get("quiz")
    if quiz is not None and not (isinstance(quiz, dict) and "source" in quiz):
        err(ep, f"quiz 须为 null 或含 source 的对象：{quiz!r}")

    for key in stub:
        if key not in REQUIRED_KEYS:
            err(ep, f"demo_stub 列了未知字段：{key}")


def main() -> None:
    ep_dir = REPO / "episodes"
    files = sorted(ep_dir.glob("*.json")) if ep_dir.is_dir() else []
    if not files:
        err("episodes/", "目录为空或不存在")
    for f in files:
        check_episode(f)
        meta = json.loads(f.read_text(encoding="utf-8"))
        n_stub = len(meta.get("demo_stub") or [])
        print(f"  {f.name}: 十五键 {'OK' if all(k in meta for k in REQUIRED_KEYS) else '缺'}"
              f"，stub {n_stub} 项")
    for w in warns:
        print(f"WARN {w}")
    if errors:
        for e in errors:
            print(f"FAIL {e}")
        sys.exit(1)
    print(f"validate_episodes：{len(files)} 份集元数据全部通过")


if __name__ == "__main__":
    main()
