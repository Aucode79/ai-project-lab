# demo 验收 · spec §9.3 八条逐条对账

> 2026-09-14 · 主会话汇编。八条全过，证据均可复跑（复跑命令见各条）。
> 测试基线：**18 套件 236 条全绿**（godot 侧）+ sidecar pytest 25 + 三校验器 + tools/check.sh + sidecar/smoke_e2e.sh。
>
> **2026-09-15 追记**：本文是 2026-09-14 的验收快照。此后世界度量体系 v2 与模块化改造落地，当前测试基线为 **19 套件 297 条**（`bash tools/run_tests.sh`，23 项）；八条验收结论与已知遗留清单仍然有效。

## 1. 线性关卡链跑通 ✅

五关全部交付，每关装 2–4 件组件、配视频（占位画面 + 生产管线已贯通）。

| 关 | 组件 | 测试 | run 记录 |
|---|---|---|---|
| L1 它是谁、接什么活 | 任务牌、角色铭牌（+ops_chart） | 7 + 接线 8 | runs/e49/，kind=task |
| L2 它怎么读、怎么写 | 文件柜、扫描器、机械臂 | 10 | runs/e51/，读经扫描器/写经机械臂逐条可验 |
| L3 它记得住什么 | 上下文容器、记忆柜 | 8 | runs/e50/，写→读因果链数值对上 |
| L4 它怎么想、怎么决定 | 思考机、计划板、工具带 | 13 | runs/e40/，两次 think 计划与 token 数不同 |
| L5 它怎么跑完、怎么不错 | 回廊、执行器、校验门、旁路 | 7 | runs/e60/，拒绝→重试→通过→完成双因果链 |

五集元数据 `episodes/e{49,51,50,40,60}.json`（大纲 §7.3 十字段 + 新五字段）；e49 已出 **3 秒真片段**（compose/e49/，1080p/25fps/h264+aac，管线总耗时 ~14s）。

复跑：`tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/levels/l<N>/run_l<N>_tests.gd`；`bash tools/production/run_all.sh`

## 2. 终点产物：可用的 mini codex ✅

L5 测试 T5：**十四件实体齐备**（4 本关 + 10 占位）→ `world.export_python()` 产码 → **WSL python3 真跑 exit=0**（骨架含 `while True`+显式 break、`except→旁路重试→continue`，`max_retries` 参数化，tune 前后两版导出物逐字节不同）。产物留档 `game/runs/e60/l5_codex_skeleton.py`。

复跑：`... -s res://tests/levels/l5/run_l5_tests.gd`（T5 含 wsl 执行断言）

## 3. 自由沙盒可用 ✅

`game/scenes/sandbox/sandbox.tscn`：**28 件资产全量生成台**（base_/mach_/l2_/conc_ 分组分色），长按可搬走自由拼装、点按打开、空格跑、存/读档（DeviceStore）、导出 Python 按钮、求助屏在场。8 条测试（存 28→改 29→读回复原、导出写盘、28 件 entity_of 全可交互、常量表与 assets/assets.yaml 全量对账）。

复跑：`... -s res://tests/sandbox/run_sandbox_tests.gd`

## 4. 三个指示器都能跑 ✅

| 指示器 | 实现 | 证据 |
|---|---|---|
| 跑到它了 | 组件四态**由步记录派生**（各关组件 state_trajectory 纯函数，无状态机变量） | L1–L5 各组件测试 + L1 接线 T2 三级链路 |
| 可读取的文件 | 文件柜三格灯（绿=可读/绿+门开=可写/红锁=禁读），作用域世界声明 | L2 T1/T5（secret.txt 拒读在案） |
| 看出写了哪里 | 机械臂落点一格高标记（新增=暖橙/修改=青，常驻）+ 扫描淡痕（参数化淡出） | L2 T6（world.marks 两类留痕可分辨） |

## 5. agent 多维度评分产出 ✅

五维诊断评分器 rule_v1（正确性/结构/效率/鲁棒性/可读性）已接入五关 stage_score：**五句全带 stepRef 证据、防编话中性句、效率句含实测 ops**（基线 0% 偏差：e49 220 / e51 202 / e50 303 / e40 580 / e60 1226）。「另一实例」结构成立（独立模板表、与执行侧零共享 import）；LLM 通道预留（v1 NOT_IMPLEMENTED 回退规则）。

复跑：`... -s res://tests/scoring/run_scoring_tests.gd`；五关测试的评分断言

## 6. 12 种方块用到 ≥9 ✅

台账（assets/assets.yaml，28 件）覆盖 **9 种**：

| 类型 | 承载 |
|---|---|
| code_block | base_block 等 24 件（家族一通用） |
| text_ | base_label、conc_nameplate、conc_task_board |
| flow_ | mach_verify_gate、conc_thinker、conc_plan_board 等 7 件 |
| table_ | mach_stacker、l2_file_cabinet、conc_context_container、conc_memory_cabinet |
| timeline_ | mach_counter |
| player_ | player_screen（幕布，五关视频交付面） |
| dialogue_ | conc_thinker（提示词进/模型回答出，§五 #8 字面） |
| output_ | conc_runner（观测窗原始返回，§五 #9 字面） |
| chart_ | conc_ops_chart（L1 score 段真实 ops 驱动柱状图） |

未用的 3 种（formula_/concept_/fallback_）按裁决 #9 与五关内容本就不需要（公式走图层；E48/E54/E61 在 demo 范围外）。

复跑：`wsl python3 tools/validate_assets.py`（28 件 PASS）

## 7. 三个测量数字落盘 ✅

`docs/20-验收/测量结果.md`：单帧渲染 12.7ms（≤0.5s 档）、烘焙 2.8–6MB/集（上限 10MB）、落点前推 CPU<0.01ms/tick 但 2s 前推=2s 墙钟（虚影异步设计依据）+ 物理引擎 Jolt A/B 裁定表。交互侧虚影已按异步实现（主线程同步段 5–8µs，预测与真实落点差 0.000m）。

## 8. 配视频集的片段复用 ✅（demo 口径）

demo 五关视频为占位画面（计划 §7 第 3 步明示"视频可先用占位"）；生产管线最小闭环贯通（capture→图层→edge-tts→ffmpeg，e49 真片段取证）。§1 验收 3 的片段复用率（≥6 片段/集、≥2 复用）适用于**批量生产阶段**，demo 不做 63 集批量（计划 §4），该项顺延至批量生产验收。

---

## 已知遗留（各轮 review 的 notes 汇总，均不阻塞验收）

1. **视觉/交互打磨**：窗口模式 OrbitCam 与 hub 双喂鼠标（速度 ×2）；PickProxy 冻结刚体可被长按拖走；l1_preview.png 过时；--shot 在 headless 卡 frame_post_draw（窗口模式用）
2. **concepts.yaml 路径**：`res://../` 解析在导出包失效（开发口径可用，打包前需处理）
3. **过渡债**：9 条 exhibit→parametric WARN（c8.1/c8.5/c10.2 等概念待专用资产升 operable）；L2 的 `l2_` 前缀 vs spec `conc_` 前缀；c10.2 等概念仍为陈列口径
4. **引擎噪音**：ObjectDB leak 警告（SceneTree 测试通用）、mcp_bridge pump 对断开 peer 的 winsock 警告——均不影响退出码与判定
5. **交互 T4** 依赖真实时钟过 250ms 阈值（headless 帧率节流下稳定，潜在抖动点）
6. **step_back**（`,` 单步后退）是注入位（未注入时结构化拒绝），等状态层历史回退
7. **代做护栏**拒绝任何 recording 态中 kind==task 的运行（遗留 explore 自动收尾）——行为已符合语义
8. **慢速档位**（0.5×/0.25×）与**工具头痕迹留痕时长**未做 UI 档位（参数已可配置）
9. **L2 fs 工具**在 flow 层实现（与 sidecar fs.* 语义同构但两处代码，后续可提升共享 helper）
