extends "res://scripts/levels/flow_base.gd"

## L5 流程驱动器（五关终点关）：主题（spec §9.1.1）"它怎么跑完、怎么不错"——
## 装回廊、执行器、校验门、旁路四件，配 E60 占位视频。
## 过关检查：给它一个坏输入，它自己校验、重试、跑完。
##
## 分工（照抄 l1_flow.gd 的施工模式）：
##   * 本脚本只做"逻辑 + 步记录"：世界操作全走 WorldTools 的 12 工具面
##     （autoload 或注入内核，注入优先——测试与演示互不污染）；
##   * 可视（view，可空）：指向 l5_scene.gd 的场景实例，装组件、小车移动、
##     门体转角、计数器都是纯显示，headless 无 view 也能跑完整闭环。
##
## 终点产物（spec §9.1"终点"）：五关走完十四件齐备。**显式决定**：
## L1–L4 的十件以简化占位形式装上（stub_* 资产：小方块+名牌，完整版在
## 前四关场景里，本关不复刻其全部行为）；十件占位 + 本关四件实体 = 十四件，
## 齐备后调 world.export_python() 导出整台 codex 的骨架 Python。
##
## 坏输入任务的因果链（check_pass 判定依据，全部进步记录）：
##   学员下坏输入（task_text 内嵌 payload 缺必需字段）
##   → 回廊第 1 轮（set_param rounds=1）→ 执行器跑（world.run）
##   → 校验门拒绝（codex.verify ok=false，failId c10.3:1：字段集不等）
##   → 旁路记录重试 1（set_param retry_count=1）
##   → codex 修正输入（补默认字段）
##   → 回廊第 2 轮 → 执行器再跑 → 校验门通过（codex.verify ok=true）
##   → 显式出口（set_param @done）→ 写出结果（files @result_out）
##
## 硬规则（mini-codex §2.1）：组件四态由步记录的 actor/phase 派生
## （派生函数在各组件脚本），本类不另做状态机。

## 「另一实例」评分入口（scoring/ 包，与执行侧零共享）。显式 preload 不走
## 全局类名缓存——headless -s 模式不重扫 class cache（评分侧测试同款做法）。
const LevelAssets := preload("res://scripts/levels/level_assets.gd")
const ASSET_SCREEN := LevelAssets.ASSET_SCREEN
const ASSET_CODEX := LevelAssets.ASSET_CODEX
# ---- 十四件（编号对 docs/10-契约/mini-codex.md §一；L1–L4 十件为占位、L5 四件为实体） ----
const ASSET_TASK := "stub_task_board"          # 1 任务牌（L1 占位，block=entry）
const ASSET_PLATE := "stub_nameplate"          # 2 角色铭牌（L1 占位，block=step）
const ASSET_PLANNER := "stub_planner_board"    # 3 计划板（L4 占位，block=think）
const ASSET_CONTEXT := "stub_context_container"  # 4 上下文容器（L3 占位，block=step）
const ASSET_MODEL := "stub_model_core"         # 5 思考机（L4 占位，block=think）
const ASSET_MEMORY := "stub_memory_cabinet"    # 6 记忆柜（L3 占位，block=step）
const ASSET_TOOLS := "stub_tool_belt"          # 7 工具带（L4 占位，block=step）
const ASSET_FILES := "stub_file_cabinet"       # 8 文件柜（L2 占位，block=sink）
const ASSET_RUNNER := "conc_runner"            # 9 执行器（本关实体，block=generate_call）
const ASSET_GATE := "conc_verify_gate"         # 10 校验门（本关实体，block=validate）
const ASSET_BYPASS := "conc_bypass"            # 11 旁路（本关实体，block=recover）
const ASSET_GALLERY := "conc_loop_gallery"     # 12 回廊（本关实体，block=guard）
const ASSET_ARM := "stub_arm_head"             # 13 机械臂（L2 占位，block=step）
const ASSET_SCANNER := "stub_scanner_head"     # 14 扫描器（L2 占位，block=parse）

## 十件占位的编号与名牌（视图层 StubZone 摆放用）。
const STUBS := [
	[1, "任务牌"], [2, "角色铭牌"], [3, "计划板"], [4, "上下文容器"],
	[5, "思考机"], [6, "记忆柜"], [7, "工具带"], [8, "文件柜"],
	[13, "机械臂"], [14, "扫描器"],
]

## 校验门的 schema：payload 必须带的字段集（c10.3：字段对上闸门才开）。
const REQUIRED_FIELDS := ["tool", "args"]

# ---- 坏输入任务文本（payload= 后内嵌 JSON；坏在缺必需字段） ----
const TASK_BAD_1 := '跑一遍工具调用：payload={"tool": "run.count"}'
const TASK_BAD_2 := '跑一遍工具调用：payload={"args": {"path": "orders_v2.json"}}'
const TASK_FIXED_1 := '跑一遍工具调用：payload={"tool": "run.count", "args": {"path": "orders.json"}}'
const TASK_FIXED_2 := '跑一遍工具调用：payload={"tool": "run.count", "args": {"path": "orders_v2.json"}}'

const SEED_L5 := 20260914
const LOOP_LIMIT := 3

## 注入优先；为空时在 _ready 解析 autoload（窗口模式），再兜底自建。
## 可视场景（l5_scene.gd），可空。
var eids: Dictionary = {}     # assetId -> entityId（十四件 + 幕布）
var codex_eid := ""
var gallery_eid := ""
var runner_eid := ""
var gate_eid := ""
var bypass_eid := ""
var files_eid := ""

func _init() -> void:
	episode = 60
	default_seed = SEED_L5
# ---------- 世界初始化（工具序列之外，spec §4.5） ----------

## 资产声明即编译器投影约定（integration/world_to_graph.gd 头注释）：
## 保留参数 block=编译器方块 kind；端口 id 命中控制词汇表（ctl/next/loop/done）
## 映射控制端口，其余（in/out/raw/payload）映射数据端口。
## 十四件连成的图：入口→铭牌→计划板→工具带→[回廊环：思考机→执行器→扫描器→
## 校验门→回廊(guard，loop 回边 + done 显式出口)]→机械臂→上下文容器→记忆柜→
## 文件柜(sink)；旁路(recover)不进控制流——导出后它落在 except 分支里重试。
func setup_world() -> Dictionary:
	if _world_set_up:
		return {"ok": true, "entityId": codex_eid}
	var st := tools.state()
	st.register_asset(ASSET_TASK, WorldStateCore.KIND_PARAMETRIC,
		{"block": "entry", "task_text": "（等一条任务）"}, [
			{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_PLATE, WorldStateCore.KIND_PARAMETRIC,
		{"block": "step", "display_name": "mini codex", "role": "跑完与兜错"}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_PLANNER, WorldStateCore.KIND_PARAMETRIC,
		{"block": "think", "max_turns": LOOP_LIMIT}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_CONTEXT, WorldStateCore.KIND_PARAMETRIC,
		{"block": "step", "window_budget": 8}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_MODEL, WorldStateCore.KIND_PARAMETRIC,
		{"block": "think", "max_turns": LOOP_LIMIT, "temperature": 0.7}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_MEMORY, WorldStateCore.KIND_PARAMETRIC,
		{"block": "step", "note": "上次结果"}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_TOOLS, WorldStateCore.KIND_PARAMETRIC,
		{"block": "step", "tools": ["read", "write", "run", "search"]}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_FILES, WorldStateCore.KIND_PARAMETRIC,
		{"block": "sink", "path": "out/result.json"}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "result_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_RUNNER, WorldStateCore.KIND_PARAMETRIC,
		{"block": "generate_call", "command": "run.count", "bad_calls": 1}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_GATE, WorldStateCore.KIND_PARAMETRIC,
		{"block": "validate", "required_keys": REQUIRED_FIELDS}, [
			{"id": "payload", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_BYPASS, WorldStateCore.KIND_PARAMETRIC,
		{"block": "recover", "max_retries": 3, "retry_count": 0}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
		])
	st.register_asset(ASSET_GALLERY, WorldStateCore.KIND_PARAMETRIC,
		{"block": "guard", "loop_limit": LOOP_LIMIT, "rounds": 0}, [
			{"id": "payload", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "loop", "kind": "BOOL", "dir": "out"},
			{"id": "done", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_ARM, WorldStateCore.KIND_PARAMETRIC,
		{"block": "step", "slot": "orders.json"}, [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_SCANNER, WorldStateCore.KIND_PARAMETRIC,
		{"block": "parse"}, [
			{"id": "raw", "kind": "ANALOG", "dir": "in"},
			{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		])
	st.register_asset(ASSET_SCREEN, WorldStateCore.KIND_EXHIBIT,
		{"content": "L5·E60 占位视频"}, [])
	st.register_asset(ASSET_CODEX, WorldStateCore.KIND_PARAMETRIC,
		{"display_name": "mini codex"}, [
			{"id": "touched", "kind": "BOOL", "dir": "in"},
		])
	# codex 本体是世界初始化声明（不是学员的操作步，不进步记录）
	var placed: Dictionary = st.place(ASSET_CODEX, [2, 0, 4])
	codex_eid = str(placed.get("entityId", ""))
	_world_set_up = true
	return placed


# ---------- 五个阶段 ----------

## 阶段一：幕布亮起，播占位内容（步记录 phase=video；E60）。
func stage_video() -> Dictionary:
	var place: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_SCREEN, "pos": [4, 0, -2]},
		{"actor": "level", "caption": "幕布方块就位（player_ 展示方块，占位内容）"})
	if bool(place.get("ok", false)):
		eids[ASSET_SCREEN] = str(place["result"]["entityId"])
	if view != null:
		view.get_player_screen().play()
	_record_level_step("video",
		{"tool": "level.stage", "args": {"stage": "video", "episode": 60, "content": "placeholder"}},
		"幕布亮起：L5 · E60 占位视频（占位内容，不引真视频）")
	return place


## 阶段二：装四件 + 前十件占位（world.place），再连成整台 codex（world.connect）。
func stage_install() -> Dictionary:
	var placements: Array = [
		# [assetId, 格点, caption]
		[ASSET_RUNNER, [-4, 0, -1], "装上执行器（conc_runner，本关实体）"],
		[ASSET_GATE, [-2, 0, -3], "装上校验门（conc_verify_gate，本关实体）"],
		[ASSET_BYPASS, [1, 0, -3], "装上旁路（conc_bypass，本关实体）"],
		[ASSET_GALLERY, [-1, 0, 1], "装上回廊（conc_loop_gallery，本关实体）"],
		[ASSET_TASK, [3, 0, -4], "占位装上任务牌（L1 完整版在 L1 场景）"],
		[ASSET_PLATE, [4, 0, -3], "占位装上角色铭牌（L1 完整版在 L1 场景）"],
		[ASSET_PLANNER, [5, 0, -2], "占位装上计划板（L4 完整版在 L4 场景）"],
		[ASSET_CONTEXT, [6, 0, -1], "占位装上上下文容器（L3 完整版在 L3 场景）"],
		[ASSET_MODEL, [6, 0, 1], "占位装上思考机（L4 完整版在 L4 场景）"],
		[ASSET_MEMORY, [5, 0, 2], "占位装上记忆柜（L3 完整版在 L3 场景）"],
		[ASSET_TOOLS, [4, 0, 3], "占位装上工具带（L4 完整版在 L4 场景）"],
		[ASSET_FILES, [3, 0, 4], "占位装上文件柜（L2 完整版在 L2 场景）"],
		[ASSET_ARM, [6, 0, 3], "占位装上机械臂（L2 完整版在 L2 场景）"],
		[ASSET_SCANNER, [5, 0, 4], "占位装上扫描器（L2 完整版在 L2 场景）"],
	]
	var out := {}
	for p in placements:
		var r: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
			{"assetId": p[0], "pos": p[1]},
			{"actor": "player", "caption": str(p[2])})
		out[p[0]] = r
		if bool(r.get("ok", false)):
			eids[p[0]] = str(r["result"]["entityId"])
	gallery_eid = str(eids.get(ASSET_GALLERY, ""))
	runner_eid = str(eids.get(ASSET_RUNNER, ""))
	gate_eid = str(eids.get(ASSET_GATE, ""))
	bypass_eid = str(eids.get(ASSET_BYPASS, ""))
	files_eid = str(eids.get(ASSET_FILES, ""))

	# 连线（13 控制 + 7 数据）：整台 codex 的骨架，export_python 的数据源
	var wiring: Array = [
		# 控制：入口链
		["%s:next" % ASSET_TASK, "%s:ctl" % ASSET_PLATE],
		["%s:next" % ASSET_PLATE, "%s:ctl" % ASSET_PLANNER],
		["%s:next" % ASSET_PLANNER, "%s:ctl" % ASSET_TOOLS],
		["%s:next" % ASSET_TOOLS, "%s:ctl" % ASSET_MODEL],
		# 控制：回廊环（强连通分量 = 带 while True 的循环体）
		["%s:next" % ASSET_MODEL, "%s:ctl" % ASSET_RUNNER],
		["%s:next" % ASSET_RUNNER, "%s:ctl" % ASSET_SCANNER],
		["%s:next" % ASSET_SCANNER, "%s:ctl" % ASSET_GATE],
		["%s:next" % ASSET_GATE, "%s:ctl" % ASSET_GALLERY],
		["%s:loop" % ASSET_GALLERY, "%s:ctl" % ASSET_MODEL],
		# 控制：显式出口 + 出口后链
		["%s:done" % ASSET_GALLERY, "%s:ctl" % ASSET_ARM],
		["%s:next" % ASSET_ARM, "%s:ctl" % ASSET_CONTEXT],
		["%s:next" % ASSET_CONTEXT, "%s:ctl" % ASSET_MEMORY],
		["%s:next" % ASSET_MEMORY, "%s:ctl" % ASSET_FILES],
		# 数据
		["%s:out" % ASSET_TASK, "%s:in" % ASSET_PLANNER],
		["%s:out" % ASSET_TASK, "%s:in" % ASSET_MODEL],
		["%s:out" % ASSET_MODEL, "%s:in" % ASSET_RUNNER],
		["%s:out" % ASSET_RUNNER, "%s:raw" % ASSET_SCANNER],
		["%s:out" % ASSET_SCANNER, "%s:payload" % ASSET_GATE],
		["%s:out" % ASSET_SCANNER, "%s:payload" % ASSET_GALLERY],
		["%s:out" % ASSET_SCANNER, "%s:in" % ASSET_CONTEXT],
	]
	var wired := 0
	for wi in wiring.size():
		var w: Array = wiring[wi]
		var from_ref := "%s:%s" % [eids[w[0].split(":")[0]], w[0].split(":")[1]]
		var to_ref := "%s:%s" % [eids[w[1].split(":")[0]], w[1].split(":")[1]]
		var c: Dictionary = tools.call_tool(WorldToolsCore.TOOL_CONNECT,
			{"from": from_ref, "to": to_ref},
			{"actor": "player", "caption": "连线：%s -> %s" % [from_ref, to_ref]})
		if bool(c.get("ok", false)):
			wired += 1
		out["wire_%d" % (wi + 1)] = c

	if view != null:
		view.install_loop_gallery()
		view.install_runner()
		view.install_verify_gate()
		view.install_bypass()
		for s in STUBS:
			view.install_stub(int(s[0]), str(s[1]))
		_refresh_visuals()

	_record_level_step("install",
		{"tool": "level.stage", "args": {
			"stage": "install",
			"components": 14,
			"l5_entities": [ASSET_GALLERY, ASSET_RUNNER, ASSET_GATE, ASSET_BYPASS],
			"stubs": STUBS.map(func(s): return s[0]),
			"wired": wired,
		}},
		"十四件齐备：本关四件实体 + L1–L4 十件占位，整台 codex 连线就绪（显式决定：占位体不复刻前四关行为）")
	return out


## 阶段三：坏输入任务——codex 自己校验、重试、跑完（kind=task 全程落盘）。
## flow 坏在缺字段：rounds 表示回廊轮次（延续计数，tune 再跑接着数）。
func stage_run(task_text := TASK_BAD_1, fixed_text := TASK_FIXED_1, start_round := 1) -> Dictionary:
	var out: Dictionary = {}
	out["set_task"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": str(eids[ASSET_TASK]), "key": "task_text", "value": task_text},
		{"actor": "player", "caption": "学员下了坏输入任务（task_text 内嵌 payload，格式坏）"})
	out["accept"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": str(eids[ASSET_TASK]), "key": "@out", "value": 1.0},
		{"actor": "codex", "caption": "codex 接活：任务流进整台 codex"})
	if view != null:
		await view.codex_goto(view.gallery_front_pos())
	# ---- 第 1 轮：执行器跑 → 校验门拒绝 ----
	out["round1"] = _run_one_round(start_round, task_text)
	# ---- 拒绝才走旁路：记录重试 + codex 修正输入（通过则无重试步） ----
	if not bool((out["round1"] as Dictionary)["verify"]["passed"]):
		out["reject_retry"] = _record_retry_and_fix(fixed_text, out)
	# ---- 第 2 轮：执行器再跑 → 校验门通过 ----
	out["round2"] = _run_one_round(start_round + 1, fixed_text)
	# ---- 显式出口 + 写出结果 ----
	out["done"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": gallery_eid, "key": "@done", "value": true},
		{"actor": "codex", "caption": "回廊走显式出口：第二轮通过，循环结束"})
	out["result"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": files_eid, "key": "@result_out", "value": 1.0},
		{"actor": "codex", "caption": "跑完写出结果（文件柜 result_out=1）"})
	if view != null:
		view.get_runner().set_flowing(false)
		_refresh_visuals()
	_record_level_step("run",
		{"tool": "level.stage", "args": {
			"stage": "run", "taskText": task_text, "fixedText": fixed_text,
		}},
		"坏输入跑完：第 1 轮校验拒绝（缺字段）→ 旁路重试 → 修正输入 → 第 2 轮通过 → 写出结果")
	# ---- 终点演示：十四件齐备，导出整台 codex 的骨架 Python ----
	out["export"] = tools.export_python()
	return out


## 阶段四：改一个参数再跑——重试上限 3→2 + 换一种坏输入（缺 tool）。
func stage_tune() -> Dictionary:
	var out: Dictionary = {}
	out["set_limit"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": bypass_eid, "key": "max_retries", "value": 2},
		{"actor": "player", "caption": "改一个参数：旁路重试上限 3→2"})
	out["set_task"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": str(eids[ASSET_TASK]), "key": "task_text", "value": TASK_BAD_2},
		{"actor": "player", "caption": "换一种坏输入：payload 缺 tool 字段"})
	if view != null:
		view.get_bypass().set_max_retries(2)
	_record_level_step("tune",
		{"tool": "level.stage", "args": {
			"stage": "tune", "maxRetries": 2, "taskText": TASK_BAD_2,
		}},
		"改参重跑：重试上限 3→2、坏输入换成缺 tool，同一台 codex 再跑一遍")
	# 再跑：同一因果链，坏法不同、上限更紧
	var run2: Dictionary = await stage_run(TASK_BAD_2, TASK_FIXED_2, 3)
	out["rerun"] = {"steps": run2.size()}
	out["export"] = run2.get("export", {})
	return out


## 阶段五：评分——交给「另一实例」ScorerService（scoring/ 包，与执行侧零共享）：
## 输入是冻结前的 run 文档 + 本关 task_goal（goals.gd 纯数据，不从本类取状态）；
## LLM 通道不可用时自动回退规则评分（rule_v1，本关 failures 在案，鲁棒维会
## 检出拒绝→重试闭环）。五句与 evidence 落进 score 步的 output
## （args.dimensions 保持旧形状兼容：[{dim, sentence}×5]）。
func stage_score() -> Dictionary:
	var rc := tools.recorder()
	var verdict: Dictionary = ScorerServiceScript.new().score(rc.get_doc(), ScorerGoalsScript.goal_for("L5"))
	var dims: Array = []
	for s in verdict.get("sentences", []):
		var d: Dictionary = s
		dims.append({"dim": str(d.get("dim", "")), "sentence": str(d.get("text", ""))})
	var ops_total := 0
	for s in rc.get_steps():
		ops_total += int((s as Dictionary).get("ops", 0))
	_record_level_step("score",
		{"tool": "level.score", "args": {"stub": false, "dimensions": dims}},
		"五维诊断已出（另一实例评分：%s，五句与证据见本步 output）" % str(verdict.get("scorer", "")),
		{
			"ok": true,
			"sentences": verdict.get("sentences", []),
			"evidence": verdict.get("evidence", {}),
			"scorer": str(verdict.get("scorer", "")),
			"llm": verdict.get("llm", {}),
		})
	return {
		"dimensions": dims,
		"sentences": verdict.get("sentences", []),
		"evidence": verdict.get("evidence", {}),
		"scorer": verdict.get("scorer", ""),
		"llm": verdict.get("llm", {}),
		"ops": ops_total,
	}


## 全流程一条龙：装→跑→改→评→落盘→判定（测试与判定用）。
func drive_full() -> Dictionary:
	setup_world()
	begin()
	await stage_video()
	await stage_install()
	await stage_run()
	await stage_tune()
	stage_score()
	finish_run()
	return check_pass()


# ---------- 过关检查（读冻结的 run JSON，不重跑世界） ----------

## 判定"给它一个坏输入，它自己校验、重试、跑完"：
##   1. 存在校验拒绝步（codex.verify ok=false，failId c10.3:1）
##   2. 其后存在旁路重试步（set_param retry_count）
##   3. 其后存在第二轮通过步（codex.verify ok=true）
##   4. 其后存在最终完成步（set_param @done / @result_out）
##   5. 重试计数与上限一致：计数终值 == 步记录最大值，且不超 max_retries 终值
func check_pass() -> Dictionary:
	var rc := tools.recorder()
	if rc.state_name() != "frozen":
		return {"pass": false, "reason": "not_frozen", "runId": rc.run_id()}
	var doc: Dictionary = JSON.parse_string(rc.frozen_text())
	var steps: Array = doc.get("steps", [])
	var rejects: Array = []
	var retries: Array = []
	var passes: Array = []
	var completions: Array = []
	var retry_values: Array = []
	for i in steps.size():
		var step: Dictionary = steps[i]
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		var args: Dictionary = action.get("args", {})
		var output: Dictionary = step.get("output", {}) if step.get("output", {}) is Dictionary else {}
		if tool == "codex.verify":
			if bool(output.get("ok", false)):
				passes.append(i)
			else:
				rejects.append(i)
		elif tool == WorldToolsCore.TOOL_SET_PARAM and str(args.get("entityId", "")) == bypass_eid:
			if str(args.get("key", "")) == "retry_count" and bool(output.get("ok", false)):
				retries.append(i)
				retry_values.append(int(args.get("value", 0)))
		elif tool == WorldToolsCore.TOOL_SET_PARAM and bool(output.get("ok", false)):
			var key := str(args.get("key", ""))
			var eid := str(args.get("entityId", ""))
			if (eid == gallery_eid and key == "@done" and bool(args.get("value", false))) \
					or (eid == files_eid and key == "@result_out" and float(args.get("value", 0.0)) > 0.0):
				completions.append(i)
	# 最后一条完整因果链（tune 重跑后仍成立）
	var chain_ok := false
	var chain := {}
	if not rejects.is_empty() and not passes.is_empty() and not completions.is_empty():
		var last_reject: int = rejects[rejects.size() - 1]
		var retry_after := -1
		for j in retries:
			if j > last_reject:
				retry_after = j
		var pass_after := -1
		for j in passes:
			if j > last_reject:
				pass_after = j
		var completion_after := -1
		for j in completions:
			if j > last_reject:
				completion_after = j
		if retry_after > last_reject and pass_after > retry_after and completion_after > pass_after:
			chain_ok = true
			chain = {"reject": last_reject, "retry": retry_after,
				"pass": pass_after, "done": completion_after}
	# 重试计数与上限一致（终值从冻结 JSON 的世界摘要读，不重跑世界）
	var retry_max := 0
	for v in retry_values:
		retry_max = maxi(retry_max, int(v))
	var final_retry := _final_param(steps, bypass_eid, "retry_count")
	var final_limit := _final_param(steps, bypass_eid, "max_retries")
	var counts_ok := final_retry >= 1 and retry_values.has(final_retry) \
		and final_retry <= final_limit
	return {
		"pass": chain_ok and counts_ok and not rejects.is_empty(),
		"chain": chain,
		"rejects": rejects.size(),
		"retries": retries.size(),
		"passes": passes.size(),
		"completions": completions.size(),
		"retryMax": retry_max,
		"retryFinal": final_retry,
		"retryLimitFinal": final_limit,
		"countsConsistent": counts_ok,
		"runId": rc.run_id(),
		"path": rc.out_path(),
		"steps": steps.size(),
	}


# ---------- 内部：一轮回廊 ----------

## 回廊一轮：计数 → 执行器跑（world.run）→ 校验门检查 payload。
## 返回 {round, verify: {passed, missing}}。
func _run_one_round(round_no: int, task_text: String) -> Dictionary:
	var out: Dictionary = {}
	out["round"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": gallery_eid, "key": "rounds", "value": round_no},
		{"actor": "codex", "caption": "回廊进入第 %d 轮（循环上限 %d）" % [round_no, LOOP_LIMIT]})
	out["run"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "第 %d 轮：执行器跑，输出在观测窗流动" % round_no})
	out["runner_out"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": runner_eid, "key": "@out", "value": float(round_no)},
		{"actor": "codex", "caption": "执行器输出流过观测窗（@out=%d）" % round_no})
	var payload := extract_payload(task_text)
	out["verify"] = _verify_step(payload)
	if view != null:
		view.get_runner().set_flowing(true)
	_refresh_visuals()
	return out


## 校验门的检查步（codex.verify：schema 字段集比对，c10.3）。
## 拒绝时 output.ok=false 并写 failures（failId c10.3:1：字段集不等）。
func _verify_step(payload: Dictionary) -> Dictionary:
	var missing: Array = []
	for f in REQUIRED_FIELDS:
		if not payload.has(f):
			missing.append(f)
	var passed := missing.is_empty()
	var t0 := Time.get_ticks_usec()
	var output := ({"ok": true, "result": {"verdict": "pass", "gate": "正门"}}) if passed \
		else ({"ok": false, "error": {
			"code": "schema_field_missing",
			"message": "缺少必需字段：%s" % "、".join(PackedStringArray(missing)),
		}})
	var caption := ("校验门通过：字段对上（%s），走正门" % "、".join(PackedStringArray(REQUIRED_FIELDS))) if passed \
		else ("校验门拒绝：payload 缺少必需字段 %s（failId c10.3:1），走岔路" % "、".join(PackedStringArray(missing)))
	var i := tools.recorder().record_step({
		"t": tools.state().world_t(),
		"phase": WorldToolsCore.PHASE_RUN,
		"actor": "codex",
		"input": {"payload": payload, "required": REQUIRED_FIELDS},
		"action": {"tool": "codex.verify", "args": {
			"entityId": gate_eid,
			"payload": payload,
			"required": REQUIRED_FIELDS,
		}},
		"output": output,
		"tokens": 0,
		"ops": 1,
		"costMs": (Time.get_ticks_usec() - t0) / 1000.0,
		"world": tools.state().state_digest(),
		"caption": caption,
	})
	if not passed:
		tools.recorder().record_failure(i, "c10.3:1", "schema_field_missing",
			"校验门拒绝：返回字段集与 schema 声明的字段集不等（缺 %s），该次调用记为失败" % "、".join(PackedStringArray(missing)))
	if view != null:
		view.get_verify_gate().set_verdict(passed,
			("通过：字段对上，走正门" if passed else "拒绝：缺少必需字段 %s" % "、".join(PackedStringArray(missing))))
	return {"passed": passed, "missing": missing}


## 拒绝后的兜底：旁路计数 +1，然后 codex 修正输入（补默认值）。
func _record_retry_and_fix(fixed_text: String, _context: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	var retry_no := _last_retry_count() + 1
	out["retry"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": bypass_eid, "key": "retry_count", "value": retry_no},
		{"actor": "codex", "caption": "旁路记录重试 %d（岔路管道走回回廊入口）" % retry_no})
	out["fix"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": str(eids[ASSET_TASK]), "key": "task_text", "value": fixed_text},
		{"actor": "codex", "caption": "codex 修正输入：补默认字段（%s）" % fixed_text})
	if view != null:
		view.get_bypass().set_retry_count(retry_no)
		_refresh_visuals()
	return out


func _last_retry_count() -> int:
	var value := 0
	for s in tools.recorder().get_steps():
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == bypass_eid and str(args.get("key", "")) == "retry_count":
				value = int(args.get("value", 0))
	return value


# ---------- 内部：工具 ----------

## 从任务文本里抠出 payload= 后面的 JSON 对象（坏输入的载体）。
static func extract_payload(task_text: String) -> Dictionary:
	var key := "payload="
	var idx := task_text.find(key)
	if idx < 0:
		return {}
	var raw := task_text.substr(idx + key.length())
	var parsed: Variant = JSON.parse_string(raw)
	return parsed if parsed is Dictionary else {}


## 冻结 JSON 里某实体某参数的终值（从 set_param 步取，不重跑世界）。
static func _final_param(steps: Array, entity_id: String, key: String) -> int:
	var value := 0
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) != WorldToolsCore.TOOL_SET_PARAM:
			continue
		var args: Dictionary = action.get("args", {})
		if str(args.get("entityId", "")) == entity_id and str(args.get("key", "")) == key:
			value = int(args.get("value", 0))
	return value


## 关卡自身的阶段步（video/install/tune/score 这些 kernel 没有的 phase），
## 与工具步走同一条记录通道（照抄 l1_flow 的做法）。
## output 参数默认 {"ok": true}；score 步把评分器的五句与证据放进来。
## 状态灯与计数器永远从步记录重算（mini-codex §2.1：不另做状态机）。
func _refresh_visuals() -> void:
	if view == null:
		return
	var steps := tools.recorder().get_steps()
	var gallery = view.get_loop_gallery()
	if gallery != null:
		gallery.set_state_visual(gallery.derive_state_from_steps(steps, gallery_eid))
		gallery.set_rounds(_final_param(steps, gallery_eid, "rounds"))
		gallery.set_exit_open(bool(_final_bool(steps, gallery_eid, "@done")))
	var runner = view.get_runner()
	if runner != null:
		runner.set_state_visual(runner.derive_state_from_steps(steps, runner_eid, gate_eid))
	var gate = view.get_verify_gate()
	if gate != null:
		gate.set_state_visual(gate.derive_state_from_steps(steps, gate_eid))
	var bypass = view.get_bypass()
	if bypass != null:
		bypass.set_state_visual(bypass.derive_state_from_steps(steps, bypass_eid, files_eid))


static func _final_bool(steps: Array, entity_id: String, key: String) -> bool:
	var value := false
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) != WorldToolsCore.TOOL_SET_PARAM:
			continue
		var args: Dictionary = action.get("args", {})
		if str(args.get("entityId", "")) == entity_id and str(args.get("key", "")) == key:
			value = bool(args.get("value", false))
	return value
