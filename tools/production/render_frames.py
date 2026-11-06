#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""微课生产管线 · 动效逐帧渲染器（HTML → 1920×1080 PNG 序列）。

为什么不是 render_layers.py：那个只出静态图层 PNG（一张透明底标题/字幕），
成片要的是"每 3–9 秒一次画面变化"的动效。这里把 HTML 当渲染器用：
场景自己实现 window.seek(t)（第 t 秒画面长什么样），本脚本按 fps 逐帧摆位 + 截图。
不用 CSS animation / requestAnimationFrame，一切状态由 t 推出 → 同一 t 永远同一帧，
重跑可比对，改一帧不用重跑全片。

注入的数据（场景里读 window.__DATA__）：
  plates      —— data/<集号>_shots.json 的 plates.<id>.out（3D 底板绝对路径）
  spins       —— mode=spin 的 plates.<id>.out 目录下的全部帧路径（拉出特写慢旋，场景按 t 换图）
  shots       —— layers/<集号>/narration.json 的实测时间线（start/end/line/cues）
  report_lines—— data/<集号>_shots.json 的报告正文（分镜稿 §1 原文）

用法（WSL）：
  python3 tools/production/render_frames.py --episode w01                 # 全片帧
  python3 tools/production/render_frames.py --episode w01 --from 27 --to 36   # 只渲一段，改风格时用
  python3 tools/production/render_frames.py --episode w01 --encode compose/w01/pilot.mp4 \
      --audio layers/w01/narration.wav                                       # 直接出片，不落帧
产物：--out 目录下的 frame00000.png ...（默认 compose/<集号>/frames/，可再生，gitignore 掉）

为什么默认要 --encode：帧 PNG 写 /mnt/d 是 9p 小文件写，实测 ~0.9 s/帧（渲染本身
只要 0.2 s），1572 帧会白等 25 分钟。改成 rawvideo 管道喂 ffmpeg，帧不落盘、
一次顺序写一个 mp4，同机实测回到 ~0.25 s/帧。要逐帧看图时再用 ffmpeg 从 mp4 抽。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import time
from io import BytesIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compose_clip import find_tool, tool_path  # noqa: E402  复用 ffmpeg/ffprobe 发现与路径转换

REPO = Path(__file__).resolve().parent.parent.parent
W, H = 1920, 1080


def load_data(ep: str) -> dict:
    shots_path = REPO / "data" / f"{ep}_shots.json"
    narr_path = REPO / "layers" / ep / "narration.json"
    if not shots_path.exists():
        sys.exit(f"缺 {shots_path.relative_to(REPO)}（先写镜头时间线）")
    if not narr_path.exists():
        sys.exit(f"缺 {narr_path.relative_to(REPO)}（先跑 build_narration.py）")
    meta = json.loads(shots_path.read_text(encoding="utf-8"))
    narr = json.loads(narr_path.read_text(encoding="utf-8"))
    plates, spins = {}, {}
    for pid, spec in (meta.get("plates") or {}).items():
        if spec.get("mode") == "spin":   # 慢旋序列：out 是目录，注成帧路径列表
            d = REPO / spec["out"]
            frames = sorted(d.glob("frame*.png"))
            if not frames:
                sys.exit(f"缺 {d.relative_to(REPO)}/frame*.png（先跑 prep_plates.py --episode ...）")
            spins[pid] = [str(f.resolve()) for f in frames]
        else:
            plates[pid] = str((REPO / spec["out"]).resolve())
    return {"plates": plates, "spins": spins, "shots": narr["shots"],
            "report_lines": meta.get("report_lines") or [],
            "fps": narr.get("fps") or meta.get("fps") or 25}


def main() -> None:
    ap = argparse.ArgumentParser(description="HTML 动效 → PNG 帧序列 / 直接出片")
    ap.add_argument("--episode", required=True)
    ap.add_argument("--scene", default=None, help="场景目录（默认 scenes/<集号>_intro）")
    ap.add_argument("--out", default=None, help="帧输出目录（默认 compose/<集号>/frames）")
    ap.add_argument("--encode", default=None, help="直接编码成 mp4（帧不落盘）")
    ap.add_argument("--audio", default=None, help="配音视频轨，仅与 --encode 同用")
    ap.add_argument("--fps", type=int, default=0)
    ap.add_argument("--crf", type=int, default=18)
    ap.add_argument("--from", dest="t0", type=float, default=None)
    ap.add_argument("--to", dest="t1", type=float, default=None)
    ap.add_argument("--step", type=int, default=1, help="每 N 帧出一帧（抽帧自检用）")
    args = ap.parse_args()

    data = load_data(args.episode)
    fps = args.fps or data["fps"]
    scene_dir = REPO / (args.scene or f"scenes/{args.episode}_intro")
    html = scene_dir / "index.html"
    if not html.exists():
        sys.exit(f"缺 {html.relative_to(REPO)}")
    if args.encode and args.out:
        sys.exit("FAIL：--encode 不落帧，别同时给 --out")
    if args.encode and args.step != 1:
        sys.exit("FAIL：--encode 配 --step 会丢帧、成片变短（抽帧自检请渲 PNG 或用 qc_sheet.py）")
    out_dir = REPO / (args.out or f"compose/{args.episode}/frames")
    if not args.encode:
        out_dir.mkdir(parents=True, exist_ok=True)

    enc = None
    if args.encode:
        from PIL import Image  # noqa: F401  解码 screenshot 的 PNG
        enc = Encoder(fps, args.crf, REPO / args.encode, REPO / args.audio if args.audio else None)

    from playwright.sync_api import sync_playwright

    t0 = time.time()
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--force-color-profile=srgb", "--font-render-hinting=none"])
        page = browser.new_page(viewport={"width": W, "height": H}, device_scale_factor=1)
        page.on("pageerror", lambda e: print(f"帧：JS 报错 {e}", file=sys.stderr))
        page.add_init_script(f"window.__DATA__ = {json.dumps(data, ensure_ascii=False)};")
        page.goto(html.resolve().as_uri())
        page.wait_for_function("window.__ready === true", timeout=15000)
        page.wait_for_function(
            "Array.from(document.images).every(i => i.complete && i.naturalWidth > 0)", timeout=30000)
        duration = page.evaluate("window.DURATION")
        start = args.t0 if args.t0 is not None else 0.0
        stop = args.t1 if args.t1 is not None else duration
        if stop > duration:
            sys.exit(f"FAIL：--to={stop} 超过场景总长 {duration}s")
        n = int(round((stop - start) * fps))
        where = args.encode or str(out_dir.relative_to(REPO))
        print(f"帧：{html.relative_to(REPO)}  总长 {duration:.2f}s  渲 {n} 帧 @{fps}fps → {where}")
        for i in range(n):
            if i % args.step:
                continue
            t = start + i / fps
            page.evaluate(f"window.seek({t:.4f})")
            png = page.screenshot(type="png")
            if enc:
                enc.push(png)
            else:
                (out_dir / f"frame{i:05d}.png").write_bytes(png)
            if i and i % 250 == 0:
                el = time.time() - t0
                print(f"帧：{i}/{n}  {el:.0f}s 已用  约 {(n - i) * el / max(i, 1) / 60:.1f} 分钟后完")
        browser.close()

    if enc:
        enc.close()
        print(f"帧：{n} 帧 / {time.time() - t0:.0f}s（{(time.time() - t0) / max(n, 1):.2f} s/帧）→ {args.encode}")
        return
    made = len(list(out_dir.glob("frame*.png")))
    print(f"帧：{made} 张 / {time.time() - t0:.0f}s（{(time.time() - t0) / max(made, 1) * 1000:.0f} ms/帧）")


class Encoder:
    """rawvideo 管道喂 ffmpeg：帧不落盘，一次顺序写一个 mp4。"""

    def __init__(self, fps: int, crf: int, out: Path, audio: Path | None) -> None:
        ffmpeg = find_tool("ffmpeg")
        out.parent.mkdir(parents=True, exist_ok=True)
        self.out, self.part = out, Path(f"{out}.part.mp4")
        cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y",
               "-f", "rawvideo", "-pix_fmt", "rgba", "-s", f"{W}x{H}", "-r", str(fps), "-i", "-"]
        if audio:
            cmd += ["-i", tool_path(ffmpeg, audio)]
        cmd += ["-c:v", "libx264", "-preset", "veryfast", "-crf", str(crf),
                "-pix_fmt", "yuv420p", "-r", str(fps)]
        if audio:
            cmd += ["-map", "0:v", "-map", "1:a", "-c:a", "aac", "-b:a", "160k",
                    "-shortest", "-movflags", "+faststart"]
        cmd += [tool_path(ffmpeg, self.part)]
        self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stderr=subprocess.PIPE)

    def push(self, png: bytes) -> None:
        from PIL import Image

        raw = Image.open(BytesIO(png)).convert("RGBA").tobytes()
        try:
            self.proc.stdin.write(raw)
        except BrokenPipeError:
            self.close()
            raise

    def close(self) -> None:
        if self.proc.stdin:
            self.proc.stdin.close()
        err = self.proc.stderr.read().decode(errors="replace")
        rc = self.proc.wait()
        if rc != 0:
            sys.exit(f"FAIL：ffmpeg 退出 {rc}\n{err[-1500:]}")
        self.part.replace(self.out)
        print(f"帧：{self.out.relative_to(REPO)}  {self.out.stat().st_size} B")


if __name__ == "__main__":
    main()
