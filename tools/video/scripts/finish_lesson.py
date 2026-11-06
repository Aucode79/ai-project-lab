"""Measure voices, align words with faster-whisper, write captions and mix audio.

Run using tools/video/.venv-win/Scripts/python.exe. --mux assembles existing frames.
"""
import argparse
import difflib
import json
import math
import os
import re
import subprocess
import wave
from array import array
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1] / "lesson01"
parser = argparse.ArgumentParser()
parser.add_argument("--mux", action="store_true")
opts = parser.parse_args()


def stamp(sec):
    tick = round(sec * 100)
    return f"{tick//360000}:{tick//6000%60:02}:{tick//100%60:02}.{tick%100:02}"


def run(command):
    flags = (subprocess.CREATE_NO_WINDOW | subprocess.ABOVE_NORMAL_PRIORITY_CLASS) if os.name == "nt" else 0
    result = subprocess.run(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, creationflags=flags)
    if result.returncode:
        raise RuntimeError(result.stderr.decode("utf-8", errors="replace"))


if opts.mux:
    edit = json.loads((ROOT / "edit.json").read_text(encoding="utf-8"))
    run(["ffmpeg", "-y", "-framerate", "25", "-i", str(ROOT / "frames/frame_%04d.jpg"),
         "-i", str(ROOT / "narration.wav"), "-vf", "ass=captions.ass",
         "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
         "-af", "loudnorm=I=-19:TP=-2.2:LRA=7", "-ar", "48000", "-c:a", "aac", "-b:a", "192k",
         "-t", str(edit["duration"]), "-movflags", "+faststart", "lesson01-agent.mp4"])
    print("VIDEO COMPLETE")
    raise SystemExit()

from align_smoke import load_model, parse_args, DEFAULT_MODEL_DIR
if not (DEFAULT_MODEL_DIR / "model.bin").exists():
    raise SystemExit("whisper 模型缺失：" + str(DEFAULT_MODEL_DIR)
                     + "  请按 tools/video/ENVIRONMENT.md 一节下载 "
                       "Systran/faster-whisper-large-v3 到该目录"
                       "（HF_ENDPOINT=https://hf-mirror.com，Xet 401 时加 HF_HUB_DISABLE_XET=1）。")
align_args = parse_args(["--language", "zh", "--model", str(DEFAULT_MODEL_DIR)])
model, device, compute = load_model(align_args)
assert device == "cuda", "Production alignment requires the configured GPU runtime"
lines = json.loads((ROOT / "narration.json").read_text(encoding="utf-8"))
alignment = {}
normalized = lambda s: re.sub(r"[^\w]", "", s).lower()


def transcribe_words(path, text):
    """initial_prompt occasionally trips whisper into a canned hallucination
    (e.g. the 明镜 outro); on low similarity retry without the prompt."""
    best = None
    for kwargs in ({"initial_prompt": text}, {}):
        segments, info = model.transcribe(str(path), language="zh",
            word_timestamps=True, beam_size=5, **kwargs)
        words = [{"word": w.word, "start": w.start, "end": w.end,
                  "probability": w.probability}
                 for seg in segments for w in (seg.words or [])]
        recognized = "".join(w["word"] for w in words)
        similarity = difflib.SequenceMatcher(None, normalized(text),
                                             normalized(recognized)).ratio()
        if not best or similarity > best[3]:
            best = (words, info, recognized, similarity)
        if similarity >= 0.6:
            break
    return best


for line in lines:
    source = ROOT / "voice" / (line["id"] + ".wav")
    words, info, recognized, similarity = transcribe_words(source, line["text"])
    assert words, line["id"]
    tempo = min(1.0, info.duration / max(info.duration, len(line["text"]) / 4))
    output = ROOT / "voice_edit" / (line["id"] + ".wav")
    output.parent.mkdir(exist_ok=True)
    run(["ffmpeg", "-y", "-i", str(source), "-af", f"atempo={tempo:.6f}",
         "-ar", "48000", "-ac", "1", "-c:a", "pcm_s16le", str(output)])
    alignment[line["id"]] = {"words": words, "text": recognized, "similarity": similarity, "tempo": tempo}
    print("ALIGNED", line["id"], round(similarity, 3), flush=True)
    # Persist each completed alignment so interruption does not hide progress.
    (ROOT / "alignment.json").write_text(json.dumps(alignment, ensure_ascii=False, indent=2), encoding="utf-8")

# The edit now uses actual speech length after rate correction.
edit = json.loads((ROOT / "edit.json").read_text(encoding="utf-8"))
old_shots = {s["id"]: dict(s) for s in edit["shots"]}
cursor = 0.0
audio = array("h")
THINKING_EXTRA = {"closure": 3.0}
# ---- v12.4 音画同步（2026-10-06 用户裁定）：事件不再均匀撒网格，而是锚定到
# "描述它的那句台词"的词级时间戳；无锚事件在相邻锚点间插值。锚=（主短语, 兜底短语,
# 镜内事件序号）。ASR 未命中任一短语时该锚放弃、退回网格段，不会更糟。----
PHRASE_ANCHORS = {
    "task": [("任务给出了目标", "任务", 0)],
    "read": [("问一句", "查路", 0), ("答案回到眼前", "回到眼前", 2)],
    "pickup": [("出主意的不露面", "出主意", 0), ("动手的看得见", "动手", 1)],
    "closure": [("到了", "运输车", 1), ("路被封住了", "封住", 2)],
    "feedback": [("先看结果", "看结果", 0)],
    "reroute": [("重新想了想", "重新想", 0)],
    "boundary": [("一次只挪一段", "挪一段", 1)],
    "delivery": [("货落了地", "货落", 1)],
    "evidence": [("最后查一眼", "查一眼", 0)],
    "second": [("再派个新活", "新活", 0)],
}


def _phrase_time(al, phrases):
    """在词级对齐里找短语首词的源语音时间；找不到返回 None。"""
    import re as _re
    words = al["words"]
    joined = _re.sub(r"[^\w]", "", "".join(w["word"] for w in words)).lower()
    cum, spans = 0, []
    for w in words:
        wn = _re.sub(r"[^\w]", "", w["word"]).lower()
        spans.append((cum, cum + len(wn)))
        cum += len(wn)
    for ph in phrases:
        pos = joined.find(_re.sub(r"[^\w]", "", ph).lower())
        if pos >= 0:
            for w, (a, b) in zip(words, spans):
                if a <= pos < max(b, a + 1):
                    return w["start"]
    return None


def retime_shot_events(sid, evs, base, length, al, reserve):
    n = len(evs)
    if not n:
        return
    end_t = base + max(0.5, length - reserve)
    anchors = []
    if al:
        for phrase, fallback, ordinal in PHRASE_ANCHORS.get(sid, []):
            if ordinal >= n:
                continue
            t = _phrase_time(al, (phrase, fallback))
            if t is not None:
                anchors.append((ordinal, min(max(base + 0.35 + t / al["tempo"],
                                                 base + 0.4), end_t)))
    anchors.sort()
    dedup = []
    for o, t in anchors:  # 锚只与锚去重（首字锚可与镜首边界重合）
        if dedup and t <= dedup[-1][1] + 0.15:
            continue
        dedup.append((o, t))
    for o, t in dedup:
        evs[o]["time"] = round(t, 3)
    segs = [(-1, base + 0.4)] + dedup + [(n, end_t)]
    anchored = {o for o, _ in dedup}
    for (o0, t0), (o1, t1) in zip(segs, segs[1:]):
        for i in range(o0 + 1, o1):
            if i in anchored:
                continue
            f = (i - o0) / (o1 - o0)
            evs[i]["time"] = round(t0 + f * (t1 - t0), 3)


# The edit now uses actual speech length after rate correction.
edit = json.loads((ROOT / "edit.json").read_text(encoding="utf-8"))
old_shots = {s["id"]: dict(s) for s in edit["shots"]}
cursor = 0.0
audio = array("h")
DIGEST_EXTRA = {"boundary": 1.25, "collect": 1.25, "s13_context": 1.25, "s14_model": 1.25}
for shot in edit["shots"]:
    with wave.open(str(ROOT / "voice_edit" / (shot["id"] + ".wav")), "rb") as wav:
        samples = array("h", wav.readframes(wav.getnframes()))
    duration = len(samples) / 48000
    reserve = 2.5 + THINKING_EXTRA.get(shot["id"], 0.0) + DIGEST_EXTRA.get(shot["id"], 0.0)
    length = math.ceil(max(duration+reserve, len(shot["text"])/4+0.8)*25)/25
    old = old_shots[shot["id"]]
    shot.update(start=cursor, end=cursor+length, duration=length, voice_duration=duration)
    if "step_range" in shot:
        lo, hi = shot["step_range"]
        shot_events = [ev for ev in edit["events"] if lo <= ev["step"] <= hi]
        retime_shot_events(shot["id"], shot_events, cursor, length,
                           alignment.get(shot["id"]), reserve)
        # v12.7：豁免全撤——所有位移 ≥2s（用户裁定"任何一次位移"）
        if True:
            prev_t = None
            for ev in shot_events:
                if ev["tool"] == "move":
                    floor_prev = (prev_t + 0.8) if prev_t is not None else 0.0
                    ev["time"] = round(max(cursor + 0.3, ev["time"] - 0.5,
                                           floor_prev), 3)
                prev_t = ev["time"]
            seen_first_obs = False
            for i, ev in enumerate(shot_events[:-1]):
                if ev["tool"] == "move":
                    floor_t = ev["time"] + 2.0
                    push_gap = 0.8
                elif ev["tool"] == "tool.observation" and not seen_first_obs:
                    # v12.10：首次结果卡沿箭头走 1.75s（2.5 倍），后继让位
                    floor_t = ev["time"] + 1.8
                    push_gap = 0.8
                    seen_first_obs = True
                else:
                    continue
                for j in range(i + 1, len(shot_events)):
                    if shot_events[j]["time"] < floor_t:
                        shot_events[j]["time"] = round(floor_t, 3)
                    floor_t = shot_events[j]["time"] + push_gap
            # 全局最小间隙 0.6s（obs→gen 等连环变状态不再叠拍）
            for i in range(1, len(shot_events)):
                if shot_events[i]["time"] - shot_events[i-1]["time"] < 0.6:
                    shot_events[i]["time"] = round(shot_events[i-1]["time"] + 0.6, 3)
            need = 0.0
            obs_tail_done = False
            for ev in shot_events:
                if ev["tool"] == "move":
                    tail = 2.0
                elif ev["tool"] == "tool.observation" and not obs_tail_done:
                    tail = 2.6   # 首次结果卡 1.75s 走箭头 + 收尾
                    obs_tail_done = True
                else:
                    tail = 0.8
                need = max(need, ev["time"] - cursor + tail)
            need += 0.8
            if need > length:
                length = math.ceil(need * 25) / 25
                shot["end"] = round(cursor + length, 3)
                shot["duration"] = length
    if shot["id"] == "s01_teaser":
        # v12.7：全景走一遍也要容纳 ≥2s 位移——按事件最小占时动态延长镜长
        story = [ev for ev in edit["events"] if ev["step"] <= 27]
        n_move = sum(1 for ev in story if ev["tool"] == "move")
        need = 1.2 + n_move * 2.0 + (len(story) - n_move) * 0.5 + 2.0
        if need > length:
            length = math.ceil(need * 25) / 25
            shot["end"] = round(cursor + length, 3)
            shot["duration"] = length
    audio.extend(array("h", [0])*16800)
    audio.extend(samples)
    expected_end = round((cursor+length)*48000)
    audio.extend(array("h", [0])*max(0, expected_end-len(audio)))
    cursor += length
edit.update(duration=round(cursor, 3), frames=round(cursor*25))
(ROOT / "edit.json").write_text(json.dumps(edit, ensure_ascii=False, indent=2), encoding="utf-8")
with wave.open(str(ROOT / "narration.wav"), "wb") as wav:
    wav.setnchannels(1)
    wav.setsampwidth(2)
    wav.setframerate(48000)
    wav.writeframes(audio.tobytes())

header = """[Script Info]
ScriptType: v4.00+
PlayResX: 1920
PlayResY: 1080
ScaledBorderAndShadow: yes
WrapStyle: 2

[V4+ Styles]
Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
Style: Subtitle,Microsoft YaHei,44,&H00F1DA36,&H00FFFFFF,&H002B211A,&H00302520,0,0,0,0,100,100,0,0,3,14,0,2,70,70,50,1
Style: Header,Microsoft YaHei,29,&H00403B26,&H00403B26,&H00F9FCFD,&H00F9FCFD,0,0,0,0,100,100,0,0,1,0,0,7,70,70,45,1
Style: Title,Microsoft YaHei,46,&H00403B26,&H00403B26,&H00F9FCFD,&H00F9FCFD,1,0,0,0,100,100,0,0,1,0,0,7,70,70,96,1
Style: Tag,Microsoft YaHei,26,&H00403B26,&H00403B26,&H00F9FCFD,&H00F9FCFD,0,0,0,0,100,100,0,0,1,0,0,9,70,70,49,1
Style: Tool,Microsoft YaHei,29,&H00403B26,&H00403B26,&H00E9F4F6,&H00E9F4F6,0,0,0,0,100,100,0,0,3,12,0,7,70,70,180,1

[Events]
Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
"""
rows = []


def add(start, end, text, style, layer=1):
    rows.append(f"Dialogue: {layer},{stamp(start)},{stamp(end)},{style},,0,0,0,,{text}")


for shot in edit["shots"]:
    start, end = shot["start"], shot["end"]
    add(start, end, "AI PROJECT LAB  /  第一课", "Header")
    add(start, end, shot["title"], "Title")
    label = ("开场" if shot["index"] < 3 else
             ("真实运行回放 · 等待已压缩" if shot["index"] < 14 else
              ("复盘 · 安名字" if shot["index"] < 21 else "课后体验")))
    add(start, end, f'{label}    {shot["index"]+1:02d} / {len(edit["shots"])}', "Tag")
    aligned = alignment[shot["id"]]
    # Match script glyphs to recognized word intervals. Punctuation/unrecognized
    # glyphs inherit nearest anchors; the QA report exposes ASR disagreement.
    recognized, anchors = "", []
    for word in aligned["words"]:
        for index, char in enumerate(word["word"]):
            recognized += char
            anchors.append((word["start"]+(word["end"]-word["start"])*index/max(1,len(word["word"])))/aligned["tempo"])
    text = shot["text"]
    positions = {}
    for match in difflib.SequenceMatcher(None, text.lower(), recognized.lower()).get_matching_blocks():
        for offset in range(match.size): positions[match.a+offset] = anchors[match.b+offset]
    timings = []
    for index in range(len(text)):
        if index in positions:
            timing = positions[index]
        else:
            before = max((k for k in positions if k < index), default=-1)
            after = min((k for k in positions if k > index), default=len(text))
            a = positions.get(before, 0)
            b = positions.get(after, shot["voice_duration"])
            timing = a + (b-a)*(index-before)/(after-before)
        timings.append(max(timings[-1] if timings else 0, timing))
    timings.append(shot["voice_duration"])
    # Phrase boundaries follow punctuation and otherwise cap at 22 glyphs.
    chunks, begin = [], 0
    for index, char in enumerate(text):
        if (char in "，。；：" and index-begin >= 7) or index-begin >= 21 or index == len(text)-1:
            chunks.append((begin, index+1))
            begin = index+1
    for lo, hi in chunks:
        a, b = start+0.35+timings[lo], start+0.35+timings[hi]
        caption = "".join("{\\kf%d}" % max(1,round((timings[i+1]-timings[i])*100)) + text[i] for i in range(lo,hi))
        add(a, max(a+0.1,b), caption, "Subtitle")

events = edit["events"]
for index, event in enumerate(events):
    end = events[index+1]["time"] if index+1 < len(events) else edit["shots"][20]["start"]
    tool, args = event["tool"], event["args"]
    text = ""
    # v12 卡片降日常语（复盘挂牌段才给学名；运行段零术语口径的卡片面）
    zh = {"observe": "查路", "pickup": "装货", "drop": "卸货", "move": "移动"}
    if tool == "model.generate":
        call = args["response"]
        text = "它想了想 → " + zh.get(call["tool"], str(call["tool"]))
    elif tool in ("observe", "move", "pickup", "drop"):
        text = "干了一下 · " + zh.get(tool, tool)
        if tool == "move" and isinstance(args, dict) and "to" in args:
            text = "干了一下 · 移动到 " + str(args["to"])
    elif tool == "tool.observation":
        state = event["state"]
        text = "看了一眼 · 位置=" + state["carrier"] + "  装载=" + (state["carrying"] or "空")
        if state["blocked_edges"]: text += "  B—C 已封路"
    elif tool == "environment.close_road": text = "环境变了 · B—C 已封路"
    elif tool == "dialogue.submit": text = "派活 · " + args["text"]
    elif tool == "dialogue.reply": text = "回复 · " + args["text"]
    # Escape ASS control syntax in JSON and keep cards within the frame width.
    text = text.replace("{", "[").replace("}", "]")
    if len(text) > 49: text = text[:49] + "…"
    if text: add(event["time"], end, f'#{event["step"]:02d}  '+text, "Tool")
(ROOT / "captions.ass").write_text(header + "\n".join(rows), encoding="utf-8-sig")
print("AUDIO AND CAPTIONS", edit["duration"], "seconds")
