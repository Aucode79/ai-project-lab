#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""微课生产管线 · 抽帧自检拼图（成片的视觉取证入口）。

headless 出不了图、逐帧 PNG 又写不动 /mnt/d（见 render_frames.py 的管道口径），
所以看片统一从成片 mp4 抽：给几个秒数，抽帧拼成一张带时间标注的联络表，
一次看整段的构图/字幕/转场，而不是逐张开图。

用法（WSL）：
  python3 tools/production/qc_sheet.py --video compose/w01/pilot.mp4 --at 2,8,13,19 --cols 2
  # 只渲了一段时（render_frames --from 24 --to 45），片内时钟从 0 起：
  # 用 --offset 把秒数换回全片口径，标注才对得上分镜稿的秒位
  python3 tools/production/qc_sheet.py --video compose/w01/probe2.mp4 --offset 24 --at 26,31,35
产物：game/shots/production/qc/<片名>_<n>帧.png（gitignore 掉的取证图）
"""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compose_clip import find_tool, tool_path  # noqa: E402

REPO = Path(__file__).resolve().parent.parent.parent
TILE = (896, 504)


def main() -> None:
    ap = argparse.ArgumentParser(description="从成片抽帧拼联络表")
    ap.add_argument("--video", required=True)
    ap.add_argument("--at", required=True, help="逗号分隔的秒数（配 --offset 时写全片秒位）")
    ap.add_argument("--offset", type=float, default=0.0, help="这段片子对应全片的起点秒")
    ap.add_argument("--cols", type=int, default=3)
    ap.add_argument("--out", default=None)
    args = ap.parse_args()

    from PIL import Image, ImageDraw

    ffmpeg = find_tool("ffmpeg")
    video = REPO / args.video
    if not video.is_file():
        sys.exit(f"FAIL：{args.video} 不存在")
    times = [float(x) for x in args.at.split(",") if x.strip()]
    tmp = REPO / "game/shots/production/qc"
    tmp.mkdir(parents=True, exist_ok=True)

    tiles = []
    for t in times:
        seek = t - args.offset
        if seek < 0:
            sys.exit(f"FAIL：{t}s 早于本片起点 {args.offset}s")
        png = tmp / f"_grab_{str(t).replace('.', '_')}.png"
        cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y", "-ss", f"{seek:.3f}",
               "-i", tool_path(ffmpeg, video), "-frames:v", "1", tool_path(ffmpeg, png)]
        if subprocess.run(cmd, capture_output=True, text=True).returncode != 0 or not png.exists():
            sys.exit(f"FAIL：{t}s（片内 {seek:.2f}s）抽帧失败")
        img = Image.open(png).convert("RGB").resize(TILE)
        d = ImageDraw.Draw(img)
        d.rectangle([0, 0, 132, 34], fill=(16, 22, 32))
        d.text((12, 8), f"{t:6.2f}s", fill=(255, 255, 255))
        tiles.append(img)
        png.unlink()

    cols = min(args.cols, len(tiles))
    rows = -(-len(tiles) // cols)
    gap = 12
    sheet = Image.new("RGB", (cols * TILE[0] + (cols + 1) * gap,
                              rows * TILE[1] + (rows + 1) * gap), (24, 28, 34))
    for i, tile in enumerate(tiles):
        sheet.paste(tile, (gap + (i % cols) * (TILE[0] + gap), gap + (i // cols) * (TILE[1] + gap)))
    stem = video.stem.replace(".mp4", "")
    out = REPO / (args.out or f"game/shots/production/qc/{stem}_{len(tiles)}up.png")
    sheet.save(out)
    print(f"拼图：{len(tiles)} 帧 {times} → {out.relative_to(REPO)}  {sheet.size[0]}x{sheet.size[1]}")


if __name__ == "__main__":
    main()
