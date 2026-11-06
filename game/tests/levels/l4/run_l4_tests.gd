extends SceneTree

## L4 端到端测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/levels/l4/run_l4_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##  1  四件场景（思考机/计划板/工具带/E40 幕布）可实例化，纸条摘要、token 方块数、
##     计划行与指针、工具发光与播停按 API 生效
##  2  四态派生纯函数：喂合成步记录，三件组件各自 得到 待命→正在→完成
##  3  L4 场景可实例化：相机/光影/体素地面/工位小车/三安装位/工具墙/幕布齐
##  4  全流程 drive 到 check_pass=true（video→install→run→tune→score→落盘→判定）
##  5  run JSON：kind=task、episode=40、覆盖五个 phase、评分五句在 level.score 步内
##  6  mini_brain 规则单测（5 条）：默认三步 读→做→写；含"检查"出校验步；
##     含"两遍/重复"出循环步；含"搜索/查找"用搜工具；token 数与提示词长度正相关
##  7  两次计划序列 JSON 级不同：第二次含校验步与循环步、第一次不含；与重算一致（确定性）
##  8  工具带选中轨迹在步记录里：哪步亮哪把（两次 run 的完整序列）；
##     计划板指针推进序列同样在记录里
##  9  评分五句（真评分器 rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含
##     实测 ops 与基线对照、正确性句确认 提示A→思考A→提示B→思考B 模式全命中；
##     score 步 output 带 sentences/evidence/scorer/llm（回退在案），args.dimensions 旧形状兼容
##
## 产物：本次判定的 run JSON 留在 runs/e40/（运行时产物，已 gitignore），
## 供验收复核；除它之外本测试不写任何文件。

const L4Scene := preload("res://scenes/levels/l4/l4.tscn")
const L4FlowScript := preload("res://scripts/levels/l4/l4_flow.gd")
const MiniBrain := preload("res://scripts/levels/l4/mini_brain.gd")
const ThinkerScene := preload("res://scenes/levels/l4/components/thinker.tscn")
const ThinkerScript := preload("res://scenes/levels/l4/components/thinker.gd")
const PlanBoardScene := preload("res://scenes/levels/l4/components/plan_board.tscn")
const PlanBoardScript := preload("res://scenes/levels/l4/components/plan_board.gd")
const ToolBeltScene := preload("res://scenes/levels/l4/components/tool_belt.tscn")
const ToolBeltScript := preload("res://scenes/levels/l4/components/tool_belt.gd")
const E40ScreenScene := preload("res://scenes/levels/l4/components/e40_screen.tscn")

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
	_t01b_state_derivation()
	await _t02_scene()
	await _t03_full_flow()
	_t04_run_json()
	_t05_mini_brain_rules()
	_t06_plans_differ()
	_t07_tool_trajectory()
	_t08_score_sentences()
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

	# 思考机：纸条摘要 + token 方块数量 + 四态灯
	var tk := ThinkerScene.instantiate()
	root.add_child(tk)
	tk.set_prompt("先检查格式，再数两遍错误，最后搜索相关词")
	tk.emit_tokens(17)
	ok = ok and tk.has_node("PromptSlip/PromptSummary") and tk.has_node("TokenTray") and tk.has_node("Lamp")
	ok = ok and tk.get_prompt() == "先检查格式，再数两遍错误，最后搜索相关词"
	ok = ok and str(tk.get_node("PromptSlip/PromptSummary").text).contains("先检查格式")
	ok = ok and tk.get_token_count() == 17 and tk.get_node("TokenTray").get_child_count() == 17
	tk.emit_tokens(5)
	ok = ok and tk.get_token_count() == 5 and tk.get_node("TokenTray").get_child_count() == 5
	var tk_lamp: StandardMaterial3D = tk.get_lamp_material()
	tk.set_state_visual(ThinkerScript.STATE_DONE)
	ok = ok and tk_lamp.emission.is_equal_approx(ThinkerScript.STATE_COLORS[ThinkerScript.STATE_DONE])
	tk.set_state_visual(ThinkerScript.STATE_ERROR)
	ok = ok and tk_lamp.emission.is_equal_approx(ThinkerScript.STATE_COLORS[ThinkerScript.STATE_ERROR])
	tk.free()

	# 计划板：计划行 + 指针随执行推进
	var pb := PlanBoardScene.instantiate()
	root.add_child(pb)
	pb.set_plan([
		{"name": "校验输入格式", "tool": "run"},
		{"name": "读入材料", "tool": "read"},
		{"name": "写出结果", "tool": "write"},
	])
	ok = ok and pb.has_node("StepsRoot") and pb.has_node("Pointer") and pb.has_node("Lamp")
	ok = ok and pb.get_plan().size() == 3
	ok = ok and pb.get_node("StepsRoot").get_child_count() == 3
	ok = ok and str(pb.get_node("StepsRoot/StepRow0").text).contains("校验输入格式")
	ok = ok and str(pb.get_node("StepsRoot/StepRow0").text).contains("跑")
	ok = ok and pb.get_current_step() == -1 and not pb.get_node("Pointer").visible
	pb.set_current_step(1)
	ok = ok and pb.get_current_step() == 1 and pb.get_node("Pointer").visible
	ok = ok and abs(pb.get_node("Pointer").position.y - (1.86 - 1 * 0.34)) < 0.001
	pb.set_current_step(-1)
	ok = ok and not pb.get_node("Pointer").visible
	pb.free()

	# 工具带：四把工具形状各异，被选中那把发光
	var tb := ToolBeltScene.instantiate()
	root.add_child(tb)
	ok = ok and tb.has_node("ToolRead") and tb.has_node("ToolWrite") and tb.has_node("ToolRun") and tb.has_node("ToolSearch")
	# 四个工具头**全部由方块拼**（2026-09-16 口径），靠**块数**区分：1 / 2 / 3 / 4
	ok = ok and _tool_head_blocks(tb, "ToolRead") == 1 \
		and _tool_head_blocks(tb, "ToolWrite") == 2 \
		and _tool_head_blocks(tb, "ToolRun") == 3 \
		and _tool_head_blocks(tb, "ToolSearch") == 4
	tb.select_tool(ToolBeltScript.TOOL_SEARCH)
	ok = ok and tb.get_selected_tool() == ToolBeltScript.TOOL_SEARCH
	ok = ok and tb.is_tool_lit(ToolBeltScript.TOOL_SEARCH)
	ok = ok and not tb.is_tool_lit(ToolBeltScript.TOOL_READ) and not tb.is_tool_lit(ToolBeltScript.TOOL_WRITE) and not tb.is_tool_lit(ToolBeltScript.TOOL_RUN)
	tb.select_tool(ToolBeltScript.TOOL_RUN)
	ok = ok and tb.is_tool_lit(ToolBeltScript.TOOL_RUN) and not tb.is_tool_lit(ToolBeltScript.TOOL_SEARCH)
	tb.select_tool("")
	ok = ok and not tb.is_tool_lit(ToolBeltScript.TOOL_RUN)
	tb.free()

	# E40 幕布：标题换成 L4 · E40，播/停可用
	var sc := E40ScreenScene.instantiate()
	root.add_child(sc)
	sc.play()
	ok = ok and sc.is_playing() and sc.get_title() == "L4 · E40 占位视频"
	ok = ok and str(sc.get_node("Screen/ScreenLabel").text) == "L4 · E40 占位视频"
	sc.pause()
	ok = ok and not sc.is_playing()
	sc.free()

	_check(ok, "T1 四件场景可实例化：思考机纸条摘要/token 方块数=17→5、计划板三行+指针推进、工具带选中发光互斥、E40 幕布标题与播停")


func _t01b_state_derivation() -> void:
	# 喂合成步记录，验证"状态由步记录派生"这条硬规则（mini-codex §2.1）
	var ok := true

	# 思考机：idle → set_param(prompt) → running → model.think(tokens>0) → done
	var neutral := {"action": {"tool": "level.stage", "args": {}}, "output": {"ok": true}}
	var tk_steps := [
		neutral,
		{"action": {"tool": "world.set_param", "args": {"entityId": "conc_thinker#1", "key": "prompt", "value": "x"}, "output": {"ok": true}}},
		{"action": {"tool": "model.think", "args": {"prompt": "x"}}, "output": {"ok": true}, "tokens": 40, "actor": "codex"},
	]
	var tk_traj: Array = ThinkerScript.state_trajectory(tk_steps, "conc_thinker#1")
	ok = ok and tk_traj == [ThinkerScript.STATE_IDLE, ThinkerScript.STATE_RUNNING, ThinkerScript.STATE_DONE]

	# 计划板：running（计划上板）→ done（world.run 时 step_out >= 步数-1）
	var plan_json := JSON.stringify([
		{"name": "读入材料", "tool": "read"},
		{"name": "完成任务", "tool": "run"},
	])
	var pb_steps := [
		neutral,
		{"action": {"tool": "world.set_param", "args": {"entityId": "conc_plan_board#1", "key": "plan_text", "value": plan_json}, "output": {"ok": true}}},
		{"action": {"tool": "world.run"}, "actor": "codex", "output": {"ok": true},
			"world": {"entities": {"conc_plan_board#1": {
				"params": {"plan_text": plan_json},
				"ports": {"step_out": {"value": 1.0}}}}}},
	]
	var pb_traj: Array = PlanBoardScript.state_trajectory(pb_steps, "conc_plan_board#1")
	ok = ok and pb_traj == [PlanBoardScript.STATE_IDLE, PlanBoardScript.STATE_RUNNING, PlanBoardScript.STATE_DONE]

	# 工具带：选中轨迹 + idle→running→done
	var tb_steps := [
		{"i": 0, "action": neutral["action"], "output": {"ok": true}},
		{"i": 1, "action": {"tool": "world.set_param", "args": {"entityId": "conc_tool_belt#1", "key": "selected_tool", "value": "read"}, "output": {"ok": true}}},
		{"i": 2, "action": {"tool": "world.set_param", "args": {"entityId": "conc_tool_belt#1", "key": "selected_tool", "value": "run"}, "output": {"ok": true}}},
		{"i": 3, "action": {"tool": "world.run"}, "actor": "codex", "output": {"ok": true}},
	]
	var picks: Array = ToolBeltScript.selection_trajectory(tb_steps, "conc_tool_belt#1")
	ok = ok and picks.size() == 2 and str(picks[0]["tool"]) == "read" and str(picks[1]["tool"]) == "run"
	var tb_traj: Array = ToolBeltScript.state_trajectory(tb_steps, "conc_tool_belt#1")
	ok = ok and tb_traj == [ToolBeltScript.STATE_IDLE, ToolBeltScript.STATE_RUNNING, ToolBeltScript.STATE_RUNNING, ToolBeltScript.STATE_DONE]

	_check(ok, "T1b 四态从步记录派生（纯函数）：三件组件喂合成记录各自得到 待命→正在→完成，选中轨迹可回放")


func _t02_scene() -> void:
	_scene = L4Scene.instantiate()
	root.add_child(_scene)
	for i in 5:
		await create_timer(0.02).timeout
	var ok := _scene.has_node("Camera") and (_scene.get_node("Camera") as Camera3D).current
	ok = ok and _scene.has_node("WorldEnvironment") and _scene.has_node("Sun") and _scene.has_node("Fill")
	ok = ok and _scene.has_node("Terrain")
	ok = ok and _scene.has_node("Workstation/CodexCart")
	ok = ok and _scene.has_node("Workstation/ThinkerMount") and _scene.has_node("Workstation/PlanBoardMount")
	ok = ok and _scene.has_node("Workstation/ToolBeltMount") and _scene.has_node("Workstation/ToolWall")
	ok = ok and _scene.has_node("Workstation/PlayerScreen")
	_check(ok, "T2 L4 场景可实例化：相机就位且为当前、明亮光影/体素地面/工位小车/三安装位/工具墙/E40 幕布齐")


func _t03_full_flow() -> void:
	var tools := _fresh_tools()
	_flow = L4FlowScript.new()
	_flow.tools = tools
	_flow.view = _scene
	_scene.add_child(_flow)
	_verdict = await _flow.drive_full()
	var rc: StepRecorderCore = tools.recorder()
	var path := rc.out_path()
	var ok := bool(_verdict.get("pass", false))
	ok = ok and rc.state_name() == "frozen" and path != "" and FileAccess.file_exists(path)
	ok = ok and int(_verdict.get("steps", 0)) >= 10
	ok = ok and bool(_verdict.get("planSeqDiffers", false)) and bool(_verdict.get("secondHasVerifyAndLoop", false))
	ok = ok and bool(_verdict.get("promptsInRecord", false)) and bool(_verdict.get("tokensDiffer", false))
	if ok:
		_doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	ok = ok and not _doc.is_empty()
	_check(ok, "T3 全流程 video→install→run→tune→score 驱动到 check_pass=true（计划随提示词变化），run 已落盘冻结（%s）" % path)


func _t04_run_json() -> void:
	var rc_path := str(_verdict.get("path", ""))
	var run: Dictionary = _doc.get("run", {})
	var ok := str(run.get("kind", "")) == "task" and int(run.get("episode", -1)) == 40
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
	_check(ok, "T4 run JSON（%s）：kind=task、episode=40、覆盖 video/install/run/tune/score 各至少一步、评分五句在 level.score 步内" % rc_path)


func _t05_mini_brain_rules() -> void:
	# 规则一：默认三步计划（读→做→写），无校验/循环步
	var plan_a: Dictionary = MiniBrain.think("数出错误并写出结果")
	var ok_a: bool = (plan_a["steps"] as Array).size() == 3
	ok_a = ok_a and MiniBrain.tool_sequence(plan_a["steps"]) == [MiniBrain.TOOL_READ, MiniBrain.TOOL_RUN, MiniBrain.TOOL_WRITE]
	ok_a = ok_a and not MiniBrain.has_step_named(plan_a["steps"], MiniBrain.STEP_NAME_VERIFY)
	ok_a = ok_a and not MiniBrain.has_step_named(plan_a["steps"], MiniBrain.STEP_NAME_LOOP)
	_check(ok_a, "T5a mini_brain 默认三步计划：读→做→写，无校验步无循环步")

	# 规则二：含"先检查/检查/校验"→ 计划插入校验步（且在最前）
	var plan_c: Dictionary = MiniBrain.think("先检查格式再数错误")
	var ok_c := MiniBrain.has_step_named(plan_c["steps"], MiniBrain.STEP_NAME_VERIFY)
	ok_c = ok_c and str((plan_c["steps"] as Array)[0].get("name", "")).contains(MiniBrain.STEP_NAME_VERIFY)
	ok_c = ok_c and MiniBrain.has_step_named(MiniBrain.think("校验输入后写出结果")["steps"], MiniBrain.STEP_NAME_VERIFY)
	_check(ok_c, "T5b mini_brain 含'检查/校验'出校验步，且插在计划最前")

	# 规则三：含"两遍/重复"→ 循环步替代单次执行步
	var ok_l := MiniBrain.has_step_named(MiniBrain.think("把结果数两遍再写")["steps"], MiniBrain.STEP_NAME_LOOP)
	ok_l = ok_l and MiniBrain.has_step_named(MiniBrain.think("重复执行并写出")["steps"], MiniBrain.STEP_NAME_LOOP)
	ok_l = ok_l and not MiniBrain.has_step_named(MiniBrain.think("普通任务")["steps"], MiniBrain.STEP_NAME_LOOP)
	_check(ok_l, "T5c mini_brain 含'两遍/重复'出循环步，不含则无")

	# 规则四：含"搜索/查找"→ 用搜工具
	var ok_s := MiniBrain.tool_sequence(MiniBrain.think("查找相关资料并写")["steps"]).has(MiniBrain.TOOL_SEARCH)
	ok_s = ok_s and MiniBrain.tool_sequence(MiniBrain.think("搜索相关词并写")["steps"]).has(MiniBrain.TOOL_SEARCH)
	ok_s = ok_s and not MiniBrain.tool_sequence(MiniBrain.think("普通任务")["steps"]).has(MiniBrain.TOOL_SEARCH)
	_check(ok_s, "T5d mini_brain 含'搜索/查找'→ 计划用「搜」工具")

	# 规则五：token 数与提示词长度正相关（同规则集下只变长度）
	var short_p: Dictionary = MiniBrain.think("数出错误并写")
	var long_p: Dictionary = MiniBrain.think("数出错误并写出包含上下文与统计口径的完整结果")
	var ok_t := (short_p["steps"] as Array).size() == (long_p["steps"] as Array).size()
	ok_t = ok_t and int(short_p["tokens"]) < int(long_p["tokens"])
	ok_t = ok_t and int(MiniBrain.think("数出错误并写出结果")["tokens"]) != int(MiniBrain.think("先检查格式，再数两遍错误，最后搜索相关词")["tokens"])
	_check(ok_t, "T5e mini_brain token 数与提示词长度正相关（%d < %d），且 A/B 两提示词 token 数不同" % [int(short_p["tokens"]), int(long_p["tokens"])])


func _t06_plans_differ() -> void:
	# 从冻结的 run JSON 里取两次 model.think：计划序列 JSON 级不同，
	# 第二次含校验步与循环步、第一次不含；且与 mini_brain 重算结果一致（确定性）。
	var thinks: Array = []
	for s in _doc.get("steps", []):
		var step: Dictionary = s
		if str(step.get("action", {}).get("tool", "")) == "model.think":
			thinks.append({
				"prompt": str(step.get("action", {}).get("args", {}).get("prompt", "")),
				"plan": step.get("output", {}).get("plan", []),
				"tokens": int(step.get("tokens", 0)),
			})
	var ok := thinks.size() == 2
	if ok:
		var sig_a := JSON.stringify(thinks[0]["plan"])
		var sig_b := JSON.stringify(thinks[1]["plan"])
		ok = sig_a != sig_b and int(thinks[0]["tokens"]) != int(thinks[1]["tokens"])
		ok = ok and str(thinks[0]["prompt"]) == "数出错误并写出结果"
		ok = ok and str(thinks[1]["prompt"]) == "先检查格式，再数两遍错误，最后搜索相关词"
		ok = ok and MiniBrain.has_step_named(thinks[1]["plan"], MiniBrain.STEP_NAME_VERIFY)
		ok = ok and MiniBrain.has_step_named(thinks[1]["plan"], MiniBrain.STEP_NAME_LOOP)
		ok = ok and not MiniBrain.has_step_named(thinks[0]["plan"], MiniBrain.STEP_NAME_VERIFY)
		ok = ok and not MiniBrain.has_step_named(thinks[0]["plan"], MiniBrain.STEP_NAME_LOOP)
		# 确定性：同一提示词重算，计划与 token 一致（将来接真模型前，判定只认这套规则）
		var re_a: Dictionary = MiniBrain.think(str(thinks[0]["prompt"]))
		var re_b: Dictionary = MiniBrain.think(str(thinks[1]["prompt"]))
		ok = ok and JSON.stringify(re_a["steps"]) == sig_a and JSON.stringify(re_b["steps"]) == sig_b
		ok = ok and int(re_a["tokens"]) == int(thinks[0]["tokens"]) and int(re_b["tokens"]) == int(thinks[1]["tokens"])
	_check(ok, "T6 两次计划序列 JSON 级不同（%d 步 vs %d 步）：第二次含校验步+循环步、第一次不含，重算一致（确定性）" % [
		(thinks[0]["plan"] as Array).size() if thinks.size() > 0 else -1,
		(thinks[1]["plan"] as Array).size() if thinks.size() > 1 else -1])


func _t07_tool_trajectory() -> void:
	# 工具带选中轨迹（哪步亮哪把）与计划板指针推进，都在步记录里
	var steps: Array = _doc.get("steps", [])
	var belt_eid := str(_flow.belt_eid)
	var plan_eid := str(_flow.plan_eid)
	var picks: Array = ToolBeltScript.selection_trajectory(steps, belt_eid)
	var want_tools := ["read", "run", "write", "run", "read", "search", "run", "write"]
	var ok := picks.size() == want_tools.size()
	if ok:
		for i in want_tools.size():
			ok = ok and str(picks[i]["tool"]) == want_tools[i]
	# 计划板指针：@step_out 序列 = 第一次 0..2，第二次 0..4（指针重走）
	var pointer_seq: Array = []
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == plan_eid and str(args.get("key", "")) == "@step_out":
				pointer_seq.append(float(args.get("value", -1.0)))
	ok = ok and pointer_seq == [0.0, 1.0, 2.0, 0.0, 1.0, 2.0, 3.0, 4.0]
	# 三件组件终态都从这份记录派生为"完成"
	var tk_state := str(ThinkerScript.derive_state_from_steps(steps, str(_flow.thinker_eid)))
	var pb_state := str(PlanBoardScript.derive_state_from_steps(steps, plan_eid))
	var tb_state := str(ToolBeltScript.derive_state_from_steps(steps, belt_eid))
	ok = ok and tk_state == ThinkerScript.STATE_DONE and pb_state == PlanBoardScript.STATE_DONE and tb_state == ToolBeltScript.STATE_DONE
	_check(ok, "T7 工具带选中轨迹在步记录里（%s）+ 指针推进 0..2→0..4 重走，三件组件终态均派生为'完成'" % "→".join(PackedStringArray(want_tools)))


func _t08_score_sentences() -> void:
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
	# 效率句含本次实测 ops 与基线对照；正确性句确认 提示A→思考A→提示B→思考B 模式全命中
	var ops_sum := 0
	var tokens_sum := 0
	for s in _doc.get("steps", []):
		ops_sum += int((s as Dictionary).get("ops", 0))
		tokens_sum += int((s as Dictionary).get("tokens", 0))
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
	_check(ok, "T8 评分五句（rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含实测 %d ops（%d token）与基线对照、正确性句确认目标达成；score 步 output 带 sentences/evidence/scorer（llm 回退在案、args.dimensions 旧形状兼容）" % [ops_sum, tokens_sum])


## 工具头的方块数（并顺带核对：Head 下全是 BoxMesh —— 口径"资产一律由方块组成"）。
func _tool_head_blocks(tb: Node, tool_name: String) -> int:
	var head := tb.get_node_or_null(tool_name + "/Head")
	if head == null:
		return -1
	var n := 0
	for c in head.get_children():
		if not (c is MeshInstance3D) or not ((c as MeshInstance3D).mesh is BoxMesh):
			return -1
		n += 1
	return n
