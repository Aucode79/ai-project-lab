extends "res://scripts/levels/flow_base.gd"

## L3 流程驱动器（第 3 关，spec §9.1.1："它记得住什么"）：把一关的闭环
##   看视频(占位) → 装组件 → 跑一遍 → 改一个参数 → 评分 → 过关检查
## 在 headless 可判定、窗口模式可看两种方式下跑通（同 l1_flow.gd 施工模式）。
##
## 本关两件组件：上下文容器（conc_context_container）+ 记忆柜（conc_memory_cabinet）。
## 过关检查："能看到它把上一次的结果带进这一次"——因果链全部走真实工具面：
##   任务 1：codex 读 report.txt（world.read）→ 数出"错误"个数 → 写进记忆柜
##          抽屉 1（world.set_param drawer1，并记 memory.write 步：开合动作可见）
##   任务 2：codex 开记忆柜（world.read 本柜）→ **从读取返回里**取上次值
##          （不是魔法变量）→ 乘 2 → 写到 out 格（world.set_param @out）
##   tune：容量上限 8→4，装 6 份日志 → 按窗口预算裁掉最旧 2 件
##          （context.trim 步，被裁件可见：view 上被裁方块淡出下沉）
##
## 分工：本脚本只做"逻辑 + 步记录"，世界操作全走 WorldTools 的 12 工具面；
## 可视（view，可空）指向 l3_scene.gd 的场景实例。硬规则（mini-codex §2.1）：
## 组件状态由步记录的 actor/phase 派生（派生函数在组件 .gd），
## _refresh_visuals() 每次都从 recorder 的 steps 重算。

const ContainerScript := preload("res://scenes/levels/l3/components/context_container.gd")

## 「另一实例」评分入口（scoring/ 包，与执行侧零共享）。显式 preload 不走
## 全局类名缓存——headless -s 模式不重扫 class cache（评分侧测试同款做法）。
const LevelAssets := preload("res://scripts/levels/level_assets.gd")
const CabinetScript := preload("res://scenes/levels/l3/components/memory_cabinet.gd")

const ASSET_CONTAINER := "conc_context_container"
const ASSET_CABINET := "conc_memory_cabinet"
const ASSET_SCREEN := LevelAssets.ASSET_SCREEN
const ASSET_CODEX := LevelAssets.ASSET_CODEX
const ASSET_REPORT := "l3_report_txt"
const ASSET_OUT := "l3_out_cell"

## report.txt 的正文（世界初始化声明的内容；"错误"恰好出现 3 次）
const REPORT_TEXT := "部署日志 report.txt：\n第 3 行：错误 缺少分号\n第 7 行：错误 越界访问\n第 9 行：错误 重复定义"

const TASK_TEXT_1 := "数 report.txt 的'错误'个数，结果存进记忆柜抽屉 1"
const TASK_TEXT_2 := "开记忆柜取上次数出的错误数，乘 2 写到 out 格"
const TUNE_TASK_TEXT := "把 6 份日志装进上下文容器比对（容量已改小，看裁剪）"
const TUNE_FILES := ["log_1.txt", "log_2.txt", "log_3.txt", "log_4.txt", "log_5.txt", "log_6.txt"]

const MEMORY_KEY := "last_result"
const DEFAULT_CAPACITY := 8
const EPISODE_L3 := 50
const SEED_L3 := 20260915

## 注入优先；为空时在 _ready 解析 autoload（窗口模式），再兜底自建。
## 可视场景（l3_scene.gd），可空。
var container_eid := ""
var cabinet_eid := ""
var screen_eid := ""
var codex_eid := ""
var report_eid := ""
var out_eid := ""

func _init() -> void:
	episode = EPISODE_L3
	default_seed = SEED_L3
# ---------- 世界初始化（工具序列之外，spec §4.5） ----------

func setup_world() -> Dictionary:
	if _world_set_up:
		return {"ok": true, "entityId": codex_eid}
	var st := tools.state()
	st.register_asset(ASSET_CONTAINER, WorldStateCore.KIND_PARAMETRIC,
		{"capacity": DEFAULT_CAPACITY, "files": []}, [
			{"id": "load_in", "kind": "ANALOG", "dir": "in"},
			{"id": "fill_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_CABINET, WorldStateCore.KIND_PARAMETRIC,
		{"drawer1": "", "drawer2": "", "drawer3": ""}, [
			{"id": "note_in", "kind": "ANALOG", "dir": "in"},
			{"id": "note_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_SCREEN, WorldStateCore.KIND_EXHIBIT,
		{"content": "L3·E50 占位视频"}, [])
	st.register_asset(ASSET_CODEX, WorldStateCore.KIND_PARAMETRIC,
		{"display_name": "mini codex"}, [
			{"id": "touched", "kind": "BOOL", "dir": "in"},
		])
	# report.txt（任务输入）与 out 格（任务 2 的交付格）也是世界初始化声明
	st.register_asset(ASSET_REPORT, WorldStateCore.KIND_EXHIBIT,
		{"content": REPORT_TEXT}, [])
	st.register_asset(ASSET_OUT, WorldStateCore.KIND_PARAMETRIC,
		{"label": "out"}, [
			{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	# 以上声明不进步记录（spec §4.5：世界初始化在 run 记录之外）
	var placed: Dictionary = st.place(ASSET_CODEX, [2, 0, 4])
	codex_eid = str(placed.get("entityId", ""))
	var rep: Dictionary = st.place(ASSET_REPORT, [5, 0, 2])
	report_eid = str(rep.get("entityId", ""))
	var outc: Dictionary = st.place(ASSET_OUT, [4, 0, 3])
	out_eid = str(outc.get("entityId", ""))
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
		{"tool": "level.stage", "args": {"stage": "video", "episode": EPISODE_L3, "content": "placeholder"}},
		"幕布亮起：L3 · E50 占位视频（占位内容，不引真视频）")
	return place


## 阶段二：装上上下文容器与记忆柜两件（world.place），并连一条
## note_out -> load_in 的线：记忆取回的内容自动进上下文（隐式记忆的教学点）。
func stage_install() -> Dictionary:
	var c: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_CONTAINER, "pos": [-2, 0, -1]},
		{"actor": "player", "caption": "装上上下文容器（conc_context_container，容量 %d）" % DEFAULT_CAPACITY})
	var m: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_CABINET, "pos": [-4, 0, -1]},
		{"actor": "player", "caption": "装上记忆柜（conc_memory_cabinet，三屉；codex 自己那只）"})
	container_eid = str(c.get("result", {}).get("entityId", ""))
	cabinet_eid = str(m.get("result", {}).get("entityId", ""))
	var w: Dictionary = tools.call_tool(WorldToolsCore.TOOL_CONNECT,
		{"from": cabinet_eid + ":note_out", "to": container_eid + ":load_in"},
		{"actor": "player", "caption": "连线：note_out -> load_in（记忆取回的内容自动进上下文）"})
	if view != null:
		view.install_context_container()
		view.install_memory_cabinet()
		_refresh_visuals()
	_record_level_step("install",
		{"tool": "level.stage", "args": {
			"stage": "install",
			"components": [ASSET_CONTAINER, ASSET_CABINET],
			"ports": ["load_in", "fill_out", "note_in", "note_out"],
		}},
		"两件组件装上：上下文容器 + 记忆柜，绑定表就位")
	return {"container": c, "cabinet": m, "connect": w}


## 阶段三：两次连续任务（spec §9.1.1 过关检查："能看到它把上一次的结果带进这一次"）。
## 任务 1 数错误数写进抽屉 1；任务 2 开柜取上次值乘 2 写 out 格。
## 任务 2 用的值**从 world.read 的返回里来**——上一次的产物经由记忆柜带进这一次。
func stage_run() -> Dictionary:
	var out: Dictionary = {}

	# ---- 任务 1：数 report.txt 的"错误"个数，结果写入记忆柜抽屉 1 ----
	_record_level_step("run",
		{"tool": "level.task", "args": {"task": 1, "text": TASK_TEXT_1}},
		"学员下任务 1：" + TASK_TEXT_1)
	if view != null:
		await view.codex_goto(view.container_front_pos())
	out["read_report"] = tools.call_tool(WorldToolsCore.TOOL_READ,
		{"ref": report_eid},
		{"actor": "codex", "caption": "codex 读 report.txt：读取走工具面，命中内容进上下文"})
	var content := ""
	if bool(out["read_report"].get("ok", false)):
		content = str(out["read_report"]["result"].get("params", {}).get("content", ""))
	var error_count := content.count("错误")
	# report.txt 装进上下文容器（码成一摞）
	out["load"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": container_eid, "key": "files", "value": ["report.txt"]},
		{"actor": "codex", "caption": "report.txt 装进上下文容器，码成一摞（占用 1/%d）" % DEFAULT_CAPACITY})
	# 写记忆柜抽屉 1（显式记忆：一次显式写，跨轮保留）
	out["mem_write"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": cabinet_eid, "key": "drawer1", "value": error_count},
		{"actor": "codex", "caption": "codex 开记忆柜抽屉 1，存入 %s=%d，抽屉合上" % [MEMORY_KEY, error_count]})
	_record_level_step("run",
		{"tool": "memory.write", "args": {
			"drawer": 1, "key": MEMORY_KEY, "value": error_count, "motion": "open_close"}},
		"记忆柜抽屉 1 开合可见：存入 %s=%d（显式记忆，跨轮保留）" % [MEMORY_KEY, error_count])
	if view != null:
		var mc = view.get_memory_cabinet()
		if mc != null:
			mc.anim_seconds = 0.3
			await mc.open_drawer(1)
			mc.set_drawer_note(1, "%s=%d" % [MEMORY_KEY, error_count])
			await mc.close_drawer(1)
		var cc = view.get_context_container()
		if cc != null:
			cc.set_stack_visual(["report.txt"])
			cc.set_occupancy_visual(1, DEFAULT_CAPACITY)
		_refresh_visuals()
	out["run1"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "任务 1 完成：错误数 %d 已写进记忆柜抽屉 1" % error_count})

	# ---- 任务 2：开记忆柜取上次结果，乘 2 写到 out 格 ----
	_record_level_step("run",
		{"tool": "level.task", "args": {"task": 2, "text": TASK_TEXT_2}},
		"学员下任务 2：" + TASK_TEXT_2)
	if view != null:
		await view.codex_goto(view.cabinet_front_pos())
	# 真实读取：值从 world.read 的返回里来，不是魔法变量
	out["mem_read"] = tools.call_tool(WorldToolsCore.TOOL_READ,
		{"ref": cabinet_eid},
		{"actor": "codex", "caption": "codex 开记忆柜读抽屉 1：把上一次的结果取回来"})
	var raw_prev: Variant = null
	if bool(out["mem_read"].get("ok", false)):
		raw_prev = out["mem_read"]["result"].get("params", {}).get("drawer1", null)
	var prev_value := -1
	if raw_prev is int or raw_prev is float:
		prev_value = int(raw_prev)
	if prev_value < 0:
		tools.recorder().record_failure(int(out["mem_read"].get("step", -1)),
			"c10.2:empty_drawer", "empty_drawer",
			"记忆柜抽屉 1 是空的：任务 2 要先有任务 1 的写入（记忆是显式的，不会自动有）")
	_record_level_step("run",
		{"tool": "memory.read", "args": {
			"drawer": 1, "key": MEMORY_KEY, "value": prev_value, "motion": "open_close"}},
		"记忆柜抽屉 1 开合可见：取回 %s=%d（上一次的结果被带进这一次）" % [MEMORY_KEY, prev_value])
	# 记忆进入上下文：note_out 沿连线传 load_in（隐式记忆=上下文自动携带，c10.2 对比点）
	out["note_out"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": cabinet_eid, "key": "@note_out", "value": float(prev_value)},
		{"actor": "codex", "caption": "取回的 %s=%d 沿连线进入上下文容器（隐式记忆自动携带）" % [MEMORY_KEY, prev_value]})
	out["load2"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": container_eid, "key": "files", "value": ["report.txt", "memory:" + MEMORY_KEY]},
		{"actor": "codex", "caption": "上下文码到 2 摞：report.txt + 记忆便签（占用 2/%d）" % DEFAULT_CAPACITY})
	var doubled := prev_value * 2
	out["write_out"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": out_eid, "key": "@out", "value": float(doubled)},
		{"actor": "codex", "caption": "out 格写入 %d×2=%d（读记忆→乘 2→写 out）" % [prev_value, doubled]})
	if view != null:
		var mc2 = view.get_memory_cabinet()
		if mc2 != null:
			await mc2.open_drawer(1)
			await mc2.close_drawer(1)
		var cc2 = view.get_context_container()
		if cc2 != null:
			cc2.set_stack_visual(["report.txt", "memory:" + MEMORY_KEY])
			cc2.set_occupancy_visual(2, DEFAULT_CAPACITY)
		view.set_out_value(doubled)
		_refresh_visuals()
	out["run2"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "任务 2 完成：%d×2=%d 已写到 out 格（写→读→写因果链闭环）" % [prev_value, doubled]})
	if view != null:
		_refresh_visuals()
	return out


## 阶段四：改一个参数——容量上限 8→4，装 6 份日志，看最旧 2 件被裁（裁剪可见）。
func stage_tune() -> Dictionary:
	var out: Dictionary = {}
	out["set_capacity"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": container_eid, "key": "capacity", "value": 4},
		{"actor": "player", "caption": "改一个参数：上下文容量上限 %d→4（窗口预算变小）" % DEFAULT_CAPACITY})
	_record_level_step("tune",
		{"tool": "level.stage", "args": {
			"stage": "tune", "param": "capacity", "from": DEFAULT_CAPACITY, "to": 4}},
		"改参重跑：容量 %d→4，接下来装 6 份日志，看裁剪" % DEFAULT_CAPACITY)
	_record_level_step("tune",
		{"tool": "level.task", "args": {"task": 3, "text": TUNE_TASK_TEXT}},
		"学员下任务 3：" + TUNE_TASK_TEXT)
	if view != null:
		await view.codex_goto(view.container_front_pos())
		var cc3 = view.get_context_container()
		if cc3 != null:
			cc3.set_capacity_visual(4)
	# 读回当前容量（真实读取，不拿本地变量当依据）
	out["read_cap"] = tools.call_tool(WorldToolsCore.TOOL_READ,
		{"ref": container_eid},
		{"actor": "codex", "caption": "codex 读容器参数：确认窗口预算（容量上限）"})
	var capacity_now := DEFAULT_CAPACITY
	if bool(out["read_cap"].get("ok", false)):
		capacity_now = int(out["read_cap"]["result"].get("params", {}).get("capacity", DEFAULT_CAPACITY))
	# 6 份日志一次装入（超过容量上限）
	out["load6"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": container_eid, "key": "files", "value": TUNE_FILES},
		{"actor": "codex", "caption": "6 份日志装进容器：6 > 容量 %d，超了" % capacity_now})
	if view != null:
		var cc4 = view.get_context_container()
		if cc4 != null:
			cc4.set_stack_visual(TUNE_FILES)
			cc4.set_occupancy_visual(TUNE_FILES.size(), capacity_now)
		_refresh_visuals()
	# 窗口预算裁剪：留最新 capacity_now 件，最旧的被裁掉
	var kept: Array = TUNE_FILES.slice(TUNE_FILES.size() - capacity_now)
	var removed: Array = TUNE_FILES.slice(0, TUNE_FILES.size() - capacity_now)
	out["trim"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": container_eid, "key": "files", "value": kept},
		{"actor": "codex", "caption": "按窗口预算裁剪：最旧的 %d 件（%s）被裁掉" % [removed.size(), "、".join(PackedStringArray(removed))]})
	_record_level_step("tune",
		{"tool": "context.trim", "args": {
			"capacity": capacity_now, "removed": removed, "kept": kept, "visible": true}},
		"裁剪可见：被裁的方块淡出下沉（超限的旧内容离开上下文）")
	if view != null:
		var cc5 = view.get_context_container()
		if cc5 != null:
			cc5.set_stack_visual(kept)
			cc5.set_occupancy_visual(kept.size(), capacity_now)
			cc5.play_trim(removed)
		_refresh_visuals()
	out["run"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "小容量下重跑：上下文里只看得到最近 %d 件" % capacity_now})
	if view != null:
		_refresh_visuals()
	return out


## 阶段五：评分——交给「另一实例」ScorerService（scoring/ 包，与执行侧零共享）：
## 输入是冻结前的 run 文档 + 本关 task_goal（goals.gd 纯数据，不从本类取状态）；
## LLM 通道不可用时自动回退规则评分（rule_v1）。五句与 evidence 落进 score 步的
## output（args.dimensions 保持旧形状兼容：[{dim, sentence}×5]）。
func stage_score() -> Dictionary:
	var rc := tools.recorder()
	var verdict: Dictionary = ScorerServiceScript.new().score(rc.get_doc(), ScorerGoalsScript.goal_for("L3"))
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

## 判定"能看到它把上一次的结果带进这一次"（spec §9.1.1 L3 行）：
##   ① 存在 memory.write（任务 1）与其后的 memory.read（任务 2），两步 value
##     相等——写→读因果链可从记录复盘，且 out 格被写为 read 值 ×2；
##   ② tune 段存在 context.trim 步且 removed 非空（裁剪可见）。
func check_pass() -> Dictionary:
	var rc := tools.recorder()
	if rc.state_name() != "frozen":
		return {"pass": false, "reason": "not_frozen", "runId": rc.run_id()}
	var doc: Dictionary = JSON.parse_string(rc.frozen_text())
	var steps: Array = doc.get("steps", [])
	var write_i := -1
	var write_value := -1
	var read_i := -1
	var read_value := -1
	for i in steps.size():
		var step: Dictionary = steps[i]
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		var args: Dictionary = action.get("args", {})
		if tool == "memory.write":
			write_i = i
			write_value = int(args.get("value", -1))
		elif tool == "memory.read":
			read_i = i
			read_value = int(args.get("value", -1))
	var memory_chain := write_i >= 0 and read_i > write_i and read_value == write_value and write_value > 0
	# out 格写入值 = read 值 ×2（读记忆→乘 2→写 out 的闭环）
	var out_written := -1
	for step in steps:
		var s: Dictionary = step
		var action: Dictionary = s.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == out_eid and str(args.get("key", "")) == "@out":
				out_written = int(float(args.get("value", -1)))
	var out_ok := out_written == read_value * 2 and out_written > 0
	# tune 段的裁剪步（被裁件非空 = 裁剪可见的记录面）
	var trimmed := false
	var removed_count := 0
	for step in steps:
		var s: Dictionary = step
		if str(s.get("phase", "")) == "tune" and str(s.get("action", {}).get("tool", "")) == "context.trim":
			var args: Dictionary = s["action"].get("args", {})
			var removed: Variant = args.get("removed", [])
			if removed is Array and not (removed as Array).is_empty():
				trimmed = true
				removed_count = (removed as Array).size()
	# 容量确实改过（tune 参数面）
	var capacity_changed := false
	var capacity_to := -1
	for step in steps:
		var s: Dictionary = step
		var action: Dictionary = s.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == container_eid and str(args.get("key", "")) == "capacity":
				capacity_changed = true
				capacity_to = int(args.get("value", -1))
	return {
		"pass": memory_chain and out_ok and trimmed,
		"memoryChain": memory_chain,
		"writeValue": write_value,
		"readValue": read_value,
		"outWritten": out_ok,
		"outValue": out_written,
		"trimFound": trimmed,
		"removedCount": removed_count,
		"capacityChanged": capacity_changed,
		"capacityTo": capacity_to,
		"runId": rc.run_id(),
		"path": rc.out_path(),
		"steps": steps.size(),
	}


# ---------- 内部 ----------

## 关卡自身的阶段步（video/install/tune/score 这些 kernel 没有的 phase，
## 以及 memory.write / memory.read / context.trim 这些组件动作步），
## 与工具步走同一条记录通道（参照 report_physics_event 的做法）。
## output 参数默认 {"ok": true}；score 步把评分器的五句与证据放进来。
## 组件状态永远从步记录重算（mini-codex §2.1：不另做状态机）。
func _refresh_visuals() -> void:
	if view == null:
		return
	var steps := tools.recorder().get_steps()
	var cc = view.get_context_container()
	if cc != null:
		cc.set_state_visual(ContainerScript.derive_state_from_steps(steps, container_eid))
	var mc = view.get_memory_cabinet()
	if mc != null:
		mc.set_state_visual(CabinetScript.derive_state_from_steps(steps, cabinet_eid))
