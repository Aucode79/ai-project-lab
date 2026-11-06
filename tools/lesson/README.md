# 可执行 Agent 沙盒

在仓库根运行：

```powershell
powershell -ExecutionPolicy Bypass -File tools/lesson/start_agent_lab.ps1
```

窗口截图可运行 `tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game scenes/lessons/agent_lab.tscn --resolution 1920x1080 -- --shot`；场景会等浮岛体素就绪，保存到 `game/shots/agent-lab/unified-world.png`。

导入节点的 `sourceSpan` 行号从 1 开始，列号从 0 开始并按 Unicode 字符计数；Python AST 的 UTF-8 字节列会在导入时转换，中文代码前缀不会让源码锚点错位。

把一个 `.py` 文件拖进可执行程序场景，或在 F1 菜单点“导入 Python 程序…”、按 Ctrl+O 选择文件，即可导入为当前可抓取、可下钻、可连线的 3D 程序。导入成功后场景立即重建机器；空格打开 JSON 输入对话框，预填程序的示例输入，确认后执行。请求保留原始 JSON 数字文本，因此整数与浮点数会传给 Python 为对应的 `int` 与 `float`。旧程序先备份。不支持的语法会显示出错行，导入失败不会替换当前程序。当前可执行导入范围是**一个或多个无装饰器、无默认参数和注解的顶层函数、受限顶层类，以及数字、字符串、布尔值或 `None` 标量常量赋值**；默认入口优先选 `main`、其次 `solve`、否则取首个函数。函数允许零个或多个位置参数，支持数值、字符串、布尔值、`None`、列表、字符串键字典、常量键索引、常见算术与比较、`and` / `or` / `not`、条件表达式（分支不含文件读写或自定义函数调用）、`abs` / `len` / `sum` / `min` / `max` 单参数调用、`range` 调用、局部赋值、常量键的字典或列表项赋值与复合赋值、UTF-8 工作区文件的 `read(path)` / `write(path, content)`、仅末尾单条返回的 `with open(path) as file: return file.read()` 只读作用域（默认使用当前 Python 的文本编码，也接受显式 UTF-8）、独立表达式语句、分支内单条 `return` 的 `if`、只含一个 `except ZeroDivisionError` 且两侧各单条 `return` 的 `try`、函数调用与递归，以及末尾 `return` 或完整 `if/else` 返回。`for` 可遍历已有表达式或 `range(...)`，`while` 可按已有表达式判断；循环体目前只允许更新循环前已定义的单变量，允许 `+=` 等复合赋值，不支持嵌套循环、`break`、`continue`、循环 `else` 或在循环体内返回。模块和函数文档字符串可以保留。模块常量引用会成为带名称的常量节点；选中常量按 F2 输入 JSON 标量时，程序中同名引用同步修改；整数与十进制/指数数值保留 Python 的 `int` / `float` 区分。0–9 键可快速修改选中的数字常量。示例输入会根据遍历、聚合及常量键索引生成列表或字典；`read(path)` 的路径参数默认填入工作区《任务.md》，其余参数默认取 41；运行对话框允许在执行前改成实际所需的 JSON 值。此入口尚不支持任意 Python。

保存整张程序图时，后端会恢复与上一版数值相同的未编辑整数参数类型；F2 数值修改会显式携带 `int` 或 `float` 类型，避免 Godot JSON 往返把整数常量变成浮点数。

受限类子集只接受无继承、无装饰器且类体只含实例方法的顶层类，并要求定义 `__init__`。方法参数须使用已有子集支持的位置参数形式；`__init__` 只能返回 `None`，条件或循环中的提前返回会拒绝导入，显式返回只能放在字段初始化之后的最后一条语句。实例字段须在 `__init__` 的直线代码中赋值。入口函数只从 `ClassName()` 构造和变量别名跟踪实例类型；已识别的实例变量不能在条件或循环体内重新绑定，方法也不能重新绑定接收实例的参数。实例值只能用于属性访问、方法接收者或变量别名。每次构造创建独立状态，别名继续引用同一状态。字段和方法同名、除 `__init__` 外的双下划线方法及双下划线字段均拒绝导入，避免把 Python 特殊方法、名称改写或内建实例属性误当普通字典状态。继承、类属性、静态方法、类方法、属性装饰器、动态属性解析和从函数参数推导实例类型均拒绝导入。

比较表达式支持链式写法，如 `0 < value < limit`；比较按 Python 顺序短路。链式操作数中的自定义函数、Agent 调用和文件读写会拒绝导入，避免把有副作用的操作提前执行。

可直接把 `game/lesson_samples/class_counter.py` 拖入 Agent Lab 导入。它返回 `[2, 2, 0]`，用于检查实例隔离与别名共享；同一编译图重复运行仍返回相同结果。构造器和实例方法调用现在共用装配台造型，字段显示为状态槽，独立构造对应独立槽组，别名仍沿用同一实例的数据连线。3D 导入图见 `game/shots/agent-lab/class-counter-preview.png`。

可把 `game/lesson_samples/editable_score_map.py` 拖入 Agent Lab，或按 Ctrl+O 选择它。默认输入 `[1, 2, 3]` 返回 `{"value-01": 2, "value-02": 4, "value-03": 6}`。图中的格式文本与乘数均可编辑；修改乘数后再次运行，结果应与修改后的 Python 程序一致。跨层验收通过实际 Agent Lab 场景完成导入、3D 下钻、F2 编辑保存和运行，并比较结果值与数值类型。

跨层导入验收运行：

```powershell
& 'D:/smolagents/.venv/Scripts/python.exe' -X utf8 tools/lesson/test_agent_import_asset.py
```

它启动临时回环服务并以隔离地址加载实际 Agent Lab 场景，通过文件选择信号导入样例，在 3D 图中下钻、按 F2 改乘数、按空格运行，最后将冻结图、执行事件和结果与修改后的 CPython 程序对照；不会绑定或连接共享的 7331/7332 端口。该自动化不代替 Windows 原生选择器的真实点击和操作系统拖放验收。

Agent 工具循环可使用 Agent Lab 的 `message(role, value)`、`model(messages, tools)` 和 `dispatch(action, tools)` 调用：模型动作必须是包含 `tool` 与 `args` 的对象；循环自行判断 `finish`，其他动作才分派，分派回执由程序加入下一轮消息。`message` 的角色须为字符串常量；这些调用不能放进 `and`、`or` 或条件表达式分支。完整导入样例为 `game/lesson_samples/agent_tool_loop.py`。它走现有模型、工具权限和沙盒运行时，不支持任意 Python 可调用对象或动态函数表。

生成器表达式目前支持一个同步循环、单变量目标和无副作用的过滤/产出表达式；它必须直接作为函数最后一条 `return` 的值，以保留惰性迭代语义并避免后续语句改变闭包变量。导入图使用 `generator` 重复器、`generator_input` 和过滤/产出数据口，编译执行时仍返回 Python generator；创建时立即取得外层迭代器，逐项 `next()` 时才处理过滤和产出。每个输入项、过滤结果和产出值都会写入原始执行事件，并由同一 3D 机器动画流点亮节点、传递数据包。HTTP 运行边界逐项消费它，并以 JSON 列表返回有限结果，同时在每项之间检查取消信号。嵌套或多层循环、异步生成器、循环体内的自定义调用/文件操作、将生成器先赋值再返回，以及把生成器嵌进列表或字典等结构都会拒绝导入。示例 `game/lesson_samples/lazy_positive_doubles.py` 的默认输入为 `[1, 2, 3]`，渲染图见 `game/shots/agent-lab/generator-expression-detail-20260924.png`。

列表推导式支持单层同步循环、单变量目标及无副作用的过滤和产出表达式，可直接赋值或嵌入其他表达式；执行时立即取迭代器并完整生成列表，使用同一 3D 重复器、输入和数据节点。嵌套推导式、多层循环及循环体内自定义调用或文件操作会拒绝导入。默认运行输入会按推导式的外层迭代器预填列表。

字典推导式支持相同的单层循环与纯过滤边界，键和值都成为重复器的数据输入；执行结果遵循 Python 字典规则，包括相同键由后出现的值覆盖。嵌套推导式、多个循环和副作用调用会拒绝导入。

格式化字符串支持字面文本、转义花括号、`!s`/`!r`/`!a` 转换和静态格式说明。导入图把文本保留为可编辑字符串常量，每个插值转成带输入端口的 `format` 数据节点，再用字符串拼接节点组合；插值中的函数调用、文件读写和动态格式说明会拒绝导入。格式值的实际结果遵循 Python `format()` 语义。

查看线性查找的 Python 3D 教学样例：

```powershell
powershell -ExecutionPolicy Bypass -File tools/lesson/start_agent_lab.ps1 -LinearSearchSample
```

此模式在同一 Agent Lab 场景中读取 `game/lesson_samples/linear_search.json`，不会载入或覆盖当前可执行 Agent 程序。样例保留 3D 视角旋转、下钻和长按移动；它是只读的结构展示，不会执行算法或向运行服务保存编辑。样例 JSON 由 `tools/lesson/python_visual_ir.py` 从 `game/lesson_samples/linear_search.py` 的 Python AST 生成；更新源码后运行 `python tools/lesson/python_visual_ir.py game/lesson_samples/linear_search.py game/lesson_samples/linear_search.json` 重新生成。

入口是 F1 菜单中的“沙盒 · 可执行程序机器”，也可用上方启动命令直达。程序机器、运输道路、车和货物同处自由沙盒的浮岛地形。旧的 28 件静态组件仍在 F1 菜单的“组件资产工区”，尚未转成这台机器的可执行节点。预装 Agent 已连接世界观测、移动、装卸与文本读写；默认任务是读《任务.md》，运输三个方块并写《报告.md》。模型通过 CLI 收到结构化世界状态，包括道路、封路、运输车、货物和文档清单。场景操作不再显示二维编辑器、浮空/贴地文字标签或文字操作面板。

右键拖动旋转三维视角，滚轮缩放。整机层只展示真实程序中的任务入口、工具集合、Agent 调用与返回件；双击 Agent 块进入内部，显示上下文初始化、模型、工具分派、循环与观测等大组件。汇总层把真实程序子图映射为可抓取的 3D 组件块，并显示由真实控制边压缩得到的通道关系及组件间直接数据关系；这些概览通道只用于说明大组件交接，不改变执行图，也不显示低层临时节点、文字工具栏或文件列表。组件块长按 0.28 秒提起；抓起后的线框虚影随拖动预示按 0.25 m 网格吸附的落点，松手后保留到实体落稳并保存位置。静止选中使用贴地细边框。双击可调用组件继续进入真实的三维内部，Backspace 返回上层；内部端口仍可拖线。选中常量节点按 F2 编辑标量，0–9 快捷键只修改选中的数字常量。键盘 Space 运行（导入的 Python 程序先填写 JSON 输入），Escape 停止，R 重置，F5 重新载入程序。导入 Python 后，赋值与返回语句显示在对应的 3D 盒表面；源码文字和行列范围不改变程序语义哈希。

Python 源码导入示例见 `game/agent-lab/a_plus_one.py`。命令行也可运行 `python tools/lesson/import_python.py game/agent-lab/a_plus_one.py`，与窗口导入走同一服务入口。底层 `Statement` 节点保存语句种类、赋值目标、表达式模块和符号依赖；函数模块的 `scope.symbols` 记录参数与局部变量。赋值/返回表达式由独立表达式图表示。原始源码片段和行列范围用于显示及回溯，不参与语义哈希；多行表达式仍是一个语句，分号分隔的多个语句仍分别建模。数据连线表示符号引用，控制连线表示语句顺序；导入的 Python 图将数据通道半透明绘制，控制通道保持更醒目，以便在复杂循环中读到盒面源码；函数调用另有真实调用盒与控制顺序，递归仍调用同一函数盒。`setitem` 盒把容器项更新保留为原地修改，容器原有别名指向同一个对象；变量和容器项的复合赋值使用 Python 原地运算，同一列表的别名会同步看到变化。新值的表达式在盒内显示并可下钻。`read` 仅读取 Agent Lab 工作区中的 UTF-8 文本，`write` 仅写入该作用域内的相对路径；`with open(path) as file: return file.read()` 的路径同样受工作区约束，未指定编码时采用当前 Python 默认文本编码，也可显式指定 UTF-8，文件节点记录为执行事件。循环图用 `phi` 状态槽接收进入循环前的值与上一轮赋值结果；`for` 使用迭代器的 `each`/`done` 出口，`while` 使用条件回边。导入器按 AST 判定语句，不按物理行切分；当前独立表达式语句只接受导入器支持的表达式；`if` 仅支持分支内单条 `return`；`try` 仅支持单个 `except ZeroDivisionError` 且 try/except 分支各返回一条语句。其他异常类型、finally/else、多条分支语句、分支内状态更新、短路或条件分支中的自定义函数调用和文件读写、继承、类属性、异步和导入语句仍不支持。首版可见内构已在 call、statement 和带模块的 return 盒中显示其直接子模块的三维缩略图；缩略图不可编辑，双击仍进入完整模块。深层递归缩略、通用 Python 覆盖与通用语义原语映射尚未完成。可用 `tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game scenes/lessons/agent_lab_art_preview.tscn --resolution 1920x1080 -- --shot` 渲染当前实际 `program.json`，输出 `game/shots/agent-lab/art-preview.png`。目标架构与验收门见[递归程序盒与可见内构](../../docs/30-决策/2026-09-23-递归程序盒与可见内构.md)；低层 IR 见[语义语句与表达式层级](../../docs/30-决策/2026-09-23-语义语句与表达式层级.md)。

为保留 Python 名称解析语义，模块标量常量不能被当作内置函数或 `read`/`write` 文件操作执行；`except ZeroDivisionError` 在局部变量、模块常量或顶层函数同名时拒绝导入。`with open(...)` 只接受未被局部变量、模块常量或顶层函数覆盖的内置 `open`；资源读取会直接落成文件节点，不会借用用户可定义的 `read` 名称。

修改导入图中的常量或连接后，原始 Python 语句可能已不再对应新语义；服务会移除旧源码文字和行列范围，保留图作为新的执行依据。移动布局不改变语义，因此保留源码定位。

检查未写入用户程序的导入图时，`agent_lab_art_preview.tscn` 可在 `--shot` 后接 `--program=res://...json`、`--module=<模块 ID>` 和 `--out=res://...png`，分别指定图文件、下钻模块与截图目标。

首批扩展示例 `game/agent-lab/python_subset_demo.py` 用乘法、局部变量和加法生成 `task * 2 + 3` 组件链；运行 `python tools/lesson/import_python.py game/agent-lab/python_subset_demo.py` 可将它载入当前沙盒，默认示例输入 41，结果应为 85。

A+1 的 3D 方案对照场景：`tools/godot/Godot_v4.7.2-stable_win64.exe --path game scenes/lessons/agent_viz_options.tscn --resolution 1920x1080`。由左至右分别为流水线、表达式树、嵌套模块；右键旋转，滚轮缩放，长按组件可抓取。三者是视觉方案原型，还未替换正式导入器的组件渲染。

模块可通过双击 call 节点逐层进入，按 Backspace 回退。递归仍使用普通 Python 调用栈，资源上限由 Python 和计算机决定。详细模块内可框选、长按移动节点并拖动端口连线；本轮整机概览只展示 Agent 必需的大组件，均可抓取移动。添加算子、任意接口名与复合参数仍未完成，不能视为完整交付。

图文件为 game/agent-lab/program.json，首次启动由 lab_preset.py 生成。工作目录为 game/agent-lab/workspace/；其中每个文件映射为一个沙盒文档对象。外部修改由服务扫描同步，约 0.7 秒一次。双击列表中的文档可打开、编辑、保存、重命名或删除；有未保存修改时，外部内容变化保留草稿并拒绝覆盖。文本编辑面向 UTF-8 文件；二进制文件仍会列入清单，但不能作为文本编辑。

启动时冻结整份程序。运行中的编辑只影响下一轮；断开工具会同时改变下一轮模型收到的工具说明与 CLI 权限。循环、分支、返回和异常处理来自图生成的 Python；运行层不加 Agent 专用自动重试。停止请求在节点边界或模型请求返回后生效，正在进行的模型请求最长等待 90 秒。

Godot 世界接口使用 localhost:7331，编辑与运行服务使用 localhost:7332。编译语义集中在 module_compiler.py；Godot 的 module_program.gd 调用同一个编译器，旧图格式继续走原编译器。运行目录 game/runs/agent-lab/r-*/ 保留冻结图、生成代码、sourceMap、逐次模型请求与原始响应、execution.jsonl、世界记录和结果。图层布局及名称不影响代码或语义哈希。

默认使用本机 D:/smolagents/.venv/Scripts/python.exe，已安装 openai；可用 AGENT_LAB_PYTHON 覆盖。模型凭据沿用下面旧环境的 SMOL_* 配置方式。新增实现无额外 pip 依赖。用户草稿、工作文件、运行产物与截图已排除在 Git 跟踪外。

旧验收见 [可执行 Agent 沙盒验收](../../docs/20-验收/2026-09-22-可执行Agent沙盒.md)；整机引擎 v2 见 [整机引擎验收](../../docs/20-验收/2026-09-23-整机引擎v2.md)。三维整机由 `machine_view.gd` 构建；旧验收中的二维编辑器操作说明已失效。旧工坊的 26 件静态组件不等于这个可执行程序。第一课视频的概念镜头已更新为包含这台整机的画面。

---

# 第一课运输环境

在仓库根运行 `powershell -ExecutionPolicy Bypass -File tools/lesson/start_lesson.ps1`，然后在对话框中发送任务。已有游戏可按 F1 进入“第一课 · 真实 Agent 运输”；对话框仍需本地模型服务。

默认任务是“把货物从 A 运到 D”。第一次成功移动后，环境关闭 B—C 道路。`move` 只允许走一条相邻、未封闭的道路，不含寻路算法。模型通过最新观测选择后续节点。运输车一次只能装一个方块，`drop` 后才完成卸货。第二个任务可发送“把蓝方块、黄方块整理到 D”。

模型服务使用 `D:/smolagents/.venv` 中已有的 OpenAI 客户端，默认读取已配置示例的 `SMOL_API_KEY`、`SMOL_BASE_URL`、`SMOL_MODEL`；同名环境变量可覆盖。密钥只在内存中使用，不复制到本仓或运行记录。当前模型为 `deepseek-flash`。控制循环位于 `run_agent.py`，每次模型调用只产生一个 JSON 工具请求，没有预写路线。单任务最多 36 次模型调用，不自动重试请求。

Godot 场景监听 `127.0.0.1:7321`；对话服务监听 `127.0.0.1:7322`。新环境复用现有 `StepRecorderCore` 的 schema v6；没有改动原 MCP 桥的 12 个世界工具。课程端口只服务本场景，工具名和参数由场景显式检查。现有工坊的“运行”按钮仍不代表真实 Agent 已接入。

`run_agent.py --demo` 在新开的场景中连续执行两项真实模型任务，保存 `tools/video/lesson01/run.json` 和 `verification.json`，原始冻结记录在 `game/runs/e1/`。后续每次模型调用前，实际请求写入 `requests/` 下的独立文件，避免不同场次或服务重启覆盖。每条 `model.generate` 的 `contextFile` 指向该请求，`responseText` 保存原始输出；`runId-context.json` 是便于阅读的会话末尾副本。首个成片源运行保存的是解析后的模型输出与工具返回，原始请求消息文件未保留；`dialogue-check-context.json` 属于之后的对话通路验证，不作为成片源运行的原始请求证据。`tool.observation` 保存实际返回值，环境事件单列，模型内部推理不进入展示。

环境回归：新开一个场景后，用同一 Python 运行 `tools/lesson/check_environment.py`。它重放已保存的实际工具调用，验证非法跨节点移动、穿越封路被拒绝，三个货物最终卸载在 D 并分别显示。这是环境确定性回归，不计作另一次模型成功。

新增场景和课程服务用于隔离运输规则；新增视频脚本负责语音、时间线、Blender 与字幕。没有修改已有资产 ID、原关卡任务或模型权重。
