#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""微课生产管线 · 图层渲染器（spec §3.2/§8：HTML → 透明 PNG，输出 layers/e{集号}/）。

数据来源（不自造文案）：
  * episodes/e{集号}.json 的 id/title/marks —— 集号牌与标记
  * episodes/e{集号}.json 的 data[0] 指向的 JSON —— 字幕文案（opening_line）

视觉口径按大纲 §7.2 固定版式：顶部左侧集号与标记、顶部右侧进度条、底部字幕条。
色板说明：大纲 §7.2 只给色名（概念蓝/公式橙/错误红/拓展灰）未给色值，以下取
docs/10-契约/美术方向.md 与 game/scenes/levels/l1/components/task_board.gd 现有色的近似：
  概念蓝 #3D6FB5（明亮版冷蓝灰系）  公式橙 #E08A3C（美术方向焦点橙）
  错误红 #E95353（task_board STATE_ERROR）  拓展灰 #7888A0（task_board POST_COLOR）
字体：WSL 无中文系统字体，从 Windows 字体目录借微软雅黑（msyh.ttc）；
playwright/chromium 装不动时退 Pillow 直绘（同版式，白字加描边近似）。

用法（WSL）：
  python3 tools/production/render_layers.py --episode e49
  python3 tools/production/render_layers.py --episode e49 --engine pillow
产物：layers/e49/{title,progress,subtitle}.png（1920×1080，透明底）
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent.parent
W, H = 1920, 1080

PALETTE = {
    "concept_blue": "#3D6FB5",
    "formula_orange": "#E08A3C",
    "error_red": "#E95353",
    "extend_gray": "#7888A0",
    "ink": "#1F2937",
    "bar_bg": "rgba(16,22,32,0.72)",
}
MARK_COLOR = {  # 大纲标记 → §7.2 色名
    "必修": "concept_blue",
    "加考": "formula_orange",
    "拓展": "extend_gray",
    "专项": "formula_orange",
}

WIN_FONT_CANDIDATES = [
    Path("/mnt/c/Windows/Fonts/msyh.ttc"),
    Path("/mnt/c/Windows/Fonts/simhei.ttf"),
    Path("/mnt/c/Windows/Fonts/simsun.ttc"),
]
FONT_DIR = Path.home() / ".local/share/fonts/production-cjk"
FONT_FAMILY = '"Microsoft YaHei", "SimHei", "Noto Sans CJK SC", sans-serif'


def load_episode(ep: str) -> dict:
    ep_path = REPO / "episodes" / f"{ep}.json"
    if not ep_path.exists():
        sys.exit(f"缺 {ep_path}（先写集元数据）")
    meta = json.loads(ep_path.read_text(encoding="utf-8"))
    data_files = meta.get("data") or []
    opening = ""
    if data_files:
        dp = REPO / data_files[0]
        if dp.exists():
            opening = json.loads(dp.read_text(encoding="utf-8")).get("opening_line", "")
    return {
        "id": meta["id"],
        "title": meta["title"],
        "marks": meta.get("marks") or [],
        "opening": opening,
    }


def ensure_cjk_font() -> None:
    """WSL 无中文字体时，从 Windows 字体目录拷一份到用户字体目录（幂等）。"""
    r = subprocess.run(["fc-list", ":lang=zh", "family"], capture_output=True, text=True)
    if r.returncode == 0 and r.stdout.strip():
        return
    FONT_DIR.mkdir(parents=True, exist_ok=True)
    copied = False
    for cand in WIN_FONT_CANDIDATES:
        if cand.exists():
            dst = FONT_DIR / cand.name
            if not dst.exists():
                shutil.copy2(cand, dst)
            copied = True
    if copied:
        subprocess.run(["fc-cache", "-f", str(FONT_DIR)], capture_output=True)
        print(f"图层：已借 Windows 中文字体到 {FONT_DIR}")
    else:
        print("图层：警告——找不到可用中文字体，中文可能渲染成方框", file=sys.stderr)


# ---------- HTML 引擎（首选） ----------

HTML_TMPL = """<!DOCTYPE html>
<html><head><meta charset="utf-8"><style>
* {{ margin: 0; padding: 0; }}
html, body {{ width: {W}px; height: {H}px; background: transparent;
  font-family: {FONT}; }}
.layer {{ position: relative; width: {W}px; height: {H}px; }}
{body}
</style></head><body><div class="layer">{content}</div></body></html>"""

CSS_TITLE = """
.titlebox { position: absolute; top: 36px; left: 48px; display: flex; align-items: center; gap: 18px; }
.epno { background: %(concept_blue)s; color: #fff; font-size: 34px; font-weight: 700;
  padding: 10px 22px; border-radius: 10px; letter-spacing: 1px; }
.mark { font-size: 28px; font-weight: 700; color: #fff; padding: 8px 20px;
  border-radius: 999px; }
.title { font-size: 40px; font-weight: 700; color: %(ink)s;
  text-shadow: 0 1px 0 rgba(255,255,255,0.8); }
"""

CSS_PROGRESS = """
.progressbox { position: absolute; top: 52px; right: 48px; width: 420px; height: 12px;
  background: rgba(31,41,55,0.18); border-radius: 999px; overflow: hidden; }
.progressbox .fill { position: absolute; inset: 0 auto 0 0; width: 10%%;
  background: %(concept_blue)s; border-radius: 999px; }
"""

CSS_SUBTITLE = """
.subtitlebox { position: absolute; left: 50%%; bottom: 56px; transform: translateX(-50%%);
  background: %(bar_bg)s; color: #fff; font-size: 40px; font-weight: 600;
  padding: 22px 46px; border-radius: 16px; letter-spacing: 2px;
  text-shadow: 0 0 2px rgba(0,0,0,0.4); white-space: nowrap; }
"""


def html_for(kind: str, ep: dict) -> tuple[str, str]:
    if kind == "title":
        marks = "".join(
            f'<span class="mark" style="background:{PALETTE[MARK_COLOR.get(m, "extend_gray")]}">{m}</span>'
            for m in ep["marks"]
        )
        css, content = CSS_TITLE, (
            f'<div class="titlebox"><span class="epno">{ep["id"].upper()}</span>'
            f"{marks}<span class=\"title\">{ep['title']}</span></div>"
        )
    elif kind == "progress":
        css, content = CSS_PROGRESS, '<div class="progressbox"><div class="fill"></div></div>'
    elif kind == "subtitle":
        css, content = CSS_SUBTITLE, f'<div class="subtitlebox">{ep["opening"]}</div>'
    else:
        raise ValueError(kind)
    return css % PALETTE, content


def render_html(out_dir: Path, ep: dict, kinds: list[str]) -> None:
    from playwright.sync_api import sync_playwright

    ensure_cjk_font()
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--force-color-profile=srgb"])
        page = browser.new_page(viewport={"width": W, "height": H})
        for kind in kinds:
            css, content = html_for(kind, ep)
            html = HTML_TMPL.format(W=W, H=H, FONT=FONT_FAMILY, body=css, content=content)
            page.set_content(html)
            page.screenshot(path=str(out_dir / f"{kind}.png"), omit_background=True)
        browser.close()


# ---------- Pillow 引擎（回退：HTML 渲染器装不动时用） ----------

def _pillow_font(size: int):
    from PIL import ImageFont

    for cand in WIN_FONT_CANDIDATES:
        if cand.exists():
            return ImageFont.truetype(str(cand), size)
    return ImageFont.load_default()


def render_pillow(out_dir: Path, ep: dict, kinds: list[str]) -> None:
    from PIL import Image, ImageDraw

    note = "（Pillow 回退：HTML 渲染器不可用，版式为近似）"
    for kind in kinds:
        img = Image.new("RGBA", (W, H), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        if kind == "title":
            f_no = _pillow_font(36)
            d.rounded_rectangle([48, 36, 190, 92], 10, fill=PALETTE["concept_blue"])
            d.text((76, 46), ep["id"].upper(), font=f_no, fill="#FFFFFF",
                   stroke_width=2, stroke_fill="#FFFFFF")
            x = 210
            f_mark = _pillow_font(30)
            for m in ep["marks"]:
                color = PALETTE[MARK_COLOR.get(m, "extend_gray")]
                w = d.textlength(m, font=f_mark)
                d.rounded_rectangle([x, 42, x + w + 40, 88], 24, fill=color)
                d.text((x + 20, 50), m, font=f_mark, fill="#FFFFFF",
                       stroke_width=2, stroke_fill="#FFFFFF")
                x += w + 60
            f_t = _pillow_font(40)
            d.text((x + 8, 44), ep["title"], font=f_t, fill=PALETTE["ink"],
                   stroke_width=1, stroke_fill="#FFFFFF")
        elif kind == "progress":
            x0, y0, x1, y1 = W - 48 - 420, 52, W - 48, 64
            d.rounded_rectangle([x0, y0, x1, y1], 6, fill=(31, 41, 55, 46))
            d.rounded_rectangle([x0, y0, x0 + int(420 * 0.10), y1], 6,
                                fill=PALETTE["concept_blue"])
        elif kind == "subtitle":
            f = _pillow_font(40)
            text = ep["opening"] + note
            tw = d.textlength(text, font=f)
            x0 = (W - tw) / 2 - 46
            d.rounded_rectangle([x0, H - 56 - 88, x0 + tw + 92, H - 56], 16,
                                fill=(16, 22, 32, 184))
            d.text(((W - tw) / 2, H - 56 - 66), text, font=f, fill="#FFFFFF",
                   stroke_width=1, stroke_fill="#000000")
        img.save(out_dir / f"{kind}.png")


def main() -> None:
    ap = argparse.ArgumentParser(description="图层渲染器：HTML → 透明 PNG")
    ap.add_argument("--episode", required=True, help="集号，如 e49")
    ap.add_argument("--engine", choices=["html", "pillow"], default="html")
    ap.add_argument("--out", default=None, help="输出目录（默认 layers/<集号>/）")
    args = ap.parse_args()

    ep = load_episode(args.episode)
    out_dir = Path(args.out) if args.out else REPO / "layers" / args.episode
    out_dir.mkdir(parents=True, exist_ok=True)
    kinds = ["title", "progress", "subtitle"]

    import time
    t0 = time.time()
    if args.engine == "html":
        try:
            render_html(out_dir, ep, kinds)
        except Exception as exc:  # noqa: BLE001 —— 回退要兜住 playwright 一切失败
            print(f"图层：HTML 引擎失败（{exc}），退 Pillow", file=sys.stderr)
            render_pillow(out_dir, ep, kinds)
    else:
        render_pillow(out_dir, ep, kinds)

    for k in kinds:
        f = out_dir / f"{k}.png"
        if not f.exists() or f.stat().st_size == 0:
            sys.exit(f"FAIL：{f} 未产出")
        print(f"图层：{f.relative_to(REPO)}  {f.stat().st_size} B")
    print(f"图层：{len(kinds)} 张 / {time.time() - t0:.1f}s → {out_dir}")


if __name__ == "__main__":
    main()
