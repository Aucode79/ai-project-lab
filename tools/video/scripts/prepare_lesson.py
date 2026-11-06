"""Create a measured edit from voice files and the verified schema-v6 run."""
import json
import math
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "lesson01"
lines = json.loads((ROOT / "narration.json").read_text(encoding="utf-8"))
run = json.loads((ROOT / "run.json").read_text(encoding="utf-8"))
# Inclusive step references from this verified run, never synthetic tool actions.
RANGES = {"task": (0, 0), "read": (1, 3), "pickup": (4, 6), "closure": (7, 9),
          "feedback": (10, 10), "reroute": (11, 19), "boundary": (20, 22),
          "delivery": (23, 25), "evidence": (26, 27), "second": (28, 31), "collect": (32, 45)}
TITLES = ["全景 · 完整跑一遍", "智能体（agent）", "派任务",
          "任务与目标", "问路", "开工", "封路！", "坏消息到了", "改道", "一次一段",
          "交活", "验货", "新任务", "又开工了",
          "回放 · 安名字", "上下文 context", "大语言模型 LLM", "工具 tool",
          "观测 observation", "控制循环 control loop", "六个名字一台机",
          "同一台机器", "轮到你了", "下一课"]
# v11 思考窗：封路镜在常规 2.5s 停顿外再加 3s 全片唯一思考窗（第一课 §3）。
THINKING_EXTRA = {"closure": 3.0}
# 2026-10-06 用户裁决：台词含"未引入先用"术语的镜，句后停顿 = 2.5s × 1.5（多 1.25s 消化垫）。
# 清单来自当日术语顺序审计：boundary(功能) / collect(工具) / s13_context(便签) / s14_model(第零课·模型)。
DIGEST_EXTRA = {"boundary": 1.25, "collect": 1.25, "s13_context": 1.25, "s14_model": 1.25}
events, shots, cursor = [], [], 0.0
last_state = run["steps"][0]["world"]["entities"]
for index, line in enumerate(lines):
    wav = ROOT / "voice" / (line["id"] + ".wav")
    duration = 0
    if wav.exists():
        with wave.open(str(wav), "rb") as voice:
            duration = voice.getnframes() / voice.getframerate()
    reserve = 2.5 + THINKING_EXTRA.get(line["id"], 0.0) + DIGEST_EXTRA.get(line["id"], 0.0)
    length = math.ceil(max(duration + reserve, len(line["text"]) / 4 + 0.8) * 25) / 25
    shot = dict(line, start=round(cursor, 3), end=round(cursor + length, 3),
                duration=length, voice_duration=duration, title=TITLES[index], index=index)
    if line["id"] in RANGES:
        lo, hi = RANGES[line["id"]]
        source = run["steps"][lo:hi+1]
        for offset, step in enumerate(source):
            time = cursor + 0.4 + offset / max(1, len(source)) * (length - reserve)
            events.append({"time": round(time, 3), "step": step["i"], "tool": step["action"].get("tool"),
                           "args": step["action"].get("args", {}), "state": step["world"]["entities"]})
        shot["step_range"] = [lo, hi]
    shots.append(shot)
    cursor += length
manifest = {"fps": 25, "duration": round(cursor, 3), "frames": round(cursor * 25),
            "runId": run["run"]["runId"], "initial": last_state, "shots": shots, "events": events}
(ROOT / "edit.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
print("EDIT", manifest["duration"], "seconds", manifest["frames"], "frames")
