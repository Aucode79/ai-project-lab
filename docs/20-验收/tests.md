# tests.md · 测试地图

> 这篇讲：35 个测试套件分别管什么、怎么一键全量、改一处代码该跑哪些验证。
> 权威验证命令同时登记在 `AGENTS.md §1`（档案）与 `§2`（验证映射）。
> **改了代码不知道跑什么？`bash tools/run_tests.sh --changed` 就行**——不用查表（口径见下）。

`agent_lab` 有四个套件：`module_program`（可视化模块编译、递归与共享定义、文件生命周期、Agent/生成器语义、CLI 编码与权限、HTTP /import→/run 隔离执行、Godot 文件选择/拖入回调、JSON 运行输入与常量编辑、源码范围 Unicode 列定位、编辑器实例和端口操作；31 项 Python 行为测试 + 2 项 CLI 子进程测试）、`machine_view`（三维整机构建器，含生成器节点及其惰性数据端口）、`machine_anim`（执行包动画）与 `machine_nav`（层级导航和通道端口）。证据见[可执行 Agent 验收](2026-09-22-可执行Agent沙盒.md)。

## 怎么跑

```bash
# 新克隆的环境先跑一次（补齐引擎与 voxel 插件，幂等，见 tools/bootstrap.sh）
bash tools/bootstrap.sh

# 一键全量：35 个 Godot 套件（其中 module_program 会运行 Python 行为测试）+ 三校验器(WSL) + check.sh 冒烟，共 39 项，需数分钟
bash tools/run_tests.sh

# 按 git 改动自动选套件（日常推荐；认不出的路径回退全量）
bash tools/run_tests.sh --changed
bash tools/run_tests.sh --changed=HEAD~3     # 指定比较基线（缺省：工作区 vs HEAD，干净则 HEAD~1）

bash tools/run_tests.sh --list              # 列出全部套件名
bash tools/run_tests.sh --suite l2          # 只跑套件名匹配（正则）的
bash tools/run_tests.sh --no-validators     # 无 WSL 环境时跳过校验器

# 单套件（等价于 runner 内部做的事）
tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
  -s res://tests/levels/l2/run_l2_tests.gd

# 秒级冒烟（spike 视觉 spike 能否搭起来）
bash tools/check.sh

# sidecar（不在 run_tests.sh 内）
wsl -e bash -lc 'cd /mnt/d/ai-project-lab/sidecar && ./.venv/bin/python -m pytest tests/ -q'
wsl -e bash -lc 'bash sidecar/smoke_e2e.sh'
```

### `--changed` 的映射口径（与代码同源）

- 路径 → 套件的映射**固化在 `tools/run_tests.sh` 的 `map_suites()`** 里：改映射改那一处，文档不再平行维护一张表（避免两处漂移）。
- 只改 `docs/**`、`AGENTS.md`、`tools/*.sh` → 直接告诉你"无需跑测试"并退 0；
- 只改 `tools/validate_*.py` → 只跑三校验器；
- 只改 `sidecar/**` → 把该跑的 `pytest` 命令打给你（它不在本 runner 内）；
- 认不出的路径 → **回退全量**（宁可多跑）；
- `--changed` 与 `--suite` 互斥（前者自动、后者手动），同时给会报错退 2。

全部套件是 **SceneTree 脚本 + 退出码制**：退出码 0 = PASS，非 0 = FAIL。
引擎与 runner 依赖 `GODOT` 环境变量（缺省 `tools/godot/Godot_v4.7.2-stable_win64_console.exe`，不入库）。

## 套件总表（35 个）

| 套件名（`--suite`） | 入口 | 覆盖 |
|---|---|---|
| `world` | `tests/world/run_world_tests.gd` | 世界内核：状态层 / 端口 / 步记录 schema |
| `compiler` | `tests/compiler/run_compiler_tests.gd` | 编译器：graph_model / validate / fold / codegen_python / compiler |
| `integration` | `tests/integration/run_integration_tests.gd` | 世界→编译器桥 `world_to_graph` |
| `interaction` | `tests/interaction/run_interaction_tests.gd` | 交互 hub / 手势路由 / 拖拽 / 虚影预测 / 轨道相机 / 运行控制器 |
| `assets` | `tests/assets/run_asset_tests.gd` | 资产库三层与 `yaml_lite` 解析 |
| `scoring` | `tests/scoring/run_scoring_tests.gd` | 五维评分 `five_dim_scorer` / `goals` / `llm_bridge` / `scorer_service` |
| `help` | `tests/help/run_help_tests.gd` | 求助屏：`fail_counter` / `hint_service` / `concept_reader` / `anchor_bubble` |
| `persistence` | `tests/persistence/run_persistence_tests.gd` | 存读档 `device_store` + 跨 run diff `run_diff` |
| `agent_demo` | `tests/agent_demo/run_agent_demo_tests.gd` | 代做/接管：`demo_driver` / `bridge_client` + `l1_flow` + 任务牌 |
| `agent_lab/module_program` | `tests/agent_lab/run_module_program_tests.gd` | Agent Lab：Python 行为/CLI 测试 + Godot 编译入口 + 编辑器实例（连线/封装/复制） |
| `agent_lab/machine_view` | `tests/agent_lab/run_machine_view_tests.gd` | 三维整机 `machine_view`：布局确定性/0.25 网格/端口表/类型判定/走线/组装 |
| `agent_lab/machine_anim` | `tests/agent_lab/run_machine_anim_tests.gd` | 执行包动画：弧长插值、整格移动、事件限速回放、工作态材质和叠板深度 |
| `agent_lab/machine_nav` | `tests/agent_lab/run_machine_nav_tests.gd` | 层级导航：路径栈、下钻目标解析、模块视图节点与端口通道完整性 |
| `blocks` | `tests/blocks/run_ops_chart_tests.gd` | 展柜 `ops_chart`（+ `l1_flow` 喂图接线） |
| `mcp` | `tests/mcp/run_mcp_tests.gd` | MCP 桥内核 |
| `levels/l1` | `tests/levels/l1/run_l1_tests.gd` | L1 流程 + `l1.tscn` 总装 + 任务牌/铭牌 |
| `levels/l1/l1_wiring` | `tests/levels/l1/run_l1_wiring_tests.gd` | L1 接线：`l1.tscn` + 拖拽/相机 |
| `levels/l2` | `tests/levels/l2/run_l2_tests.gd` | L2 流程 + `l2.tscn` + 文件柜/扫描器/机械臂 |
| `levels/l3` | `tests/levels/l3/run_l3_tests.gd` | L3 流程 + `l3.tscn` + 上下文容器/记忆柜 |
| `levels/l4` | `tests/levels/l4/run_l4_tests.gd` | L4 流程 + `l4.tscn` + 思考机/计划板/工具带 + `mini_brain` |
| `levels/l5` | `tests/levels/l5/run_l5_tests.gd` | L5 流程 + `l5.tscn` + 回廊/运行器/校验门/旁路/桩 |
| `sandbox` | `tests/sandbox/run_sandbox_tests.gd` | 自由沙盒 `sandbox.tscn` + `sandbox_assets` + 相机 |
| `sandbox/island` | `tests/sandbox/run_island_tests.gd` | 箱庭浮空岛：形状不变量（顶面平整 / 形状函数与体素一致 / 收束） / 四段地层 / 灯笼柱 / 材质库 / 场景装配（**没有草叶几何**）/ **甲板碰撞**（T9）/ **草是顶层方块的表面**（T10） |
| `sandbox/ground` | `tests/sandbox/run_ground_tests.gd` | 地面与摆位：**甲板代理轮廓 vs 海岸线**（16 方向 × 0.1 m 多点射线）/ 生成台全量在场（防静默截断）/ **摆位三条口径：同向 yaw=0 · 落 0.25 格且整数 cell 唯一 · 可见体互不穿模（含南侧工区）** / 全部件在夯土台面内 / **T7 部件外延落格**（28 件子树全部可见网格 AABB 六面落 0.25 m 格点，2026-09-17 新增；修复前基线见同目录 `extent_violations_baseline.txt`） |
| `sandbox/shader_space` | `tests/sandbox/run_shader_space_tests.gd` | **着色器坐标空间契约**：fragment 不得用 `MODEL_MATRIX` 重建世界坐标、世界量必须走 vertex→varying、草皮档装配对账 |
| `sandbox/block_conformance` | `tests/sandbox/run_block_conformance_tests.gd` | **方块合规**：整个沙盒场景（含工区屏 / 树石 / 按钮）里每个可见实体几何为 `BoxMesh` 或通过 44 三角形 / 0.05 m 向内倒角 / 向外法线校验的 ArrayMesh；每个节点旋转都是 90° 的整数倍 |
| `bright_loop` | `tests/bright_loop/run_bright_loop_tests.gd` | 新组件形状、尺度与样件覆盖 |
| `bright_loop/bright_interaction` | `tests/bright_loop/run_bright_interaction_tests.gd` | 工坊点按、长按与字砖 |
| `bright_loop/execution_link` | `tests/bright_loop/run_execution_link_tests.gd` | 源码可达与显式缺口 |
| `bright_loop/unfolding` | `tests/bright_loop/run_unfolding_tests.gd` | 分层阅读、滚动、源码定位 |
| `bright_loop/workbench_finish` | `tests/bright_loop/run_workbench_finish_tests.gd` | 26 件搬移落定、完整虚影、地面、字砖拾取、布局往返与控制器释放 |
| `bright_loop/lesson_view` | `tests/bright_loop/run_lesson_view_tests.gd` | L2–L5 可操作相机与直角朝向；L1 地形延迟就绪不解冻手持物 |
| `interaction/drop_grid` | `tests/interaction/run_drop_grid_tests.gd` | 外延落格与拒绝回滚 |
| `interaction/orthographic_zoom` | `tests/interaction/run_orthographic_zoom_tests.gd` | 正交镜头滚轮缩放 |
| `sandbox/sandbox_catalog` | `tests/sandbox/run_sandbox_catalog_tests.gd` | K 目录、按钮与完整滚动 |

> 关卡套件直接 preload 各关 `.tscn`，所以**改 `lN_scene.gd` / `sandbox.gd` 会被对应关卡套件覆盖**（这是场景总装重构的安全网）。

## 三校验器（WSL python3）

| 校验器 | 管什么 |
|---|---|
| `tools/validate_assets.py` | 28 件资产 yaml 与 `asset_lib` 规格一致（防漂移） |
| `tools/validate_concepts.py` | `concepts.yaml` 概念映射完整 |
| `tools/validate_episodes.py` | `episodes/` 元数据合法 |

三者由 `tools/run_tests.sh` 一并跑；任一非 0 退出 → 全量判 FAIL。

## 没有自动化判据的部分

**画面好不好看，没有断言。** 这是有意的：美观标准没有客观阈值，硬编码一个会让测试变成摆设。
替代做法是 `tools/render_previews.sh` 渲染各关预览图（`game/tests/**/*_preview.png`），人工比对两次改动之间的漂移；
`game/bench/` 下的基准复跑管性能数字。结构与行为由上面的套件断言。
