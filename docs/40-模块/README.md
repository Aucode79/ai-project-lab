# 模块索引 · `game/` 的目录、职责与坑

> 2026-09-15 重写：原 `modules/game-scripts-main.md` 只写 `main.gd` 一件，随 docs 分层重组扩成**全模块索引**，并按代码实况修正了过期数字。
>
> **边界（别重复劳动）**：
> - 「改了哪个模块该跑哪个测试套件」的**唯一真源**是 `tools/run_tests.sh` 的 `map_suites()`。
> - 本文补 `AGENTS.md` 不覆盖的**模块级细节**：一句话职责、入口文件、接口与坑。
> - Godot 工程根 = `game/`，故 `res://` 即 `game/`；`scripts/` 指 `game/scripts/`。

## 2026-09-18 新入口与共享视觉

`scenes/studio/component_studio.tscn` 是默认入口，脚本为 `scripts/interaction/bright_workbench.gd`。正式组件几何在 `scripts/asset_lib/component_catalog.gd`；`asset_style.gd` 统一颜色与原生 UI，`block_surface.gd` 缓存倒角网格，`text_tile.gd` 烘焙并复用平面文字。`scripts/scene/scene_menu.gd` 为工坊、沙盒与五关提供 F1 导航。详情见 [本轮验收](../20-验收/2026-09-18-美术统一与组件工坊.md)。

## 1. 模块总表

| 模块目录 | 一句话职责 | 入口文件 | 跑哪套 |
|---|---|---|---|
| `scripts/`（顶层 2 件） | 基准冒烟场景与体素地形生成器 | `main.gd`、`terrain_generator.gd` | `check.sh` 冒烟 |
| `scripts/core/` | 世界内核：状态层、实体/绑定表、端口、工具面、步记录 schema v6、计价、物理单向上报 | `world_state_core.gd` | `--suite world` |
| `scripts/autoload/` | 5 个 autoload 薄壳（WorldState / WorldTools / StepRecorder / CostModel / McpBridge），实现全在 `core/` | `world_state.gd` | `--suite world`（T12/T13 覆盖注册段与无 autoload 兜底） |
| `scripts/compiler/` | 方块编译器（连接图 → IR → Python）：折叠不变量、位置无关逐字节验证 | `compiler.gd` | `--suite compiler` |
| `scripts/integration/` | 世界 → 编译器桥：把 WorldState 的装置投影成编译器图 | `world_to_graph.gd` | `--suite integration` |
| `scripts/scene/` | 场景总装基座：`world_builder.gd`（调色板/地形/环境/材质/相机，全仓唯一一份）+ `level_scene_base.gd`（五关与沙盒场景脚本的基类） | `world_builder.gd` | 全部关卡套件 + `check.sh` |
| `scripts/levels/` | 五关流程：`flow_base.gd` 共用骨架（工具内核解析/集号种子/开始收尾/逐级步记录）+ `l1`–`l5_flow.gd` | `flow_base.gd` | `--suite l1`…`l5` + `scoring\|mcp\|agent_demo` |
| `scripts/asset_lib/` | 三层资产库（`base_` → `mach_` → `conc_`）的公共基座；`STANDARD_CUBE_SIZE := 0.5` 是全仓尺寸唯一真源 | `asset_node.gd` | `--suite assets` |
| `scripts/interaction/` | 学员交互总装：长按搬 / 点按开、异步虚影（物理落点预测）、轨道相机、空格运行 | `interaction_hub.gd` | `--suite interaction` |
| `scripts/scoring/` | 五维诊断评分器（`rule_v1`，纯逻辑不挂场景：拿 run 记录与任务目标比对） | `five_dim_scorer.gd` | `--suite scoring` |
| `scripts/help/` | 三级提示服务：现象 → 诊断 → 代做，逐级升级但不直接给答案 | `hint_service.gd` | `--suite help` |
| `scripts/persistence/` | 装置存档与跨 run diff 双轨（存档/读档、回上一版） | `device_store.gd` | `--suite persistence` |
| `scripts/agent_demo/` | 代做接管：codex 经 MCP 桥真实操作世界（place → set_param → run → read） | `demo_driver.gd` | `--suite agent_demo` |
| `scripts/sandbox/` | 自由沙盒场景、资产台账（28 件全量生成台）与**箱庭浮空岛世界配方**（`sandbox_island.gd` 地形 + `sandbox_diorama.gd` 天空/光照/移轴/相机机位 + `sandbox_block.gd/.gdshader` 方块本体的倒角与表面、草皮顶块，沙盒专属，不复用关卡配方；自然装饰（树石 / 浮尘粒子）2026-09-17 全删，`sandbox_flora.gd` 已移除，**草不是几何**） | `sandbox.gd` | `--suite sandbox\|sandbox/island\|sandbox/ground\|sandbox/shader_space` |
| `scripts/studio/` | 资产片段捕获（生产管线第一步），`-s` 脚本 + Movie Maker | `capture.gd` | 无套件（由 `tools/production/capture.sh` 调起） |

`scenes/` 侧与之对应：`scenes/levels/lN/`（各关 .tscn + `components/` 组件）、`scenes/sandbox/`、`scenes/blocks/`（可复用展示方块）、`scenes/main.tscn`。场景内容全部代码搭建，`.tscn` 只挂根节点 + 脚本（见 `AGENTS.md §2` 铁律 3）。

## 2. 顶层基准场景：`scripts/main.gd` + `scripts/terrain_generator.gd`

**一句话职责**：用 `zylann.voxel` 扩展搭出方块沙盒的基准世界，并把美术方向（正交等距 + 限定调色板 + 纯色烘 AO）写进代码而不是留给后期——它同时是 `tools/check.sh` 的冒烟对象。

- **被谁依赖**：`scenes/main.tscn` 把 `main.gd` 挂在根节点上。
- **依赖谁**：`zylann.voxel` GDExtension（`game/addons/zylann.voxel/`）。**体积 129M**，其中 `bin/`（129M）由 `tools/install_voxel.sh` 获取、`.gitignore` 挡住不入库；其余 33 个文件（LICENSE / icons / 脚本等）**已入库**（原文写"51MB 不入库"对 bin/ 成立、对整目录不成立）。

| 文件 | 职责 |
|---|---|
| `terrain_generator.gd` | `VoxelGeneratorScript` 子类，无随机数（同一坐标必得同一结果）。逐格写 7 种方块：`1 深层基岩 / 2 岩层 / 3 承重结构 / 4 甲板面 / 5 机器 / 6 核心 / 7 电路线`（0 是空气）。高度量化成 5 格一阶，地表是甲板而非草地，每 8 格嵌一道发光电路线，原点附近一座带四角信标塔的机器平台 |
| `main.gd` | 组装世界：方块库、网格化器、地形节点、正交相机、`VoxelViewer`、环境与光照；提供 `--check` / `--shot` 两种模式 |

**调色板真源**：教学资产颜色角色在 `scripts/asset_lib/asset_style.gd`；关卡 `world_builder.gd` 按体素索引引用这些角色，五关共享。沙盒地形调色板在 `sandbox_island.gd`；历史 main/bench 仍保留其测量配方。关卡生成器已移除树，关卡粒子装配点保留为空函数。

### 入口

```bash
# 结构与生成自检（要开窗口——VoxelTerrain 依赖渲染管线）
tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game -- --check

# 渲染截图到 game/shots/world.png
tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game -- --shot
```

### 关键 API 事实（实测得来，不是抄文档）

| 事实 | 说明 |
|---|---|
| `VoxelBlockyModel.set_material_override(index, mat)` | 索引只有 **2 个槽**，传 0..5 会报 `Index out of bounds (size = 2)`。别按立方体的 6 个面去理解 |
| `VoxelMesherBlocky.TINT_RAW_COLOR` | 会去读体素数据的**颜色通道**，该通道没配深度就报 `Color channel depth not supported`，网格化整个卡死。本项目改用**每个方块模型自带的材质**上色 |
| `VoxelEngineUpdater` | GDExtension 版本提供的节点。扩展挂不进引擎主循环，需要在场景里放一个来驱动 `VoxelEngine` |
| `VoxelViewer` 的位置 | 它是"玩家"，要放在**世界里**。挂在远处的正交相机上会让需求区落到地形 bounds 之外 |
| `VoxelTerrain.get_statistics()` | **逐帧**统计，且**没有** `mesh_blocks` 这类键。拿它当"是否生成好了"的判据会永远得到 0 |

**判据要问对对象**：判断地形好没好别读统计字典，直接问地形 `_terrain.has_data_block(_terrain.voxel_to_data_block(Vector3i(0, 20, 0)))`——`--check` 的等待循环等的就是这个条件。

### 美术方向怎么落在代码里

| 手段 | 落点 |
|---|---|
| ① 正交等距镜头 | `Camera3D.projection = PROJECTION_ORTHOGONAL`，`size = 74`，机位 (94, 36, 94) 看向 (0, 14, 0) |
| ② 限定调色板 | `PALETTE`（见上），冷色系打底 + 暖橙（机器）+ 青（核心/电路线）作强调 |
| ③ 纯色 + 烘 AO | 每个方块模型一个 `StandardMaterial3D`，`vertex_color_use_as_albedo = true` 让 mesher 烘的 AO 生效 |

### 设计要点与坑

- **高度要量化**。平滑噪声直接取整会产生满地 1 格台阶，地形读成灯芯绒，且崖面只有 1 格高、露不出分层。量化成 5 格一阶后台阶变少变大，崖面自然显出横向色带。
- **太阳方位角要对准相机那一侧**。相机在 +X+Z，方位角给 132° 会整个地形逆光发黑；给 45°（`rotation_degrees = (-48, 45, 0)`）才对。
- **GDScript 生成器逐格写体素**，`bounds` 的纵向范围直接决定生成量；开太大（如 192 格）会让待生成体素数冲到千万级，看起来像卡死。
- **地形边缘会露馅**。当前 `VoxelViewer.view_distance = 96`，画面里能看到世界边界；真要开放世界得上 `VoxelLodTerrain` 的 LOD 与流式加载。
- **`.godot/` 与 `shots/` 不入库**；`addons/zylann.voxel/bin/` 不入库（同目录其余文件入库）。

### 测试

| 覆盖点 | 怎么跑 |
|---|---|
| 地形/网格化器/生成器就位、7 种方块各带材质、方块库 8 个模型、相机正交、观察者就位、环境开关、地形产出数据块（**15 条断言**；口径为 `模型数 == PALETTE.size()` 即 8、`带材质 == PALETTE.size() - 1` 即 7） | `--check` |
| 实际渲染产出 | `--shot` 后看 `game/shots/world.png` |
| 体素管线是否可用（含生成器产出） | `bash tools/check.sh` |

> 6 个 spike 期探针（`probe_*.gd`）已于 2026-09-15 退役，`.uid` 残留一并从 git 清除；历史在 `git log`。
