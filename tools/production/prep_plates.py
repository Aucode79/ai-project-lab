#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""微课生产管线 · 3D 底板加工（把捕获产物变成 HTML 能直接摆的插图）。

三种模式（data/w<集号>_shots.json 的 plates.<id>.mode 指定）：
  trim     —— capture.sh 出的整画布 RGBA 帧（默认取中间一帧）：按不透明像素裁掉
              透明留白，再四周补 pad 比例，得到"贴边"的组件插图。不裁的话组件在
              卡片里只占一小块，留白全被算进尺寸。
  crop169  —— 工坊 --shot 出的整屏静帧（窗口高度受屏幕限制时不是整 16:9）：居中
              裁成 16:9，供 Ken Burns 推入当底片。
  spin     —— capture.sh <机位> spin 出的整段透明底慢旋序列（微课"拉出特写"用）：
              对全部帧取**并集**包围盒（各帧轮廓随旋转变，逐帧各自裁会让件在画面里
              游动），按该并集统一裁一版、再等比缩到 max_side，抽 stride 留帧写进
              out 目录（HTML 按 t 逐帧换图转起来）。src/out 都是目录，不是单文件。

plates.<id>.src 是目录时按 frame*.png 排序取中间一帧。裁到画面边缘 = 取景把件切了，
直接报错让人去改机位，而不是静默产出一张缺角的插图。

用法（WSL）：
  python3 tools/production/prep_plates.py --episode w01
  python3 tools/production/prep_plates.py --episode w01 --only studio_wide
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
PAD = 0.06          # trim 后四周补的留白，按裁出短边的比例
EDGE_SLACK = 2      # 不透明像素距画面边缘小于此值 = 件被切
SPIN_MAX_SIDE = 760  # spin 序列统一缩到此最长边（HTML 里再铺满舞台，省显存）
SPIN_STRIDE = 2      # spin 抽帧步长（200 帧 25fps → 每 2 帧留 1，8s 转一圈 = 12.5fps）


def pick_frame(src: Path) -> Path:
    if src.is_file():
        return src
    frames = sorted(src.glob("frame*.png"))
    if not frames:
        sys.exit(f"FAIL：{src} 下没有 frame*.png（先跑 tools/production/capture.sh）")
    return frames[len(frames) // 2]


def trim(img):
    from PIL import Image

    alpha = img.getchannel("A")
    bbox = alpha.getbbox()
    if bbox is None:
        sys.exit("FAIL：整帧全透明，捕获没出画面")
    x0, y0, x1, y1 = bbox
    if min(x0, y0) < EDGE_SLACK or x1 > img.width - EDGE_SLACK or y1 > img.height - EDGE_SLACK:
        sys.exit(f"FAIL：件被画面边缘切到（bbox={bbox} 画布={img.size}）——换机位重拍")
    pad = int(min(x1 - x0, y1 - y0) * PAD)
    box = (max(0, x0 - pad), max(0, y0 - pad),
           min(img.width, x1 + pad), min(img.height, y1 + pad))
    return img.crop(box), f"trim {img.size}→{box[2] - box[0]}x{box[3] - box[1]}"


def spin_frames(src: Path, out: Path, stride: int, max_side: int):
    """整段慢旋序列：并集包围盒统一裁一版，抽帧缩图写进 out 目录，返回说明。"""
    from PIL import Image

    frames = sorted(src.glob("frame*.png"))
    if not frames:
        sys.exit(f"FAIL：{src} 下没有 frame*.png（先跑 tools/production/capture.sh ... spin）")
    union = None
    for f in frames:
        bbox = Image.open(f).getchannel("A").getbbox()
        if bbox is None:
            continue
        union = bbox if union is None else (
            min(union[0], bbox[0]), min(union[1], bbox[1]),
            max(union[2], bbox[2]), max(union[3], bbox[3]))
    if union is None:
        sys.exit(f"FAIL：{src} 整段全透明，捕获没出画面")
    x0, y0, x1, y1 = union
    first = Image.open(frames[0])
    if min(x0, y0) < EDGE_SLACK or x1 > first.width - EDGE_SLACK or y1 > first.height - EDGE_SLACK:
        sys.exit(f"FAIL：{src.name} 旋转中有帧被画面边缘切到（并集 bbox={union} 画布={first.size}）——"
                 f"给 capture.sh 加 -- --margin=<更大值> 重拍")
    pad = int(min(x1 - x0, y1 - y0) * PAD)
    box = (max(0, x0 - pad), max(0, y0 - pad),
           min(first.width, x1 + pad), min(first.height, y1 + pad))
    scale = max_side / max(box[2] - box[0], box[3] - box[1])
    size = (max(1, round((box[2] - box[0]) * scale)), max(1, round((box[3] - box[1]) * scale)))

    kept = frames[::stride]
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("frame*.png"):
        old.unlink()
    for i, f in enumerate(kept):
        Image.open(f).crop(box).resize(size, Image.LANCZOS).save(out / f"frame{i:05d}.png")
    return f"spin {len(kept)}/{len(frames)} 帧 union{box[2]-box[0]}x{box[3]-box[1]}→{size[0]}x{size[1]}"


def crop169(img, trim_top=0.0):
    target = 16 / 9
    if trim_top:
        cut = int(img.height * trim_top)
        img = img.crop((0, cut, img.width, img.height))
    if img.width / img.height > target:
        w = int(round(img.height * target))
        box = ((img.width - w) // 2, 0, (img.width - w) // 2 + w, img.height)
    else:
        h = int(round(img.width / target))
        box = (0, (img.height - h) // 2, img.width, (img.height - h) // 2 + h)
    return img.crop(box), f"crop169(top-{trim_top:.0%}) →{box[2] - box[0]}x{box[3] - box[1]}"


def main() -> None:
    ap = argparse.ArgumentParser(description="3D 底板加工：裁留白 / 裁 16:9")
    ap.add_argument("--episode", required=True, help="课号，如 w01")
    ap.add_argument("--only", default=None, help="只做某一块底板（调试用）")
    args = ap.parse_args()

    from PIL import Image

    meta_path = REPO / "data" / f"{args.episode}_shots.json"
    if not meta_path.exists():
        sys.exit(f"缺 {meta_path.relative_to(REPO)}（先写镜头时间线）")
    plates = json.loads(meta_path.read_text(encoding="utf-8")).get("plates") or {}
    if not plates:
        sys.exit(f"{meta_path.relative_to(REPO)} 没有 plates 段")

    made = 0
    for pid, spec in plates.items():
        if args.only and pid != args.only:
            continue
        if spec["mode"] == "spin":
            note = spin_frames(REPO / spec["src"], REPO / spec["out"],
                               int(spec.get("stride", SPIN_STRIDE)),
                               int(spec.get("max_side", SPIN_MAX_SIDE)))
            made += 1
            print(f"底板：{pid:24s} {note:34s} → {spec['out']}/")
            continue
        src = pick_frame(REPO / spec["src"])
        out = REPO / spec["out"]
        img = Image.open(src)
        if spec["mode"] == "trim":
            if img.mode != "RGBA":
                sys.exit(f"FAIL：{pid} 要 trim 但 {src.name} 没有 alpha 通道（{img.mode}）")
            result, note = trim(img)
        elif spec["mode"] == "crop169":
            result, note = crop169(img.convert("RGB"), float(spec.get("trim_top") or 0.0))
        else:
            sys.exit(f"FAIL：{pid} 的 mode={spec['mode']!r} 不认识（trim / crop169 / spin）")
        out.parent.mkdir(parents=True, exist_ok=True)
        result.save(out)
        made += 1
        print(f"底板：{pid:24s} {note:26s} → {out.relative_to(REPO)}  {result.size[0]}x{result.size[1]}")
    print(f"底板：{made} 张")


if __name__ == "__main__":
    main()
