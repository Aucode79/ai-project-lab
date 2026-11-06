> **📌 V0.2 现行体系（2026-10-08）**：本仓库根目录 = V0.2。
> ①课程线＝第零课（编程扫盲）＋9 课＋毕业任务（现行真源 [`docs/50-课程/`](docs/50-课程/) 与《课程设计规范》v5）；
> ②视频＝全 2D 数据驱动管线（真源 [`tools/video/README.md`](tools/video/README.md)）；
> 下方 2026-09-18 状态段描述的是上一代游戏 demo，保留作历史。

# AI Project Lab

> 作者：[@Aucode79](https://github.com/Aucode79) 与 [@yizhang-dream](https://github.com/yizhang-dream) 联合开发（2 人团队）。本仓库为 V0.2 公开快照，不含完整提交历史与早期内部资料。

面向青少年（8–18 岁）的 AI Agent 教育产品：用方块流水线把「编程 / agent 概念」具象化——学员亲手配置一台自己的 mini codex，再改坏它、修好它。交付标准对齐 CCF LMCC-T 认证（青少年组）。

**当前状态（2026-09-18）**：默认进入 26 件组件工坊，F1 切换自由沙盒与五关。已统一功能色与倒角、补齐搬运和鼠标源码阅读。实现范围、实际性能与剩余边界见 [本轮验收](docs/20-验收/2026-09-18-美术统一与组件工坊.md)。

**第一课新增（2026-09-22）**：F1 可进入真实 Agent 运输环境，支持对话派任务、运输途中封路、模型改道和整理散落方块。启动方法见 [第一课环境](tools/lesson/README.md)，视频与 Blender 制作流程见 [视频工具链](tools/video/README.md)。

**可执行 Agent 沙盒（2026-09-22，同日补完）**：新增共享模块与递归编辑、具名连线、Python 生成执行、CLI 世界观测、文件与沙盒文档双向同步；三维整机为分形铸造式立方体语言（分层布局 + 双面端口 + 箭头走线），支持**三维端口直接拖线**与具名参数字段编辑。运行 `powershell -ExecutionPolicy Bypass -File tools/lesson/start_agent_lab.ps1`；[操作说明](tools/lesson/README.md) · [真实任务与验收](docs/20-验收/2026-09-22-可执行Agent沙盒.md)。

## 怎么跑

**干净克隆后第一条命令**（引擎与 voxel 插件都不入库，它会把两者补齐并自检；幂等，可反复跑）：

```bash
bash tools/bootstrap.sh
```

之后的日常命令（**Godot 工程根是 `game/`，不是仓库根**）：

```bash
# 正式组件工坊；F1 切换沙盒与五关
tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game --resolution 1920x1080

# 窗口跑 L1（演示模式；--demo 是关卡自演示，另有 --shot 出预览图）
tools/godot/Godot_v4.7.2-stable_win64_console.exe \
  --path game scenes/levels/l1/l1.tscn --resolution 1920x1080 -- --demo

# 改完代码只跑相关套件（按 git 改动自动映射，不用查表）
bash tools/run_tests.sh --changed

# 收尾全量验证：32 个 Godot 套件 + 三个数据校验器 + 冒烟，共 36 项（数分钟）
bash tools/run_tests.sh
bash tools/run_tests.sh --list          # 列全部套件
bash tools/run_tests.sh --suite l2      # 按正则过滤套件名（例：只跑含 l2 的）
bash tools/check.sh                     # 秒级冒烟（退出码 0 = PASS）
```

Python sidecar（MCP server，与学员共用工具面）单独跑：

```bash
wsl -e bash -lc 'cd /mnt/d/ai-project-lab/sidecar && ./.venv/bin/python -m pytest tests/ -q'
wsl -e bash -lc 'bash sidecar/smoke_e2e.sh'
```

## 文档从哪进

| 想知道 | 看 |
|---|---|
| **新会话从哪开始** | [`docs/00-入口/计划.md`](docs/00-入口/计划.md)（汇总 / 定序 / 下一步） |
| 全部文档的索引 | [`docs/README.md`](docs/README.md) |
| 工程约定（验证命令 / 铁律 / 坑位） | [`AGENTS.md`](AGENTS.md) |
| 某个模块干什么、有哪些坑 | [`docs/40-模块/README.md`](docs/40-模块/README.md) |
| 某个决定当时是怎么想的 | [`docs/30-决策/`](docs/30-决策/) |
| 设计规格（现行契约 v6） | [`docs/10-契约/specs/2026-09-13-sandbox-as-studio-design.md`](docs/10-契约/specs/2026-09-13-sandbox-as-studio-design.md) |

`docs/` 按层分目录：`00-入口/` 汇总与交接、`10-契约/` 设计专题与 spec、`20-验收/` 验收与测量与测试现状、`30-决策/` 逐条 ADR、`40-模块/` 模块细节、`90-历史/` spike 时代快照（默认别读）。

## 已知缺口

- 早期内部资料（立项预案、竞品调研、V0.1 历史快照）未随本公开快照分发。
- 视觉与交互打磨、其余关卡的真 LLM 接入、过渡债清偿、63 集批量生产——见 [`docs/00-入口/计划.md`](docs/00-入口/计划.md) §7 与 [`docs/20-验收/验收-demo.md`](docs/20-验收/验收-demo.md) 的"已知遗留"。

## 沿革

2026-09-13 从 `D:\rl course\ai-project-lab` 分出独立成库——项目混在强化学习课程目录里会让上下文串味（上一轮设计就曾把课程目录里已有的代码当成项目全部依据、忽略了更早的立项文档）。分出后当天产出原 spec，随后形态重做为由方块词汇构成的沙盒世界；2026-09-14 demo 完工验收，2026-09-15 完成世界度量体系 v2 与场景/流程层模块化改造。逐条裁决见 [`docs/30-决策/`](docs/30-决策/)。
