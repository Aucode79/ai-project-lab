# AI Project Lab · 工程约定

> 本仓的工程事实与约定：项目档案、目录地图、改代码前该读哪篇、必须遵守的铁律与已知坑位。
> 产品说明与怎么跑见 [`README.md`](README.md)；文档索引见 [`docs/README.md`](docs/README.md)。

---

## 1. 项目档案

```yaml
项目定位:   Godot 4 教学游戏「AI Project Lab」——用方块流水线具象化编程/agent 概念；
            L1-L5 关卡 + 自由沙盒 + 资产库 + 编译器 + Agent Lab(可执行方块程序) + sidecar(Python MCP)；
            demo 完工（2026-09-14）；Agent Lab 交付并补完（2026-09-22，三维端口拖线可用）；
            整机引擎 v2（2026-09-23，工厂感+三维嵌套）
技术栈:     Godot 4.7.2-stable / GDScript + Jolt 物理 + zylann.voxel GDExtension（无编辑器插件）；
            sidecar Python（.venv 3.12 / .venv-win 3.13 双套并存）；数据校验器走 WSL python3
入口:       引擎二进制 tools/godot/Godot_v4.7.2-stable_win64_console.exe（不在 PATH）；
            **Godot 工程根 = game/ 子目录**（project.godot 在 game/，不在仓库根）；
            默认入口：组件工坊；窗口验收："$G" --path game --resolution 1920x1080；F1 切换沙盒与五关
验证命令:
  Windows:   PowerShell 显式用 & 'C:/Program Files/Git/bin/bash.exe' tools/run_tests.sh；系统 bash 是 WSL 入口
  (build/typecheck/lint 均无：Godot 无独立构建步，--check-only 未被任何脚本使用)
  test_all:   bash tools/run_tests.sh —— 35 个 Godot 套件（当前发现数量见 --list）+ 三校验器(WSL) + check.sh，
              共 39 项（含 26 件逐件搬移，运行需数分钟）；退出码 0 = 全绿。选项：--changed 按 git 改动自动选套件、
              --list 列套件、--no-validators 跳 WSL。
              单独数断言：逐套件直跑后汇总，两套汇总格式 `TOTAL: N passed, M failed`
              与 `结果：PASS N / FAIL M`。
  test_one:   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
              -s res://tests/<目录>/run_<x>_tests.gd   （35 套件，SceneTree 脚本+退出码制）
  fast:       bash tools/check.sh （spike 冒烟，秒级，退出码 0=PASS）
  shot:       "$G" --path game scenes/sandbox/sandbox.tscn --resolution 1920x1080 -- --shot \
                [--yaw=<rad>] [--pitch=<rad>] [--dist=<m>] [--out=res://<路径>]
              （须开窗口：headless 出不了图。机位/落盘覆写是美术取证用的同机位对照入口，
                缺省时与从前逐字一致；证据落 game/shots/art-upgrade/<阶段>/。
                **L2–L5 已改为手动轨道相机；同机位对照仍显式给 --yaw/--pitch/--dist**）
  sidecar:    wsl -e bash -lc 'cd /mnt/d/ai-project-lab/sidecar && ./.venv/bin/python -m pytest tests/ -q'
              + wsl -e bash -lc 'bash sidecar/smoke_e2e.sh'（两者不在 run_tests.sh 内，单独跑）
密钥:       干净。高置信模式 0 命中；15 组弱命中全为游戏教学内容/文档词汇/第三方库源码；
            .env 已 gitignore（磁盘上不存在）
git:        是仓库；master 分支（提交数/文件数实时值看 `git rev-list --count HEAD`
            / `git ls-files | wc -l`）；remote=origin → GitHub 私有仓 yizhang-dream/ai-project-lab
            （2026-09-28 建，私有不开源；加协作者走仓库 Settings→Collaborators）；
            历轮在途改动已于 2026-09-28 全量收编提交，工作区自此保持干净
结构红线:   活跃 .gd 已无 >800 行（最大 793 为测试套件）；
            >800 的仅 6 个 research/lmcc 调研 md（参考资产，不拆）；
            循环依赖 1 组：game/bench/bench_bake.gd ↔ bench_world.gd（静态 preload+运行时 load，非编译期环）
文档真源:   **入口** = docs/README.md（唯一文档索引，按层分组）；docs/00-入口/计划.md（汇总/定序/下一步）
            + docs/00-入口/2026-09-22-可执行Agent沙盒实施方案.md（Agent Lab 实施方案）
            + docs/20-验收/2026-09-23-整机引擎v2.md（最新验收：整机引擎 v2）
            + docs/20-验收/2026-09-22-可执行Agent沙盒.md（上一轮验收：Agent Lab + 同日补完轮）；
            历轮交接（demo 完工/两轮美术改造/组件从零设计）2026-09-22 已归档 90-历史/；
            docs/ 分层：00-入口 / 10-契约（4 专题 + specs/ 两份规格，v6 为现行契约）
            / 20-验收 / 30-决策（ADR）/ 40-模块 / 50-课程（课程线：总纲 + 设计规范 + 第一课 v7 + 第二课 v1） / 90-历史（spike 快照，仅沿革）；
            项目无 CHANGELOG 与版本号
已知缺口:
  - "无 lint；sidecar/requirements.txt 与实际 import 的一致性未核"
  - "game/bench/out/ 11M 序列帧磁盘残留（已 ignore，删前问）；sidecar 双 venv 并存（删前问）"
```

---

## 2. 项目地图与验证映射

**顶层布局**（Godot 工程根 = `game/`，故 `res://` 即 `game/`）

| 路径 | 是什么 |
|---|---|
| `game/scripts/` + `game/scenes/` | 代码两棵树：scripts 放逻辑（14 个模块目录），scenes 放场景与各关组件。**逐个模块的职责/入口/坑见 `docs/40-模块/README.md`**（本节不再重列，避免两处漂移） |
| `game/tests/`（35 套件） | 全部 headless 退出码制；聚合入口 `tools/run_tests.sh`；套件现状见 `docs/20-验收/tests.md` |
| `sidecar/` | Python MCP server（与学员共用工具面），跑法见 §1，不在 runner 内 |
| `assets/` + `concepts.yaml` | 28 件资产与概念映射（双校验器防漂移）；id 权威源 `research/lmcc/outline_index.json` |
| `docs/`（00-入口 / 10-契约 / 20-验收 / 30-决策 / 40-模块 / 50-课程 / 90-历史） | 文档按层分目录；**唯一索引** `docs/README.md` |
| `tools/video/` + `tools/blender/` | Blender 视频工具链（Blender 中枢 + glTF 桥 + faster-whisper 对齐 + CosyVoice3 配音），真源 `tools/video/README.md` |

**改代码前该读哪篇文档**：见 `docs/README.md` 的「改代码前读哪篇」节（按代码里的实际引用汇总）。

**该跑什么测试**：**不用查表** —— `bash tools/run_tests.sh --changed` 按 git 改动自动选套件。
路径→套件的映射**只有一处真源**：runner 里的 `map_suites()`（改映射改那一处即可）；认不出的路径**回退全量**（宁可多跑）；
只改文档/工具会直接告诉你"无需跑测试"；只改 `sidecar/**` 会把 pytest 命令打给你；改基准场景（`main.gd`/`bench`）会跑 `check.sh` 冒烟。
手动过滤仍可用 `--suite <正则>`（与 `--changed` 互斥）。

**铁律（违反即回归）**
1. 新代码一律 `const X := preload("res://…")`，**不用 `class_name`**（避开 headless `-s` 的全局类缓存坑）。
2. 尺寸唯一真源 = `scripts/asset_lib/asset_node.gd` 的 `STANDARD_CUBE_SIZE`（0.5 m 标准方块）；主轮廓 `n×0.5`、摆位 `n×0.25`（块状化 v2 已废除工艺件/端口/圆轮豁免）；**部件外延六面落 0.25 格（2026-09-17 起，`run_ground_tests` T7 锁）**；**裸露表面统一直切 45°×0.05 m 倒角（向内切、不改占格；砖缝/花纹走材质层，其余一律纯盒），自然装饰物不进场景**——见 `docs/30-决策/2026-09-14-世界度量体系以方块为基准.md`、`docs/30-决策/2026-09-16-教学资产表面细节尺度.md`（表面细节 2026-09-17 裁定）。
3. `.tscn` 由生成器产出（`game/bench/gen_scene.gd` 模式），场景内容全部代码搭建；tscn 只挂根节点+脚本。
4. conceptId 以 `research/lmcc/outline_index.json` 为准；先改 outline 再改 `concepts.yaml`。
5. 决策落 `docs/30-决策/YYYY-MM-DD-<标题>.md`（背景/备选/选择/后果四段式）。
6. `*.gd`/`*.sh`/`*.py` 强制 LF（`.gitattributes` 兜底，Windows 侧别存成 CRLF）。

**已知坑位**
1. **不加管道**：godot headless 的退出码经管道会丢；用 `tools/run_tests.sh`（落临时文件）或 `rc=$?` 直取。
2. **float 断言**：浮点别用 `str()` 化比对（丢精度），按容差比较。
3. **headless `-s` 类缓存**：靠 `class_name` 的脚本在 `-s` 下可能解析不到 → 一律 preload。
4. **形状口径**：`BoxShape3D.size` 是整边长（= 半边长×2），摆位别按半径算；端口方向用 `in`/`out`。
5. **ObjectDB 泄漏噪音**：headless 退出可能打印 ObjectDB 泄漏告警，属噪音——看退出码，不看它。
6. **体素就绪是异步的**：`VoxelViewer`/碰撞体流式到位前解冻刚体会穿地 → 先 `await wait_ready()`。
7. **spatial shader 的 fragment 里 VERTEX / NORMAL 都是视空间**（官方文档 built-ins 表原文 "in view space"），
   而 `MODEL_MATRIX` 是"模型→世界"。所以 `MODEL_MATRIX * vec4(VERTEX,1.0)` 得到的既不是世界也不是视空间、
   而是**跟着相机转**的坐标；把世界向上的常量与视空间法线混合同理。两种写法都编译得过、单张截图看不出问题，
   只在转镜头时才露脸（图案在表面游动 / 受光跟着镜头转）。世界量一律在 `vertex()` 里算好、经 varying 传下去。
   回归锁：`tests/sandbox/run_shader_space_tests.gd`（判定前**必须剥注释**，否则注释里的词会把检查喂饱）。
8. **headless 不执行 shader，也不能出图**：`--headless` 下 `RenderingServer.frame_post_draw` 永不触发，
   `--shot` 会挂死。渲染取证与 shader 验收只能开窗口跑（见 §1 的 `--shot` 机位覆写）。
9. **`AnimatableBody3D`（+`sync_to_physics`）的子节点，父节点不能"先进树再摆位"**：它进树那一刻把自己的
   世界变换当绝对值交给物理服务器，父节点之后再移动，服务器就把节点局部变换补偿回去 —— 子节点留在原地。
   实测：传送带带面被写成局部 `(2.5, −22.5, −1.75)`、落到世界原点。**载体一律"先摆位、再 add_child"**；
   玩家搬走传送带时同样会脱开带面，所以这是产品缺陷而不只是摆位问题。
10. **量包围盒别用 `get_global_transform()`**：上面那类 `AnimatableBody3D` 子节点在 headless 下
   它可能**没接上父链**（实测传送带带面落到原点附近，包围盒凭空宽 2 m、误报"穿模"）。
   逐级合成局部变换（`t * child.transform`）才可靠。

---

## 3. 工程约定

**验证**
- 改完代码必须跑 §1 的验证命令并**修到全绿再停**；报告里贴命令输出作为证据，不接受"看起来改好了"。

**范围**
- 只做被要求的事。不做未被要求的重构、缓存、重试、配置化、防御式抽象；单调用点不引入接口/工厂/包装器（≥3 个真实调用点才许抽象）。
- 新文件/新依赖必须给理由；能放进现有模块的合并回去。

**结构**
- 新增代码不得使任何文件超过 **800 行**（目标 500）；触碰上限必须先拆再改。
- 依赖方向单向；禁止引入循环依赖；安全/权限/校验逻辑**写在调用处本地可见**，不藏进配置或中间件。
- 新功能优先"新增文件、少改旧文件"；不新建 services/utils/common 这类收纳层。

**命名**
- 一个概念一个独特、可 grep 的名字，跨代码/配置/文档保持同一字符串；禁用 data/helper/utils/misc 等泛化名做顶级命名。

**测试**
- 修复 bug = 先写复现失败的测试，再修，测试留下当回归锁。
- **不改测试文件**（除非本任务就是写测试）。

**文档**
- 改行为必须同步对应文档；发现文档与代码矛盾时报告并修复，不默默绕过。

## Agent 行为契约（防冗余）

1. 比例防御：校验/备份/评审动作必须能指出它防的具体失效模式，指不出就不做并一行说明省略原因；可逆小改动用最轻流程。
2. 验证节制：只执行本文件或任务说明预定义的验证命令，不自创冒烟/门控/回归流程；同一命令一次任务只跑一次；追加检查前先回答「若 bug 存在，这条命令报什么错」，答不出就不做。
3. 三栏汇报：汇报只含「进度 / 指标原始值 / 阻塞」（阻塞=需人拍板的选择题）；统计结论只在预设判据满足时给；哈希等内部凭据进日志不进汇报；承诺带时间点或判据。
4. 范围刚性：按既定计划推进，发现额外问题只登记不处理；改计划前先请示（[异常]+[影响面]+[A/B 选项]）。
5. 实验模式（实验/训练/仿真代码适用）：fail-fast——禁 try/except 吞计算错误、静默 fallback/默认值兜底、重试包装、日志框架、抽象层；保留随机种子、NaN/shape 断言、checkpoint 落盘、边界校验。
（与 ~/.zcode/AGENTS.md 同源）


## 历史材料隔离（2026-10-08 起）

- `V0.1/`＝2026-10-08 前的完整快照、`tools/video/archive/`＋`tools/video/scripts/render_lesson.py`＋`render_run_shots_v11.py`＝退役 3D 管线、`docs/90-历史/`＝旧稿——**全部是存档，不作为任何现行依据**。
- 检索/调研一律排除 `V0.1/` 与 `archive/`（例：`grep -r --exclude-dir=V0.1 --exclude-dir=archive ...`）；课程真源＝`docs/50-课程/`，视频真源＝`tools/video/README.md`，环境＝`tools/video/ENVIRONMENT.md`。
- 两版对照走 git tag `v0.1`/`v0.2` 或 `docs/20-验收/2026-10-08-第一课成片迭代全记录.md`。
