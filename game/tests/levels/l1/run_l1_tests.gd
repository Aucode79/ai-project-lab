extends SceneTree

## L1 端到端测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/levels/l1/run_l1_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##  1  三件组件场景可实例化，状态灯/铭牌文本/幕布播停指示按 API 生效
##  2  L1 场景可实例化：相机就位、光影/体素地面/工位/两安装位/播放器方块齐
##  3  全流程 drive 到 check_pass=true（video→install→run→tune→score→落盘→判定）
##  4  runs/ 落盘 JSON：kind=task、steps 覆盖 video/install/run/score 各至少一步、
##     评分五句落在 level.score 步内
##  5  任务牌四态中"完成"被达到（轨迹覆盖 待命→正在→完成，终态 done）
##  6  改参后第二次 run 与第一次的 task_text 不同，且每次下任务其后都有 codex 的 run
##  7  评分五句（真评分器 rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含
##     实测 ops 与基线对照、正确性句确认目标模式全命中；score 步 output 带
##     sentences/evidence/scorer/llm（回退在案），args.dimensions 旧形状兼容
##
## 产物：本次判定的 run JSON 留在 runs/e49/（运行时产物，已 gitignore），
## 供验收复核；除它之外本测试不写任何文件。

const L1Scene := preload("res://scenes/levels/l1/l1.tscn")
const L1FlowScript := preload("res://scripts/levels/l1/l1_flow.gd")
const TaskBoardScript := preload("res://scenes/levels/l1/components/task_board.gd")
const TaskBoardScene := preload("res://scenes/levels/l1/components/task_board.tscn")
const NameplateScene := preload("res://scenes/levels/l1/components/nameplate.tscn")
const PlayerBlockScene := preload("res://scenes/blocks/player_block.tscn")

const RUN_OUT := "runs/e49"

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
	_t01_components()
	_t02_scene()
	await _t03_full_flow()
	_t04_run_json()
	_t05_state_trajectory()
	_t06_tune_differs()
	_t07_score_sentences()
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

	var tb := TaskBoardScene.instantiate()
	root.add_child(tb)
	tb.set_task_text("测试任务：数一数")
	tb.set_state_visual(TaskBoardScript.STATE_DONE)
	var lamp_mat: StandardMaterial3D = tb.get_lamp_material()
	ok = ok and tb.has_node("TaskText") and tb.has_node("StateCaption") and tb.has_node("Lamp")
	ok = ok and tb.get_task_text() == "测试任务：数一数"
	ok = ok and str(tb.get_node("StateCaption").text) == "完成"
	ok = ok and lamp_mat.emission.is_equal_approx(TaskBoardScript.STATE_COLORS[TaskBoardScript.STATE_DONE])
	tb.set_state_visual(TaskBoardScript.STATE_ERROR)
	ok = ok and lamp_mat.emission.is_equal_approx(TaskBoardScript.STATE_COLORS[TaskBoardScript.STATE_ERROR])
	tb.free()

	var np := NameplateScene.instantiate()
	root.add_child(np)
	np.apply_identity("mini codex", "工位 01 · 接活与报数")
	ok = ok and np.has_node("NameText") and np.has_node("RoleText")
	ok = ok and np.get_name_text() == "mini codex" and np.get_role_text() == "工位 01 · 接活与报数"
	ok = ok and str(np.get_node("NameText").text) == "mini codex"
	np.free()

	var pb := PlayerBlockScene.instantiate()
	root.add_child(pb)
	pb.play()
	ok = ok and pb.is_playing() and pb.get_node("PlayIndicator").visible and not pb.get_node("PauseIndicator").visible
	pb.pause()
	ok = ok and not pb.is_playing() and not pb.get_node("PlayIndicator").visible and pb.get_node("PauseIndicator").visible
	ok = ok and pb.get_title() == "L1 · E49 占位视频"
	pb.free()

	_check(ok, "T1 三件组件场景可实例化：任务牌灯色四态切换、铭牌名字/角色就位、幕布播/停指示器互斥")


func _t02_scene() -> void:
	_scene = L1Scene.instantiate()
	root.add_child(_scene)
	for i in 5:
		await create_timer(0.02).timeout
	var ok := _scene.has_node("Camera") and (_scene.get_node("Camera") as Camera3D).current
	ok = ok and _scene.has_node("WorldEnvironment") and _scene.has_node("Sun") and _scene.has_node("Fill")
	ok = ok and _scene.has_node("Terrain")
	ok = ok and _scene.has_node("Workstation/CodexCart")
	ok = ok and _scene.has_node("Workstation/TaskBoardMount") and _scene.has_node("Workstation/NamePlateMount")
	ok = ok and _scene.has_node("Workstation/PlayerScreen")
	_check(ok, "T2 L1 场景可实例化：相机就位且为当前、明亮光影/体素地面/工位小车/两安装位/播放器方块齐")


func _t03_full_flow() -> void:
	var tools := _fresh_tools()
	_flow = L1FlowScript.new()
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
	_check(ok, "T3 全流程 video→install→run→tune→score 驱动到 check_pass=true，run 已落盘冻结（%s）" % path)


func _t04_run_json() -> void:
	var rc_path := str(_verdict.get("path", ""))
	var ok := str((_doc.get("run", {}) as Dictionary).get("kind", "")) == "task"
	var phases := {}
	var score_dims := -1
	for s in _doc.get("steps", []):
		var step: Dictionary = s
		phases[str(step.get("phase", ""))] = true
		if str(step.get("action", {}).get("tool", "")) == "level.score":
			var args: Dictionary = step["action"].get("args", {})
			score_dims = (args.get("dimensions", []) as Array).size()
	for want in ["video", "install", "run", "tune", "score"]:
		ok = ok and phases.has(want)
	ok = ok and score_dims == 5
	_check(ok, "T4 run JSON（%s）：kind=task、覆盖 video/install/run/score 各至少一步、评分五句在 level.score 步内" % rc_path)


func _t05_state_trajectory() -> void:
	var board_eid := str(_flow.board_eid)
	var traj: Array = TaskBoardScript.state_trajectory(_doc.get("steps", []), board_eid)
	var ok := traj.has(TaskBoardScript.STATE_IDLE) and traj.has(TaskBoardScript.STATE_RUNNING) and traj.has(TaskBoardScript.STATE_DONE)
	ok = ok and str(traj[traj.size() - 1]) == TaskBoardScript.STATE_DONE
	ok = ok and not traj.has(TaskBoardScript.STATE_ERROR)
	_check(ok, "T5 任务牌状态由步记录派生：轨迹覆盖 待命→正在→完成（'完成'被达到，终态 done，无出错）")


func _t06_tune_differs() -> void:
	var steps: Array = _doc.get("steps", [])
	var board_eid := str(_flow.board_eid)
	var texts: Array = []
	var each_followed := true
	for i in steps.size():
		var step: Dictionary = steps[i]
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == board_eid and str(args.get("key", "")) == "task_text":
				texts.append(str(args.get("value", "")))
				var found := false
				for j in range(i + 1, steps.size()):
					var sj: Dictionary = steps[j]
					if str(sj.get("action", {}).get("tool", "")) == WorldToolsCore.TOOL_RUN and str(sj.get("actor", "")) == "codex":
						found = true
						break
				each_followed = each_followed and found
	var ok: bool = texts.size() >= 2 and texts[0] != "" and texts[1] != "" and texts[0] != texts[1]
	ok = ok and texts[0] == "读取 report.txt 并数出'错误'出现次数"
	ok = ok and each_followed
	ok = ok and str(_verdict.get("firstText", "")) == texts[0] and str(_verdict.get("secondText", "")) == texts[1]
	_check(ok, "T6 改参生效：两次下任务的 task_text 不同（%d 条记录），且每次其后都有 codex 的 world.run" % texts.size())


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
	# 效率句含本次实测 ops 与基线对照；正确性句确认目标模式全命中（goal 校准生效）
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
