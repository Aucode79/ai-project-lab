"""Batch CosyVoice3 synthesis in the existing WSL runtime; load model once."""
import json
import sys
from pathlib import Path

sys.path.insert(0, "/root/opt/CosyVoice")
from smoke_cosyvoice3 import (patch_torchaudio_io, patch_modelscope_local_first,
    MODEL_DIR, PROMPT_TEXT, PROMPT_WAV, TARGET_SR, save_wav)
import torch
import torchaudio
from cosyvoice.cli.cosyvoice import AutoModel

root = Path(sys.argv[1])
lines = json.loads((root / "narration.json").read_text(encoding="utf-8"))
patch_torchaudio_io()
patch_modelscope_local_first()
model = AutoModel(model_dir=MODEL_DIR)
assert getattr(model.frontend, "text_frontend", ""), "text normalization unavailable"
for line in lines:
    output = root / "voice" / (line["id"] + ".wav")
    output.parent.mkdir(parents=True, exist_ok=True)  # 全新克隆无 voice/（gitignore）——自建，免手工 mkdir
    if output.is_file():
        continue
    chunks = [v["tts_speech"] for v in model.inference_zero_shot(
        line["text"], PROMPT_TEXT, PROMPT_WAV, stream=False)]
    audio = torch.cat(chunks, dim=1)
    if model.sample_rate != TARGET_SR:
        audio = torchaudio.functional.resample(audio, model.sample_rate, TARGET_SR)
    save_wav(str(output), audio, TARGET_SR)
    print("VOICE", line["id"], audio.shape[-1] / TARGET_SR, flush=True)
