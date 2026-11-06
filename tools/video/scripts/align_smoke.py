"""faster-whisper 词级时间戳冒烟：转写一段 wav，输出逐词 start/end。

用于逐字点亮字幕的可行性验证：确认本机 Windows venv 能加载 large-v3、
拿到带时间戳的中文词序列，并把完整结果落 JSON 供后续管线对齐。

跑法（先设 CUDA DLL 由脚本自己接，无需手改 PATH）：
  D:/ai-project-lab/tools/video/.venv-win/Scripts/python.exe \
      tools/video/scripts/align_smoke.py
可选环境变量 HF_ENDPOINT=https://hf-mirror.com（hf.co 慢时用镜像下载模型）。
"""

import argparse
import json
import logging
import os
import sys
import time
from pathlib import Path

# --- CUDA 运行时 DLL：ctranslate2 的 CUDA 后端需要 CUDA12+cuDNN9，pip 的
#     nvidia-cudnn-cu12 / nvidia-cublas-cu12 把 DLL 放在 site-packages/nvidia/*/bin，
#     不在系统 PATH 里，必须在 import ctranslate2 之前补进去。 ---
_HERE = Path(__file__).resolve()
_VIDEO_DIR = _HERE.parent.parent              # tools/video
_SITE_PACKAGES = Path(sys.prefix) / "Lib" / "site-packages"
_CUDA_DLL_DIRS = [
    _SITE_PACKAGES / "nvidia" / "cudnn" / "bin",
    _SITE_PACKAGES / "nvidia" / "cublas" / "bin",
]
_extra_dll_dirs = [str(d) for d in _CUDA_DLL_DIRS if d.is_dir()]
if _extra_dll_dirs:
    os.environ["PATH"] = os.pathsep.join(_extra_dll_dirs + [os.environ.get("PATH", "")])
    if hasattr(os, "add_dll_directory"):
        for _d in _extra_dll_dirs:
            os.add_dll_directory(_d)

import ctranslate2  # noqa: E402
import faster_whisper  # noqa: E402

DEFAULT_AUDIO = _VIDEO_DIR / "smoke" / "whisper_input.wav"
DEFAULT_OUT = _VIDEO_DIR / "smoke" / "whisper_align.json"
DEFAULT_MODEL_DIR = _VIDEO_DIR / "models" / "whisper"
MODEL_ID = "large-v3"          # Systran/faster-whisper-large-v3


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="faster-whisper 词级时间戳冒烟")
    p.add_argument("--audio", default=str(DEFAULT_AUDIO), help="输入 wav 路径")
    p.add_argument("--model", default=MODEL_ID, help="模型名或 HF repo id")
    p.add_argument("--download-root", default=str(DEFAULT_MODEL_DIR),
                   help="模型缓存目录（必须留在 D 盘）")
    p.add_argument("--out", default=str(DEFAULT_OUT), help="词级结果落盘 JSON 路径")
    p.add_argument("--device", default="cuda", choices=["cuda", "cpu"],
                   help="首选设备；cuda 起不来会自动退 cpu 并打印 FALLBACK")
    p.add_argument("--compute-type", default=None, help="缺省 cuda=float16 / cpu=int8")
    p.add_argument("--language", default=None, help="缺省自动检测")
    p.add_argument("--beam-size", type=int, default=5)
    p.add_argument("--limit", type=int, default=10, help="打印前 N 个词")
    return p.parse_args(argv)


def load_model(args):
    """按首选设备加载模型；cuda 失败则明确落回 cpu。"""
    attempts = []
    if args.device == "cuda":
        attempts.append(("cuda", args.compute_type or "float16"))
    attempts.append(("cpu", args.compute_type or "int8"))

    last_err = None
    for device, compute_type in attempts:
        t0 = time.time()
        try:
            model = faster_whisper.WhisperModel(
                args.model,
                device=device,
                compute_type=compute_type,
                download_root=args.download_root,
            )
        except Exception as exc:  # cudnn/cublas 缺失等
            last_err = exc
            print(f"[device] {device}/{compute_type} 加载失败：{type(exc).__name__}: {exc}",
                  file=sys.stderr)
            if device == "cpu":
                raise
            print("[device] FALLBACK -> CPU（GPU 不可用，词级对齐退 CPU 跑）", file=sys.stderr)
            continue
        print(f"[device] 使用 {device} / compute_type={compute_type}"
              f"（模型加载 {time.time() - t0:.1f}s）")
        return model, device, compute_type
    raise last_err


def collect(model, audio, args):
    t0 = time.time()
    segments, info = model.transcribe(
        audio,
        language=args.language,
        word_timestamps=True,
        beam_size=args.beam_size,
    )
    # segments 是惰性生成器：必须在这里消费完
    seg_list = []
    words = []
    for seg in segments:
        seg_words = []
        for w in (seg.words or []):
            item = {
                "word": w.word,
                "start": round(w.start, 3),
                "end": round(w.end, 3),
                "probability": round(w.probability, 4),
            }
            seg_words.append(item)
            words.append(item)
        seg_list.append({
            "id": seg.id,
            "start": round(seg.start, 3),
            "end": round(seg.end, 3),
            "text": seg.text,
            "words": seg_words,
        })
    elapsed = time.time() - t0
    return seg_list, words, info, elapsed


def main(argv=None):
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    args = parse_args(argv)

    audio = str(Path(args.audio).resolve())
    if not Path(audio).is_file():
        print(f"输入音频不存在：{audio}", file=sys.stderr)
        return 2

    print(f"[env] faster-whisper {faster_whisper.__version__} / "
          f"ctranslate2 {ctranslate2.__version__} / "
          f"CUDA device count {ctranslate2.get_cuda_device_count()}")
    print(f"[env] CUDA DLL 目录 {_extra_dll_dirs or '（无，未装 nvidia-*-cu12）'}")
    print(f"[env] 模型缓存 {Path(args.download_root).resolve()}")

    model, device, compute_type = load_model(args)
    seg_list, words, info, elapsed = collect(model, audio, args)

    print(f"[asr] audio={audio}")
    print(f"[asr] 检测语言 {info.language}（p={info.language_probability:.3f}）"
          f" 时长 {info.duration:.2f}s 转写耗时 {elapsed:.2f}s")
    print(f"[asr] 词数 {len(words)} / 片段 {len(seg_list)}；前 {args.limit} 个词：")
    for i, w in enumerate(words[: args.limit]):
        print(f"  [{i:>2}] word={w['word']!r} start={w['start']:.3f} end={w['end']:.3f}")

    report = {
        "audio": audio,
        "audio_duration_s": round(info.duration, 3),
        "model": args.model,
        "model_cache": str(Path(args.download_root).resolve()),
        "faster_whisper_version": faster_whisper.__version__,
        "ctranslate2_version": ctranslate2.__version__,
        "device": device,
        "compute_type": compute_type,
        "cuda_device_count": ctranslate2.get_cuda_device_count(),
        "language": info.language,
        "language_probability": round(info.language_probability, 4),
        "transcribe_seconds": round(elapsed, 2),
        "full_text": "".join(s["text"] for s in seg_list).strip(),
        "segments": seg_list,
        "words": words,
    }
    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"[out] 已写出 {out.resolve()}（{out.stat().st_size} bytes，"
          f"device={device} 词数={len(words)}）")
    return 0 if words else 1


if __name__ == "__main__":
    sys.exit(main())
