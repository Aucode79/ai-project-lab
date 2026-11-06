# 环境搭建（当前管线所需全套）

> 2026-10-08 从旧 README §三/§四/§八分拣重建，只保留**当前全 2D 管线仍需要的东西**。
> 3D 时代独有依赖（Blender、Godot→glTF 桥）已归档至 [`archive/README-v1-legacy.md`](archive/README-v1-legacy.md)，当前管线**不需要**。

## 总览

| 组件 | 位置 | 用途 |
|---|---|---|
| Python 3.12 | `py -3.12`（系统） | prepare/finish 等数据脚本 |
| whisper venv | `tools/video/.venv-win` | faster-whisper 词级对齐（finish_lesson） |
| Manim venv | `tools/video/.venv-manim` | 全部渲染（render_lesson_2d） |
| ffmpeg 静态构建 | `tools/video/ffmpeg-master-latest-win64-gpl/` | 抽帧/混流/ffprobe（不入库） |
| CosyVoice3 | WSL `/root/opt/CosyVoice` | 中文配音（9.1GB 模型在 WSL 原生路径） |

## 一、whisper venv（Python 3.13 亦可）

```bash
py -3.13 -m venv .venv-win
./.venv-win/Scripts/python.exe -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple \
  faster-whisper==1.2.1 ctranslate2==4.8.2 nvidia-cudnn-cu12 nvidia-cublas-cu12 soundfile av==14.2.0
```

- **av 必须钉 14.2.0**：19.x 删了 `metadata_errors` 参数（faster-whisper 调用即崩）；12.x 无 cp313 轮子。
- 模型 `Systran/faster-whisper-large-v3`（2.9GB）平铺在 `tools/video/models/whisper/`，调用必须显式 `--model models/whisper`（默认走 HF 联网解析会超时）。下载用 `HF_ENDPOINT=https://hf-mirror.com`；**若报 Xet 401，加 `HF_HUB_DISABLE_XET=1`**。
- cuDNN/cublas DLL 由脚本自动从 pip 包补 PATH，无需手配。

## 二、Manim venv

```bash
py -3.12 -m venv .venv-manim
./.venv-manim/Scripts/python.exe -m pip install -i https://pypi.tuna.tsinghua.edu.cn/simple   -r requirements-manim.txt      # 必须钉 manim==0.21.0（新版 API 漂移未验证）
```

- 当前 Manim CE 0.21，全轮子安装；**不需要 LaTeX**（中文走系统微软雅黑 `Text(font="Microsoft YaHei")`）。
- ffmpeg 复用上面的静态构建（跑渲染前把它的 bin prepend 到 PATH）。

## 三、ffmpeg 静态构建（Windows）

```bash
curl -fL -o ffmpeg.zip "https://github.com/BtbN/FFmpeg-Builds/releases/latest/download/ffmpeg-master-latest-win64-gpl.zip"
unzip ffmpeg.zip && rm ffmpeg.zip   # → ffmpeg-master-latest-win64-gpl/
```

验收必看退出码与版本输出（曾发生 `-t` 残值吞掉管道失败的假成功）。

## 四、CosyVoice3（WSL，从零部署实录）

模型：`FunAudioLLM/Fun-CosyVoice3-0.5B-2512`（9.1GB）→ WSL 原生路径 `/root/opt/pretrained_models/Fun-CosyVoice3-0.5B/`（**严禁放 /mnt/**，9p 文件系统慢）。

```bash
# uv + Python 3.12（WSL 系统源是 3.14，torch 生态偏新）
curl -LsSf https://astral.sh/uv/install.sh | sh
git clone https://github.com/FunAudioLLM/CosyVoice.git --recursive   # → ~/opt/CosyVoice
cd ~/opt/CosyVoice && uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python torch==2.11.0 torchaudio==2.11.0 \
  --index-url https://download.pytorch.org/whl/cu128
# 依赖（对官方 requirements 的实测偏离，逐条钉）：
#   matplotlib==3.9.2（3.7.5 无 cp312 轮子会整批失败）、grpcio/grpcio-tools==1.62.3、
#   不装 deepspeed/tensorrt、onnxruntime==1.18.0、modelscope 升最新（1.20 已被服务端拒收）、
#   openai-whisper==20231117 需 setuptools<=75 + --no-build-isolation + 装 tiktoken、
#   需要系统 g++（pyworld 源码编译）、阿里云 PyPI 镜像
# 模型下载：
uvx --from modelscope modelscope download --model FunAudioLLM/Fun-CosyVoice3-0.5B-2512 \
  --local_dir ~/opt/pretrained_models/Fun-CosyVoice3-0.5B
# wetext 预热（必须，否则中文正则化静默失效；限流 403 就循环重试到 ZH TN OK）：
.venv/bin/python -c 'from modelscope import snapshot_download; snapshot_download("pengzhendong/wetext")'
```

**shim**：`scripts/smoke_cosyvoice3.py` 拷到 `/root/opt/CosyVoice/`（voice_lesson 的 sys.path 指向那里）。它内置三个补丁：torchaudio 2.11 走 soundfile（无需 TorchCodec）、modelscope 有本地缓存直接放行不请求 hub（新版即使缓存齐全也会发列表请求、被限流后 wetext 静默退化）、Matcha-TTS 子模块 PYTHONPATH。

输出口径：48 kHz / mono / 16 bit（模型原生 24kHz，脚本重采样）。性能参考：fp32 / 8GB 卡 RTF≈1.6–1.9。

## 五、首次自检清单

```bash
# 1) whisper 冒烟（应输出词级时间戳 JSON）
./.venv-win/Scripts/python.exe scripts/align_smoke.py --model models/whisper \
  --audio smoke/whisper_input.wav --out smoke/_check.json --language zh --device cuda
# 2) CosyVoice 冒烟（WSL 内，应出 48kHz wav）
CV3_TEXT="冒烟测试。" CV3_OUT=/tmp/smoke.wav .venv/bin/python smoke_cosyvoice3.py
# 3) Manim 冒烟（应出含中文的测试帧）
./.venv-manim/Scripts/python.exe -m manim -ql smoke/manim_smoke.py Smoke -o manim_smoke.mp4
```
