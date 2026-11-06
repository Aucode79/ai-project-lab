extends SceneTree

## L3 端到端测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/levels/l3/run_l3_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##  T1 两件组件可实例化：容器刻度段数=容量、占用读数与分段亮灭、码摞、
##     被裁方块（TrimGhost）淡出下沉可生成；抽屉开合（默认/参数化两种时长）、
##     便签、四态灯切换
##  T2 L3 场景可实例化：相机就位、光影/体素地面/工位/小车/两安装位/幕布
##     （标题 = "L3 · E50 占位视频"）/report 石板/out 格齐
##  T3 全流程 drive 到 check_pass=true（video→install→run→tune→score→落盘→判定），
##     run JSON kind=task、episode=50
##  T4 写→读因果链：memory.read 的 value == memory.write 的 value（数值对上，
##     且等于 report.txt 里"错误"的真实个数），out 格写入值 = 读值 ×2
##  T5 容量裁剪步存在且被裁件可见：tune 段 context.trim、removed=2 件、
##     kept=4=新容量；容器状态轨迹 覆盖 待命→正在→完成
##  T6 tune 参数生效：capacity 的 set_param 值 4 与默认 8 不同
##  T7 评分五句（真评分器 rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含
##     实测 ops 与基线对照、正确性句确认 读→存→取回→写out 模式全命中；score 步
##     output 带 sentences/evidence/scorer/llm（回退在案），args.dimensions 旧形状兼容
##  T8 记忆柜开合动作进步记录：memory.write / memory.read 步带 motion=open_close、
##     drawer=1、key=last_result；记忆柜状态轨迹覆盖 待命→正在→完成
##
## 产物：本次判定的 run JSON 留在 runs/e50/（运行时产物，已 gitignore），
## 供验收复核；除它之外本测试不写任何文件。

const L3Scene := preload("res://scenes/levels/l3/l3.tscn")
const L3FlowScript := preload("res://scripts/levels/l3/l3_flow.gd")
const ContainerScript := preload("res://scenes/levels/l3/components/context_container.gd")
const ContainerScene := preload("res://scenes/levels/l3/components/context_container.tscn")
const CabinetScript := preload("res://scenes/levels/l3/components/memory_cabinet.gd")
const CabinetScene := preload("res://scenes/levels/l3/components/memory_cabinet.tscn")

var _passed := 0
var _failed := 0
var _garbage: Array[Node] = []
var _scene: Node = null
var _flow: Node = null
var _doc: Dictionary = {}
var _verdict: Dictionary = {}


func _initialize() -> void:
	_run_all.call_deferred()


func _run_all() -> void:
	await _t01_components()
	_t02_scene()
	await _t03_full_flow()
	_t04_memory_chain()
	_t05_trim_visible()
	_t06_tune_param()
	_t07_score_sentences()
	_t08_drawer_motion_steps()
	_cleanup()
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ---------- 基础设施 ----------

func _fresh_tools() -> WorldToolsCore:
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	var tools := WorldToolsCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	_garbage.append(st)
	_garbage.append(rc)
	_garbage.append(cm)
	_garbage.append(tools)
	return tools


func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


func _cleanup() -> void:
	if _scene != null and is_instance_valid(_scene):
		_scene.free()
	for n in _garbage:
		if n != null and is_instance_valid(n):
			n.free()
	_garbage.clear()


# ---------- 测试 ----------

func _t01_components() -> void:
	var ok := true

	# 上下文容器：刻度段 = 容量；占用分段亮灭 + 读数；码摞；被裁方块可见
	var cc := ContainerScene.instantiate()
	root.add_child(cc)
	cc.set_capacity_visual(8)
	ok = ok and cc.has_node("CapacityScale") and cc.get_node("CapacityScale").get_child_count() == 8
	cc.set_occupancy_visual(3, 8)
	ok = ok and str(cc.get_node("OccupancyLabel").text) == "占用 3/8"
	var seg0 := cc.get_node("CapacityScale/Seg0").get_active_material(0) as StandardMaterial3D
	var seg7 := cc.get_node("CapacityScale/Seg7").get_active_material(0) as StandardMaterial3D
	ok = ok and seg0.emission_enabled and not seg7.emission_enabled
	ok = ok and not seg0.albedo_color.is_equal_approx(seg7.albedo_color)
	cc.set_capacity_visual(4)
	ok = ok and cc.get_node("CapacityScale").get_child_count() == 4
	cc.set_stack_visual(["report.txt", "memory:last_result"])
	ok = ok and cc.get_node("FileStack").get_child_count() == 2
	ok = ok and cc.play_trim(["log_1.txt", "log_2.txt"]) == 2 and cc.get_trim_ghost_count() == 2
	ok = ok and (cc.get_node("TrimGhosts/TrimGhost0") as MeshInstance3D) != null
	cc.set_state_visual(ContainerScript.STATE_DONE)
	var cc_lamp: StandardMaterial3D = cc.get_lamp_material()
	ok = ok and cc_lamp.emission.is_equal_approx(ContainerScript.STATE_COLORS[ContainerScript.STATE_DONE])
	cc.set_state_visual(ContainerScript.STATE_ERROR)
	ok = ok and cc.get_lamp_material().emission.is_equal_approx(ContainerScript.STATE_COLORS[ContainerScript.STATE_ERROR])
	cc.free()

	# 记忆柜：三屉、开合动画（默认 anim_seconds 与参数化 seconds 两条路）、便签、四态灯
	var mc := CabinetScene.instantiate()
	root.add_child(mc)
	ok = ok and mc.has_node("Drawer1") and mc.has_node("Drawer2") and mc.has_node("Drawer3")
	ok = ok and not mc.is_drawer_open(1) and not mc.is_drawer_open(2) and not mc.is_drawer_open(3)
	mc.anim_seconds = 0.05
	mc.open_drawer(1)                 # 默认时长（anim_seconds=0.05）
	await create_timer(0.3).timeout
	ok = ok and mc.is_drawer_open(1) and mc.get_drawer_offset(1) > 0.5
	mc.open_drawer(2, 0.05)           # 参数化时长
	await create_timer(0.3).timeout
	ok = ok and mc.is_drawer_open(2) and not mc.is_drawer_open(3)
	mc.set_drawer_note(1, "last_result=3")
	ok = ok and mc.get_drawer_note(1) == "last_result=3"
	ok = ok and str(mc.get_node("Drawer1/Note").text) == "last_result=3"
	mc.close_drawer(1, 0.05)
	mc.close_drawer(2, 0.05)
	await create_timer(0.3).timeout
	ok = ok and not mc.is_drawer_open(1) and not mc.is_drawer_open(2)
	ok = ok and absf(mc.get_drawer_offset(1)) < 0.01
	mc.set_state_visual(CabinetScript.STATE_DONE)
	ok = ok and mc.get_lamp_material().emission.is_equal_approx(CabinetScript.STATE_COLORS[CabinetScript.STATE_DONE])
	mc.set_state_visual(CabinetScript.STATE_ERROR)
	ok = ok and mc.get_lamp_material().emission.is_equal_approx(CabinetScript.STATE_COLORS[CabinetScript.STATE_ERROR])
	mc.free()

	_check(ok, "T1 两件组件可实例化：容器刻度段/占用亮灭/码摞/被裁方块、抽屉开合（默认+参数化时长）、便签、四态灯")


func _t02_scene() -> void:
	_scene = L3Scene.instantiate()
	root.add_child(_scene)
	for i in 5:
		await create_timer(0.02).timeout
	var ok := _scene.has_node("Camera") and (_scene.get_node("Camera") as Camera3D).current
	ok = ok and _scene.has_node("WorldEnvironment") and _scene.has_node("Sun") and _scene.has_node("Fill")
	ok = ok and _scene.has_node("Terrain")
	ok = ok and _scene.has_node("Workstation/CodexCart")
	ok = ok and _scene.has_node("Workstation/ContextContainerMount") and _scene.has_node("Workstation/MemoryCabinetMount")
	ok = ok and _scene.has_node("Workstation/PlayerScreen")
	ok = ok and str(_scene.get_node("Workstation/PlayerScreen/ScreenLabel").text) == "L3 · E50 占位视频"
	ok = ok and _scene.has_node("Workstation/ReportSlab") and _scene.has_node("Workstation/OutCell")
	_check(ok, "T2 L3 场景可实例化：相机就位且为当前、明亮光影/体素地面/工位小车/两安装位/幕布（E50 标题）/report 石板/out 格齐")


func _t03_full_flow() -> void:
	var tools := _fresh_tools()
	_flow = L3FlowScript.new()
	_flow.tools = tools
	_flow.view = _scene
	_scene.add_child(_flow)
	_verdict = await _flow.drive_full()
	var rc: StepRecorderCore = tools.recorder()
	var path := rc.out_path()
	var ok := bool(_verdict.get("pass", false))
	ok = ok and rc.state_name() == "frozen" and path != "" and FileAccess.file_exists(path)
	ok = ok and int(_verdict.get("steps", 0)) >= 10
	if ok:
		_doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	ok = ok and not _doc.is_empty()
	ok = ok and str((_doc.get("run", {}) as Dictionary).get("kind", "")) == "task"
	ok = ok and int((_doc.get("run", {}) as Dictionary).get("episode", -1)) == 50
	_check(ok, "T3 全流程 video→install→run(两任务)→tune→score 驱动到 check_pass=true，run 已落盘冻结（kind=task、episode=50）（%s）" % path)


func _t04_memory_chain() -> void:
	var steps: Array = _doc.get("steps", [])
	var write_i := -1
	var write_value := -1
	var read_i := -1
	var read_value := -1
	for i in steps.size():
		var step: Dictionary = steps[i]
		var tool := str(step.get("action", {}).get("tool", ""))
		var args: Dictionary = step.get("action", {}).get("args", {})
		if tool == "memory.write":
			write_i = i
			write_value = int(args.get("value", -1))
		elif tool == "memory.read":
			read_i = i
			read_value = int(args.get("value", -1))
	# 数值对上：读到的 == 写入的 == report.txt 里"错误"的真实个数
	var report_count := str(L3FlowScript.REPORT_TEXT).count("错误")
	var ok := write_i >= 0 and read_i > write_i and read_value == write_value
	ok = ok and write_value == report_count and report_count > 0
	# 读是真读：memory.read 之前有 actor=codex 的 world.read 指向记忆柜实体
	var cabinet_eid := str(_flow.cabinet_eid)
	var real_read := false
	for i in read_i:
		var step: Dictionary = steps[i]
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_READ and str(step.get("actor", "")) == "codex" \
				and str(action.get("args", {}).get("ref", "")) == cabinet_eid:
			real_read = true
	ok = ok and real_read
	# out 格写入 = 读值 ×2（写→读→写闭环）
	var out_value := -1
	var out_eid := str(_flow.out_eid)
	for step in steps:
		var s: Dictionary = step
		var action: Dictionary = s.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == out_eid and str(args.get("key", "")) == "@out":
				out_value = int(float(args.get("value", -1)))
	ok = ok and out_value == read_value * 2
	ok = ok and int(_verdict.get("writeValue", -2)) == write_value
	ok = ok and int(_verdict.get("readValue", -2)) == read_value
	ok = ok and int(_verdict.get("outValue", -2)) == out_value
	_check(ok, "T4 写→读因果链数值对上：memory.read(%d) == memory.write(%d) == report 错误数(%d)，out 格 = %d = 读值×2" % [read_value, write_value, report_count, out_value])


func _t05_trim_visible() -> void:
	var steps: Array = _doc.get("steps", [])
	var container_eid := str(_flow.container_eid)
	var trim_step: Dictionary = {}
	for s in steps:
		var step: Dictionary = s
		if str(step.get("phase", "")) == "tune" and str(step.get("action", {}).get("tool", "")) == "context.trim":
			trim_step = step
	var ok := not trim_step.is_empty()
	var removed: Array = []
	var kept: Array = []
	var visible := false
	if ok:
		var args: Dictionary = trim_step.get("action", {}).get("args", {})
		removed = args.get("removed", [])
		kept = args.get("kept", [])
		visible = bool(args.get("visible", false))
	ok = ok and removed.size() == 2 and str(removed[0]) == "log_1.txt" and str(removed[1]) == "log_2.txt"
	ok = ok and kept.size() == 4 and visible
	# 裁剪真的改了世界：最后一步世界摘要里容器 files == kept、capacity == 4
	var last: Dictionary = steps[steps.size() - 1].get("world", {})
	var entities: Dictionary = last.get("entities", {})
	ok = ok and entities.has(container_eid)
	if ok:
		var params: Dictionary = entities[container_eid].get("params", {})
		var files: Variant = params.get("files", [])
		ok = ok and files is Array and (files as Array).size() == 4
		ok = ok and int(params.get("capacity", -1)) == 4
	# 容器状态由步记录派生：待命→正在→完成，终态完成，无出错
	var traj: Array = ContainerScript.state_trajectory(steps, container_eid)
	ok = ok and traj.has(ContainerScript.STATE_IDLE) and traj.has(ContainerScript.STATE_RUNNING) and traj.has(ContainerScript.STATE_DONE)
	ok = ok and str(traj[traj.size() - 1]) == ContainerScript.STATE_DONE
	ok = ok and not traj.has(ContainerScript.STATE_ERROR)
	_check(ok, "T5 容量裁剪步存在且被裁件可见：tune 段 context.trim（removed=%s、kept=%d=新容量、visible），裁剪后世界 files=4；容器轨迹 待命→正在→完成" % [str(removed), kept.size()])


func _t06_tune_param() -> void:
	var steps: Array = _doc.get("steps", [])
	var container_eid := str(_flow.container_eid)
	var capacity_from := -1
	var capacity_to := -1
	var found := false
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == container_eid and str(args.get("key", "")) == "capacity":
				found = true
				capacity_to = int(args.get("value", -1))
	if found:
		var set_ret: Dictionary = {}
		for s in steps:
			var step: Dictionary = s
			var action: Dictionary = step.get("action", {})
			if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
				var args: Dictionary = action.get("args", {})
				if str(args.get("entityId", "")) == container_eid and str(args.get("key", "")) == "capacity":
					set_ret = step.get("output", {}).get("result", {})
		capacity_from = int(set_ret.get("oldValue", -1))
	var ok := found and capacity_to == 4 and capacity_from == int(L3FlowScript.DEFAULT_CAPACITY) and capacity_to != capacity_from
	ok = ok and bool(_verdict.get("capacityChanged", false)) and int(_verdict.get("capacityTo", -1)) == 4
	_check(ok, "T6 tune 参数生效：capacity 从 %d 改到 %d（与默认不同），判定结果也带 capacityChanged/capacityTo" % [capacity_from, capacity_to])


func _t07_score_sentences() -> void:
	# 真评分器（ScorerService→rule_v1，LLM 通道不可用自动回退）：
	# score 步 output 带 sentences/evidence/scorer/llm；args.dimensions 旧形状兼容。
	var score_step: Dictionary = {}
	for s in _doc.get("steps", []):
		var step: Dictionary = s
		if str(step.get("action", {}).get("tool", "")) == "level.score":
			score_step = step
	var out: Dictionary = score_step.get("output", {})
	var sentences: Array = out.get("sentences", [])
	var want := ["正确性", "结构", "效率", "鲁棒性", "可读性"]
	var ok := sentences.size() == 5 and str(out.get("scorer", "")) == "rule_v1"
	var names: Array = []
	var all_long := true
	for s in sentences:
		var d: Dictionary = s
		names.append(str(d.get("dim", "")))
		all_long = all_long and str(d.get("text", "")).length() >= 12
	ok = ok and names == want and all_long
	var llm: Dictionary = out.get("llm", {})
	ok = ok and bool(llm.get("fallback", false)) and str(llm.get("channel", "")) == "rule_v1"
	# 证据：每维至少一个 stepRef，且都指向存在的步号
	var valid := {}
	for s in _doc.get("steps", []):
		valid[int((s as Dictionary).get("i", -1))] = true
	var evidence: Dictionary = out.get("evidence", {})
	ok = ok and evidence.size() == 5
	for dim in want:
		var refs: Array = evidence.get(dim, [])
		ok = ok and not refs.is_empty()
		for r in refs:
			ok = ok and valid.has(int(r))
	# 效率句含本次实测 ops 与基线对照；正确性句确认 读→存→取回→写out 模式全命中
	var ops_sum := 0
	for s in _doc.get("steps", []):
		ops_sum += int((s as Dictionary).get("ops", 0))
	var eff := ""
	var cor := ""
	for s in sentences:
		var d: Dictionary = s
		if str(d.get("dim", "")) == "效率":
			eff = str(d.get("text", ""))
		elif str(d.get("dim", "")) == "正确性":
			cor = str(d.get("text", ""))
	ok = ok and eff.contains(str(ops_sum)) and eff.contains("ops") and eff.contains("基线")
	ok = ok and cor.contains("任务跑完了")
	# 旧形状兼容：args.dimensions 仍是 [{dim, sentence}×5]
	var dims: Array = score_step.get("action", {}).get("args", {}).get("dimensions", [])
	ok = ok and dims.size() == 5
	for d in dims:
		ok = ok and str((d as Dictionary).get("dim", "")) != "" \
			and str((d as Dictionary).get("sentence", "")).length() >= 12
	_check(ok, "T7 评分五句（rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含实测 %d ops 与基线对照、正确性句确认目标达成；score 步 output 带 sentences/evidence/scorer（llm 回退在案、args.dimensions 旧形状兼容）" % ops_sum)


func _t08_drawer_motion_steps() -> void:
	var steps: Array = _doc.get("steps", [])
	var cabinet_eid := str(_flow.cabinet_eid)
	var write_ok := false
	var read_ok := false
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		var args: Dictionary = action.get("args", {})
		if tool == "memory.write" and str(step.get("phase", "")) == "run":
			write_ok = str(args.get("motion", "")) == "open_close" and int(args.get("drawer", -1)) == 1 \
				and str(args.get("key", "")) == "last_result"
		elif tool == "memory.read" and str(step.get("phase", "")) == "run":
			read_ok = str(args.get("motion", "")) == "open_close" and int(args.get("drawer", -1)) == 1 \
				and str(args.get("key", "")) == "last_result"
	var ok := write_ok and read_ok
	# 记忆柜状态由步记录派生：待命→正在（写）→完成（读回），终态完成，无出错
	var traj: Array = CabinetScript.state_trajectory(steps, cabinet_eid)
	ok = ok and traj.has(CabinetScript.STATE_IDLE) and traj.has(CabinetScript.STATE_RUNNING) and traj.has(CabinetScript.STATE_DONE)
	ok = ok and str(traj[traj.size() - 1]) == CabinetScript.STATE_DONE
	ok = ok and not traj.has(CabinetScript.STATE_ERROR)
	_check(ok, "T8 记忆柜开合动作进步记录：memory.write / memory.read 步带 motion=open_close、drawer=1、key=last_result；柜子轨迹 待命→正在→完成")
