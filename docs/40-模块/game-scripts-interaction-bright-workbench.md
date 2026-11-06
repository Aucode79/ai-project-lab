# 组件工坊

> 2026-09-18 后续实施已进入正式场景。当前模块职责、操作、性能和剩余限制见 [最新验收](../20-验收/2026-09-18-美术统一与组件工坊.md)。下文保留早一轮样件证据；“字砖不跟随”“无地屏地面”“只有四件搬移”等已由最新记录替代。

本模块把跑圈台、记忆架、点子井、干活台放进一个可操作场景，接入现有拾取、拖拽、落点预测与源码阅读入口。它是独立增量，不替换沙盒，也不代表全项目四层实体化已经完成。

## 运行

```bash
# 交互（自己操作）
tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game --resolution 1600x1000 -s res://tests/bright_loop/capture_bright_workbench.gd

# 取证（自动截图后退出）
tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game --resolution 1600x1000 -s res://tests/bright_loop/capture_bright_workbench.gd -- --capture
```

操作：

- 左键点按样件：打开四层展开阅读器（见下）。
- 阅读器支持滚轮与滚动条，Esc 关闭；B 逐层返回。旧沙盒面板的「点一下就关」规则不变。
- 长按样件：走既有手势路由进入拖拽与异步落点预测；松手交物理，合法才提交，否则回滚到拖入前位置。
- 滚轮缩放：正交投影下改的是相机 `size`，透视下仍改距离（见下「顺带修的两个缺陷」）。

## 场景内容

**26 件全部在场景里**（14 模块 + 8 代码基元 + 4 公共设施），四列排布，行列距 6 m。每件都有 6×3 m 地面字砖（名称中英、图册用途原句、`IN ▶ 接口示意 ▶ OUT`、`空闲 · 状态示意`）。

**机位按页停，而不是一口气拉远。** 全部 26 件同屏会把字砖压到读不清；所以相机一次只框住连续三行（`ROWS_PER_PAGE = 3`），`PageDown`/`PageUp`（`ui_page_down`/`ui_page_up`）翻页。这样 26 件都实体在场景里、可拾取可点开，字砖却保持可读字号——不用在「覆盖全」和「看得清」之间二选一。

取景尺寸按真实包围盒算：递归收集该页样件与字砖的网格 AABB，投影到相机基向量上取所需宽高。**另有一处必须做对**：算尺寸前要清掉右键平移留下的 `_pivot_offset`（用 `OrbitCamera.focus_on()`），否则相机看的点与包围盒中心不一致，边角会被裁掉——实测第二页字砖被切。

`SPECIMEN_IDS` 决定放哪些对象；改这个列表就能换场景内容，不必动几何代码。

**机位不写死。** 早期用常数手算正交 `size`，12 件时右下角被裁掉。现在用真实包围盒（递归收集网格 AABB）配合相机基向量算出需要的视口尺寸，再定 `size`；增删对象或改行列数都不用再调常数。`camera.target` 也移到内容包围盒中心。

## 运行观察：区分「静态可达」与「已观察到」

`game/scripts/interaction/execution_link.gd` 把**记录到的事件**对应到已锚定的语句上：

- 语句可以声明 `events` 键（当前 11 条语句声明了 `max_steps_error`、`step_finalized`、`syntax_error`、`execution_error`、`forbidden_function`、`undefined_name`、`execution_logs`）。
- `observe(events)` 累加计数；一个键可以同时点亮多条语句（例如 `max_steps_error` 同时属于跑圈台、交卷台、体力尺）。
- 没有归属的事件进 `unmapped_events()`，显式暴露而不是静默丢弃。
- 阅读器在语句层写「运行观察：N 次（来自记录事件）」；没有事件时写「0 次（静态可达，尚无事件落到这行）」。

**边界必须说清**：本模块**不产生事件**。目前也没有任何事件源接入（沙盒的 `StepRecorder` 记的是学员程序的粗粒度步骤，映射到 smolagents 内部行会是假声明）。因此现在所有语句的观察计数都是 0，阅读器一律显示「静态可达」——这正是它要守住的那条线：**没有事件就不说执行覆盖**。机制本身由合成事件验证（17 断言）。

## 沙盒接入

四层阅读器已抽成**生产模块** `game/scripts/interaction/unfolding_reader.gd`（状态 + 渲染 + 按键），不再长在测试场景里；工作台与真实沙盒共用同一个渲染器。

沙盒侧由 `game/scripts/sandbox/sandbox_catalog.gd` 接入：沙盒里按 `K` 打开「组件目录」，从第一个已映射对象开始，数字键逐层展开、`Tab` 换对象、`B` 返回、Esc 关闭。**不做猜测映射**——沙盒的 28 件旧资产与新 26 件设计对象不是同一套 id，所以目录是显式入口；普通物件点开仍是原来的资产描述（有测试锁住）。关闭全屏或点普通物件都会退出目录模式。

沙盒接入契约：**12 通过 / 0 失败**。

## 四层展开阅读器

`game/scripts/interaction/unfolding_data.gd` 保存四层映射**数据**，`unfolding_map.gd` 是**接口**（校验、漂移检测、反向定位）。拆成两个文件是因为数据会继续增长，接口保持稳定。

| 层 | 内容 | 例子 |
|---|---|---|
| 1 功能 | 这个对象干什么 | 跑圈台：每步经过这里，决定继续、停止，或交付尽力答案 |
| 2 流程 | 拆成可展开的流程 | 跑圈台 9 个流程：进入任务 / 循环头 / 计划步 / 动作步 / 异常分流 / 收尾 / 超限 / 收尾回调 / 尽力答案 |
| 3 语句 | 具体逻辑语句 | `self._finalize_step(action_step)` |
| 4 真实源码行 | 本机 smolagents 的确切文件与行号 | `src/smolagents/agents.py:601` |

当前已映射**全部 26 件**：24 件落到真实源码（12 模块 + 8 代码基元 + 传话筒 + 分头桥 + 字砖 + 连接带），2 件（会话分身、微课地屏）显式声明尚未实现。合计 316 条已落实语句，跨 5 个 smolagents 文件 + 1 个本仓文件：

| 对象 | 文件 | 语句数 | 覆盖行段 |
|---|---|---|---|
| 跑圈台 | `agents.py` | 32 | 436–637（主循环、异常分流、`finally`、超限、收尾回调） |
| 记忆架 | `memory.py` | 26 | 228–300（系统提示槽、两种视图、回放、代码汇总、回调登记） |
| 点子井 | `models.py` | 29 | 220–626（生成契约、流式归并、请求准备、工具调用解析、导出） |
| 干活台 | `local_python_executor.py` | 42 | 1417–1758（语法分派、解析、状态、终答拦截、逐句求值、超时、输出） |
| 任务信箱 | `agents.py` | 9 | 468–488（入口、附加参数、系统提示、重来语义、第一个任务步） |
| 交卷台 | `agents.py` | 19 | 502–637（取回结果、RunResult 与用量、终答校验、超限标记） |
| 体力尺 | `agents.py` + `local_python_executor.py` | 10 | 468–707 + 58–1665（步数上限、操作数上限、墙钟超时） |
| 工具架 | `tools.py` | 14 | 106–951（基类契约、调用与初始化、序列化、从代码定义、工具集合） |
| 回音盘 | `local_python_executor.py` + `agents.py` | 12 | 64–903 + 574–1754（print 捕获与截断、执行日志与错误回填） |
| 储物柜 | `agents.py` + `local_python_executor.py` | 9 | 331–1355 + 770–805（变量表下发、赋值落表、终答按键取值） |
| 行程表 | `agents.py` | 8 | 550–1003（间隔触发、计划步生成与归档、配置导出） |
| 检票口 | `local_python_executor.py` | 10 | 850–959（名称核对、禁用函数拒绝、参数求值、未定义名报错） |
| 赋值块 | `local_python_executor.py` | 8 | 770–805（求值右值、单/多目标写入变量表） |
| 调用块 | `local_python_executor.py` | 6 | 825–918（查名、print 特例、内置与双下划线限制、真正执行） |
| 判断块 | `local_python_executor.py` | 8 | 1004–1023（条件求值、命中分支、否则分支、统一返回） |
| 循环块 | `local_python_executor.py` | 6 | 440–1035（for 迭代绑定、while 每轮重判） |
| 定义块 | `local_python_executor.py` | 7 | 462–537（登记自定义工具、闭包与局部状态） |
| 取值块 | `local_python_executor.py` | 11 | 383–959（查名与相近候选、下标、双下划线属性拒绝） |
| 异常块 | `local_python_executor.py` | 12 | 1159–1191（try/except 绑定/else/finally） |
| 返回块 | `local_python_executor.py` | 7 | 274–1562（ReturnException 信号与函数体接住） |
| 传话筒 | `agents.py` + `memory.py` | 11 | 758–832 + 46–203（组装系统提示与历史步骤、每步各自的转换） |
| 分头桥 | `agents.py` | 12 | 26–1438（登记多路调用、单路直执行、多路线程池提交、按序汇合） |
| 字砖 | 本仓 `bright_specimens.gd` | 10 | 20–301（6×3 m 牌面、四行文案、SubViewport 烘焙、无 Label3D） |
| 连接带 | 本仓 `bright_specimens.gd` | 4 | 22–242（0.5 m 一段的方向标） |

三类锚点，各有清楚的口径：

- **外部 smolagents**：比对整文件 sha256 + 逐行文本（那部分不在本仓版本控制里，行号可能悄悄漂移）。
- **本仓实现**（`"root": "repo"`，如字砖与连接带）：只比逐行文本，不做哈希——它和这份映射同一次提交，漂移会立刻表现为文本不符。
- **显式声明未实现**：`anchor` 为 `null` 且必须带 `reason`。`coverage()` 把它计入 `unmapped_ids`，阅读器写明「尚未实现」。测试断言全仓恰好两处缺口、都属于设施、且原因不为空——不许默默缺失，也不许编造代码行凑满 26 件。

两个结构性事实，测试都锁住了：

- **一行可以同时属于多个对象**。`run()` 入口 `agents.py:468` 同时是任务信箱「确认步数上限」、跑圈台「进入一轮任务」、体力尺「循环次数上限」。`owners_of(path, line)` 返回全部认领者，阅读器逐条列出，不假装只有一个主人；`reverse()` 只返回主认领者，判空方便。
- **一个对象可以跨文件**。体力尺同时引用 `agents.py`（步数）与 `local_python_executor.py`（操作数与墙钟）。

阅读器按键：数字键展开流程、再按数字键落到语句、再按一次显示该行的真实源码窗口（目标行用 `▶` 标出，并列出该行的全部认领者）；`B` 逐层返回；`Tab` 在已映射对象之间轮换（阅读器即目录，不必改场景）。换一个被点物件打开时会回到第 1 层。

**锚点纪律**（这是这一层可信的全部理由）：

- 每条语句记录整行真实文本，测试逐条回读真实文件并按 `strip_edges` 比较；文本不符即失败。
- 每个被映射的文件记录整文件 sha256。文件一变，`verify()` 报 `drifted_paths`，不允许「行号看起来对得上」就继续宣称有效。
- 覆盖数由数据推导：`coverage()` 返回 `mapped/total/unmapped_ids`；没有锚点的语句计入 unmapped，不算已落实。
- 反向定位：`owners_of(path, line)` 列出全部认领者，测试要求每条语句都出现在自己那一行的认领者里；同一行**同一对象内**只能认领一次，跨对象共用是允许且被测试断言的（`agents.py:468` 至少有多个主人）。
- 外部源码不在场时测试输出 `SKIP` 并退出，不把「没读到文件」算成通过。

26 件全部在映射里；会话分身与微课地屏是**声明式缺口**，不是漏掉。

路径口径：引擎是 Windows 可执行文件，读不到 WSL 的 `/mnt/d/...`；源根默认 `D:/smolagents`，其他环境用环境变量 `SMOLAGENTS_ROOT` 覆盖。

## 文件与依赖

- `game/scripts/interaction/bright_workbench.gd`：搭四件刚体、地面、照明、共享地面字砖，连接交互控制器与四层阅读器。
- `game/scripts/interaction/unfolding_data.gd`：四层映射数据（对象 → 流程 → 语句 → 真实行与文件哈希）。
- `game/scripts/interaction/unfolding_map.gd`：映射接口：溯源、哈希漂移检测、反向定位、覆盖统计、文件↔对象查询。
- `game/scripts/interaction/open_controller.gd`：新增默认关闭的 `scrollable_source` 选项、`key_provider` 与 `refresh()`/`reset_scroll()`。开启后使用滚动容器，点击与滚轮不再关闭面板；关闭时断开视口尺寸订阅。默认分支逐字未改。
- `game/tests/bright_loop/bright_specimens.gd`：样件几何与共享字砖来源。工作台直接依赖它，因此源码清单不能因为它在 `tests/` 目录而漏计这条运行依赖。
- `game/tests/bright_loop/run_bright_interaction_tests.gd`：射线拾取、四层逐层展开、真实源码行、反向定位、滚动、实际搬移、拒绝回滚、停手松手测试。
- `game/tests/bright_loop/run_unfolding_tests.gd`：锚点文本逐条回读、哈希漂移、反向往返、覆盖数推导测试。
- `game/tests/bright_loop/capture_bright_workbench.gd`：窗口运行与取证入口；不带 `-- --capture` 就保持交互。

### 两个刻意的实现选择

**单包围盒碰撞，视觉居中。** 现有预测器只读第一个盒体尺寸，不读子形状偏移，所以工作台把视觉整体移到刚体原点，用一个包住整件的盒体。代价是凹槽不能塞进别的物件，当前不支持孔内装配。

**文字走共享字砖，不走浮空文字。** 每件配一块 6×3 m 地面牌面（`Specimens.build_label`），四行内容：名称中英、图册用途原句、`IN ▶ 接口示意 ▶ OUT`、`空闲 · 状态示意`。文字由 `SubViewport` + `SystemFont` 烘成贴图（`bake_labels()`），非窗口运行直接跳过烘焙。整棵树没有 `Label3D`。

## 顺带修的两个真实缺陷

两个都不在本增量新引入，但都挡住了可操作性，所以按「先红后绿」修掉：

1. **正交相机滚轮缩放无效**。主相机（`scripts/main.gd`）与工作台默认都是正交投影，而 `zoom_by()` 原本只改距离；正交下改距离不改变成像大小，滚轮等于没反应。现在正交改 `size`，透视仍改距离。回归锁 `game/tests/interaction/run_orthographic_zoom_tests.gd`。
2. **停手后松手仍按旧速度抛出**。真实输入只在鼠标移动时更新速度，停住不动再松手会沿用最后一次移动速度，实测可把物件扔出场外，并让拖拽长期停在 DROPPING（工作台地面有限）。新增 `hand_stop_ms`（150 ms）：停手超过该时长，松手不再携带速度。

## 验证

```bash
tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/bright_loop/run_unfolding_tests.gd
tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/bright_loop/run_bright_interaction_tests.gd
tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/interaction/run_orthographic_zoom_tests.gd
bash tools/run_tests.sh --suite 'bright_loop|interaction|sandbox|persistence' --no-validators
```

运行观察契约：**17 通过 / 0 失败**；四层映射 **2426 通过 / 0 失败 / 0 跳过**（26 件、6 个真实文件逐行校验、2 处缺口声明核对）；交互 **265 通过 / 0 失败**（26 件样件各自的射线拾取、逐层展开到真实源码行或缺口声明、`Tab` 走遍全部 26 件、二十六块地面字砖就位）；正交缩放 `before=10.0 after=8.8` PASS；相关套件全绿。

四层映射测试的外部源码不在场时输出 `SKIP` 并退出，不把「没读到文件」算成通过。

测试从相机屏幕坐标进 Hub 排队、物理步内做射线拾取；拖拽跟手由测试注入世界坐标，松手与落定走真实物理。跑圈台确实被搬到另一位置且成功上报一次，拒绝路径恢复到最近接受的位置，停手松手不携带速度。**没有**证明其余三件的实际搬移，也没有证明真实鼠标的长按时序。

中途状态需要说明：26 件改写由另一个代理执行到一半失败，留下非法常量表达式使整个文件无法解析，工作台与测试一并阻塞；其测试还要求 `machine.footprint`/`machine.label_lines` 数据字段，而实现只有同名函数。已补齐派生字段并统一顺序。另有一次 `bright_loop` 报 exit 127，是父侧重复启动两个 runner 并发调用 Godot 所致，单独重跑为 PASS。

## 已知限制

- **不是全项目四层覆盖**。26 件设计对象已齐，但 smolagents 只覆盖 5 个文件，其他文件（远程 executor、monitoring、MCP 等）与 sidecar、本仓其余运行代码还没有清单；两件设施仍无实现。
- **每页只有三行**。翻页键目前是 `PageDown`/`PageUp`；页与页之间相邻物件的字砖会在边缘露出来（物理上就在旁边），不是裁切错误。
- **没有事件源**。联动机制已就位并由合成事件验证，但没有任何真实事件源接入；因此所有语句一律显示「静态可达」，不声称执行覆盖。
- **只验证了二十件里的一件搬移**。二十件都能被射线拾取、点开并落到各自真实源码，但搬移、拒绝回滚、停手松手的端到端证据只有跑圈台。
- **虚影与真实落点不一致**。共享虚影只查看直接子网格、否则退化成 0.5 m 立方体；预测空间也只克隆静态体，不含其他冻结样件。落在另一件样件上的预测不可信。
- **字砖不跟随物件**。字砖是静态网格，物件搬走后留在原位；字砖没有碰撞体，点字砖不会打开源码。
- **等距视角下字砖会被前排物件遮挡**。字砖平铺在地面，后排物件在屏幕空间挡住前排字砖的一部分；这是投影结果，不是空间重叠。
- 退出时有 ObjectDB / 资源占用诊断输出，不能凭退出码为零宣称无资源问题。
- 出口时仍有 `ERROR: 2 resources still in use at exit`，未定位来源。

下一步应把可读标注绑定到物件本身、把阅读器升级为四层结构化内容并加源码哈希校验，然后才谈逐批接入原沙盒。
