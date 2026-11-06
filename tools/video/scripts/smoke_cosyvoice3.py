"""CosyVoice3 运行时 shim（2026-10-02 重建；原件只在旧机器上、从未入库）。

voice_lesson.py 依赖本模块导出：patch_torchaudio_io, patch_modelscope_local_first,
MODEL_DIR, PROMPT_TEXT, PROMPT_WAV, TARGET_SR, save_wav。
本文件入库于 tools/video/scripts/，使用前拷贝到 /root/opt/CosyVoice/（voice_lesson
的 sys.path 指向那里）。音色参考用仓库自带 asset/zero_shot_prompt.wav，台词出处
example.py；换音色 = 换 CV3_PROMPT/CV3_PROMPT_TEXT（两者必须对应同一段音频）。
"""
import os
import sys

# Matcha-TTS 子模块不在 site-packages，原机器靠 run.sh export PYTHONPATH；
# 本模块在 cosyvoice 之前被 import，这里补上等效路径。
_MATCHA = "/root/opt/CosyVoice/third_party/Matcha-TTS"
if os.path.isdir(_MATCHA) and _MATCHA not in sys.path:
    sys.path.insert(0, _MATCHA)

MODEL_DIR = os.environ.get("CV3_MODEL", "/root/opt/pretrained_models/Fun-CosyVoice3-0.5B")
PROMPT_WAV = os.environ.get("CV3_PROMPT", "/root/opt/CosyVoice/asset/zero_shot_prompt.wav")
PROMPT_TEXT = os.environ.get("CV3_PROMPT_TEXT",
    "You are a helpful assistant.<|endofprompt|>希望你以后能够做的比我还好呦。")
TARGET_SR = 48000  # 课程管线口径：48 kHz / mono / 16 bit（CosyVoice3 原生 24 kHz，由调用方重采样）


def patch_torchaudio_io():
    """torchaudio 2.11 起旧版 load/save 需要 TorchCodec；统一改走 soundfile。"""
    import torch
    import torchaudio
    import soundfile as sf

    if getattr(torchaudio, "_soundfile_io_patched", False):
        return

    def load(filepath, *args, **kwargs):
        kwargs.pop("backend", None)
        frame_offset = int(kwargs.pop("frame_offset", 0) or 0)
        num_frames = kwargs.pop("num_frames", -1)
        stop = None if num_frames is None or num_frames < 0 else frame_offset + int(num_frames)
        data, sr = sf.read(filepath, dtype="float32", always_2d=True,
                           start=frame_offset, stop=stop)
        return torch.from_numpy(data.T).contiguous(), sr

    def save(filepath, src, sample_rate, *args, **kwargs):
        kwargs.pop("backend", None)
        kwargs.pop("encoding", None)
        kwargs.pop("bits_per_sample", None)
        if isinstance(src, torch.Tensor):
            src = src.detach().cpu().numpy()
        if src.ndim == 2 and src.shape[0] < src.shape[1]:
            src = src.T  # [channels, frames] -> [frames, channels]
        ext = str(filepath).lower().rsplit(".", 1)[-1]
        subtype = "PCM_16" if ext == "wav" else None
        sf.write(str(filepath), src, int(sample_rate), subtype=subtype)

    torchaudio.load = load
    torchaudio.save = save
    torchaudio._soundfile_io_patched = True


def patch_modelscope_local_first():
    """有本地缓存/本地路径时 snapshot_download 直接放行，不请求 hub。

    新版 modelscope 即使缓存齐全也会向 hub 发文件列表请求，被限流（403）后
    frontend 的 wetext 归一化会整体放弃（text_frontend=''）。wetext 在 frontend
    初始化时才 import snapshot_download，所以必须把源头模块一并包掉。
    """
    import sys

    def find_cached(model_id):
        base = os.environ.get("MODELSCOPE_CACHE", os.path.expanduser("~/.cache/modelscope"))
        for cand in (f"{base}/hub/{model_id}", f"{base}/hub/models/{model_id}",
                     f"{base}/models/{model_id}"):
            if os.path.isdir(cand):
                try:
                    next(os.scandir(cand))
                except StopIteration:
                    continue
                return cand
        return None

    def make(orig):
        def local_first(model_id, *args, **kwargs):
            if os.path.isdir(str(model_id)):
                return str(model_id)
            cached = find_cached(str(model_id))
            if cached:
                return cached
            return orig(model_id, *args, **kwargs)
        local_first._is_local_first = True
        return local_first

    def wrap(mod, attr="snapshot_download"):
        fn = getattr(mod, attr, None)
        if callable(fn) and not getattr(fn, "_is_local_first", False):
            setattr(mod, attr, make(fn))

    for name in list(sys.modules):
        root = name.split(".")[0]
        if root in ("modelscope", "modelscope_hub", "cosyvoice"):
            mod = sys.modules.get(name)
            if mod is not None and hasattr(mod, "snapshot_download"):
                wrap(mod)
    # wetext 稍后才 import，源头函数先包掉
    for name in ("modelscope_hub.snapshot_download", "modelscope.hub.snapshot_download",
                 "modelscope.hub.api"):
        try:
            mod = __import__(name, fromlist=["snapshot_download"])
            if hasattr(mod, "snapshot_download"):
                wrap(mod)
        except Exception:
            pass


def save_wav(path, audio, sample_rate):
    """16 bit PCM mono 落盘；输入 float tensor [1, frames] 或 numpy。"""
    import numpy as np
    import soundfile as sf
    import torch

    if isinstance(audio, torch.Tensor):
        audio = audio.detach().cpu().numpy()
    sf.write(str(path), np.squeeze(audio), int(sample_rate), subtype="PCM_16")


if __name__ == "__main__":
    # 冒烟：CV3_TEXT=文本 CV3_OUT=输出wav bash 里直接 python smoke_cosyvoice3.py
    import torch

    text = os.environ.get("CV3_TEXT", "欢迎使用智能体实验室。")
    out = os.environ.get("CV3_OUT", "/root/opt/CosyVoice/smoke_out.wav")
    patch_torchaudio_io()
    patch_modelscope_local_first()
    from cosyvoice.cli.cosyvoice import AutoModel
    model = AutoModel(model_dir=MODEL_DIR)
    chunks = [v["tts_speech"] for v in model.inference_zero_shot(
        text, PROMPT_TEXT, PROMPT_WAV, stream=False)]
    audio = torch.cat(chunks, dim=1)
    if model.sample_rate != TARGET_SR:
        import torchaudio
        audio = torchaudio.functional.resample(audio, model.sample_rate, TARGET_SR)
    save_wav(out, audio, TARGET_SR)
    print("SMOKE OK", out)
