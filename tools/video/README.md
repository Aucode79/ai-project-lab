# 视频制作体系（v2 · 全 2D 管线）

> 2026-10-08 重建。本文件是**当前体系的唯一操作真源**：怎么跑、有哪些参数、怎么验收。
> 不含历史——迭代全记录见 [`docs/20-验收/2026-10-08-第一课成片迭代全记录.md`](../../docs/20-验收/2026-10-08-第一课成片迭代全记录.md)；v9 时代 3D 管线归档在 [`archive/README-v1-legacy.md`](archive/README-v1-legacy.md)。
> 环境搭建见 [`ENVIRONMENT.md`](ENVIRONMENT.md)；踩坑手册见 [`PITFALLS.md`](PITFALLS.md)。
>
> **从零复现的前提**（不可消除的硬件/系统条件）：Windows 10/11 + WSL2 + **NVIDIA GPU**（whisper 对齐走 CUDA，`finish_lesson.py` 有 `assert device=="cuda"`）+ 网络可达清华/阿里 PyPI 镜像与 modelscope。两份锁定版本的依赖清单：`requirements-whisper.txt` / `requirements-manim.txt`（Manim 必须钉 0.21.0，新版 API 漂移未验证）。中文渲染依赖系统字体微软雅黑。

## 一、体系总览

一条数据脊柱驱动全部渲染；配音与字幕全数据化；渲染器只有一个（Manim）。

```
narration.json（逐镜旁白）
run.json（真实运行记录） ──→ prepare_lesson.py ──→ edit.json（时间轴）
                                               （镜起止/时长/事件初排）
voice/*.wav（CosyVoice3） ──→ finish_lesson.py ──→ alignment.json（词级时间戳）
                               （whisper 对齐 + 事件词锚重排）
                               （captions.ass 字幕/课号/进度/卡片 + narration.wav）
        ↓
render_lesson_2d.py（Manim 全 2D）
  ├ ShotScene：运行段（沙盘地图+概念联动条+事件驱动回放）
  ├ ConceptScene：概念段（名牌/派活/复盘循环图/联动条收尾/开盖）
  └ s01：全景走一遍（真实事件节拍化重放）
        ↓
extract_v11_media.py（复盘段引用的运行定帧 stills）
        ↓
ffmpeg concat + narration.wav + captions.ass → lessonNN-agent.mp4
```

**双场景体系**（`render_lesson_2d.py` 单文件）：
- **ShotScene**（运行段）：沙盘地图（A–F 节点/载体/货物/挡板/卸货湾）+ **概念联动条**（地图上方空带常驻 蓝·便签｜黄·大语言模型｜橙·工具｜蓝绿·观测 四色块 + 独立红·环境块，与复盘循环图同色同源）。每个事件同时驱动地图动画与联动条状态。
- **ConceptScene**（概念段）：s02 整机名牌、s03 对话框派活、s12–s17 复盘循环图（空圈逐站点亮→五站连圈→外圈套智能体名牌）、s18 延续定格、s19 联动条+双任务定帧、s20 对话框聚焦、s21 开盖收尾。
- 联动条核心机制：**状态常亮**（待命 0.45/激活 1.0/刚干完 0.7，保持到下一阶段）+ **徽章驻留**（指令卡停驻工具块；结果卡沿直角回程箭头走 1.75s 落到便签块下方箭头头处；同文徽章去重，重复步骤不再演示）；封路时环境块独立闪现、无箭头连模型块（"不是它干的"的视觉论证）。

## 二、工作流（复现/修改一课）

```bash
cd tools/video

# 1) 改旁白：编辑 lessonNN/narration.json
#    ⚠️ 改了哪段台词，必须删掉 voice/ 下同 id 的旧 wav（配音脚本按 id 跳过已有文件）

# 2) 配音（WSL CosyVoice3，增量）
wsl -e bash -lc 'cd ~/opt/CosyVoice && REPO=$(echo /mnt/c/Users/qihen/Desktop/*/ai-project-lab) && \
  .venv/bin/python "$REPO/tools/video/scripts/voice_lesson.py" "$REPO/tools/video/lessonNN"'

# 3) 时间轴：初排 + 对齐锚定字幕
py -3.12 scripts/prepare_lesson.py
export PATH="$(pwd)/ffmpeg-master-latest-win64-gpl/bin:$PATH"
./.venv-win/Scripts/python.exe scripts/finish_lesson.py

# 4) 渲染（顺序固定：舞台镜 → 抽 stills → 复盘镜，复盘镜引用 stills）
./.venv-manim/Scripts/python.exe scripts/render_lesson_2d.py --only <舞台镜ids>
./.venv-win/Scripts/python.exe scripts/extract_v11_media.py
./.venv-manim/Scripts/python.exe scripts/render_lesson_2d.py --only <概念镜ids>
# 调试利器：--preview <id>（只出该镜中点 PNG，秒级）；--only 精确重渲单镜

# 5) 验收（见§四，全部通过才混流）

# 6) 混流（必须切到 lessonNN/ 目录——ass 滤镜与输出名是相对路径）
cd lessonNN
#    先按 edit.json 镜序生成 concat 清单（每次重排时间轴后都要重新生成）：
py -3.12 -c "import json; e=json.load(open('edit.json',encoding='utf-8'));   open('concatNN.txt','w',encoding='utf-8').write(''.join(f\"file 'segments2d/{s['id']}.mp4'\n\" for s in e['shots']))"
ffmpeg -f concat -safe 0 -i concatNN.txt -i narration.wav -vf ass=captions.ass \
  -c:v libx264 -preset fast -crf 18 -pix_fmt yuv420p \
  -af loudnorm=I=-19:TP=-2.2:LRA=7 -ar 48000 -c:a aac -b:a 192k \
  -t <edit.json 的 duration> -movflags +faststart lessonNN-agent.mp4
```

## 三、节奏与同步参数表（全部一行可调）

| 参数 | 当前值 | 落点 |
|---|---|---|
| 镜间停顿垫 | 2.5s | `prepare/finish_lesson.py` 的 `reserve` 基数 |
| 思考窗（封路镜） | +3s | `THINKING_EXTRA` |
| 术语前置镜停顿 | ×1.5（=3.75s） | `DIGEST_EXTRA`（镜 id 清单内生效） |
| 故事镜位移 | ≥2s，可提前台词 0.5s 起跑 | finish 推挤 + renderer `d0` 分支 |
| s01 走一遍位移 | ≥1.0s（旁白时长物理约束，专用） | 同上另一分支 |
| 事件最小间隙 | 0.8s；首观测后继 1.8s | finish 推挤 |
| 镜长上限 | 无（按需自动延长） | finish `need` 计算 |
| 结果卡沿箭头时长 | 1.75s（=短距飞卡 2.5 倍，三段 0.25/1.2/0.3） | renderer obs 分支 |
| 台词预算 | ≤4 字/秒 | 《课程设计规范》§二（真源） |
| 混音响度 | mean −19.8 / max −1.6 dBFS | 混流 `-af loudnorm` 口径 |

**音画同步机制**：`finish_lesson.py` 的 `PHRASE_ANCHORS` 把关键事件锚到"描述它的台词"的词时间戳（whisper 词级对齐，`词时间/tempo + 0.35s 导白`换算成片时刻），无锚事件在锚点间插值；位移规则再对事件时刻做推挤让位（后继事件 ≥ 位移时刻+时长）。

## 四、验收规程（每版必过，缺一不交付）

1. **帧数零误差**（脚本化）：每段 ffprobe `-count_frames`，帧数 === round(duration×25)，总帧数 === edit.json 的 frames。
2. **像素级动画曲线**：追踪货物橙色像素中位 x 随时间（校准像素位见迭代记录§五），验证移动时长、起止时刻、与台词锚的先后。**凡改事件循环/缩进/时间逻辑，此步强制**——肉眼判帧已多次误判。
3. **抽帧目检**：成片多点抽帧对照预期画面（仅在前两项通过后）。
4. **几何包围盒审计**（结构性改动时）：按渲染器常量复算全部元素包围盒对画框/相邻件求交，列违例清单后修。

## 五、文件清单

**入库（真源）**：`scripts/`（voice_lesson / prepare_lesson / finish_lesson / render_lesson_2d / extract_v11_media / align_smoke / render_ending_samples[选型样片模板] / smoke_cosyvoice3[WSL 侧 shim，用前拷到 /root/opt/CosyVoice/]）、`lessonNN/narration.json|run.json|verification.json`、成片再生成的 `edit.json|alignment.json|captions.ass`。
**产物（gitignore）**：voice/ voice_edit/ frames/ segments2d/ stills/ teaser_cand/ samples/ media/ *.mp4 *.wav *.blend *.jpg。
**归档**：`archive/README-v1-legacy.md`（v9 3D 管线全文）、`scripts/render_lesson.py`+`render_run_shots_v11.py`（3D 遗产，保留可查）。

## 六、下一课怎么做

1. 建 `lessonNN/`：narration.json（按《课程设计规范》写稿）+ run.json（真实运行记录；无运行段课程可省略）。
2. prepare/finish 的 RANGES/TITLES/PHRASE_ANCHORS 按新课镜表改（三张表都在脚本头部，纯数据）。
3. render_lesson_2d.py 的镜 id 分支按分镜增删（ShotScene 取景表 / ConceptScene 内容表）。
4. 走§二工作流 + §四验收。第零课（无运行段、全概念镜）可直接从 ConceptScene 体系起步。
