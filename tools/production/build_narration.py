#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""微课生产管线 · 逐镜配音与词级字幕时间（spec §8 管线第四步的成片版）。

一句一行不够用：分镜稿把台词按镜头切好并给了名义秒位，成片要的是
"这条台词实际多长、每个字什么时候出口"。这里做三件事：

  1. 逐镜 edge-tts 合成 → layers/<集号>/shot_<id>.mp3，同时收 WordBoundary 事件
     拿词级时间（字幕逐字点亮靠它，不靠估）
  2. 按实测长度重排时间线：镜头顺序铺，镜间留 gap 呼吸，装不下台词的镜头按
     实测加长（分镜稿 §3.1 的口径是"超了就删字，不加快语速"——这里先把超了多少
     报出来，删不删字是人定的）
  3. 拼成一条 layers/<集号>/narration.wav（整片长度、已按时间线定位），
     写 layers/<集号>/narration.json（HTML 读它）与 <集号>.srt（独立字幕，§7.1）

台词里的「」『』是书面引号，不配音（进 TTS 前剥掉），字幕与画面仍按原文显示。

用法（WSL）：
  python3 tools/production/build_narration.py --episode w01
  VOICE=zh-CN-XiaoxiaoNeural RATE=+0% python3 tools/production/build_narration.py --episode w01
  # 只重合成台词改过的镜，其余复用现有 mp3 与词级 cue（改 v4 台词时用）
  python3 tools/production/build_narration.py --episode w01 --only s2,s5,s6,s7,s8
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from compose_clip import find_tool, tool_path  # noqa: E402  复用 ffmpeg/ffprobe 发现与路径转换

REPO = Path(__file__).resolve().parent.parent.parent
VOICE = os.environ.get("VOICE", "zh-CN-XiaoyiNeural")
RATE = os.environ.get("RATE", "+0%")       # 实测 4.1 字/秒，落在分镜稿"儿童向每秒 4–5 字"档内
GAP = float(os.environ.get("GAP", "0.3"))   # 镜间呼吸
TAIL = float(os.environ.get("TAIL", "0.35"))  # 台词说完到切镜的余量
GAIN = os.environ.get("GAIN", "+6dB")         # edge-tts 直出实测 max -7.6 dB / mean -25.8 dB，
                                              # 手机外放偏轻；抬 6 dB 后峰值 -1.6 dBFS，不削顶
SPEAK_STRIP = re.compile(r"[「」『』“”\"]")


def speak_text(line: str) -> str:
    return SPEAK_STRIP.sub("", line).replace("——", "，")


async def synth(text: str, mp3: Path) -> list[dict]:
    """合成一句，返回词级 cue（t 相对这一句的 0 点）。"""
    import edge_tts

    communicate = edge_tts.Communicate(text, VOICE, rate=RATE, boundary="WordBoundary")
    cues: list[dict] = []
    with mp3.open("wb") as f:
        async for chunk in communicate.stream():
            if chunk["type"] == "audio":
                f.write(chunk["data"])
            elif chunk["type"] == "WordBoundary":
                cues.append({
                    "text": chunk["text"],
                    "t": round(chunk["offset"] / 10_000_000.0, 3),
                    "dur": round(chunk["duration"] / 10_000_000.0, 3),
                })
    if mp3.stat().st_size == 0:
        sys.exit(f"FAIL：{mp3.name} 空文件——edge-tts 没出音（网络或被限流）")
    return cues


def srt_time(sec: float) -> str:
    ms = int(round(sec * 1000))
    h, rem = divmod(ms, 3600_000)
    m, rem = divmod(rem, 60_000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def write_srt(path: Path, shots: list[dict]) -> None:
    blocks = []
    for i, shot in enumerate(shots, start=1):
        blocks.append(f"{i}\n{srt_time(shot['start'])} --> {srt_time(shot['end'])}\n{shot['line']}\n")
    path.write_text("\n".join(blocks), encoding="utf-8")


def media_duration(ffprobe: str, path: Path) -> float:
    cmd = [ffprobe, "-v", "quiet", "-show_entries", "format=duration",
           "-of", "default=nw=1:nk=1", tool_path(ffprobe, path)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0 or not r.stdout.strip():
        sys.exit(f"FAIL：ffprobe 读不出 {path.name} 的时长：{r.stderr[-400:]}")
    return float(r.stdout.strip())


def mux(ffmpeg: str, shots: list[dict], out_wav: Path, total: float) -> None:
    """各镜 mp3 按实测时间线定位，混成一条整片长度的 wav。"""
    cmd = [ffmpeg, "-hide_banner", "-loglevel", "error", "-y"]
    for shot in shots:
        cmd += ["-i", tool_path(ffmpeg, REPO / shot["audio"])]
    fc = []
    for i, shot in enumerate(shots):
        delay = int(round(shot["start"] * 1000))
        fc.append(f"[{i}:a]aresample=48000,adelay={delay}|{delay}[d{i}]")
    fc.append("".join(f"[d{i}]" for i in range(len(shots)))
              + f"amix=inputs={len(shots)}:normalize=0:duration=longest,"
              + f"volume={GAIN},apad,atrim=0:{total}[aout]")
    cmd += ["-filter_complex", ";".join(fc), "-map", "[aout]",
            "-ar", "48000", "-ac", "2", tool_path(ffmpeg, out_wav)]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"FAIL：拼轨 ffmpeg 退出 {r.returncode}\n{r.stderr[-1500:]}")


def main() -> None:
    ap = argparse.ArgumentParser(description="逐镜配音 + 词级字幕时间 + 拼轨")
    ap.add_argument("--episode", required=True, help="课号，如 w01")
    ap.add_argument("--only", default=None,
                    help="只重合成这些镜（逗号分隔 id，如 s2,s5）；其余镜复用现有 mp3 与旧 cue")
    args = ap.parse_args()

    meta_path = REPO / "data" / f"{args.episode}_shots.json"
    if not meta_path.exists():
        sys.exit(f"缺 {meta_path.relative_to(REPO)}（先写镜头时间线）")
    meta = json.loads(meta_path.read_text(encoding="utf-8"))
    shots = meta["shots"]
    out_dir = REPO / "layers" / args.episode
    out_dir.mkdir(parents=True, exist_ok=True)
    ffprobe = find_tool("ffprobe")

    only = {x.strip() for x in args.only.split(",") if x.strip()} if args.only else None
    prev: dict = {}
    if only is not None:
        narr_old = out_dir / "narration.json"
        if not narr_old.exists():
            sys.exit(f"FAIL：--only 要复用旧 cue，但缺 {narr_old.relative_to(REPO)}")
        prev = {s["id"]: s for s in json.loads(narr_old.read_text(encoding="utf-8"))["shots"]}
        print(f"配音：--only 只重合成 {sorted(only)}，其余 {sorted(set(prev) - only)} 复用旧 mp3 + 词级 cue")

    cursor = 0.0
    drift = []
    for shot in shots:
        nominal = shot["end"] - shot["start"]
        mp3 = out_dir / f"shot_{shot['id']}.mp3"
        if only is not None and shot["id"] not in only:
            if shot["id"] not in prev or not mp3.exists():
                sys.exit(f"FAIL：--only 未含 {shot['id']}，但没法复用（缺 {mp3.name} 或旧 narration.json 的 cue）")
            cues = prev[shot["id"]]["cues"]
            dur = prev[shot["id"]]["audio_dur"]
        else:
            cues = asyncio.run(synth(speak_text(shot["line"]), mp3))
            dur = media_duration(ffprobe, mp3)
        start = cursor if cursor == 0.0 else cursor + GAP
        need = dur + TAIL
        length = max(nominal, need)
        if need > nominal:
            drift.append(f"  {shot['id']}：台词 {dur:.1f}s，名义镜头 {nominal:.1f}s → 加长到 {length:.1f}s")
        shot.update({"audio": f"layers/{args.episode}/shot_{shot['id']}.mp3",
                     "audio_dur": round(dur, 3),
                     "start": round(start, 3), "end": round(start + length, 3),
                     "nominal": round(nominal, 3), "cues": cues})
        cursor = shot["end"]

    total = round(cursor + 0.4, 3)
    ffmpeg = find_tool("ffmpeg")
    wav = out_dir / "narration.wav"
    mux(ffmpeg, shots, wav, total)
    (out_dir / "narration.json").write_text(
        json.dumps({"episode": args.episode, "voice": VOICE, "rate": RATE,
                    "total": total, "fps": meta.get("fps", 25),
                    "shots": [{k: s[k] for k in ("id", "start", "end", "line", "audio_dur", "cues")}
                              for s in shots]}, ensure_ascii=False, indent=1),
        encoding="utf-8")
    write_srt(out_dir / f"{args.episode}.srt", shots)
    (out_dir / "voiceover.txt").write_text(
        "\n".join(f"[{s['id']} {s['start']:.1f}–{s['end']:.1f}] {s['line']}" for s in shots) + "\n",
        encoding="utf-8")

    print(f"配音：voice={VOICE} rate={RATE}  逐镜 {len(shots)} 句 → {wav.relative_to(REPO)}")
    print(f"配音：名义总长 {meta['total']:.1f}s → 实测排布 {total:.1f}s（差 {total - meta['total']:+.1f}s）")
    if drift:
        print("配音：以下镜头装不下台词（删字还是加长，按分镜稿 §3.1 该由人定）：")
        print("\n".join(drift))
    print(f"配音：字幕 {len(shots)} 条 → {(out_dir / (args.episode + '.srt')).relative_to(REPO)}")


if __name__ == "__main__":
    main()
