# 微课生产管线（最小闭环，spec §8）

> **已弃用（2026-09-21 退役）。** 本管线整体否决、不再维护、不再作为出片口径。
> 新链见 [`../../docs/30-决策/2026-09-21-教学视频制作转向-Blender中枢.md`](../../docs/30-决策/2026-09-21-教学视频制作转向-Blender中枢.md) 与 [`../video/README.md`](../video/README.md)。
> 历史产物 **保留不删**：本目录 `compose/`（成片）、`layers/`（图层/配音）与脚本，以及抓图目录 `game/shots/production/`，仅作存档与沿革。

取资产 → studio.capture 出片段（alpha PNG 序列）→ 图层叠加 → 配音 → 合成成片 → 集元数据。
当前贯通证据：**e49 的 3 秒真片段** `compose/e49/clip_task_board_intro.mp4`
（conc_task_board `iso_idle` 75 帧 + 三张图层 + edge-tts 开场白，1080p/25fps/H.264）。

**两条出片路线，按画面类型选**：

| 路线 | 适用 | 入口 |
|---|---|---|
| 静态图层版（本文上半） | 一件资产的展示片段、占位升级 | `run_all.sh` |
| 动效版（见 §动效成片） | 正片：镜头级动效 + 逐字字幕 + 配音 | `render_frames.py` |

## 一键复跑

```bash
bash tools/production/run_all.sh        # capture → layers → tts → compose → validate 全绿
```

Godot 捕获在 Windows 侧跑（headless 是 dummy 渲染器出不了 PNG，会短暂弹窗）；
图层/配音/合成/校验在 WSL python3.12 侧跑。

## 分步命令（各自可独立复跑，路径全相对仓库根）

| 步 | 命令 | 产物 |
|---|---|---|
| 捕获 | `bash tools/production/capture.sh conc_task_board iso idle 3.0` | `assets/conc_task_board/iso_idle/frame*.png`（75 帧，1920×1080 RGBA） |
| 图层 | `wsl python3 tools/production/render_layers.py --episode e49` | `layers/e49/{title,progress,subtitle}.png` |
| 配音 | `wsl bash tools/production/tts.sh` | `layers/e49/voiceover.mp3` + `voiceover.txt` |
| 合成 | `wsl python3 tools/production/compose_clip.py --frames assets/conc_task_board/iso_idle --layer layers/e49/title.png --layer layers/e49/progress.png --layer layers/e49/subtitle.png:0.5 --audio layers/e49/voiceover.mp3 --out compose/e49/clip_task_board_intro.mp4 --duration 3` | mp4 成片 |
| 校验 | `wsl python3 tools/validate_episodes.py` | exit 0 |

参数化说明：

- `capture.sh <assetId> <机位> <动作> [时长秒] [-- 附加参数]`：机位取
  spec §3.4 词表（iso/front/top/close/vista），动作同（idle/run/open/close/fail）；
  场景路径读 `assets/<assetId>/asset.yaml` 的 `scene:` 行，缺省回退
  `game/scenes/assets/<assetId>.tscn`；输出目录固定索引路径 `assets/<assetId>/<机位>_<动作>/`。
- `render_layers.py` 的文案读 `episodes/e49.json`（集号/标题/标记）与其 `data[0]`
  （`opening_line`），不自造。
- `compose_clip.py` 的 ffmpeg：WSL 原生优先，本机回退 Windows 版
  `/mnt/c/Users/zyz/AppData/Local/Microsoft/WinGet/Links/ffmpeg.exe`
  （`/mnt/<盘>/` 路径自动转 `<盘>:/`；可用环境变量 FFMPEG/FFPROBE 覆盖）。
  **本机实测用的是 Windows ffmpeg 9.0.1**。

## 依赖（首次）

- WSL python3.12：playwright + chromium（图层 HTML 渲染）、Pillow（回退）、
  edge-tts（`pip3 install --user --break-system-packages -i 清华源`，tts.sh 会自装）。
- WSL 无中文字体：render_layers.py 首次运行自动从 Windows 借微软雅黑到
  `~/.local/share/fonts/production-cjk/` 并 fc-cache。
- Windows 侧：Godot 4.7.2 console（`tools/godot/`，环境变量 GODOT 可覆盖）。

## 产物与清理策略（对照 docs/20-验收/测量结果.md 的 470GB 推算）

PNG 序列是**中间产物**，成片合成后即可删（本仓库已在 .gitignore 排除）：

```bash
rm -rf assets/*/iso_*/ assets/*/front_*/ assets/*/top_*/ assets/*/close_*/ assets/*/vista_*/
```

mp4/图层 PNG/mp3 同为可再生产物（.gitignore 排除，目录靠 .gitkeep 锚定）；
`layers/*/voiceover.txt`（口播稿）与 `data/*.json`（图层数值）是**源数据**，入库。
gitignore 对 `data/` 的既有整目录忽略做了收口：只放行 `data/e*_*.json` 这类集源数据，
其余运行时数据仍忽略。

## 字体与色板口径（大纲 §7.2 只给色名未给色值）

- 概念蓝 `#3D6FB5`、公式橙 `#E08A3C`、错误红 `#E95353`、拓展灰 `#7888A0`——
  取 docs/10-契约/美术方向.md 与 `game/scenes/levels/l1/components/task_board.gd` 现有色的近似，
  定义在 `tools/production/render_layers.py` 的 `PALETTE`。
- 字体：微软雅黑（HTML 引擎）；Pillow 回退路径用系统黑体 + 白描边近似。

---

## 动效成片（第一课 w01 样片跑通的口径）

正片不是"一张资产图 + 三层静态字"，而是镜头级动效。画面主体用 HTML/CSS 画，
工坊 3D 只出插图；台词、字幕、时间轴共用一份数据，避免三处漂移。

```bash
# ① 3D 插图（Windows 侧，会短暂弹窗）：工坊件按 catalog id 现搭，产物改道 shots/
for id in agent_task_dock agent_model_well agent_tool_rack agent_execution_table agent_observation_tray; do
  OUT_ROOT="D:/ai-project-lab/game/shots/production/w01/${id}_iso" \
    bash tools/production/capture.sh "$id" iso idle 1.0 -- --margin=1.35
done
# 工坊全景静帧（--resolution 的高度会被屏幕夹到，1415 而非 1440，故下一步再裁 16:9）
tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game --resolution 2560x1440 \
  -- --shot --out=res://shots/production/w01/studio_page0.png

# ② 底板加工（WSL）：裁掉透明留白 / 裁 16:9，产出 data/w01_shots.json 的 plates 指向的文件
wsl python3 tools/production/prep_plates.py --episode w01

# ③ 逐镜配音 + 词级字幕时间（edge-tts WordBoundary）→ narration.wav / narration.json / w01.srt
wsl python3 tools/production/build_narration.py --episode w01

# ④ 出片（HTML seek(t) 逐帧 → rawvideo 管道 → ffmpeg，帧不落盘）
wsl python3 tools/production/render_frames.py --episode w01 \
  --encode compose/w01/pilot.mp4 --audio layers/w01/narration.wav

# ⑤ 抽帧自检：一条命令看整段构图/字幕/转场
wsl python3 tools/production/qc_sheet.py --video compose/w01/pilot.mp4 \
  --at 2,8,13,19,26,35,44,52 --cols 4
```

**场景协议**（`scenes/<集号>_intro/index.html`）：页面自己实现 `window.seek(t)`
把画面摆到第 t 秒，并暴露 `window.DURATION`。不用 CSS animation、不用
requestAnimationFrame——一切状态由 t 推出，同一 t 永远同一帧，才能逐帧截图、
改一帧不必重跑全片。渲染器把三份数据注成 `window.__DATA__`：
`plates`（3D 插图绝对路径）、`shots`（实测时间线 + 词级 cue）、`report_lines`。
台词与秒位在 `data/<集号>_shots.json`，**逐字取分镜稿**，不在 HTML 里写第二份。

**为什么帧不落盘**：PNG 序列写 `/mnt/d` 是 9p 小文件写，实测 ~0.9 s/帧，而渲染本身
只要 0.2 s（`--out` 模式 150 帧跑了 184 s）。改成 rawvideo 喂 ffmpeg 后 0.33 s/帧，
一次顺序写一个 mp4。要逐帧看图用 ⑤ 从成片抽。

**工坊件为什么走 component_catalog**：26 件工坊件没有独立 tscn（外形真源就是那份几何表），
`capture.gd` 见到 id 在 catalog 里就现搭。产物**不落 `assets/`**——那里每个目录都要
`asset.yaml`，会被 `validate_assets.py` 判缺项，所以用 `OUT_ROOT` 改道 `game/shots/`。

**实测口径（第一课段1+段2 定风格样片）**：分镜稿 §3.1 的名义秒位装不下台词——
8 镜名义 55.0 s，按 edge-tts `zh-CN-XiaoyiNeural` `+0%`（实测 4.1 字/秒，落在分镜稿
"儿童向每秒 4–5 字"档内）排出来是 **63.3 s（+8.3 s）**，超得最多的是 s4（台词 7.0 s /
名义 5.0 s）与 s5（8.3 s / 7.0 s）。分镜稿的处置口径是"超了就删字，不加快语速"，
删哪几个字归人定；样片先按实测长度出，把差额留在片里当证据。

### 拉出特写（v2 · 段2 组件介绍镜）

镜 6/7/8 的组件介绍不再用 iso 静态插图在全景里高亮，改成单组件（镜 7 两件）**透明底慢旋
特写 + 右侧名字卡**。整段构建固化成 `tools/production/build_w01_v2.sh`（产物
`compose/w01/pilot_v2.mp4`，不覆盖旧 `pilot.mp4`）：

```bash
bash tools/production/build_w01_v2.sh        # capture spin → prep → 配音 → 出片，四步一键
# 分步（每步可单独复跑）：
OUT_ROOT="D:/ai-project-lab/game/shots/production/w01/agent_model_well_spin" \
  bash tools/production/capture.sh agent_model_well close spin 8
wsl python3 tools/production/prep_plates.py --episode w01          # mode=spin 的 plates
wsl python3 tools/production/build_narration.py --episode w01 --only s2,s5,s6,s7,s8
wsl python3 tools/production/render_frames.py --episode w01 \
  --encode compose/w01/pilot_v2.mp4 --audio layers/w01/narration.wav
```

- `capture.sh <id> close spin 8`：`capture.gd` 内置动作，相机绕资产水平慢旋一整圈（8 s / 200 帧
  25 fps 透明底）。取景把件切出画面的（如工具架）加 `-- --margin=1.3` 重拍。
- 工坊全景静帧（镜 2/5 底片）也要重拍：`asset_lib/component_catalog.gd` 的显示名已改 v4
  （点子井/干活台/回音盘一套），2026-09-19 的旧静帧字牌还是改名前的（模型井/执行台），
  沿用会和组件介绍镜的新名打架。命令见 `build_w01_v2.sh` 步骤 ①。
- `prep_plates.py` 新增 `mode: "spin"`：src 是整段慢旋序列目录，对**全部帧取并集**包围盒统一裁一版
  （逐帧各自裁会让件在画面里游动），抽 `stride` 帧、等比缩到 `max_side`，写进 out 目录（帧序）。
- `render_frames.py` 把 spin plate 注成帧路径列表（`window.__DATA__.spins`）；场景按镜头本地秒位
  换图（8 s 转一圈），同一 t 永远同一帧。
- `build_narration.py --only <ids>`：只重合成台词改过的镜，其余镜复用现有 mp3 与旧词级 cue
  （复用镜缺 mp3 或旧 cue 时直接报错，不静默重合成）。

