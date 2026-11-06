extends "res://scripts/levels/flow_base.gd"

## L1 流程驱动器（计划 §7 第 3 步）：把一关的闭环
##   看视频(占位) → 装组件 → 跑一遍 → 改一个参数 → 评分 → 过关检查
## 在 headless 可判定、窗口模式可看两种方式下跑通。
##
## 分工：
##   * 本脚本只做"逻辑 + 步记录"：世界操作全走 WorldTools 的 12 工具面
##     （autoload 或注入内核，注入优先——测试与演示互不污染）；
##   * 可视（view，可空）：指向 l1_scene.gd 的场景实例，装组件、小车移动、
##     状态灯翻色都是纯显示，headless 无 view 也能跑完整闭环。
##
## 硬规则（mini-codex §2.1）：组件状态由步记录的 actor/phase 派生
## （派生函数在 task_board.gd），本类不另做状态机——
## _refresh_board_visual() 每次都从 recorder 的 steps 重算。

const TaskBoardScript := preload("res://scenes/levels/l1/components/task_board.gd")

## 代做驱动器（scripts/agent_demo/，docs/10-契约/交互方案.md §六 / docs/10-契约/mini-codex.md §四）。
## 显式 preload 不走全局类名缓存——headless -s 模式不重扫 class cache。
const DemoDriverScript := preload("res://scripts/agent_demo/demo_driver.gd")

## 「另一实例」评分入口（scoring/ 包，与执行侧零共享）。显式 preload 不走
## 全局类名缓存——headless -s 模式不重扫 class cache（评分侧测试同款做法）。
const LevelAssets := preload("res://scripts/levels/level_assets.gd")
const ASSET_BOARD := "conc_task_board"
const ASSET_PLATE := "conc_nameplate"
const ASSET_SCREEN := LevelAssets.ASSET_SCREEN
const ASSET_CODEX := LevelAssets.ASSET_CODEX
const ASSET_CHART := "conc_ops_chart"

const TASK_TEXT_1 := "读取 report.txt 并数出'错误'出现次数"
const TASK_TEXT_2 := "把 report.txt 里的'错误'全部替换成'warning'，另存为 report_fixed.txt"

const SEED_L1 := 20260914

## 注入优先；为空时在 _ready 解析 autoload（窗口模式），再兜底自建。
## 可视场景（l1_scene.gd），可空。
var board_eid := ""
var plate_eid := ""
var screen_eid := ""
var codex_eid := ""
var chart_eid := ""

func _init() -> void:
	episode = 49
	default_seed = SEED_L1
# ---------- 世界初始化（工具序列之外，spec §4.5） ----------

func setup_world() -> Dictionary:
	if _world_set_up:
		return {"ok": true, "entityId": codex_eid}
	var st := tools.state()
	st.register_asset(ASSET_BOARD, WorldStateCore.KIND_PARAMETRIC,
		{"task_text": ""}, [
			{"id": "task_in", "kind": "ANALOG", "dir": "in"},
			{"id": "task_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_PLATE, WorldStateCore.KIND_PARAMETRIC,
		{"display_name": "mini codex", "role": "接活与报数"}, [
			{"id": "identity_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_SCREEN, WorldStateCore.KIND_EXHIBIT,
		{"content": "L1·E49 占位视频"}, [])
	st.register_asset(ASSET_CODEX, WorldStateCore.KIND_PARAMETRIC,
		{"display_name": "mini codex"}, [
			{"id": "touched", "kind": "BOOL", "dir": "in"},
		])
	# codex 本体是世界初始化声明（不是学员的操作步，不进步记录）
	var placed: Dictionary = st.place(ASSET_CODEX, [2, 0, 4])
	codex_eid = str(placed.get("entityId", ""))
	# 图表方块（chart_ 展示方块）：世界初始化声明 + 放置（exhibit 只读，不进步记录）；
	# 数据由 score 阶段的 _refresh_ops_chart 喂（真实步记录 ops，非手摆）
	st.register_asset(ASSET_CHART, WorldStateCore.KIND_EXHIBIT,
		{"title": "两次 run 的 ops 对比", "bars": ""}, [])
	var chart: Dictionary = st.place(ASSET_CHART, [1, 0, 2])
	if bool(chart.get("ok", false)):
		chart_eid = str(chart["entityId"])
	_world_set_up = true
	return placed


# ---------- 五个阶段 ----------

## 阶段一：幕布亮起，播占位内容（步记录 phase=video）。
func stage_video() -> Dictionary:
	var place: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_SCREEN, "pos": [4, 0, -2]},
		{"actor": "level", "caption": "幕布方块就位（player_ 展示方块，占位内容）"})
	if bool(place.get("ok", false)):
		screen_eid = str(place["result"]["entityId"])
	if view != null:
		view.get_player_screen().play()
	_record_level_step("video",
		{"tool": "level.stage", "args": {"stage": "video", "episode": 49, "content": "placeholder"}},
		"幕布亮起：L1 · E49 占位视频（占位内容，不引真视频）")
	return place


## 阶段二：装上任务牌与角色铭牌两件（world.place，绑定表就位）。
func stage_install() -> Dictionary:
	var b: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_BOARD, "pos": [-2, 0, -1]},
		{"actor": "player", "caption": "装上任务牌（conc_task_board）"})
	var p: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_PLATE, "pos": [-3, 0, -2]},
		{"actor": "player", "caption": "装上角色铭牌（conc_nameplate，任务牌背面）"})
	board_eid = str(b.get("result", {}).get("entityId", ""))
	plate_eid = str(p.get("result", {}).get("entityId", ""))
	var c: Dictionary = tools.call_tool(WorldToolsCore.TOOL_CONNECT,
		{"from": plate_eid + ":identity_out", "to": board_eid + ":task_in"},
		{"actor": "player", "caption": "连线：identity_out -> task_in"})
	if view != null:
		view.install_task_board()
		view.install_nameplate().apply_identity("mini codex", "工位 01 · 接活与报数")
		_refresh_board_visual()
	_record_level_step("install",
		{"tool": "level.stage", "args": {
			"stage": "install",
			"components": [ASSET_BOARD, ASSET_PLATE],
			"ports": ["task_in", "task_out", "identity_out"],
		}},
		"两件组件装上：任务牌 + 角色铭牌，绑定表就位")
	return {"board": b, "plate": p, "connect": c}


## 阶段三：学员下任务 → codex 移到任务牌前接活 → world.run（kind=task 全程落盘）。
func stage_run(task_text := TASK_TEXT_1) -> Dictionary:
	var out: Dictionary = {}
	out["set_task"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": board_eid, "key": "task_text", "value": task_text},
		{"actor": "player", "caption": "学员给 codex 下了一条任务"})
	if view != null:
		view.get_task_board().set_task_text(task_text)
		_refresh_board_visual()
		await view.codex_goto(view.board_front_pos())
	out["identity"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": plate_eid, "key": "@identity_out", "value": 1.0},
		{"actor": "codex", "caption": "codex 报身份：铭牌 identity_out=1"})
	out["accept"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": board_eid, "key": "@task_out", "value": 1.0},
		{"actor": "codex", "caption": "codex 接活：任务牌 task_out=1（灯翻'正在'）"})
	if view != null:
		view.get_nameplate().set_identity_lit(true)
		_refresh_board_visual()
	out["run"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "codex 在任务牌前执行：任务沿连线被接下（task_in=1.0）"})
	_record_level_step("run",
		{"tool": "level.stage", "args": {"stage": "run", "taskText": task_text}},
		"任务被接下：task_in=1.0，任务牌翻'完成'")
	if view != null:
		_refresh_board_visual()
	return out


## 阶段四：改一个参数（换一条任务）再跑一遍，看差异。
func stage_tune(task_text := TASK_TEXT_2) -> Dictionary:
	var out: Dictionary = {}
	out["set_task"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": board_eid, "key": "task_text", "value": task_text},
		{"actor": "player", "caption": "改一个参数：换一条任务"})
	_record_level_step("tune",
		{"tool": "level.stage", "args": {"stage": "tune", "taskText": task_text}},
		"改参重跑：task_text 已换，看两版差异")
	out["reset_out"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": board_eid, "key": "@task_out", "value": 0.0},
		{"actor": "codex", "caption": "上一单交付，task_out 复位"})
	if view != null:
		view.get_task_board().set_task_text(task_text)
		_refresh_board_visual()
	out["run"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "换参后再跑一遍：同一装置，不同任务"})
	if view != null:
		_refresh_board_visual()
	return out


## 阶段五：评分——交给「另一实例」ScorerService（scoring/ 包，与执行侧零共享）：
## 输入是冻结前的 run 文档 + 本关 task_goal（goals.gd 纯数据，不从本类取状态）；
## LLM 通道不可用时自动回退规则评分（rule_v1）。五句与 evidence 落进 score 步的
## output（args.dimensions 保持旧形状兼容：[{dim, sentence}×5]）。
func stage_score() -> Dictionary:
	var rc := tools.recorder()
	var verdict: Dictionary = ScorerServiceScript.new().score(rc.get_doc(), ScorerGoalsScript.goal_for("L1"))
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
	# 图表方块吃本次实测（两次 run 的 ops；纯可视，不影响上面的评分步与判定）
	_refresh_ops_chart()
	return {
		"dimensions": dims,
		"sentences": verdict.get("sentences", []),
		"evidence": verdict.get("evidence", {}),
		"scorer": verdict.get("scorer", ""),
		"llm": verdict.get("llm", {}),
		"ops": ops_total,
	}


## 评分后把两次 world.run（stage_run / stage_tune）的实测 ops 喂给图表方块
## （conc_ops_chart，chart_ 展示方块）：纯可视刷新，不写步记录、不参与判定——
## 图表失败不得影响过关判定，故 view 缺方法/为空都直接返回，set_param 的
## ok 被丢弃（l1_scene.refresh_ops_chart 内部同样吞掉喂图失败）。
func _refresh_ops_chart() -> void:
	if view == null or not view.has_method("refresh_ops_chart"):
		return
	var runs: Array = []
	for s in tools.recorder().get_steps():
		var step: Dictionary = s
		if str(step.get("actor", "")) == "codex" \
				and str(step.get("action", {}).get("tool", "")) == WorldToolsCore.TOOL_RUN:
			runs.append(int(step.get("ops", 0)))
	var bars := ""
	for i in runs.size():
		if i > 0:
			bars += ","
		bars += "run%d:%d" % [i + 1, int(runs[i])]
	view.refresh_ops_chart(bars)


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

## 判定"任务被接下"：存在 world.set_param(task_board, task_text)，
## 其后有 actor=codex 的 world.run，且任务牌状态到过"完成"。
func check_pass() -> Dictionary:
	var rc := tools.recorder()
	if rc.state_name() != "frozen":
		return {"pass": false, "reason": "not_frozen", "runId": rc.run_id()}
	var doc: Dictionary = JSON.parse_string(rc.frozen_text())
	var steps: Array = doc.get("steps", [])
	var traj: Array = TaskBoardScript.state_trajectory(steps, board_eid)
	var last_task_i := -1
	var first_text := ""
	var second_text := ""
	for i in steps.size():
		var step: Dictionary = steps[i]
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == board_eid and str(args.get("key", "")) == "task_text":
				last_task_i = i
				var txt := str(args.get("value", ""))
				if first_text == "":
					first_text = txt
				elif second_text == "" and txt != first_text:
					second_text = txt
	var run_after := false
	if last_task_i >= 0:
		for j in range(last_task_i + 1, steps.size()):
			var step: Dictionary = steps[j]
			var action: Dictionary = step.get("action", {})
			if str(action.get("tool", "")) == WorldToolsCore.TOOL_RUN and str(step.get("actor", "")) == "codex":
				run_after = true
				break
	var reached_done := traj.has(TaskBoardScript.STATE_DONE)
	return {
		"pass": last_task_i >= 0 and run_after and reached_done,
		"taskSet": last_task_i >= 0,
		"runAfterTask": run_after,
		"reachedDone": reached_done,
		"trajectory": traj,
		"firstText": first_text,
		"secondText": second_text,
		"runId": rc.run_id(),
		"path": rc.out_path(),
		"steps": steps.size(),
	}


# ---------- 代做接口段（docs/10-契约/交互方案.md §六 / docs/10-契约/mini-codex.md §四） ----------
# 「让它做」：codex 经 MCP 桥真实操作世界，把 L1 任务同语义的操作序列慢速可视
# 走一遍（DemoDriver：每步停留 slow_step_seconds、每步发 step_presented）。
# 代操作边界三条：(a) 慢速可视 (b) 随时接管（driver.take_over）(c) 不参与判定
# ——本段不往 recorder 写任何步：学员 task run 进行中（recording 态）入口直接
# 拒绝（run_agent_demo 的 student_run_in_progress 护栏），代做运行走桥自动开的
# explore run（mcp_bridge_core 的 _ensure_run），判定仍只认学员自己的 task run：
# 五 stage 与 check_pass 的既有逻辑零改动（"代做后 check_pass 不变"的硬断言见
# tests/agent_demo/）。

## 代做用的操作序列（与学员 stage 同语义：装组件+连线 → 下任务 → 跑 → 读结果）。
## 按装置状态自适应：
##   * 任务牌还没装（board_eid 为空，学员卡在拼装段）：place 任务牌+铭牌 →
##     connect(identity_out -> task_in，同 stage_install 的连线) → set_param(
##     task_text) → set_param(@identity_out=1，同学员 run 段"codex 报身份"，缺它
##     task_in 恒 0.0) → run → read，完整七步；
##   * 任务牌已装（学员卡在任务段）：只对已装的任务牌 set_param → set_param(
##     @identity_out=1) → run → read（连线 stage_install 时已连好，代做不重复连）。
## connect / set_param / read 的实体号在发送时从 place 响应动态绑定（args_fn）。
func demo_steps(task_text := TASK_TEXT_1) -> Array:
	if board_eid != "":
		var steps: Array = [
			{"tool": WorldToolsCore.TOOL_SET_PARAM,
				"args": {"entityId": board_eid, "key": "task_text", "value": task_text},
				"caption": "把任务写到已装的任务牌上"},
		]
		if plate_eid != "":
			steps.append({"tool": WorldToolsCore.TOOL_SET_PARAM,
				"args": {"entityId": plate_eid, "key": "@identity_out", "value": 1.0},
				"caption": "codex 报身份：铭牌 identity_out=1"})
		steps.append({"tool": WorldToolsCore.TOOL_RUN, "args": {"duration": 1.0},
			"caption": "跑一遍这条任务"})
		steps.append({"tool": WorldToolsCore.TOOL_READ, "args": {"ref": board_eid + ":task_in"},
			"caption": "读回任务牌的接活口"})
		return steps
	var bind_task := func(responses: Array) -> Dictionary:
		return {"entityId": _demo_board_id(responses), "key": "task_text", "value": task_text}
	var bind_read := func(responses: Array) -> Dictionary:
		return {"ref": _demo_board_id(responses) + ":task_in"}
	var bind_connect := func(responses: Array) -> Dictionary:
		return {"from": _demo_plate_id(responses) + ":identity_out",
			"to": _demo_board_id(responses) + ":task_in"}
	var bind_identity := func(responses: Array) -> Dictionary:
		return {"entityId": _demo_plate_id(responses), "key": "@identity_out", "value": 1.0}
	return [
		{"tool": WorldToolsCore.TOOL_PLACE,
			"args": {"assetId": ASSET_BOARD, "pos": [-2, 0, -1]},
			"caption": "装上任务牌"},
		{"tool": WorldToolsCore.TOOL_PLACE,
			"args": {"assetId": ASSET_PLATE, "pos": [-3, 0, -2]},
			"caption": "装上角色铭牌"},
		{"tool": WorldToolsCore.TOOL_CONNECT, "args_fn": bind_connect,
			"caption": "连线：identity_out -> task_in"},
		{"tool": WorldToolsCore.TOOL_SET_PARAM, "args_fn": bind_task,
			"caption": "把任务写到刚装的任务牌上"},
		{"tool": WorldToolsCore.TOOL_SET_PARAM, "args_fn": bind_identity,
			"caption": "codex 报身份：铭牌 identity_out=1"},
		{"tool": WorldToolsCore.TOOL_RUN, "args": {"duration": 1.0},
			"caption": "跑一遍这条任务"},
		{"tool": WorldToolsCore.TOOL_READ, "args_fn": bind_read,
			"caption": "读回任务牌的接活口"},
	]


## 「让它做」入口：用 DemoDriver 经 bridge_client 把 demo_steps 真实走一遍。
## bridge_client 只要求有 call_tool(tool, args) -> Dictionary——真跑用
## scripts/agent_demo/bridge_client.gd（连 autoload McpBridge），测试可注入 mock。
## 护栏（mini-codex §四(c)）：学员 task run 进行中（recorder 还是 recording 态）
## 时拒绝——此时桥的 _ensure_run 不会再开新 run，代做步会写进这条判定 run。
## 返回 DemoDriver 的运行结果（completed / taken_over / completed_steps /
## remaining_steps / responses / was_judged:false 等）；被护栏拒绝时返回
## {ok:false, completed:false, code:"student_run_in_progress", message, was_judged:false}。
## 工具头 0.6s 停留、"正在"灯等可视接线订阅 DemoDriver.step_presented，
## 由场景任务完成（要订阅本次运行的信号可直接自建 DemoDriver + demo_steps）。
func run_agent_demo(bridge_client, task_text := TASK_TEXT_1,
		slow_step_seconds: float = DemoDriverScript.DEFAULT_SLOW_STEP_SECONDS) -> Dictionary:
	var _rc := tools.recorder()
	if _rc.state_name() == "recording":
		if str(_rc.get_doc().get("run", {}).get("kind", "")) == "task":
			return {
				"ok": false,
				"completed": false,
				"code": "student_run_in_progress",
				"message": "学员 task run 进行中（recorder 正在 recording），代做步会被写进这条判定 run"
					+ "（mini-codex §四(c) 代做不参与判定）。请先 finish_run() 冻结该 run，再「让它做」。",
				"was_judged": false,
			}
		# 遗留的 explore recording（上次代做未收尾）：冻结收尾，让桥开新的 explore run
		_rc.end_run()
	var driver := DemoDriverScript.new()
	driver.bridge = bridge_client
	driver.slow_step_seconds = slow_step_seconds
	var result: Dictionary = await driver.run(demo_steps(task_text))
	result["driver"] = driver
	return result


## demo 序列里第 1 步 place 带回的任务牌实体号（args_fn 动态绑定用）。
func _demo_board_id(responses: Array) -> String:
	if responses.is_empty():
		return ""
	var first: Dictionary = responses[0] if responses[0] is Dictionary else {}
	return str((first.get("result", {}) as Dictionary).get("entityId", ""))


## demo 序列里第 2 步 place 带回的铭牌实体号（connect 的 from 端动态绑定用）。
func _demo_plate_id(responses: Array) -> String:
	if responses.size() < 2:
		return ""
	var second: Dictionary = responses[1] if responses[1] is Dictionary else {}
	return str((second.get("result", {}) as Dictionary).get("entityId", ""))


# ---------- 内部 ----------

## 关卡自身的阶段步（video/install/tune/score 这些 kernel 没有的 phase），
## 与工具步走同一条记录通道（参照 report_physics_event 的做法）。
## output 参数默认 {"ok": true}；score 步把评分器的五句与证据放进来。
## 状态灯永远从步记录重算（mini-codex §2.1：不另做状态机）。
func _refresh_board_visual() -> void:
	if view == null:
		return
	var board = view.get_task_board()
	if board == null:
		return
	board.set_state_visual(TaskBoardScript.derive_state_from_steps(
		tools.recorder().get_steps(), board_eid))
