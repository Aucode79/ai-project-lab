extends SceneTree

## 求助系统测试（docs/10-契约/交互方案.md §五 / §5.1）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/help/run_help_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##  T1  fail_counter：2 次不解锁 3 次解锁、按关卡隔离（L2 失败不影响 L1）、阈值参数化生效
##  T2  hint_service：三级递进顺序（1→2→3→封顶 3）、第 2 级文案来自 concepts.yaml
##      的 fail 条目真值（抽 c10.1：condition 与 symptom 原文）、第 3 级发 request_demo 信号
##  T3  对话不进 task 步记录（注入内核跑完整 L1 流程，中途问三次，步记录无 help 痕迹
##      且 check_pass=true）
##  T4  help 轻量日志落盘 runs/help/{level}.json，条目含时间与级别
##  T5  锚点气泡：设目标先贴到目标上方、目标移动后两帧内位置跟随、最终收敛、可隐藏
##  T6  求助屏未解锁时的拒绝文案；太远不答；感应进入/离开（顶灯亮/灭）
##  T7  "问什么不影响判定"：同一流程问与不问，check_pass 结果与步记录完全一致
##  T8  接入示例：走到屏前（感应触发）→ 三次失败 → 依次问三次 → 屏上三级内容递进，
##      气泡 1/2 级指问题组件（2 级含 concepts.yaml 原文）、3 级指任务牌，L1 发变红回调
##
## 产物：runs/help*/ 下的 help 日志与两条 e2e run JSON（运行时产物，已 gitignore）。

const HelpScreenScene := preload("res://scenes/blocks/help_screen.tscn")
const TaskBoardScene := preload("res://scenes/levels/l1/components/task_board.tscn")
const FailCounterScript := preload("res://scripts/help/fail_counter.gd")
const HintServiceScript := preload("res://scripts/help/hint_service.gd")
const ConceptReaderScript := preload("res://scripts/help/concept_reader.gd")
const AnchorBubbleScript := preload("res://scripts/help/anchor_bubble.gd")
const L1FlowScript := preload("res://scripts/levels/l1/l1_flow.gd")

## concepts.yaml c10.1:1 的 fail 原文（数据源真值，yaml 改了这里就该红）
const C101_FAIL1_CONDITION := "步记录里没有任何针对本任务牌成功的 set_param(task_text)，任务牌却显示「完成」"
const C101_FAIL1_SYMPTOM := "状态灯跳过「正在」直接变绿，步记录缺 set_param 步"

var _passed := 0
var _failed := 0
var _garbage: Array[Node] = []


func _initialize() -> void:
	_run_all.call_deferred()


func _run_all() -> void:
	_t01_fail_counter()
	_t02_hint_service()
	var with_help: Dictionary = await _drive_flow(true)
	var baseline: Dictionary = await _drive_flow(false)
	_t03_dialog_not_in_task_run(with_help)
	_t04_help_log(with_help)
	await _t05_anchor_bubble()
	_t06_screen_reject_and_sense()
	_t07_asking_does_not_change_verdict(with_help, baseline)
	_t08_integration_scene()
	_cleanup()
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ---------- 基础设施 ----------

func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


func _cleanup() -> void:
	for n in _garbage:
		if n != null and is_instance_valid(n):
			n.free()
	_garbage.clear()


func _adopt(n: Node) -> void:
	root.add_child(n)
	_garbage.append(n)


## 注入内核驱动 L1 全流程；with_help=true 时在 run 阶段后经求助屏问三次。
func _drive_flow(with_help: bool) -> Dictionary:
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

	var flow := L1FlowScript.new()
	flow.tools = tools
	_adopt(flow)
	flow.setup_world()
	flow.begin()
	await flow.stage_video()
	await flow.stage_install()
	await flow.stage_run()

	var ask_texts: Array = []
	if with_help:
		var screen := HelpScreenScene.instantiate()
		screen.level_id = "t_flow"
		screen.concept_map = {"t_flow": "c10.1"}
		_adopt(screen)
		var comp := Node3D.new()
		comp.name = "FlowProblemComp"
		_adopt(comp)
		screen.set_problem_component(comp)
		for i in 3:
			screen.report_fail()
		for i in 3:
			ask_texts.append(str(screen.ask("卡住了，第 %d 次问" % (i + 1)).get("text", "")))

	await flow.stage_tune()
	flow.stage_score()
	var out_root := "res://runs/help_e2e/" + ("with" if with_help else "without")
	var fin: Dictionary = flow.finish_run(out_root)
	var verdict: Dictionary = flow.check_pass()
	return {
		"pass": bool(verdict.get("pass", false)),
		"frozen": rc.state_name() == "frozen" and bool(fin.get("ok", false)),
		"steps": rc.get_steps(),
		"ask_texts": ask_texts,
	}


## 步记录里有没有 help 痕迹（对话绝不进 task 运行的步记录，交互方案 §5.1）。
func _steps_have_help_trace(steps: Array) -> bool:
	for s in steps:
		var step: Dictionary = s
		var tool := str(step.get("action", {}).get("tool", ""))
		if tool.begins_with("help.") or tool == "help.ask" or str(step.get("phase", "")) == "help":
			return true
	return false


## 只比 phase/actor/action（t 与 costMs 本来就每次不同）。
func _steps_signature(steps: Array) -> String:
	var triples := []
	for s in steps:
		var step: Dictionary = s
		triples.append({
			"phase": str(step.get("phase", "")),
			"actor": str(step.get("actor", "")),
			"action": step.get("action", {}),
		})
	return JSON.stringify(triples)


# ---------- T1 fail_counter ----------

func _t01_fail_counter() -> void:
	var fc = FailCounterScript.new()
	fc.count_fail("L1")
	fc.count_fail("L1")
	var ok: bool = fc.fails("L1") == 2 and not fc.unlocked("L1")
	fc.count_fail("L1")
	ok = ok and fc.fails("L1") == 3 and fc.unlocked("L1")

	# 按关卡计：L2 的失败不影响 L1 的计数与解锁
	for i in 5:
		fc.count_fail("L2")
	ok = ok and fc.unlocked("L2") and fc.fails("L1") == 3

	# 阈值参数化：threshold=2 时两次即解锁；reset 归零
	var fc2 = FailCounterScript.new()
	fc2.threshold = 2
	fc2.count_fail("X")
	ok = ok and not fc2.unlocked("X")
	fc2.count_fail("X")
	ok = ok and fc2.unlocked("X")
	fc2.reset("X")
	ok = ok and not fc2.unlocked("X")

	_check(ok, "T1 fail_counter：2 次不解锁 3 次解锁、按关卡隔离（L2 失败不影响 L1）、阈值参数化与 reset 生效")


# ---------- T2 hint_service ----------

func _t02_hint_service() -> void:
	var reader := ConceptReaderScript.new()
	var concepts := reader.load_concepts()
	var loaded: bool = concepts.has("c10.1") \
		and (concepts["c10.1"] as Dictionary).get("label", "") == "十-智能体身份与角色（profile）设置" \
		and (concepts["c10.1"] as Dictionary).get("fail", []).size() == 2

	var fc = FailCounterScript.new()
	var hs = HintServiceScript.new()
	hs.fail_counter = fc
	hs.concept_map = {"t_c101": "c10.1"}
	hs.concepts = concepts
	hs.problem_names = {"t_c101": "任务牌"}

	# 未达阈值：只回鼓励语，不给内容
	fc.count_fail("t_c101")
	fc.count_fail("t_c101")
	var early: Dictionary = hs.ask("t_c101", "帮帮我")
	var ok: bool = str(early.get("kind", "")) == "rejected" \
		and str(early.get("text", "")).contains("再试一次，你已经很接近了")

	# 达阈值：三级递进，第 4 问封顶在 3
	fc.count_fail("t_c101")
	var demos: Array = []
	hs.request_demo.connect(func(l: String): demos.append(l))
	var h1: Dictionary = hs.ask("t_c101", "哪里不对")
	var h2: Dictionary = hs.ask("t_c101", "为什么")
	var h3: Dictionary = hs.ask("t_c101", "做给我看")
	var h4: Dictionary = hs.ask("t_c101", "再做一遍")
	ok = ok and int(h1.get("level", 0)) == 1 and str(h1.get("anchor", "")) == "problem" \
		and int(h2.get("level", 0)) == 2 and str(h2.get("anchor", "")) == "fail" \
		and int(h3.get("level", 0)) == 3 and str(h3.get("anchor", "")) == "task" \
		and int(h4.get("level", 0)) == 3
	ok = ok and bool(h1.get("highlight", false)) and str(h1.get("component", "")) == "任务牌"

	# L2 文案 = concepts.yaml 的 fail 条目原文（唯一数据源）
	var h2_text := str(h2.get("text", ""))
	ok = ok and h2_text.contains(C101_FAIL1_CONDITION) and h2_text.contains(C101_FAIL1_SYMPTOM) \
		and h2_text.contains("c10.1:1") and h2_text.contains("c10.1:2")
	var fails: Array = h2.get("fails", [])
	ok = ok and fails.size() == 2 \
		and str((fails[0] as Dictionary).get("condition", "")) == C101_FAIL1_CONDITION \
		and str((fails[0] as Dictionary).get("symptom", "")) == C101_FAIL1_SYMPTOM

	# L3 只发信号（代做执行后续接 sidecar）；封顶后重复问仍发
	ok = ok and str(h3.get("text", "")).contains("代做不参与判定") and bool(h3.get("demo", false))
	ok = ok and demos == ["t_c101", "t_c101"]

	# 进度按关卡隔离：另一关从 L1 重新开始
	ok = ok and hs.hint_level("t_c101") == 3 and hs.hint_level("other") == 0

	_check(loaded and ok,
		"T2 hint_service：三级递进 1→2→3 封顶、L2 文案含 concepts.yaml c10.1 fail 原文（condition+symptom）、L3 发 request_demo（封顶后重复问仍发）")


# ---------- T3 对话不进 task 步记录 ----------

func _t03_dialog_not_in_task_run(with_help: Dictionary) -> void:
	var steps: Array = with_help.get("steps", [])
	var asked: Array = with_help.get("ask_texts", [])
	var ok: bool = bool(with_help.get("pass", false)) and bool(with_help.get("frozen", false))
	ok = ok and asked.size() == 3 and str(asked[0]).contains("现象") \
		and str(asked[1]).contains("诊断") and str(asked[2]).contains("代做")
	ok = ok and not steps.is_empty() and not _steps_have_help_trace(steps)
	_check(ok, "T3 对话不进 task 步记录：注入内核跑完整 L1 流程、中途经求助屏问三次（三次文案齐），步记录无任何 help 痕迹且 check_pass=true")


# ---------- T4 help 日志 ----------

func _t04_help_log(with_help: Dictionary) -> void:
	var path := "res://runs/help/t_flow.json"
	var ok: bool = FileAccess.file_exists(path)
	var doc = {}
	if ok:
		doc = JSON.parse_string(FileAccess.get_file_as_string(path))
		ok = doc is Dictionary
	var entries: Array = (doc.get("entries", []) if doc is Dictionary else []) as Array
	ok = ok and entries.size() >= 3
	var last3_hint_levels := []
	var last3_have_time := true
	for i in range(maxi(0, entries.size() - 3), entries.size()):
		var e: Dictionary = entries[i]
		last3_hint_levels.append(int(e.get("hintLevel", -1)))
		var at := str(e.get("at", ""))
		last3_have_time = last3_have_time and at.contains("T") and at.ends_with("Z") \
			and float(e.get("unix", 0.0)) > 0.0
	ok = ok and last3_hint_levels == [1, 2, 3] and last3_have_time
	ok = ok and str((entries[entries.size() - 1] as Dictionary).get("levelId", "")) == "t_flow"
	ok = ok and str((entries[entries.size() - 3] as Dictionary).get("question", "")).contains("第 1 次问")
	_check(ok, "T4 help 日志落盘 runs/help/t_flow.json：条目含时间（ISO at + unix）与级别（hintLevel 1/2/3、levelId、问题原文）")


# ---------- T5 锚点气泡 ----------

func _t05_anchor_bubble() -> void:
	var target := Node3D.new()
	target.name = "BubbleTarget"
	target.position = Vector3(0.0, 1.0, 0.0)
	_adopt(target)
	var bubble := AnchorBubbleScript.new()
	bubble.name = "AnchorBubble"
	_adopt(bubble)
	await process_frame   # 让 _ready 跑完（top_level 生效）

	bubble.set_target(target, "测试气泡")
	var goal := target.global_position + Vector3(0.0, bubble.FOLLOW_HEIGHT, 0.0)
	var ok: bool = bubble.visible and bubble.global_position.distance_to(goal) < 0.001

	# 目标瞬移后：两帧内位置已开始跟随（弹簧，固定步长）
	target.global_position = Vector3(10.0, 1.0, 0.0)
	goal = target.global_position + Vector3(0.0, bubble.FOLLOW_HEIGHT, 0.0)
	var d0 := bubble.global_position.distance_to(goal)
	await process_frame
	await process_frame
	var d2 := bubble.global_position.distance_to(goal)
	ok = ok and d2 < d0 - 0.1

	# 收敛：目标不再动，气泡最终钉在目标上方
	for i in 200:
		await process_frame
	var d_end := bubble.global_position.distance_to(goal)
	ok = ok and d_end < 0.2

	# 换目标 / 隐藏 API
	var target2 := Node3D.new()
	target2.name = "SecondTarget"
	target2.position = Vector3(-6.0, 0.5, 2.0)
	_adopt(target2)
	bubble.set_target(target2, "换目标")
	ok = ok and bubble.get_target() == target2 and bubble.visible
	bubble.clear_target()
	ok = ok and bubble.get_target() == null and not bubble.visible

	_check(ok, "T5 锚点气泡：设目标先贴到目标上方、目标移动后两帧内跟随（%s→%s）、200 帧收敛（残差 %.3f）、换目标与隐藏 API 生效" % [
		"%.3f" % d0, "%.3f" % d2, d_end])


# ---------- T6 求助屏：拒绝文案 + 感应 ----------

func _t06_screen_reject_and_sense() -> void:
	var screen := HelpScreenScene.instantiate()
	screen.level_id = "t_screen"
	_adopt(screen)
	var visitor := Node3D.new()
	visitor.name = "Visitor"
	visitor.position = Vector3(10.0, 0.0, 0.0)   # 屏在原点：太远
	_adopt(visitor)

	var events: Array = []
	screen.visitor_entered.connect(func(): events.append("enter"))
	screen.visitor_left.connect(func(): events.append("left"))

	screen.set_visitor(visitor)
	var ok: bool = not screen.is_visitor_in_range() \
		and screen.get_lamp_material().emission_energy_multiplier == 0.0

	# 太远：屏不答（走近再说），不算一次真正的问
	var far: Dictionary = screen.ask("到底哪错了")
	ok = ok and str(far.get("kind", "")) == "too_far" and str(far.get("text", "")).contains("走近")

	# 走到屏前：感应触发（进入信号 + 顶灯亮）
	visitor.position = Vector3(1.0, 0.0, 0.0)
	screen.set_visitor(visitor)
	ok = ok and screen.is_visitor_in_range() and events == ["enter"] \
		and screen.get_lamp_material().emission_energy_multiplier > 0.0

	# 未解锁时的拒绝文案：不给内容
	var rej: Dictionary = screen.ask("到底哪错了")
	ok = ok and str(rej.get("kind", "")) == "rejected" \
		and screen.get_last_text().contains("再试一次，你已经很接近了") \
		and not screen.get_last_text().contains("set_param")

	# 离开：感应信号 + 顶灯灭
	visitor.position = Vector3(30.0, 0.0, 0.0)
	screen.set_visitor(visitor)
	ok = ok and not screen.is_visitor_in_range() and events == ["enter", "left"] \
		and screen.get_lamp_material().emission_energy_multiplier == 0.0

	_check(ok, "T6 求助屏：太远不答（走近再说）、未解锁只回「再试一次，你已经很接近了」不给内容、感应进入/离开（enter/left 信号 + 顶灯亮/灭）")


# ---------- T7 问什么不影响判定 ----------

func _t07_asking_does_not_change_verdict(with_help: Dictionary, baseline: Dictionary) -> void:
	var ok: bool = bool(with_help.get("pass", false)) and bool(baseline.get("pass", false))
	var steps_asked: Array = with_help.get("steps", [])
	var steps_plain: Array = baseline.get("steps", [])
	ok = ok and steps_asked.size() == steps_plain.size() and steps_asked.size() > 0
	ok = ok and _steps_signature(steps_asked) == _steps_signature(steps_plain)
	ok = ok and not _steps_have_help_trace(steps_asked) and not _steps_have_help_trace(steps_plain)
	_check(ok, "T7 问什么不影响判定：同一 L1 流程问三次与不问，check_pass 同为 pass、步数相同（%d vs %d）、phase/actor/action 逐步一致且无 help 痕迹" % [
		steps_asked.size(), steps_plain.size()])


# ---------- T8 接入示例：三次失败 → 三问递进 ----------

func _t08_integration_scene() -> void:
	var screen := HelpScreenScene.instantiate()
	screen.level_id = "t_int"
	screen.concept_map = {"t_int": "c10.1"}
	_adopt(screen)

	var comp := Node3D.new()
	comp.name = "SickComponent"
	comp.position = Vector3(3.0, 0.0, 0.0)
	_adopt(comp)
	var board := TaskBoardScene.instantiate()
	board.position = Vector3(-3.0, 0.0, 0.0)
	_adopt(board)
	var visitor := Node3D.new()
	visitor.name = "Visitor"
	visitor.position = Vector3(1.2, 0.0, 0.0)   # 走到屏前（感应距离 2.4 内）
	_adopt(visitor)

	var highlights: Array = []
	var demos: Array = []
	var entered: Array = []
	screen.request_highlight.connect(func(t: Node3D): highlights.append(t))
	screen.request_demo.connect(func(l: String): demos.append(l))
	screen.visitor_entered.connect(func(): entered.append(true))

	screen.set_problem_component(comp)
	screen.set_task_board(board)
	screen.set_visitor(visitor)

	# 三次失败前：拒绝
	screen.report_fail()
	screen.report_fail()
	var pre: Dictionary = screen.ask("哪错了")
	var ok: bool = str(pre.get("kind", "")) == "rejected" and entered.size() == 1

	# 第三次失败 → 解锁；依次问三次，屏上三级递进 + 气泡逐级指对。
	# 气泡目标与屏文在每次问后立即取样（问下一问就会翻页）。
	screen.report_fail()
	var a1: Dictionary = screen.ask("第 1 问")
	var tgt1: Node3D = screen.get_bubble().get_target()
	var txt1: String = screen.get_last_text()
	var a2: Dictionary = screen.ask("第 2 问")
	var tgt2: Node3D = screen.get_bubble().get_target()
	var txt2: String = screen.get_last_text()
	var a3: Dictionary = screen.ask("第 3 问")
	var tgt3: Node3D = screen.get_bubble().get_target()
	var txt3: String = screen.get_last_text()

	ok = ok and int(a1.get("level", 0)) == 1 and tgt1 == comp \
		and highlights == [comp] \
		and txt1.contains("SickComponent") and txt1.contains("现象") \
		and not txt1.contains("set_param")

	ok = ok and int(a2.get("level", 0)) == 2 and tgt2 == comp \
		and txt2.contains(C101_FAIL1_SYMPTOM) \
		and txt2.contains("c10.1:1")

	ok = ok and int(a3.get("level", 0)) == 3 and tgt3 == board \
		and txt3.contains("代做不参与判定") and demos == ["t_int"]

	# 屏上三级内容递进：三段文案互不相同
	ok = ok and txt1 != txt2 and txt2 != txt3 and txt1 != txt3

	_check(ok, "T8 接入示例：走到屏前感应触发 → 三次失败解锁 → 三问递进（L1 指问题组件+变红回调、L2 指同一组件且文案为 concepts.yaml 原文、L3 指任务牌+发 request_demo、三段文案互不相同）")
