# -*- coding: utf-8 -*-
"""结尾段小样（v12.13 备选方案对比，不动正片）：
S_s18a_family  方案A：干净全家福（循环图+六名字，无照片缩略图）
S_s21e_next    方案E：s21 去循环图叠影（机身+开盖箭头）
S_s18c_family  方案C：四拍轮流定格（逐站 站名+大图，末拍合圈）

渲染（仓库根）：
  tools/video/.venv-manim/Scripts/python.exe -m manim --disable_caching \
    --resolution 1920,1080 --fps 25 --media_dir tools/video/media \
    -o <名> tools/video/scripts/render_ending_samples.py S_<名>
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import render_lesson_2d as R  # noqa: E402  (复用其全部组件与数据加载)

from manim import Arrow, Create, FadeIn, GrowArrow, UL, VGroup  # noqa: E402
import numpy as np  # noqa: E402

# 样片镜注册：借用正片对应镜的时长/文本记录
for _sid, _src in (("s18a_family", "s18_family"), ("s18c_family", "s18_family"),
                   ("s21e_next", "s21_next"), ("s19e_multi", "s19_multi")):
    R.SHOT_BY_ID[_sid] = dict(R.SHOT_BY_ID[_src])


def _family_photo(play_, idle, end, settle_pulse=True):
    """方案A 的核心画面：循环图 + 控制循环卡 + 外圈 + 智能体名牌（无照片）。"""
    diag = R.build_loop([0, 0.1], 1.05, lit=4, labels_on=True)
    R.scene_add = None  # 防呆
    return diag


class SampleScene(R.ConceptScene):
    """公共：背景与帧设定沿用 ConceptScene。"""


class S_s18a_family(R.ConceptScene):
    sid = "s18a_family"

    def _content(self, play_, idle, end):
        # v2（用户裁定"同图反复出现要优化"）：s18 不再重建——第 0 帧即 s17 结尾
        # 的完整构图（同尺寸同位置），纯延续式定格 + 一次轻呼吸
        diag = R.build_loop([0, 0.1], 1.15, lit=4, labels_on=True)
        arrows = R.loop_arrows(diag)
        card = R.term_card("控制循环", "control loop", R.PURPLE, 0.95).move_to(diag["center"])
        outer = R.rr(8.6, 7.6, 0.5, R.BG, stroke=R.STRUCTURE, sw=6, fo=0)
        agent = R.term_card("智能体", "agent", R.STRUCTURE, 0.85).move_to([0, 3.45, 0])
        self.add(diag["group"], arrows, card, outer, agent)
        idle(max(0.0, end * 0.45 - 0.5))
        play_([outer.animate(rate_func=R.rf.there_and_back).set_stroke(width=9)], 0.9)
        idle(end - 0.9 - max(0.0, end * 0.45 - 0.5) if end > 0 else 0)


class S_s21e_next(R.ConceptScene):
    sid = "s21e_next"

    def _content(self, play_, idle, end):
        machine = R.machine_glyph(0.9).move_to([0, 0.4, 0])
        lid = R.rr(6.4 * 0.9, 0.34, 0.1, R.STRUCTURE, stroke=R.INK, sw=2)
        lid.move_to(machine.get_corner(UL) + np.array([0, 0.18, 0]))
        play_([FadeIn(machine)], 0.5)
        self.add(lid)
        play_([lid.animate(rate_func=R.rf.smooth)
               .rotate(-0.28, about_point=lid.get_right())
               .shift(np.array([0, 0.32, 0]))], 0.8)
        arrow = Arrow([-4.6, 3.0, 0], [-3.8, 3.6, 0], buff=0,
                      stroke_width=7, color=R.ORANGE,
                      max_tip_length_to_length_ratio=0.4)
        play_([GrowArrow(arrow)], 0.45)


class S_s19e_multi(R.ConceptScene):
    sid = "s19e_multi"

    def _content(self, play_, idle, end):
        # v2：弃循环图（避免第三次重复）——回到运行段语言：联动条 + 工具块闪两下
        # + 两个任务的真实定帧（同一台机器，两种活）
        xs = [-4.6, -2.2, 0.2, 2.6]
        blocks, labels = [], []
        for i in range(4):
            b = R.rr(1.9, 0.6, 0.12, R.STATION_COLORS[i], stroke=R.INK, sw=1.5, fo=0.45)
            b.move_to([xs[i], 1.9, 0]).set_z_index(6)
            lb = R.txt(R.STATION_NAMES[i], 18, R.INK, "BOLD").move_to([xs[i], 1.9, 0])
            lb.set_z_index(7)
            blocks.append(b)
            labels.append(lb)
            self.add(b, lb)
        s1 = R.framed_still("delivery", 2.9).move_to([-2.9, -1.3, 0])
        s2 = R.framed_still("second", 2.9).move_to([2.9, -1.3, 0])
        play_([FadeIn(s1)], 0.5)
        play_([FadeIn(s2)], 0.5)
        idle(max(0.0, end * 0.4 - 1.0 - 0.5))
        for _ in range(2):
            play_([blocks[2].animate(rate_func=R.rf.there_and_back).scale(1.25)], 0.55)
            blocks[2].set_fill(opacity=1.0)
            idle(0.3)


class S_s18c_family(R.ConceptScene):
    sid = "s18c_family"

    def _content(self, play_, idle, end):
        diag = R.build_loop([-2.7, 0.2], 0.9, lit=0, labels_on=True)
        self.add(diag["group"])
        arrows = R.loop_arrows(diag).set_opacity(0)
        self.add(arrows)
        frame = self.camera.frame
        stills = ["task", "read", "pickup", "feedback"]
        beat = max(1.2, (end - 1.9) / 4)
        for i in range(4):
            st = diag["nodes"][i]
            lb = diag["labels"][i]
            lb.set_opacity(1.0)
            img = R.framed_still(stills[i], 3.0).move_to([3.2, 0.3, 0])
            play_([st.animate(rate_func=R.rf.smooth).set_fill(opacity=0.95),
                   FadeIn(img),
                   frame.animate(rate_func=R.rf.smooth).move_to([0.4, 0.3, 0]).set(width=12.0)],
                  min(0.9, beat * 0.55))
            idle(max(0.15, beat - 0.9))
            if i < 3:
                play_([img.animate(rate_func=R.rf.smooth).set_opacity(0),
                       st.animate(rate_func=R.rf.smooth).set_fill(opacity=0.4)], 0.35)
        # 末拍：合圈收束（四站全亮 + 箭头现形 + 循环卡 + 外圈 + 智能体名牌）
        card = R.term_card("控制循环", "control loop", R.PURPLE, 0.85).move_to(diag["center"])
        outer = R.rr(8.6, 7.6, 0.5, R.BG, stroke=R.STRUCTURE, sw=6, fo=0).move_to([-2.5, 0.2, 0])
        agent = R.term_card("智能体", "agent", R.STRUCTURE, 0.8).move_to([-2.5, 3.5, 0])
        last_img_fade = [diag["nodes"][3].animate(rate_func=R.rf.smooth).set_fill(opacity=0.4)]
        play_(last_img_fade, 0.2)
        play_([frame.animate(rate_func=R.rf.smooth).move_to([0, 0.15, 0]).set(width=14.0),
               arrows.animate(rate_func=R.rf.smooth).set_opacity(1),
               FadeIn(card), Create(outer), FadeIn(agent)], 1.2)
        for i in range(4):
            play_([diag["nodes"][i].animate(rate_func=R.rf.smooth).set_fill(opacity=0.95)], 0.15)
