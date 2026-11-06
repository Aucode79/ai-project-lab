> ⚠️ **本文件为历史归档（2026-10-08 起停止维护）**：v9 时代 3D 管线与重建记录。
> 当前体系的操作真源是 [`../README.md`](../README.md)；环境见 [`../ENVIRONMENT.md`](../ENVIRONMENT.md)；
> 坑位见 [`../PITFALLS.md`](../PITFALLS.md)；迭代史见 `docs/20-验收/2026-10-08-第一课成片迭代全记录.md`。
> 仍有效的经验（whisper av 版本钉子、CosyVoice 部署偏离、混流目录规矩等）已分拣进新文档，本档仅存历史脉络。

# Blender 视频工具链（教学微课新制作管线 · 真源）

> **本篇是本工具链的唯一真源**：路径、版本、可复用命令行、坑位、冒烟取证索引都记在这里。
> 决策背景与为什么换轨见 [`../../docs/30-决策/2026-09-21-教学视频制作转向-Blender中枢.md`](../../docs/30-决策/2026-09-21-教学视频制作转向-Blender中枢.md)；
> 给下一个创作 Agent 的交班见 [`../../docs/00-入口/交接-2026-09-21-Blender视频工具链.md`](../../docs/00-入口/交接-2026-09-21-Blender视频工具链.md)。
> 成片规格（时长/语速/版式/字幕）真源在 [`../../docs/50-课程/课程设计规范.md`](../../docs/50-课程/课程设计规范.md)。
> 旧管线 `tools/production/` 已于 2026-09-21 退役（产物保留不删），见其 README 顶部横幅。

四单元：**Blender 中枢**（渲染/时间线/合成）+ **Godot→glTF 资产桥**（26 件组件几何）+ **faster-whisper**（词级对齐）+ **CosyVoice3**（配音）。全栈零费用。

---

## 一、Blender 5.2.2 LTS（制作中枢）

| 项 | 值 |
|---|---|
| 路径 | `tools/blender/blender-5.2.2-windows-x64/blender.exe` |
| 版本 | **5.2.2 LTS**，build date 2026-09-15（官方下载，sha256 校验一致） |
| 用途 | 3D 场景搭建、渲染、时间线剪辑、合成；headless 可脚本化（Python API） |

**已验**：headless EEVEE 冒烟通过（出图 `smoke/blender_smoke.png`）；glTF 导入冒烟通过。批量导入联测：**26 个 `.glb` 全部导入成功、132 个网格对象、0 失败**。

坑位：

- **5.2.2 的 EEVEE 引擎标识符是 `BLENDER_EEVEE`**，不是 4.x 的 `BLENDER_EEVEE_NEXT`——脚本里设 `scene.render.engine` 用错名会报错/回退。
- `Material.use_nodes` 的**弃用告警是噪音**，不影响渲染结果，不必消除。

---

## 二、Godot → glTF 资产桥

| 项 | 值 |
|---|---|
| 脚本 | `game/scripts/video_pipeline/export_components_gltf.gd`（97 行，`extends SceneTree`、`preload` 制、无 `class_name`） |
| 几何真源 | 复用 `component_catalog` / `capture.gd` **同源几何**（真实几何，非包围盒） |
| 坐标约定 | **原点 = 底部中心**，米制（Godot 默认 1 单位 = 1 米，不缩放） |
| 产物 | `game/shots/video3d/components/<id>.glb` × **26**（每块倒角砖 96 顶点 / 44 三角形的真实几何，非包围盒；已被 `game/shots/` 的 ignore 覆盖，不入库） |

可复用命令行（headless，退出码制；直接取 `$?`，勿过管道）：

```bash
./tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
  -s res://scripts/video_pipeline/export_components_gltf.gd
```

退出码 **0** = 全部导出成功；1 = 有组件失败（原因经 stderr）。改脚本后全量测试 **35/35 绿**。

坑位：

- **Godot 4.7 的 `GLTFDocument` 写盘 API 叫 `write_to_filesystem`**（没有 `write_to_file`）——写错方法静默失败或报错。
- 结尾 **ObjectDB 泄漏告警是噪音**，看退出码即可（AGENTS.md 已知坑位）。

---

## 三、faster-whisper 词级对齐（Windows）

| 项 | 值 |
|---|---|
| venv | `tools/video/.venv-win`（Python **3.13.5**） |
| 依赖 | faster-whisper **1.2.1** + ctranslate2 **4.8.2** |
| 模型 | `Systran/faster-whisper-large-v3`（**2.9 GiB**）落 `tools/video/models/whisper` |
| 用途 | 拿配音的**逐词 start/end**，喂逐字点亮字幕（说到哪亮到哪） |

可复用命令行：

```bash
D:/ai-project-lab/tools/video/.venv-win/Scripts/python.exe D:/ai-project-lab/tools/video/scripts/align_smoke.py \
  --audio <wav> --out <json> [--language zh] [--device cuda] [--limit N]
```

性能实测：**GPU cuda/float16 0.56× 实时**（生产路径）；**CPU int8 85× 实时，不可作生产路径**（太慢）。

坑位：

- **cuDNN / cublas 由脚本自动加 PATH**：从 venv 的 pip 包（`nvidia-cudnn-cu12` / `nvidia-cublas-cu12`）里取 DLL 补进 `PATH`，无需手改环境。
- **重下模型时**用 `HF_ENDPOINT=https://hf-mirror.com`（实测比代理快）。

---

## 四、CosyVoice3 配音（WSL）

| 项 | 值 |
|---|---|
| 部署 | WSL `/root/opt/CosyVoice`（venv `.venv`，torch **2.11.0+cu128**、CUDA **12.8**、sm_120 直跑） |
| 模型 | `Fun-CosyVoice3-0.5B-2512`（**9.1 GB**）在 `/root/opt/pretrained_models/Fun-CosyVoice3-0.5B/` |
| 冒烟脚本 | `/root/opt/CosyVoice/smoke_cosyvoice3.py`（环境变量入参 `CV3_TEXT` / `CV3_OUT` / `CV3_MODEL` / `CV3_PROMPT`） |
| 输出规格 | 固定 **48 kHz / mono / 16 bit**（模型原生 24 kHz，脚本重采样） |

Windows 一条命令：

```bash
wsl -e bash -lc "cd ~/opt/CosyVoice && .venv/bin/python smoke_cosyvoice3.py"
```

性能：加载 **17–41 s**、合成 **RTF ≈1.6–1.9**（典型值，复测曾到 1.91；fp32 / 8 GB 卡——勿把该区间当硬判据）；提速可试 `fp16=True` 或 `load_vllm`。

坑位：

1. **新机须先预热 wetext**，否则中文正则化会**静默失效**（不报错、结果错）。预热命令：
   ```bash
   wsl -e bash -lc 'cd ~/opt/CosyVoice && .venv/bin/python -c "from modelscope import snapshot_download; snapshot_download(\"pengzhendong/wetext\")"'
   ```
   冒烟脚本会打印 `text_frontend` 供核对。
2. **torchaudio 2.11 需 TorchCodec**，脚本内已带 soundfile shim，别删。
3. **requirements 偏离已实测记录**：grpcio **1.62.3**、不装 deepspeed / tensorrt、openai-whisper 用 `--no-deps`、走阿里云 PyPI 镜像。
4. **onnxruntime CUDA EP 起不来**，已优雅回退 CPU，不影响合成。
5. **模型严禁挪到 `/mnt/d`**（9p 文件系统慢），保持在 WSL 原生路径。

---

## 五、冒烟取证索引（`tools/video/smoke/`）

| 文件 | 取证内容 |
|---|---|
| `blender_version.txt` | Blender 5.2.2 LTS 版本与 build 信息 |
| `blender_smoke.png` + `blender_smoke_render.log` | headless EEVEE 出图冒烟 |
| `gltf_import_smoke.txt` | glTF 导入冒烟（导出→导入往返） |
| `blender_import_batch.py` + `blender_import_batch.log` | 批量导入联测：26 个 `.glb`、132 网格对象、0 失败 |
| `min_cube.glb` | 冒烟用最小立方体素材 |
| `whisper_input.wav` + `whisper_align.json` | faster-whisper 词级对齐冒烟（**19 个中文词**，全带 start/end/probability） |
| `cosyvoice_smoke.wav` | CosyVoice3 合成冒烟（**5.8 s 真语音**） |

---

## 六、成片规格与混音口径（引用，非本链真源）

- 视频规格约束真源：[`docs/50-课程/课程设计规范.md`](../../docs/50-课程/课程设计规范.md)（**3–5 分钟**、**≤4 字/秒**、禁整页截屏、版式三件套）。
- 字幕：**逐字点亮跟配音走**，`finish_lesson.py` 用 faster-whisper 词级时间戳匹配已校对的课稿，输出 ASS 字幕；ffmpeg 负责最终合成。
- 混音响度链目标（沿用旧链实测口径）：**mean −19.8 / max −1.6 dBFS**。


## 七、第一课完整制作

运行环境见 [`tools/lesson/README.md`](../lesson/README.md)。`lesson01/run.json` 是成片源记录，`verification.json` 校验 24 次模型调用、封路次序与最终交付状态。`narration.json` 是逐句旁白源；`edit.json` 记录镜头、真实步号和制作时间映射，不修改原始运行。

概念镜头（软件系统 / 可视化表示 / 搭建 / 工具与权限）中的可执行整机来自真实程序几何，出片前先导出（改程序后重跑）：

```bash
./tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
  -s res://scripts/video_pipeline/export_agent_lab_gltf.gd
```

产物在 `game/shots/video3d/agent-lab/`：`machine.glb`（原点 = 包围盒底部中心）与 `machine_map.json`（节点标签/位置，Blender 侧文字由它重建）。`render_lesson.py` 读这两个文件，把整机摆在概念件右侧并配平台与标注。

按顺序运行以下阶段，GPU 配音、对齐和渲染不要同时占用显存：

1. 在 WSL 的 CosyVoice 环境运行 `scripts/voice_lesson.py /mnt/d/ai-project-lab/tools/video/lesson01`，生成 23 段 48 kHz 配音。脚本复用已验证的音频与 wetext 兼容处理。
2. 用已有 Python 运行 `scripts/prepare_lesson.py`，建立镜头与真实步号的映射。
3. 用 `tools/video/.venv-win/Scripts/python.exe` 运行 `scripts/finish_lesson.py`，完成 CUDA 词级对齐、必要的减速、音轨拼接和字幕；实际时长 220.32 秒。ASR 仅提供时间锚点，字幕正文仍使用课稿。
4. 在仓库根执行 `tools/blender/blender-5.2.2-windows-x64/blender.exe -b -t 6 --gpu-backend vulkan --python-exit-code 1 --python tools/video/scripts/render_lesson.py -- --bake`。当前采用 Blender Workbench 的材质色与屏幕曲率轮廓，保留真实 glTF 几何；逐帧输出 1920×1080，不用整页截图替代三维动画。`--bake` 写入可编辑动画关键帧，场景内保存源 runId 和 SHA-256。`--engine eevee` 可切换为场景光照渲染。
5. 切到 `tools/video/lesson01`，用视频 venv 运行 `../scripts/finish_lesson.py --mux`，输出 `lesson01-agent.mp4`。规格为 1080p、25 fps、H.264 CRF18 与 AAC；最后以实际媒体探测值为准。
6. 运行 `scripts/inspect_lesson.py`，检查镜头接触表、分辨率、帧数、时长和音量，并逐张检查关键镜头。

`--preview` 只出关键帧；它不替代完整视频验收。Blender 命令须带 `--python-exit-code 1`，避免 Python 脚本异常却返回退出码 0。

---

## 八、全链重建记录（2026-10-02，原 D 盘环境丢失后从零复建并出片 219.96 s）

原件 `smoke_cosyvoice3.py` 从未入库、随旧环境丢失；现重建为 **`tools/video/scripts/smoke_cosyvoice3.py`（已入库）**，使用前拷贝到 WSL `/root/opt/CosyVoice/`（`voice_lesson.py` 的 sys.path 指向那里）。音色参考改用仓库自带 `asset/zero_shot_prompt.wav`（台词出 example.py）；**原版配音音色不可复现**（原 PROMPT_WAV 未入库），画面轨道逐帧可复现。

**WSL CosyVoice3 从零部署**（Ubuntu，root，uv + Python 3.12；torch 2.11.0+cu128）：

- `git clone https://github.com/FunAudioLLM/CosyVoice.git --recursive`（Matcha-TTS 子模块必须，shim 会补 PYTHONPATH）；模型 `modelscope download FunAudioLLM/Fun-CosyVoice3-0.5B-2512 --local_dir ~/opt/pretrained_models/Fun-CosyVoice3-0.5B`（9.1 GB）。
- requirements 在 §四偏离之上新增实测钉子：**matplotlib 3.9.2**（3.7.5 无 cp312 轮子会整体失败）、**modelscope 升最新**（1.20.0 已被服务端 API 拒收）、**openai-whisper 需 setuptools≤75 + `--no-build-isolation`**（新版 setuptools 移除 pkg_resources）、tiktoken、**g++**（pyworld 源码编译）。uv 事务全有或全无：一个包构建失败＝整批未装。
- **wetext 预热必须循环重试**：新 modelscope 即使缓存齐全也发 hub 列表请求，限流 403 会静默退化（`no frontend is avaliable`）；shim 的 `patch_modelscope_local_first` 已缓存直读，预热仍建议跑到 `ZH TN OK`。
- `voice/` 目录不存在会写盘失败（脚本不建目录），首次先 `mkdir -p lesson01/voice`。

**Windows 侧**：whisper venv（Python 3.13）在 §三基础上加 **av==14.2.0**（19.x 删了 `metadata_errors` 参数；12.x 无 cp313 轮子）；模型平铺在 `models/whisper`，调用须显式 `--model models/whisper`（`finish_lesson.py` 已改为默认指向该目录）。ffmpeg 用静态构建 `tools/video/ffmpeg-*-win64-gpl/bin`（不入库），跑 finish/inspect 前先 prepend 到 PATH。混流必须**切到 `lesson01/` 目录执行**（字幕滤镜与输出名是相对路径）。

---

## 九、2D 渲染单元（2026-10-03 试点，转不转正待裁决）

同一数据脊柱（narration.json / edit.json / run.json 与配音、对齐、captions.ass **全复用**），只把画面渲染单元从 Blender 3D 换成 Manim CE——`tools/video/.venv-manim`（Python 3.12 + Manim 0.21，全轮子安装；无需 LaTeX，中文走系统微软雅黑；ffmpeg 复用 §八静态构建）。

- **渲染器真源**：`scripts/render_lesson_2d.py`。一镜一 Scene（模块级 `type()` 批量生成 `S_<shot_id>`）；`--only id1,id2` 与 `--preview id` 双模式支持单镜快速迭代；事件驱动动画对照 §七 render_lesson.py 的 update()（move smoothstep、pickup/drop、close_road 砸落红闪、model.generate 面板脉冲、tool.observation 脉冲、信号点巡游）；全程确定性。镜头取景与 3D 版逐镜对应，版式铁律同 §三（画面内**不渲染**课号牌/进度条/字幕/工具卡片——那些由 captions.ass 在混流阶段烧录）。
- **产物**：`lesson01/segments2d/<id>.mp4` ×28（1920×1080、25fps，帧数与 edit.json 逐镜零误差，总 7653）。

- **Pacing 口径（2026-10-04 用户裁决）**：每镜旁白结束后的停顿垫从 1.0s 加长到 **2.5s**（镜=观点，一镜一事）；概念段（9 镜）之后插入 **5 个回顾镜**（review_model/tools/observation/context/loop，自问自答复述，进度条段名「回顾 · X」），字幕段标签按镜序判定（结构示意 <9 / 回顾 9–13 / 真实运行回放 14–24 / 课后体验 ≥25）。落点：finish/prepare 的 `duration+2.5`、render_lesson_2d 的 `MODULE_FRAME`。

- **whisper 幻听坑（2026-10-04 实测）**：`initial_prompt=课文` 偶发触发 large-v3 退化解码，整段幻听成「请不吝点赞 订阅 转发 打赏支持明镜与点点栏目」（相似度≈0）。finish_lesson.py 已加兜底：相似度 <0.6 自动去 prompt 重转写取更优。Manim 0.21 坑：帧数记账统一走 play 路径 `run_time=(k-0.5)/25`，纯 wait 会截断漂移。
- **混流**（lesson01 目录执行，concat2d.txt 由 edit.json 镜序生成）：`ffmpeg -f concat -safe 0 -i concat2d.txt -i narration.wav -vf ass=captions.ass -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p -af loudnorm=I=-19:TP=-2.2:LRA=7 -ar 48000 -c:a aac -b:a 192k -t <edit.json 的 duration> -movflags +faststart lesson01-agent-2d.mp4`
- **成片**：`lesson01-agent-2d.mp4`（306.12s，约 13MB；含回顾块与 2.5s 停顿的当前口径）。与 3D 版配音/字幕/卡片同轨。§七 3D 管线保留不删（3D 渲染器未加 review 镜支持，重跑前需先补）。
