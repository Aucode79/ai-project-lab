"""【3D 遗产·已退役】v11 3D 时代产物，仅存档可查；现行渲染＝render_lesson_2d.py（见 tools/video/README.md）。原说明：v11 混合管线 · 3D 运行段逐镜渲染编排。

对 edit.json 中 RUN_IDS 的每一镜：用 Blender 渲该镜全局帧区间（复用 v9 的
render_lesson.py 与机位/标签逻辑，无 --bake），再用 ffmpeg 从帧序列切出
segments3d/<id>.mp4（帧数=该镜 duration×25）。幂等：跳过已有 mp4（FORCE=1 重渲）。

用法（仓库根，Git Bash）：
  tools/video/.venv-win/Scripts/python.exe tools/video/scripts/render_run_shots_v11.py
"""
import json
import os
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tools/video/lesson01"
SEGS = OUT / "segments3d"
FRAMES = OUT / "frames"
BLENDER = ROOT / "tools/blender/blender-5.2.2-windows-x64/blender.exe"
FFMPEG = ROOT / "tools/video/ffmpeg-master-latest-win64-gpl/bin/ffmpeg.exe"
FPS = 25

EDIT = json.loads((OUT / "edit.json").read_text(encoding="utf-8"))
RUN_IDS = ["task", "read", "pickup", "closure", "feedback", "reroute",
           "boundary", "delivery", "evidence", "second", "collect"]


def run(cmd, **kw):
    print("  $", " ".join(str(c)[:60] for c in cmd[:6]), "...", flush=True)
    subprocess.run([str(c) for c in cmd], check=True, **kw)


def main():
    force = os.environ.get("FORCE") == "1"
    SEGS.mkdir(exist_ok=True)
    FRAMES.mkdir(exist_ok=True)
    for sid in RUN_IDS:
        shot = next(s for s in EDIT["shots"] if s["id"] == sid)
        out = SEGS / f"{sid}.mp4"
        if out.exists() and not force:
            print(f"skip {sid} (exists)", flush=True)
            continue
        f0 = round(shot["start"] * FPS) + 1
        f1 = round(shot["end"] * FPS)
        n = f1 - f0 + 1
        assert n == round(shot["duration"] * FPS), (sid, n)
        print(f"render3d {sid}: frames {f0}-{f1} ({n})", flush=True)
        log = SEGS / f"{sid}.log"
        with open(log, "w", encoding="utf-8") as lf:
            proc = subprocess.run(
                [str(BLENDER), "-b", "-t", "6", "--gpu-backend", "vulkan",
                 "--python-exit-code", "1",
                 "--python", str(ROOT / "tools/video/scripts/render_lesson.py"),
                 "--", "--start", str(f0), "--end", str(f1)],
                stdout=lf, stderr=subprocess.STDOUT)
        if proc.returncode != 0:
            tail = log.read_text(encoding="utf-8", errors="replace")[-3000:]
            raise SystemExit(f"blender failed for {sid}:\n{tail}")
        run([FFMPEG, "-y", "-framerate", FPS, "-start_number", f0,
             "-i", FRAMES / "frame_%04d.jpg", "-frames:v", n,
             "-c:v", "libx264", "-preset", "fast", "-crf", "18",
             "-pix_fmt", "yuv420p", out])
        print(f"  -> {out}", flush=True)
    print("RUN3D DONE", len(RUN_IDS), "shots")


if __name__ == "__main__":
    main()
