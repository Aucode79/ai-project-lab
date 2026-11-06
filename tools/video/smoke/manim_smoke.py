from manim import *

class Smoke(Scene):
    def construct(self):
        self.camera.background_color = "#F9FCFD"
        box = RoundedRectangle(corner_radius=0.15, width=7, height=2.2, stroke_color="#36A2B8", stroke_width=6)
        t = Text("智能体实验室 · Manim 冒烟", font="Microsoft YaHei", font_size=40, color="#2B211A")
        self.add(box, t)
