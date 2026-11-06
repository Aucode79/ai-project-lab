"""v11 混合管线 · 复盘定帧 stills + 开场 teaser 快剪素材抽取。

stills: 从 segments3d/<id>.mp4 抽 7 张定帧（复盘段右栏 + s19 双任务对比）。
candidates: teaser 5 个候选时刻各抽 1 帧，供主会话目检后定 crop 窗口。

用法（仓库根）：
  tools/video/.venv-win/Scripts/python.exe tools/video/scripts/extract_v11_media.py
"""
import json
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tools/video/lesson01"
SEG3 = OUT / "segments2d"
STILLS = OUT / "stills"
FF = ROOT / "tools/video/ffmpeg-master-latest-win64-gpl/bin/ffmpeg.exe"
EDIT = json.loads((OUT / "edit.json").read_text(encoding="utf-8"))
SHOT = {s["id"]: s for s in EDIT["shots"]}

# (still 名, 源镜, 相对时刻比例)
STILL_PLAN = [
    ("task", "task", 0.75),        # 任务提交
    ("read", "read", 0.45),        # 查路返回
    ("pickup", "pickup", 0.55),    # 装货执行
    ("feedback", "feedback", 0.5), # 封路信息回来
    ("closure", "closure", 0.8),   # 路障已落
    ("delivery", "delivery", 0.45),# 卸货落湾
    ("second", "second", 0.5),     # 第二任务开始
]
# teaser 候选：车轮动 / 转弯 / 路被封 / 改道 / 卸货
CAND_PLAN = [
    ("c1_move", "pickup", 0.5),
    ("c2_turn", "reroute", 0.22),
    ("c3_block", "closure", 0.72),
    ("c4_detour", "reroute", 0.6),
    ("c5_drop", "delivery", 0.4),
]


def grab(src, frac, out):
    t = SHOT[src]["duration"] * frac
    subprocess.run([str(FF), "-y", "-ss", f"{t:.3f}", "-i", str(SEG3 / f"{src}.mp4"),
                    "-frames:v", "1", str(out)], check=True,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print("grab", out.name)


def main():
    STILLS.mkdir(exist_ok=True)
    for name, src, frac in STILL_PLAN:
        grab(src, frac, STILLS / f"still_{name}.png")
    cand = OUT / "teaser_cand"
    cand.mkdir(exist_ok=True)
    for name, src, frac in CAND_PLAN:
        grab(src, frac, cand / f"{name}.png")
    print("EXTRACT DONE")


if __name__ == "__main__":
    main()
