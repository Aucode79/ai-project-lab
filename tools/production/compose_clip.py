#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""微课生产管线 · 合成器（spec §8：片段 + 图层 + 配音 → compose/e{集号}/ 成片）。

ffmpeg 选择：WSL 原生优先；本机 WSL 未装 ffmpeg 时回退 Windows 版
（默认 /mnt/c/Users/zyz/AppData/Local/Microsoft/WinGet/Links/ffmpeg.exe，
可用环境变量 FFMPEG/FFPROBE 覆盖）。调 Windows exe 时自动把 /mnt/<盘>/ 路径
转成 <盘>:/ 形式。

用法（WSL）：
  python3 tools/production/compose_clip.py \
    --frames assets/conc_task_board/iso_idle \
    --layer layers/e49/title.png --layer layers/e49/progress.png \
    --layer layers/e49/subtitle.png:0.5 \
    --audio layers/e49/voiceover.mp3 --audio-delay 0.2 \
    --out compose/e49/clip_task_board_intro.mp4 --duration 3

日志报告各段耗时与产物字节数（对照 docs/20-验收/测量结果.md"写盘是瓶颈"口径）。
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
WIN_FFMPEG_DEFAULT = "/mnt/c/Users/zyz/AppData/Local/Microsoft/WinGet/Links"


def find_tool(name: str) -> str:
    env = os.environ.get(name.upper())
    if env and Path(env).exists():
        return env
    w = shutil.which(name)
    if w:
        return w
    win = Path(WIN_FFMPEG_DEFAULT) / (name + (".exe" if name.startswith("ff") else ""))
    if win.exists():
        return str(win)
    sys.exit(f"找不到 {name}（WSL 原生或 {WIN_FFMPEG_DEFAULT} 均无，可用环境变量 {name.upper()} 指定）")


def tool_path(tool: str, path: Path | str) -> str:
    """Windows exe 吃不了 /mnt/ 路径，转成 <盘>:/ 形式。"""
    s = str(path)
    if not tool.endswith(".exe"):
        return s
    m = re.match(r"^/mnt/([a-zA-Z])/(.*)$", s)
    if m:
        return f"{m.group(1).upper()}:/{m.group(2)}"
    return s


def frame_pattern(frames_dir: Path) -> tuple[str, int]:
    pngs = sorted(p.name for p in frames_dir.glob("frame*.png"))
    if not pngs:
        sys.exit(f"FAIL：{frames_dir} 下没有 frame*.png")
    m = re.match(r"^frame(\d+)\.png$", pngs[0])
    if not m:
        sys.exit(f"FAIL：帧文件名不含序号：{pngs[0]}")
    digits = len(m.group(1))
    return f"frame%0{digits}d.png", int(m.group(1))


def probe(ffprobe: str, video: Path) -> dict:
    cmd = [ffprobe, "-v", "quiet", "-print_format", "json",
           "-show_format", "-show_streams", tool_path(ffprobe, video)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAIL：ffprobe 失败 {r.stderr}")
    info = json.loads(r.stdout)
    fmt = info["format"]
    v = next(s for s in info["streams"] if s["codec_type"] == "video")
    return {
        "duration_s": float(fmt["duration"]),
        "bytes": int(fmt["size"]),
        "width": v["width"],
        "height": v["height"],
        "video_codec": v["codec_name"],
        "frame_count": int(v.get("nb_frames", 0)),
    }


def main() -> None:
    ap = argparse.ArgumentParser(description="合成器：PNG 序列 + 图层 + 配音 → mp4")
    ap.add_argument("--frames", required=True, help="资产 PNG 序列目录")
    ap.add_argument("--layer", action="append", default=[],
                    help="图层 PNG，可带出现时间：path[:start_sec]（默认 0）")
    ap.add_argument("--audio", default=None, help="配音 mp3（缺省则静音轨）")
    ap.add_argument("--audio-delay", type=float, default=0.0)
    ap.add_argument("--out", required=True)
    ap.add_argument("--duration", type=float, default=3.0)
    ap.add_argument("--fps", type=int, default=25)
    ap.add_argument("--scale", type=float, default=0.7, help="资产占画面短边比例")
    ap.add_argument("--bg", default="0xEEF2F7")
    args = ap.parse_args()

    ffmpeg = find_tool("ffmpeg")
    ffprobe = find_tool("ffprobe")
    is_win = ffmpeg.endswith(".exe")

    frames_dir = (REPO / args.frames).resolve()
    pattern, start_no = frame_pattern(frames_dir)
    out = (REPO / args.out).resolve()
    out.parent.mkdir(parents=True, exist_ok=True)

    # 画布 1920×1080；资产按 scale 缩放置中；图层原尺寸叠加
    aw, ah = int(1920 * args.scale) // 2 * 2, int(1080 * args.scale) // 2 * 2
    ox, oy = (1920 - aw) // 2, (1080 - ah) // 2 - 40

    t0 = time.time()
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
           "-f", "lavfi", "-i", f"color=c={args.bg}:s=1920x1080:r={args.fps}:d={args.duration + 0.2:.2f}",
           "-framerate", str(args.fps), "-start_number", str(start_no),
           "-i", tool_path(ffmpeg, frames_dir / pattern)]
    for spec in args.layer:
        cmd += ["-i", tool_path(ffmpeg, spec.split(":")[0])]
    if args.audio:
        cmd += ["-i", tool_path(ffmpeg, args.audio)]

    fc = [f"[0:v]format=rgba[base]",
          f"[1:v]scale={aw}:{ah}:flags=lanczos[asset]",
          f"[base][asset]overlay=x={ox}:y={oy}[v1]"]
    last = "v1"
    for i, spec in enumerate(args.layer):
        delay = spec.split(":")[1] if ":" in spec else "0"
        outl = f"lay{i}"
        fc.append(f"[{i + 2}:v]format=rgba[{outl}_in]")
        fc.append(f"[{last}][{outl}_in]overlay=x=0:y=0:"
                  f"enable='gte(t,{delay})'[{outl}]")
        last = outl
    fc.append(f"[{last}]format=yuv420p[vout]")
    if args.audio:
        fc.append(f"[{1 + len(args.layer) + 1}:a]aresample=48000,"
                  f"adelay={int(args.audio_delay * 1000)}|{int(args.audio_delay * 1000)},"
                  f"apad[aout]")
        maps = ["-map", "[vout]", "-map", "[aout]"]
    else:
        cmd += ["-f", "lavfi", "-t", f"{args.duration:.2f}",
                "-i", "anullsrc=r=48000:cl=stereo"]
        fc.append(f"[{1 + len(args.layer) + 1}:a]anull[aout]")
        maps = ["-map", "[vout]", "-map", "[aout]"]

    cmd += ["-filter_complex", ";".join(fc)] + maps + [
        "-c:v", "libx264", "-preset", "medium", "-crf", "18",
        "-c:a", "aac", "-b:a", "128k", "-r", str(args.fps),
        "-t", f"{args.duration:.2f}", "-movflags", "+faststart",
        tool_path(ffmpeg, out)]

    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAIL：ffmpeg 退出 {r.returncode}\n{r.stderr[-2000:]}")
    wall = time.time() - t0

    info = probe(ffprobe, out)
    frames_on_disk = len(list(frames_dir.glob("frame*.png")))
    print(f"compose：{out.relative_to(REPO)}  {info['bytes']} B  {wall:.1f}s")
    print(f"compose：{info['duration_s']:.2f}s  {info['width']}x{info['height']}  "
          f"{info['video_codec']}  输入 {frames_on_disk} 帧 → 成片 {info['frame_count']} 帧"
          f"  ffmpeg={'Windows exe' if is_win else 'WSL 原生'}")
    if not (0.9 * args.duration <= info["duration_s"] <= 1.15 * args.duration):
        sys.exit(f"FAIL：成片时长 {info['duration_s']}s 偏离目标 {args.duration}s")


if __name__ == "__main__":
    main()
