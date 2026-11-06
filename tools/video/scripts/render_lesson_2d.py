"""Manim CE 2D re-render of AI Project Lab lesson 01 (concept intro + review
shots + recorded run replay; shot set is defined by edit.json).

Event-driven, deterministic replacement for the Blender 3D renderer
(scripts/render_lesson.py): same edit.json replay, same palette, same
per-shot framing intent, flattened to a 1920x1080 2D stage.

Run (from repo root, Git Bash):
  tools/video/.venv-manim/Scripts/python.exe tools/video/scripts/render_lesson_2d.py --preview agent,model,task,closure,scope,representation
  tools/video/.venv-manim/Scripts/python.exe tools/video/scripts/render_lesson_2d.py --only agent
  tools/video/.venv-manim/Scripts/python.exe tools/video/scripts/render_lesson_2d.py            # all 23 shots

Outputs: tools/video/lesson01/segments2d/<id>.mp4 and preview_<id>.png
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
from manim import (
    Animation,
    Arrow,
    Circle,
    Create,
    CurvedArrow,
    DashedVMobject,
    FadeIn,
    Group,
    GrowArrow,
    ImageMobject,
    Line,
    MovingCameraScene,
    Rectangle,
    RoundedRectangle,
    Scene,
    Succession,
    Text,
    UL,
    ValueTracker,
    VGroup,
    rate_functions as rf,
)

# ----------------------------------------------------------------------------
# Data
# ----------------------------------------------------------------------------
ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tools/video/lesson01"
SEGS = OUT / "segments2d"
MEDIA = ROOT / "tools/video/media"
FFMPEG_BIN = ROOT / "tools/video/ffmpeg-master-latest-win64-gpl/bin"

EDIT = json.loads((OUT / "edit.json").read_text(encoding="utf-8"))
MACHINE_MAP = json.loads(
    (ROOT / "game/shots/video3d/agent-lab/machine_map.json").read_text(encoding="utf-8")
)
SHOTS = EDIT["shots"]
SHOT_BY_ID = {s["id"]: s for s in SHOTS}
EVENTS = EDIT["events"]
EVENT_TIMES = [e["time"] for e in EVENTS]
for _i, _e in enumerate(EVENTS):
    # previous recorded state, used for move/drop start points
    _e["_prev"] = EVENTS[_i - 1]["state"] if _i else EDIT["initial"]
FPS = EDIT["fps"]

PREVIEW_MODE = os.environ.get("RENDER2D_PREVIEW") == "1"
FONT = "Microsoft YaHei"

# ----------------------------------------------------------------------------
# Palette / layout constants (2D stage, manim units: canvas 14.22 x 8)
# ----------------------------------------------------------------------------
BG = "#fdfcf9"
PAPER = "#f7f0d8"
INK = "#263b40"
DECK = "#b9cbcb"
STRUCTURE = "#536b73"
ORANGE = "#ef743b"
BLUE = "#24b9cf"
YELLOW = "#f2c43d"
RED = "#db6268"
GREEN = "#68ab5d"
PURPLE = "#9261c5"

K = 0.62                    # world -> screen scale for the sandbox map
OX, OY = -2.6, -1.35        # screen position of world origin (0, 0)
MOD_X = [-5.6, -2.8, 0.0, 2.8, 5.6]
MOD_Y = 2.6
MOD_LABELS = ["大语言模型", "工具", "观测", "上下文", "控制循环"]
MACH_C = (4.75, -1.05)
MS = 0.48                   # machine_map.json -> screen scale

CRATE_SIZE = 0.42
CARRIER_SIZE = 0.58
CRATE_ORDER = ["货物", "蓝方块", "黄方块"]
CRATE_COLOR = {"货物": ORANGE, "蓝方块": BLUE, "黄方块": YELLOW}

# v12 概念联动条：地图上方空带的四色块（与复盘循环图同色同源）+ 独立环境块。
STRIP_Y = 1.15
# 2026-10-06 用户裁定：整体左移 0.4，消除观测块与环境块重叠
STRIP_XS = [-5.1, -2.9, -0.7, 1.5]
STRIP_ENV_X = 3.2
STRIP_NAMES = ["便签", "大语言模型", "工具", "观测"]
STRIP_SHOTS = {"s01_teaser", "task", "read", "pickup", "closure", "feedback",
               "reroute", "boundary", "delivery", "evidence", "second", "collect"}

MODULE_FRAME = {"model": 0, "tools": 1, "observation": 2, "context": 3,
                "review_model": 0, "review_tools": 1, "review_observation": 2,
                "review_context": 3, "review_loop": 4}
MAP_SHOTS = {
    "task", "read", "pickup", "closure", "reroute", "boundary",
    "delivery", "evidence", "second", "collect",
}
SIGNAL_SHOTS = {"agent", "loop", "build", "context"}


def q(d: float) -> float:
    """Quantize a duration to the frame grid (1/25 s)."""
    return round(d * FPS) / FPS


def node_p(name: str) -> np.ndarray:
    x, y = EDIT["initial"]["nodes"][name]
    return np.array([OX + x * K, OY - y * K, 0.0])


NODE_P = {n: node_p(n) for n in EDIT["initial"]["nodes"]}


def mach_p(key: str) -> np.ndarray:
    p = MACHINE_MAP["nodes"][key]["pos"]
    return np.array([MACH_C[0] + p[0] * MS, MACH_C[1] - p[2] * MS, 0.0])


def bay_slot(index: int) -> np.ndarray:
    """Delivery bay slots at D, mirroring render_lesson.py offsets."""
    x = 4 + (index - 1) * 0.75
    return np.array([OX + x * K, OY + 1.25 * K, 0.0])


def state_at(t: float) -> dict:
    idx = bisect.bisect_right(EVENT_TIMES, t) - 1
    return EVENTS[idx]["state"] if idx >= 0 else EDIT["initial"]


def shot_events(shot: dict) -> list:
    lo = bisect.bisect_left(EVENT_TIMES, shot["start"])
    hi = bisect.bisect_left(EVENT_TIMES, shot["end"])
    return EVENTS[lo:hi]


def rr(w, h, r, fill, stroke=None, sw=1.5, fo=1.0, so=1.0):
    return RoundedRectangle(
        corner_radius=r, width=w, height=h,
        fill_color=fill, fill_opacity=fo,
        stroke_color=stroke if stroke else fill,
        stroke_width=0 if stroke is None else sw,
        stroke_opacity=so,
    )


def txt(s, size, color=INK, weight="NORMAL"):
    return Text(s, font=FONT, font_size=size, color=color, weight=weight)


# ----------------------------------------------------------------------------
# Stage: the whole 2D set, built identically in every scene
# ----------------------------------------------------------------------------
class Stage:
    def __init__(self, scene: Scene, state0: dict):
        self.scene = scene
        self._build_map()
        self._build_machine()
        self._build_modules()
        self._build_strip()
        self._apply_state(state0)
        # Map items are added last: they are the ones that animate most, and
        # Cairo re-renders everything after the first moving mobject.
        self.all = [
            self.underglow, self.machine_platform, self.machine_wires,
            *self.machine_blocks.values(), self.machine_title,
            *self.machine_labels.values(),
            *self.modules, *self.module_labels, self.ring,
            *self.strip_blocks, self.strip_arrows, self.strip_env,
            self.deck, self.roads, self.bay, self.node_labels, self.road_flash,
            self.carrier, *self.crates.values(), self.barrier,
        ]
        for m in self.all:
            scene.add(m)

    # -- map ------------------------------------------------------------------
    def _build_map(self):
        self.deck = rr(6.85, 3.85, 0.18, DECK, stroke=None).move_to([-2.275, -1.925, 0])
        roads = []
        for a, b in EDIT["initial"]["edges"]:
            pa, pb = NODE_P[a], NODE_P[b]
            c = (pa + pb) / 2
            w = abs(pa[0] - pb[0]) + 0.62
            h = abs(pa[1] - pb[1]) + 0.62
            roads.append(Rectangle(width=w, height=h, fill_color=PAPER,
                                   fill_opacity=1, stroke_width=0).move_to(c))
        self.roads = VGroup(*roads)
        self.bay = Rectangle(width=1.86, height=0.62, fill_color=GREEN,
                             fill_opacity=1, stroke_width=0).move_to(
            [OX + 4 * K, OY + 1.25 * K, 0])
        self.node_labels = VGroup(*(
            txt(n, 22).move_to(NODE_P[n] + [0, -0.45, 0]) for n in "ABCDEF"))
        # red flash overlay on the B-C road (closed in the demo run)
        bc_mid = (NODE_P["B"] + NODE_P["C"]) / 2
        self.road_flash = Rectangle(
            width=abs(NODE_P["B"][0] - NODE_P["C"][0]) + 0.62, height=0.62,
            fill_color=RED, fill_opacity=0, stroke_width=0).move_to(bc_mid)
        self.road_flash.set_z_index(3)
        # roadblock across B-C
        self.barrier = rr(0.34, 0.95, 0.06, RED, stroke=INK, sw=1).move_to(bc_mid + [0, 4.0, 0])
        self.barrier.set_opacity(0)
        self.barrier.set_z_index(5)
        self.carrier = self._make_carrier()
        self.carrier.set_z_index(4)
        self.crates = {name: rr(CRATE_SIZE, CRATE_SIZE, 0.06, color, stroke=INK, sw=1)
                       for name, color in CRATE_COLOR.items()}
        for c in self.crates.values():
            c.set_z_index(3)

    def _make_carrier(self):
        body = rr(CARRIER_SIZE, CARRIER_SIZE, 0.1, STRUCTURE, stroke=INK, sw=1)
        light = rr(0.16, 0.1, 0.03, ORANGE).move_to(body.get_center() + [0.14, -0.16, 0])
        return VGroup(body, light)

    # -- machine panel ----------------------------------------------------------
    def _build_machine(self):
        cx, cy = MACH_C
        self.underglow = rr(4.15, 4.75, 0.22, ORANGE, stroke=None, fo=0).move_to([cx, cy, 0])
        self.underglow.set_z_index(1)
        self.machine_platform = rr(3.8, 4.4, 0.18, DECK, stroke=STRUCTURE, sw=1.5, so=0.5).move_to([cx, cy, 0])
        self.machine_platform.set_z_index(2)
        self.machine_title = txt("可执行的方块程序", 20).move_to([cx, cy + 2.43, 0])
        self.machine_title.set_z_index(6)
        lines = []
        t_keys = ["t0", "t1", "t2", "t3", "t4", "t5", "t6"]
        pairs = [("task", "start")] + [("start", k) for k in t_keys] + \
                [(k, "tools") for k in t_keys] + [("tools", "done")]
        for a, b in pairs:
            lines.append(Line(mach_p(a), mach_p(b), stroke_width=2,
                              stroke_color=STRUCTURE, stroke_opacity=0.45))
        self.machine_wires = VGroup(*lines)
        self.machine_wires.set_z_index(3)
        blocks, labels = {}, {}
        for k in t_keys:
            world_tool = k in ("t0", "t1", "t2", "t3")
            body = rr(0.44, 0.44, 0.08, ORANGE if world_tool else YELLOW,
                      stroke=INK, sw=1)
            dot_col = BLUE if world_tool else STRUCTURE
            dots = VGroup(*(
                Circle(radius=0.035, fill_color=dot_col, fill_opacity=1,
                       stroke_width=0).move_to(body.get_center() + d)
                for d in ([-0.09, 0.09, 0], [0.09, 0.09, 0], [0, -0.08, 0])))
            blocks[k] = VGroup(body, dots)
        blocks["task"] = rr(0.56, 0.56, 0.1, PAPER, stroke=INK, sw=2).move_to(mach_p("task"))
        blocks["tools"] = rr(0.56, 0.56, 0.1, ORANGE, stroke=INK, sw=1).move_to(mach_p("tools"))
        blocks["start"] = rr(0.56, 0.56, 0.1, STRUCTURE, stroke=INK, sw=1).move_to(mach_p("start"))
        blocks["done"] = rr(0.56, 0.56, 0.1, GREEN, stroke=INK, sw=1).move_to(mach_p("done"))
        for k, b in blocks.items():
            b.move_to(mach_p(k))
            b.set_z_index(4)
        for key, label, dy in (("task", "对话输入", -0.42), ("tools", "已连接的工具", -0.42),
                               ("start", "Agent · 进入内部", -0.42), ("done", "最终回答", -0.42)):
            labels[key] = txt(label, 15)
            p = mach_p(key)
            if key == "start":  # left-align: keeps the long label inside the panel
                labels[key].move_to([p[0] - 0.26 + labels[key].width / 2, p[1] + dy, 0])
            else:
                labels[key].move_to([p[0], p[1] + dy, 0])
            labels[key].set_z_index(6)
        self.machine_blocks = blocks
        self.machine_labels = labels

    # -- concept module row -----------------------------------------------------
    def _build_modules(self):
        mods = []
        for i in range(5):
            g = VGroup()
            if i == 0:  # 大语言模型
                g.add(rr(2.2, 1.05, 0.14, YELLOW, stroke=INK, sw=1.5))
                g.add(rr(0.6, 0.6, 0.08, STRUCTURE).move_to([-0.3, 0.02, 0]))
                g.add(rr(0.5, 0.4, 0.08, PAPER).move_to([0.32, -0.06, 0]))
            elif i == 1:  # 工具
                g.add(rr(2.2, 1.05, 0.14, ORANGE, stroke=INK, sw=1.5))
                for x in (-0.6, 0.0, 0.6):
                    g.add(rr(0.22, 0.6, 0.05, PAPER).move_to([x, 0.08, 0]))
                g.add(Rectangle(width=2.0, height=0.14, fill_color=STRUCTURE,
                                fill_opacity=1, stroke_width=0).move_to([0, -0.36, 0]))
            elif i == 2:  # 观测
                g.add(rr(2.2, 1.05, 0.12, PAPER, stroke=BLUE, sw=5))
                for x in (-0.75, -0.25, 0.25, 0.75):
                    g.add(rr(0.16, 0.16, 0.03, BLUE).move_to([x, 0.62, 0]))
            elif i == 3:  # 上下文
                g.add(rr(2.2, 0.55, 0.1, STRUCTURE).move_to([0, -0.25, 0]))
                g.add(rr(2.0, 0.75, 0.1, PAPER, stroke=INK, sw=1).move_to([0, 0.12, 0]))
                for x in (-0.55, 0.25):
                    g.add(rr(0.2, 0.2, 0.04, BLUE).move_to([x, 0.55, 0]))
            else:  # 控制循环
                g.add(rr(2.2, 1.05, 0.14, PURPLE, stroke=INK, sw=1.5))
                g.add(rr(0.95, 0.7, 0.1, PAPER))
                g.add(rr(0.5, 0.14, 0.05, ORANGE).move_to([-0.62, 0.4, 0]))
                g.add(rr(0.5, 0.14, 0.05, ORANGE).move_to([0.62, -0.4, 0]))
            g.move_to([MOD_X[i], MOD_Y, 0])
            g.set_z_index(7)
            mods.append(g)
        self.modules = mods
        self.module_labels = []
        for i, s in enumerate(MOD_LABELS):
            lb = txt(s, 22).move_to([MOD_X[i], 3.42, 0])
            lb.set_z_index(8)
            self.module_labels.append(lb)
        self.ring = rr(2.55, 1.4, 0.16, BG, stroke=YELLOW, sw=5, fo=0)
        self.ring.move_to([MOD_X[0], MOD_Y, 0]).set_stroke(opacity=0)
        self.ring.set_z_index(9)
        self.ring_target = -1

    def _build_strip(self, named: bool = True):
        # v12.3：名字写在块身上；v12.6 方案B：默认暗态 0.45、激活 1.0 常亮到
        # 下一阶段（红绿灯式状态栏），替代"闪一下"的瞬时脉冲
        self.strip_badges = {0: None, 2: None}
        self.strip_pending_fade = None
        self.strip_blocks = []
        for i in range(4):
            b = rr(1.75, 0.55, 0.12, STATION_COLORS[i], stroke=INK, sw=1.5,
                   fo=0.45)
            b.set_z_index(6)
            name = txt(STATION_NAMES[i] if named else "", 17, INK, "BOLD")
            name.set_z_index(7)
            g = VGroup(b, name).move_to([STRIP_XS[i], STRIP_Y, 0])
            self.strip_blocks.append(g)
        arrs = []
        for a, b in ((0, 1), (1, 2), (2, 3)):
            x0 = STRIP_XS[a] + 0.92
            x1 = STRIP_XS[b] - 0.92
            arrs.append(Arrow([x0, STRIP_Y, 0], [x1, STRIP_Y, 0], buff=0,
                              stroke_width=3, color=STRUCTURE,
                              max_tip_length_to_length_ratio=0.35))
        # 观测 → 上下文 的回程（2026-10-06 用户裁定：有棱有角——竖直向下、
        # 水平向左、竖直向上回上下文；此前 CurvedArrow 指向大语言模型，与
        # S17"观测回、便签再进"及复盘循环图语义冲突且弧线挤在标签行里错位）。
        # 垂直段走块中心线（块下标签已并入块内），水平段 y=0.30 留在标签与地图之间。
        ret_y = 0.30
        self.ret_y = ret_y
        ret_x_obs = STRIP_XS[3]
        ret_x_ctx = STRIP_XS[0]
        block_bot = STRIP_Y - 0.275
        arrs.append(Line([ret_x_obs, block_bot, 0], [ret_x_obs, ret_y, 0],
                         stroke_width=3, color=STRUCTURE))
        arrs.append(Line([ret_x_obs, ret_y, 0], [ret_x_ctx, ret_y, 0],
                         stroke_width=3, color=STRUCTURE))
        arrs.append(Arrow([ret_x_ctx, ret_y, 0], [ret_x_ctx, block_bot, 0], buff=0,
                          stroke_width=3, color=STRUCTURE,
                          max_tip_length_to_length_ratio=0.3))
        self.strip_arrows = VGroup(*arrs).set_z_index(5)
        env_box = rr(1.15, 0.55, 0.12, RED, stroke=INK, sw=1.5)
        env_box.set_z_index(6)
        env_name = txt("环境" if named else "", 17, INK, "BOLD")
        env_name.set_z_index(7)
        self.strip_env = VGroup(env_box, env_name).move_to([STRIP_ENV_X, STRIP_Y, 0])
        self.strip_env.set_opacity(0)
        self.strip_group = VGroup(*self.strip_blocks, self.strip_arrows,
                                  self.strip_env)

    def strip_states(self, anims: list, ops: dict):
        """方案B：块状态常亮——{块号: 填充透明度}，1.0=激活 / 0.7=刚干完 / 0.45=待命。"""
        for i, op in ops.items():
            anims.append(self.strip_blocks[i][0].animate(rate_func=rf.smooth)
                         .set_fill(opacity=op))

    def strip_badge(self, slot: int, start, text: str, anims: list):
        """方案C：卡飞达目标块上方后驻留为徽章；同文徽章已驻留则不再演示（重复步骤只放一次）；
        便签槽(0)来自观测(3)时沿直角回程箭头走（观测下→左→上进便签）。"""
        cur = self.strip_badges[slot]
        if cur is not None and getattr(cur[1], "text", "") == text:
            return None  # 同步骤重复：徽章已在，不再演示
        if cur is not None and anims is not None:
            anims.append(cur.animate(rate_func=rf.smooth).set_opacity(0))
        elif cur is not None:
            # 不在此处直接 play（会逃过帧数记账）——挂起，由调用方并入首个分段
            self.strip_pending_fade = cur
        elbow = (slot == 0 and isinstance(start, int) and start == 3)
        if elbow:
            p0, p1, p2, p3 = self.elbow_points()
            start_pt = p0                      # 箭头起点（观测块底边的线上）
        elif isinstance(start, int):
            start_pt = self.strip_blocks[start].get_center() + np.array([0, 0.55, 0])
        else:
            start_pt = np.array([start[0], start[1], 0.0])
        land = self.strip_blocks[slot][0].get_center() + np.array([0, 0.52, 0])
        card = rr(0.66, 0.36, 0.08, "#ffffff", stroke=INK, sw=2).move_to(start_pt)
        t = txt(text, 13, INK).move_to(card)
        g = VGroup(card, t)
        g.set_z_index(8)   # v12.12：卡盖在箭头上（原 z=0 被箭头穿过）
        self.scene.add(g)
        if not elbow and anims is not None:
            anims.append(g.animate(rate_func=rf.smooth).move_to(land))
        self.strip_badges[slot] = g
        return g

    def elbow_points(self):
        """结果卡的直角路径（严格在箭头线上）：观测块底→水平段→箭头头部。"""
        block_bot = STRIP_Y - 0.275
        # v12.11（用户裁定）：落点下移到块正下方——卡顶恰抵块底、箭头尖微露，
        # 不再压块/贴名字
        return (np.array([STRIP_XS[3], block_bot, 0.0]),
                np.array([STRIP_XS[3], self.ret_y, 0.0]),
                np.array([STRIP_XS[0], self.ret_y, 0.0]),
                np.array([STRIP_XS[0], block_bot - 0.18, 0.0]))

    def strip_fly(self, start, target, text: str, anims: list):
        """指令/结果小卡从 start 飞向 target（均可为块下标或 (x, y) 坐标）并淡出。"""
        def ref_pt(ref):
            if isinstance(ref, int):
                return self.strip_blocks[ref].get_center() + np.array([0, 0.55, 0])
            return np.array([ref[0], ref[1], 0.0])
        start_pt = ref_pt(start)
        end_pt = ref_pt(target)
        card = rr(0.66, 0.36, 0.08, "#ffffff", stroke=INK, sw=2).move_to(start_pt)
        t = txt(text, 13, INK).move_to(card)
        g = VGroup(card, t)
        g.set_z_index(8)   # v12.12：飞卡同样盖线
        self.scene.add(g)
        anims.append(g.animate(rate_func=rf.smooth).move_to(end_pt).set_opacity(0))

    def _build_signal(self, p0: float):
        self.tracker = ValueTracker(p0)
        self.signal_ghosts = []
        for k in range(1, 6):
            ghost = Circle(radius=0.10 - 0.012 * k, fill_color=BLUE,
                           fill_opacity=0.35 - 0.05 * k, stroke_width=0)
            ghost.set_z_index(10)
            ghost.add_updater(
                lambda m, off=0.14 * k: m.move_to(self.signal_point(self.tracker.get_value() - off)))
            self.signal_ghosts.append(ghost)
        self.signal_dot = Circle(radius=0.13, fill_color=BLUE, fill_opacity=1,
                                 stroke_color=PAPER, stroke_width=2)
        self.signal_dot.set_z_index(11)
        self.signal_dot.add_updater(
            lambda m: m.move_to(self.signal_point(self.tracker.get_value())))

    @staticmethod
    def signal_point(phase: float) -> np.ndarray:
        p = phase % 4
        i = min(int(p), 3)
        f = p - i
        a = np.array([MOD_X[i], MOD_Y, 0.0])
        b = np.array([MOD_X[i + 1], MOD_Y, 0.0])
        return a * (1 - f) + b * f

    # -- state ------------------------------------------------------------------
    def _apply_state(self, state: dict):
        cpos = NODE_P[state["carrier"]]
        self.carrier.move_to(cpos)
        for i, name in enumerate(CRATE_ORDER):
            crate = self.crates[name]
            crate.clear_updaters()
            if state["carrying"] == name:
                crate.move_to(cpos).set_z_index(6)
                crate.add_updater(lambda m: m.move_to(self.carrier.get_center()))
            else:
                crate.move_to(self.crate_home(name, state)).set_z_index(3)
        if state["blocked_edges"]:
            self.barrier.move_to((NODE_P["B"] + NODE_P["C"]) / 2).set_opacity(1)
            self.strip_env.set_opacity(0.8)
        else:
            self.barrier.set_opacity(0).move_to(
                (NODE_P["B"] + NODE_P["C"]) / 2 + [0, 2.8, 0])

    def crate_home(self, name: str, state: dict) -> np.ndarray:
        node = state["crates"][name]
        if node == "D":
            return bay_slot(CRATE_ORDER.index(name))
        return NODE_P[node] + [0, 0.40, 0]

    def show_ring(self, i: int, anims: list):
        if i == self.ring_target:
            return
        self.ring_target = i
        anims.append(self.ring.animate(rate_func=rf.smooth)
                     .move_to([MOD_X[i], MOD_Y, 0]).set_stroke(opacity=0.95))

    def pulse_module(self, i: int, anims: list, amount=1.07):
        anims.append(self.modules[i].animate(rate_func=rf.there_and_back).scale(amount))


# ----------------------------------------------------------------------------
# Per-shot scenes
# ----------------------------------------------------------------------------
class ShotScene(MovingCameraScene):
    abstract = True
    sid = ""

    def framing(self):
        sid = self.sid
        if sid == "s01_teaser":
            # 全景完整跑一遍：整张沙盘地图全宽 + 顶部联动条（无字版）
            return np.array([-1.9, -1.1, 0.0]), 12.2
        if sid in ("agent", "experience"):
            return np.array([0.0, 0.2, 0.0]), 14.22
        if sid in ("system", "build"):
            return np.array([1.2, 1.2, 0.0]), 11.6
        if sid == "loop":
            return np.array([0.6, 1.1, 0.0]), 12.0
        if sid == "next":
            return np.array([1.0, 1.2, 0.0]), 11.6
        if sid == "feedback":
            # v12.2：弃 v9 半特写取景（曾把环境块截半）；与地图镜同框
            return np.array([-2.0, -1.15, 0.0]), 12.0
        if sid == "scope":
            # 工具列特写，但放宽到整机面板全部文字（标题+四条标签）在画内
            return np.array([2.9, -0.85, 0.0]), 9.4
        if sid in MAP_SHOTS:
            # v12：上带留给概念联动条
            return np.array([-2.0, -1.15, 0.0]), 12.0
        if sid == "representation":
            return np.array([-0.3, 1.1, 0.0]), 11.5  # 起点：概念件一排
        i = MODULE_FRAME[sid]
        return np.array([MOD_X[i], 2.45, 0.0]), 5.2

    def construct(self):
        shot = SHOT_BY_ID[self.sid]
        duration = shot["duration"]
        end = q(duration * 0.5 if PREVIEW_MODE else duration)
        state0 = state_at(shot["start"])
        stage = Stage(self, state0)
        self.stage = stage

        center, width = self.framing()
        frame = self.camera.frame
        frame.move_to(center).set(width=width)
        self.camera.background_color = BG
        if self.sid in MODULE_FRAME:
            # like the 3D renderer: machine text is hidden during module close-ups
            stage.machine_title.set_opacity(0)
            for lb in stage.machine_labels.values():
                lb.set_opacity(0)
        # v12.1：v9 遗留的概念件一排与整机面板整体退场——消费它们的特写/整机镜
        # 已于 v11 移除，职责由概念联动条接管；此前只剩取景上被截一半的残条。
        for legacy in (*stage.modules, *stage.module_labels, stage.ring,
                       stage.underglow, stage.machine_platform, stage.machine_wires,
                       *stage.machine_blocks.values(), stage.machine_title,
                       *stage.machine_labels.values()):
            legacy.set_opacity(0)
        if self.sid not in STRIP_SHOTS:
            stage.strip_group.set_opacity(0)
        else:
            # v12.7：s01 联动条只打故事节拍（其余事件不动条，顶部降噪）
            self._strip_beats_only = (self.sid == "s01_teaser")
            stage.strip_named = True  # s01 也带名字（2026-10-06 用户裁定）
            pass  # v12.7：collect 已截短+2s 位移，条恢复正常亮度
            if self.sid != "s01_teaser":
                # 联动条在场时隐藏机身文字（未引入先用的旧违例）
                stage.machine_title.set_opacity(0)
                for lb in stage.machine_labels.values():
                    lb.set_opacity(0)

        sig_on = self.sid in SIGNAL_SHOTS
        if sig_on:
            stage._build_signal(shot["start"] % 4)
            for g in stage.signal_ghosts:
                self.add(g)
            self.add(stage.signal_dot)
        # Every segment is rendered through the animated-play path with
        # run_time=(k-0.5)/25, which makes Manim emit exactly k frames
        # (its arange/int duration handling is float-fragile otherwise).
        dummy = ValueTracker(0.0)
        clock = 0.0

        def idle(d: float):
            nonlocal clock
            k = max(1, round(d * FPS)) if d > 1e-9 else 0
            if k <= 0:
                return
            tracker = stage.tracker if sig_on else dummy
            self.play(Advance(tracker, k / FPS, rate_func=rf.linear),
                      run_time=(k - 0.5) / FPS)
            clock += k / FPS

        def play_(anims, d: float):
            nonlocal clock
            k = max(1, round(d * FPS)) if d > 1e-9 else 0
            if k <= 0:
                return
            if sig_on:
                anims = list(anims) + [Advance(stage.tracker, k / FPS, rate_func=rf.linear)]
            if not anims:
                # v12.7：事件动画可能全被闸掉（s01 非节拍）——退化为时间推进保帧数
                anims = [Advance(dummy, k / FPS, rate_func=rf.linear)]
            self.play(*anims, run_time=(k - 0.5) / FPS)
            clock += k / FPS

        self._intro(play_, idle, frame, stage, end)

        items = []
        if self.sid == "s01_teaser":
            # 全景走一遍：第一趟任务（task→evidence，steps 0–27）压缩重放，
            # 呈现专用时间轴（presentation only），不改 edit.json 的真实事件时间。
            # v12.4：故事节拍锚定到旁白词时间（接到任务/看地图/搬上货/挡板/重新选路/
            # 送进终点/干完了），节拍之间的事件再均匀插值——与运行段同一套音画同步口径。
            import re as _re
            story = [e for e in EVENTS if e["step"] <= 27]
            n = len(story)
            al = json.loads((OUT / "alignment.json").read_text(encoding="utf-8")).get("s01_teaser")
            _norm = lambda x: _re.sub(r"[^\w]", "", x).lower()
            words = al["words"]
            joined = _norm("".join(w["word"] for w in words))
            cum, spans = 0, []
            for w in words:
                wn = _norm(w["word"])
                spans.append((cum, cum + len(wn)))
                cum += len(wn)

            def _wt(*phrs):
                for ph in phrs:
                    pos = joined.find(_norm(ph))
                    if pos >= 0:
                        for w, (aa, bb) in zip(words, spans):
                            if aa <= pos < max(bb, aa + 1):
                                return 0.35 + w["start"] / al["tempo"]
                return None

            def _find(pred, start=0):
                for k in range(start, n):
                    if pred(story[k]):
                        return k
                return None

            i_sub = _find(lambda x: x["tool"] == "dialogue.submit")
            i_obs = _find(lambda x: x["tool"] == "model.generate"
                          and x["args"].get("response", {}).get("tool") == "observe")
            i_pick = _find(lambda x: x["tool"] == "pickup")
            i_close = _find(lambda x: x["tool"] == "environment.close_road")
            i_reroute = _find(lambda x: x["tool"] == "move", (i_close or 0) + 1)
            i_drop = _find(lambda x: x["tool"] == "drop")
            i_reply = _find(lambda x: x["tool"] == "dialogue.reply")
            beats = sorted([(i, t) for i, t in (
                (i_sub, _wt("接到任务", "任务")),
                (i_obs, _wt("看一眼地图", "地图")),
                (i_pick, _wt("搬上货", "搬上")),
                (i_close, _wt("挡板", "路断了")),
                (i_reroute, _wt("重新选路", "重新")),
                (i_drop, _wt("送进终点", "送进")),
                (i_reply, _wt("干完了", "干完")),
            ) if i is not None and t is not None])
            span = max(0.1, shot["duration"] - 2.2)
            segs = [(-1, 0.9)] + [(i, min(t, span)) for i, t in beats] + [(n, span)]
            segs = [seg for k, seg in enumerate(segs)
                    if k == 0 or seg[1] > segs[k - 1][1] + 0.1]
            times = {}
            for i, t in beats:
                times[i] = min(t, span)
            for (o0, t0), (o1, t1) in zip(segs, segs[1:]):
                for k in range(o0 + 1, o1):
                    if k in times:
                        continue
                    f = (k - o0) / (o1 - o0)
                    times[k] = t0 + f * (t1 - t0)
            # v12.14：s01 位移按 ≥1.0s 推挤（用户裁定 2s 规则保留给故事镜；
            # 19.3s 旁白内 5×2s 物理不可行，曾把全部位移挤到尾部——B 点停 8 秒）
            order = sorted(times.keys())
            for k in order:
                if story[k]["tool"] == "move":
                    floor_t = times[k] + 1.1
                    for j in order:
                        if j > k and times[j] < floor_t:
                            times[j] = round(floor_t, 3)
                        if j > k:
                            floor_t = times[j] + 0.15
            span = min(span, shot["duration"] - 1.2)
            for j in order:
                times[j] = min(times[j], span)
            evs = []
            for i, e in enumerate(story):
                d = dict(e, time=shot["start"] + times.get(i, 0.9 + i * span / n))
                evs.append(d)
            beat_idx = {i for i, _ in beats}
            for i in beat_idx:
                evs[i]["_beat"] = True
        else:
            evs = shot_events(shot)
        seen_tools = set()
        for k, ev in enumerate(evs):
            t = q(ev["time"] - shot["start"])
            nxt = (evs[k + 1]["time"] - shot["start"]) if k + 1 < len(evs) else shot["duration"]
            tool = ev["tool"]
            if tool == "move":
                # v12.4 用户裁定：移动放慢防闪现（原 0.75/0.1 上/下限）
                # nxt/t 均为镜内相对时间（原式混用全局 ev["time"] 恒为负，
                # 导致移动永远只剩 0.45s 下限——"闪现"感的一半根源）
                if self.sid == "s01_teaser":
                    d0 = max(1.0, nxt - t)   # 全景走一遍专用（旁白时长物理约束）
                else:
                    d0 = max(2.0, nxt - t)   # 故事镜：任何一次位移 ≥2s
            elif tool == "tool.observation" and "tool.observation" not in seen_tools:
                d0 = 1.75   # 首次结果卡走箭头：2.5 倍时长（后续重复已被去重跳过）
            else:
                d0 = {"model.generate": 0.9, "tool.observation": 0.7,
                      "dialogue.submit": 0.8, "dialogue.reply": 0.8}.get(tool, 0.5)
            seen_tools.add(tool)
            items.append([t, d0, tool, ev])
        items.sort(key=lambda it: it[0])

        for idx, (t, d0, tool, ev) in enumerate(items):
            if t >= end - 1e-9:
                break
            idle(t - clock)
            if clock >= end - 1e-9:
                break
            nxt_t = items[idx + 1][0] if idx + 1 < len(items) else end
            d = q(min(d0, nxt_t - clock, end - clock))
            if d <= 0:
                continue
            self._event(stage, ev, d, play_, idle)
            if clock >= end - 1e-9:
                break
        idle(end - clock)
        if abs(clock - end) > 1e-6:
            print(f"[render_lesson_2d] WARNING {self.sid}: clock={clock} end={end}")

    # -- per-shot opening beats -------------------------------------------------
    def _intro(self, play_, idle, frame, stage, end):
        sid = self.sid
        if sid == "agent":
            up = Arrow([-2.35, 0.25, 0], [-2.35, 0.95, 0], buff=0,
                       stroke_width=6, color=BLUE, max_tip_length_to_length_ratio=0.5)
            dn = Arrow([-0.45, 0.95, 0], [-0.45, 0.25, 0], buff=0,
                       stroke_width=6, color=ORANGE, max_tip_length_to_length_ratio=0.5)
            up_t = txt("观测", 20, BLUE).move_to([-1.75, 0.6, 0])
            dn_t = txt("行动", 20, ORANGE).move_to([0.25, 0.6, 0])
            g_up, g_dn = VGroup(up, up_t), VGroup(dn, dn_t)
            idle(0.6)
            play_([GrowArrow(up), GrowArrow(dn), FadeIn(up_t), FadeIn(dn_t)], 0.5)
            idle(1.0)
            play_([g_up.animate(rate_func=rf.there_and_back).scale(1.18),
                   g_dn.animate(rate_func=rf.there_and_back).scale(1.18)], 0.7)
            idle(2.6)
            play_([g_up.animate(rate_func=rf.there_and_back).scale(1.18),
                   g_dn.animate(rate_func=rf.there_and_back).scale(1.18)], 0.7)
        elif sid in MODULE_FRAME:
            play_([frame.animate(rate_func=rf.smooth).set(width=5.2)], 0.6)
        elif sid in ("system", "build"):
            play_([frame.animate(rate_func=rf.smooth).set(width=11.6)], 1.0)
        elif sid == "representation":
            # 落点：整机面板全貌（标题+四条标签完整在画内）
            play_([frame.animate(rate_func=rf.smooth).move_to([2.9, -0.85, 0]).set(width=9.4)],
                  end)
        elif sid == "next":
            play_([frame.animate(rate_func=rf.linear).set(width=12.4)], end)

    def _strip_ok(self, ev: dict) -> bool:
        """联动条是否对本事件作出反应（s01 仅节拍事件，其余镜全部事件）。"""
        if getattr(self, "_strip_beats_only", False):
            return bool(ev.get("_beat"))
        return True

    # -- event-driven beats (presentation only; endpoints are recorded states) ----
    def _event(self, stage: Stage, ev: dict, d: float, play_, idle):
        tool = ev["tool"]
        anims = []
        if tool == "move":
            newc = ev["state"]["carrier"]
            anims.append(stage.carrier.animate(rate_func=rf.smooth).move_to(NODE_P[newc]))
            if self.sid in STRIP_SHOTS and self._strip_ok(ev):
                stage.strip_states(anims, {2: 1.0, 1: 0.7})
            play_(anims, d)
        elif tool == "pickup":
            crate = stage.crates[ev["args"]["crate"]]
            crate.set_z_index(6)
            d1 = q(min(d, 0.4))
            anims = [crate.animate(rate_func=rf.smooth).move_to(stage.carrier.get_center())]
            if self.sid in STRIP_SHOTS and self._strip_ok(ev):
                stage.strip_states(anims, {2: 1.0, 1: 0.7})
            play_(anims, d1)
            crate.clear_updaters()
            crate.add_updater(lambda m: m.move_to(stage.carrier.get_center()))
            idle(q(d - d1))
        elif tool == "drop":
            name = ev["_prev"]["carrying"] or CRATE_ORDER[0]
            crate = stage.crates[name]
            crate.clear_updaters()
            if self.sid in STRIP_SHOTS and self._strip_ok(ev):
                stage.strip_states(anims, {2: 1.0, 1: 0.7})
            crate.set_z_index(3)
            home = stage.crate_home(name, ev["state"])
            play_([crate.animate(rate_func=rf.smooth).move_to(home)], min(d, 0.45))
        elif tool == "environment.close_road":
            d1 = min(0.3, d)
            env_anims = [stage.barrier.animate(rate_func=rf.smooth)
                         .move_to((NODE_P["B"] + NODE_P["C"]) / 2).set_opacity(1)]
            if self.sid in STRIP_SHOTS:
                # 环境块独立闪现：无箭头连向模型块（"不是它干的"的视觉论证）
                env_anims.append(stage.strip_env.animate(rate_func=rf.smooth)
                                 .set_opacity(1))
            play_(env_anims, d1)
            if self.sid in STRIP_SHOTS:
                play_([stage.strip_env.animate(rate_func=rf.there_and_back).scale(1.3)], 0.4)
            # v12.9：封路红闪（road_flash）已删——挡板砸落+环境块+旁白足够，红矩形属噪音
        elif tool == "model.generate":
            d1 = min(0.9, d)
            if self.sid in STRIP_SHOTS:
                nxt = ev["args"].get("response", {}).get("tool", "")
                label = {"observe": "查路", "pickup": "装货", "drop": "卸货",
                         "move": "移动"}.get(nxt, "主意")
                stage.strip_states(anims, {1: 1.0, 2: 0.45, 3: 0.45})
                stage.strip_badge(2, 1, label, anims)
            play_(anims, d1)
        elif tool == "tool.observation":
            d1 = min(0.7, d)
            if self.sid in STRIP_SHOTS and self._strip_ok(ev):
                stage.strip_states(anims, {3: 1.0, 2: 0.7, 0: 0.9})
                # v12.10 用户裁定：结果卡严格沿箭头走（插在箭头中间），
                # 三段 0.25/1.20/0.30s 共 1.75s＝平时短距 0.7s 的 2.5 倍，
                # 终点落在箭头头部
                g = stage.strip_badge(0, 3, "结果", None)
                if g is not None:
                    p0, p1, p2, p3 = stage.elbow_points()
                    seg1 = list(anims)
                    if stage.strip_pending_fade is not None:
                        seg1.append(stage.strip_pending_fade.animate(rate_func=rf.smooth)
                                    .set_opacity(0))
                        stage.strip_pending_fade = None
                    play_(seg1 + [g.animate(rate_func=rf.smooth).move_to(p1)], 0.25)
                    play_([g.animate(rate_func=rf.linear).move_to(p2)], 1.20)
                    play_([g.animate(rate_func=rf.smooth).move_to(p3)], 0.30)
                    return
            play_(anims, d1)
        elif tool == "dialogue.submit":
            anims = []
            if self.sid in STRIP_SHOTS:
                # 任务卡从左侧飞入便签块并驻留（便签首次登场的锚）
                stage.strip_states(anims, {0: 0.9})
                stage.strip_badge(0, (-6.6, STRIP_Y + 0.55), "任务", anims)
            play_(anims, min(0.8, d))
        elif tool == "dialogue.reply":
            anims = []
            if self.sid in STRIP_SHOTS and self._strip_ok(ev):
                stage.strip_states(anims, {1: 0.7})
                stage.strip_fly(1, (-6.6, STRIP_Y + 0.55), "回复", anims)
            play_(anims, min(0.8, d))
        else:  # observe and any other tool execution -> tool module
            d1 = min(0.6, d)
            if self.sid in STRIP_SHOTS and self._strip_ok(ev):
                stage.strip_states(anims, {2: 1.0, 1: 0.7})
            play_(anims, d1)

class Advance(Animation):
    """Move a ValueTracker by delta across the play, linearly."""

    def __init__(self, tracker: ValueTracker, delta: float, **kwargs):
        super().__init__(tracker, **kwargs)
        self.delta = float(delta)

    def begin(self):
        self.start_v = self.mobject.get_value()
        super().begin()

    def interpolate_mobject(self, alpha: float) -> None:
        a = self.rate_func(alpha) if self.rate_func else alpha
        self.mobject.set_value(self.start_v + self.delta * a)




# ----------------------------------------------------------------------------
# v11 concept & replay scenes (2D-only; the recorded run is rendered in 3D)
# ----------------------------------------------------------------------------
CONCEPT_IDS = {"s02_agent", "s03_dock", "s12_replay", "s13_context", "s14_model",
               "s15_tools", "s16_obs", "s17_loop", "s18_family", "s19_multi",
               "s20_yourturn", "s21_next"}
# 2026-10-06 用户裁定：全 2D 管线（真实运行段也走 Manim 沙盘舞台，弃 3D）。
STILLS = OUT / "stills"
STATION_COLORS = [BLUE, YELLOW, ORANGE, GREEN]
STATION_NAMES = ["上下文", "大语言模型", "工具", "观测"]
STATION_EN = ["context", "large language model", "tool", "observation"]
STATION_LABEL_OFF = [(0.0, 0.66), (1.28, 0.0), (0.0, -0.66), (-1.28, 0.0)]


def still(name: str) -> ImageMobject:
    path = STILLS / f"still_{name}.png"
    if not path.exists():
        raise SystemExit(f"missing replay still: {path} (extract after 3D render)")
    img = ImageMobject(str(path))
    return img


def framed_still(name: str, height: float) -> Group:
    img = still(name).set_height(height)
    w = img.width
    frame = rr(w + 0.12, height + 0.12, 0.08, BG, stroke=INK, sw=3).move_to(img)
    return Group(frame, img)


def term_card(zh: str, en: str, color: str, scale: float = 1.0) -> VGroup:
    card = rr(3.5 * scale, 1.35 * scale, 0.12 * scale, "#ffffff",
              stroke=color, sw=4 * scale)
    t1 = txt(zh, int(30 * scale), INK, "BOLD").move_to(card.get_center() + [0, 0.18 * scale, 0])
    t2 = txt(en, int(15 * scale), STRUCTURE).move_to(card.get_center() + [0, -0.34 * scale, 0])
    return VGroup(card, t1, t2)


def machine_glyph(scale: float = 1.0, ghost_opacity: float = 0.5) -> VGroup:
    body = rr(6.4 * scale, 4.2 * scale, 0.2 * scale, DECK, stroke=STRUCTURE, sw=3 * scale)
    ghosts = VGroup()
    for gx in (-1, 0, 1):
        for gy in (0.5, -0.5):
            ghosts.add(rr(1.7 * scale, 1.35 * scale, 0.1 * scale, PAPER,
                          stroke=STRUCTURE, sw=1.5 * scale, so=0.8)
                       .set_fill(opacity=ghost_opacity)
                       .move_to(body.get_center() + [gx * 1.95 * scale, gy * 1.25 * scale, 0]))
    return VGroup(body, ghosts)


def dialogue_box(scale: float = 1.0) -> tuple:
    box = rr(5.2 * scale, 2.9 * scale, 0.18 * scale, "#ffffff", stroke=INK, sw=3 * scale)
    head = txt("任务对话框", int(17 * scale), STRUCTURE).move_to(
        box.get_corner(UL) + [1.15 * scale, -0.42 * scale, 0])
    line = Line(box.get_center() + [-2.1 * scale, -0.35 * scale, 0],
                box.get_center() + [2.1 * scale, -0.35 * scale, 0],
                stroke_width=2 * scale, stroke_color=DECK)
    return box, head, line


def build_loop(center, scale: float = 1.0, lit: int = 0, labels_on: bool = False):
    """Four named stations + dashed guide ring; arrows drawn only on request
    (S17 连线成圈). lit = number of stations filled (0..4)."""
    c = np.array([center[0], center[1], 0.0])
    r = 1.5 * scale
    pos = [c + np.array([0, r, 0]), c + np.array([r, 0, 0]),
           c + np.array([0, -r, 0]), c + np.array([-r, 0, 0])]
    nodes = []
    for i in range(4):
        n = Circle(radius=0.36 * scale, stroke_width=5 * scale,
                   stroke_color=STATION_COLORS[i], fill_color=STATION_COLORS[i],
                   fill_opacity=0.9 if i < lit else 0.0).move_to(pos[i])
        nodes.append(n)
    labels = VGroup()
    if labels_on:
        for i in range(4):
            off = np.array([STATION_LABEL_OFF[i][0], STATION_LABEL_OFF[i][1], 0.0]) * scale
            lb = txt(STATION_NAMES[i], int(22 * scale)).move_to(pos[i] + off)
            lb.set_opacity(1.0 if i < lit else 0.28)
            labels.add(lb)
    guide = DashedVMobject(Circle(radius=r, stroke_width=3, stroke_color=STRUCTURE,
                                  stroke_opacity=0.35).move_to(c), num_dashes=48)
    group = VGroup(*nodes, labels, guide)
    return {"pos": pos, "nodes": nodes, "labels": labels, "guide": guide,
            "center": c, "scale": scale, "group": group}


def loop_arrows(diag) -> VGroup:
    pos, s = diag["pos"], diag["scale"]
    arrows = VGroup()
    for i in range(4):
        a, b = pos[i], pos[(i + 1) % 4]
        d = (b - a) / np.linalg.norm(b - a)
        start = a + d * 0.5 * s
        end = b - d * 0.5 * s
        arr = CurvedArrow(start, end, angle=-0.55, stroke_width=5 * s,
                          color=INK)
        arrows.add(arr)
    return arrows


def loop_point(pos, ph: float) -> np.ndarray:
    i = int(ph) % 4
    f = ph - int(ph)
    return pos[i] * (1 - f) + pos[(i + 1) % 4] * f


class ConceptScene(MovingCameraScene):
    abstract = True
    sid = ""

    def construct(self):
        shot = SHOT_BY_ID[self.sid]
        duration = shot["duration"]
        end = q(duration * 0.5 if PREVIEW_MODE else duration)
        self.camera.background_color = BG
        self.camera.frame.move_to([0, 0, 0]).set(width=14.22)
        dummy = ValueTracker(0.0)
        self._clock = 0.0

        def idle(d: float):
            k = max(1, round(d * FPS)) if d > 1e-9 else 0
            if k <= 0:
                return
            self.play(Advance(dummy, k / FPS, rate_func=rf.linear),
                      run_time=(k - 0.5) / FPS)
            self._clock += k / FPS

        def play_(anims, d: float):
            k = max(1, round(d * FPS)) if d > 1e-9 else 0
            if k <= 0:
                return
            self.play(*anims, run_time=(k - 0.5) / FPS)
            self._clock += k / FPS

        idle(0.5)
        self._content(play_, idle, end)
        idle(end - self._clock)
        if abs(self._clock - end) > 1e-6:
            print(f"[render_lesson_2d] WARNING {self.sid}: clock={self._clock} end={end}")

    # -- per-shot content -------------------------------------------------------
    def _content(self, play_, idle, end):
        sid = self.sid
        if sid == "s02_agent":
            machine = machine_glyph(1.0).move_to([0, 0.7, 0])
            plate = term_card("智能体", "agent", STRUCTURE, 1.2).move_to([0, -2.7, 0])
            plate.save_state()
            play_([FadeIn(machine)], 0.8)
            for g in machine[1]:
                play_([g.animate(rate_func=rf.there_and_back).set_fill(opacity=0.75)], 0.3)
            plate.scale(1.5)
            play_([plate.animate(rate_func=rf.smooth).scale(1 / 1.5)], 0.5)
            idle(max(0, end * 0.55 - 0.5 - 2.8))
            play_([machine.animate(rate_func=rf.there_and_back).scale(1.03)], 0.8)
        elif sid == "s03_dock":
            box, head, line = dialogue_box(1.0)
            g1 = VGroup(box, head, line).move_to([-3.3, 0.5, 0])
            machine = machine_glyph(0.68, ghost_opacity=0.25).move_to([3.4, 0.4, 0])
            play_([FadeIn(g1)], 0.6)
            chars = "把货送到终点 D"
            typed = VGroup()
            for k, ch in enumerate(chars):
                t = txt(ch, 26).move_to(line.get_start() + [0.32 + k * 0.42, 0.45, 0])
                typed.add(t)
                play_([FadeIn(t)], 0.16)
            play_([FadeIn(machine)], 0.6)
            arrow = CurvedArrow(g1.get_right() + [0.1, -0.3, 0],
                                machine.get_left() + [-0.1, -0.6, 0],
                                angle=-0.5, stroke_width=5, color=STRUCTURE)
            play_([Create(arrow)], 0.5)
        elif sid == "s12_replay":
            # v12.12：缩 0.85+左移——右侧"大语言模型"一带不再拥挤
            diag = build_loop([-3.9, 0.15], 0.85, lit=0, labels_on=False)
            still_g = framed_still("closure", 4.4).move_to([2.9, 0.2, 0])
            self.add(diag["group"])
            diag["group"].set_opacity(0.0)
            play_([FadeIn(still_g)], 0.6)
            play_([diag["group"].animate.set_opacity(1.0)], 0.4)
            play_([FadeIn(diag["guide"])], 0.5)
        elif sid in ("s13_context", "s14_model", "s15_tools", "s16_obs"):
            i = {"s13_context": 0, "s14_model": 1, "s15_tools": 2, "s16_obs": 3}[sid]
            still_name = ["task", "read", "pickup", "feedback"][i]
            # v12.12：缩 0.85+左移——右站标签到定帧间隙从 0.28 扩到约 1.0
            diag = build_loop([-3.9, 0.15], 0.85, lit=i, labels_on=True)
            still_g = framed_still(still_name, 3.9).move_to([3.4, 1.1, 0])
            card = term_card(STATION_NAMES[i], STATION_EN[i], STATION_COLORS[i], 1.0)
            card.move_to([3.4, -2.1, 0])
            self.add(diag["group"], still_g)
            diag["labels"][i].set_opacity(1.0)
            play_([diag["nodes"][i].animate(rate_func=rf.smooth).set_fill(opacity=0.9),
                   FadeIn(diag["labels"][i])], 0.7)
            play_([still_g.animate(rate_func=rf.there_and_back).scale(1.02)], 0.5)
            card.save_state()
            card.scale(1.4)
            play_([card.animate(rate_func=rf.smooth).scale(1 / 1.4)], 0.5)
            idle(max(0, end * 0.5 - 3.0))
            play_([card.animate(rate_func=rf.there_and_back).scale(1.05)], 0.6)
        elif sid == "s17_loop":
            diag = build_loop([0, 0.1], 1.15, lit=4, labels_on=True)
            self.add(diag["group"])
            arrows = loop_arrows(diag)
            for a in arrows:
                play_([Create(a)], 0.4)
            loop_card = term_card("控制循环", "control loop", PURPLE, 0.95)
            loop_card.move_to(diag["center"] + [0, -0.05, 0])
            loop_card.save_state()
            loop_card.scale(1.35)
            play_([loop_card.animate(rate_func=rf.smooth).scale(1 / 1.35)], 0.5)
            outer = rr(8.6, 7.6, 0.5, BG, stroke=STRUCTURE, sw=6, fo=0)
            # v12.11：原 y=4.6 完全出画（frame 顶 4.0）——骑到外圈顶边上
            outer_label = term_card("智能体", "agent", STRUCTURE, 0.85).move_to([0, 3.45, 0])
            play_([Create(outer), FadeIn(outer_label)], 0.8)
            dot = Circle(radius=0.14, fill_color=BLUE, fill_opacity=1,
                         stroke_color=PAPER, stroke_width=2).move_to(loop_point(diag["pos"], 0))
            tracker = ValueTracker(0.0)
            dot.add_updater(lambda m: m.move_to(loop_point(diag["pos"], tracker.get_value())))
            self.add(dot)
            play_([Advance(tracker, 4.0, rate_func=rf.linear)], 2.4)
            idle(max(0, end * 0.75 - self._clock))
            play_([Advance(tracker, 4.0, rate_func=rf.linear)], 2.4)
        elif sid == "s18_family":
            # v12.13（AE 定版）：延续镜——第 0 帧即 s17 结尾完整构图，无重建动画
            diag = build_loop([0, 0.1], 1.15, lit=4, labels_on=True)
            arrows = loop_arrows(diag)
            card = term_card("控制循环", "control loop", PURPLE, 0.95).move_to(diag["center"])
            outer = rr(8.6, 7.6, 0.5, BG, stroke=STRUCTURE, sw=6, fo=0)
            agent = term_card("智能体", "agent", STRUCTURE, 0.85).move_to([0, 3.45, 0])
            self.add(diag["group"], arrows, card, outer, agent)
            idle(max(0.0, end * 0.45 - 0.5))
            play_([outer.animate(rate_func=rf.there_and_back).set_stroke(width=9)], 0.9)
        elif sid == "s19_multi":
            # v12.13（AE 定版）：弃循环图改联动条——避免循环图第三次出现；
            # 四块横排 + 工具块闪两下 + 两个任务的真实定帧（同一台机器，两种活）
            xs = [-4.6, -2.2, 0.2, 2.6]
            blocks = []
            for i in range(4):
                b = rr(1.9, 0.6, 0.12, STATION_COLORS[i], stroke=INK, sw=1.5, fo=0.45)
                b.move_to([xs[i], 1.9, 0]).set_z_index(6)
                lb = txt(STATION_NAMES[i], 18, INK, "BOLD").move_to([xs[i], 1.9, 0])
                lb.set_z_index(7)
                blocks.append(b)
                self.add(b, lb)
            s1 = framed_still("delivery", 2.9).move_to([-2.9, -1.3, 0])
            s2 = framed_still("second", 2.9).move_to([2.9, -1.3, 0])
            play_([FadeIn(s1)], 0.5)
            play_([FadeIn(s2)], 0.5)
            idle(max(0.0, end * 0.4 - 1.0 - 0.5))
            for _ in range(2):
                play_([blocks[2].animate(rate_func=rf.there_and_back).scale(1.25)], 0.55)
                blocks[2].set_fill(opacity=1.0)
                idle(0.3)
        elif sid == "s20_yourturn":
            # v12.11：定帧曾超右缘 0.02 且与对话框贴边——收进并拉开
            box, head, line = dialogue_box(1.15)
            g1 = VGroup(box, head, line).move_to([-3.5, 0.3, 0])
            mapimg = framed_still("task", 4.15).move_to([3.3, 0.2, 0])
            play_([FadeIn(g1)], 0.6)
            play_([FadeIn(mapimg)], 0.5)
            cursor = Rectangle(width=0.04, height=0.5, fill_color=INK,
                               fill_opacity=1, stroke_width=0).move_to(
                line.get_start() + [0.25, 0.5, 0])
            self.add(cursor)
            for _ in range(3):
                play_([cursor.animate(rate_func=rf.there_and_back).set_opacity(0)], 0.5)
                idle(0.2)
        elif sid == "s21_next":
            machine = machine_glyph(0.85).move_to([0, 0.4, 0])
            lid = rr(6.4 * 0.85, 0.34, 0.1, STRUCTURE, stroke=INK, sw=2)
            lid.move_to(machine.get_corner(UL) + [0, 0.18, 0])
            play_([FadeIn(machine)], 0.5)
            self.add(lid)
            play_([lid.animate(rate_func=rf.smooth)
                   .rotate(-0.28, about_point=lid.get_right())
                   .shift([0, 0.32, 0])], 0.8)
            # v12.13（方案E）：去循环图叠影（与 s18 重复），只留机身+开盖箭头
            arrow = Arrow([-4.6, 3.1, 0], [-3.9, 3.6, 0], buff=0,
                          stroke_width=6, color=ORANGE,
                          max_tip_length_to_length_ratio=0.5)
            play_([GrowArrow(arrow)], 0.4)



def _make_scene(sid: str):
    base = ConceptScene if sid in CONCEPT_IDS else ShotScene
    return type(f"S_{sid}", (base,), {"sid": sid})


for _s in SHOTS:
    globals()[f"S_{_s['id']}"] = _make_scene(_s["id"])


def manim_base_cmd():
    py = sys.executable
    return [py, "-m", "manim", "--disable_caching", "--resolution", "1920,1080",
            "--fps", "25", "--media_dir", str(MEDIA)]


def run_manim(cmd, log_path: Path):
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with open(log_path, "w", encoding="utf-8") as log:
        proc = subprocess.run(cmd, stdout=log, stderr=subprocess.STDOUT, env=ENV)
    if proc.returncode != 0:
        tail = log_path.read_text(encoding="utf-8", errors="replace")[-3000:]
        raise RuntimeError(f"manim failed ({log_path}):\n{tail}")


ENV = None


def make_env():
    global ENV
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    env["PATH"] = str(FFMPEG_BIN) + os.pathsep + env.get("PATH", "")
    ENV = env


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--only", default="", help="comma separated shot ids")
    ap.add_argument("--preview", default="", help="comma separated shot ids: midpoint PNG only")
    opts = ap.parse_args()
    make_env()
    script = Path(__file__).resolve()
    logdir = MEDIA / "manim_logs"

    if opts.preview:
        for sid in [s for s in opts.preview.split(",") if s]:
            log = logdir / f"preview_{sid}.log"
            cmd = manim_base_cmd() + ["-s", "--format=png", "-o", f"preview_{sid}",
                                      str(script), f"S_{sid}"]
            env = dict(ENV)
            env["RENDER2D_PREVIEW"] = "1"
            log.parent.mkdir(parents=True, exist_ok=True)
            with open(log, "w", encoding="utf-8") as lf:
                proc = subprocess.run(cmd, stdout=lf, stderr=subprocess.STDOUT, env=env)
            if proc.returncode != 0:
                print(log.read_text(encoding="utf-8", errors="replace")[-3000:])
                raise SystemExit(f"preview {sid} failed")
            hits = sorted(MEDIA.glob(f"images/**/preview_{sid}.png"), key=lambda p: p.stat().st_mtime)
            if not hits:
                raise SystemExit(f"preview png for {sid} not found under {MEDIA}/images")
            SEGS.mkdir(parents=True, exist_ok=True)
            dst = SEGS / f"preview_{sid}.png"
            shutil.copy(hits[-1], dst)
            print(f"preview {sid} -> {dst}")
        return

    ids = ([s for s in opts.only.split(",") if s] if opts.only
           else [s["id"] for s in SHOTS])
    SEGS.mkdir(parents=True, exist_ok=True)
    for sid in ids:
        if sid not in SHOT_BY_ID:
            raise SystemExit(f"unknown shot id: {sid}")
        log = logdir / f"{sid}.log"
        cmd = manim_base_cmd() + ["-o", sid, str(script), f"S_{sid}"]
        print(f"rendering {sid} ...", flush=True)
        run_manim(cmd, log)
        src = MEDIA / "videos" / "render_lesson_2d" / "1080p25" / f"{sid}.mp4"
        if not src.exists():
            hits = sorted(MEDIA.glob(f"videos/**/{sid}.mp4"), key=lambda p: p.stat().st_mtime)
            if not hits:
                raise SystemExit(f"output mp4 for {sid} not found (see {log})")
            src = hits[-1]
        shutil.copy(src, SEGS / f"{sid}.mp4")
        print(f"  -> {SEGS / (sid + '.mp4')}", flush=True)


if __name__ == "__main__":
    main()
