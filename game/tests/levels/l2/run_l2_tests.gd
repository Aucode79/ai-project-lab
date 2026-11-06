extends SceneTree

## L2 端到端测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/levels/l2/run_l2_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准，10 条）：
##  1  三件组件场景可实例化：柜格三态灯/门开合/扫描淡痕/机械臂落点标记/四态灯生效
##  2  L2 场景可实例化：相机就位、光影/体素地面/工位小车/三安装位/工作台/幕布齐，
##     小车工具头切换可见
##  3  全流程 drive 到 check_pass=true（video→install→run→tune→score→落盘→判定）
##  4  runs/ 落盘 JSON：kind=task、episode=51、读取步载体=扫描器、写入步载体=机械臂、
##     world.switch_tool_head 步存在
##  5  上锁格 secret.txt 的读取被拒（failures 在案、从未读成功），柜门灯为锁
##  6  写入留痕（arm_landing）与读取留痕（scan_fade）都在步记录 world 摘要里；
##     新增（out.txt 空格放入）与修改（config.yaml 先取旧再放新）模式可分辨
##  7  改参生效：两次 run 的扫描目标不同（report.txt → notes.md），tune 步记录
##     oldValue ≠ newValue，且每次下目标其后都有对该文件的读取
##  8  评分五句（真评分器 rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含
##     实测 ops 与基线对照、正确性句确认读→写模式全命中；score 步 output 带
##     sentences/evidence/scorer/llm（回退在案），args.dimensions 旧形状兼容
##  9  负路径：工具头不对（arm 头读 / scanner 头写）双双被拒——ok=false、
##     code=wrong_tool_head、failures 在案、世界未被写（文件内容不变）
## 10  phase 分段：tune 段的 fs 步与换头步 phase=="tune"（run 段仍为 "run"）
##
## 产物：本次判定的 run JSON 留在 runs/e51/（运行时产物，已 gitignore），
## 供验收复核；除它之外本测试不写任何文件。

const L2Scene := preload("res://scenes/levels/l2/l2.tscn")
const L2FlowScript := preload("res://scripts/levels/l2/l2_flow.gd")
const CabinetScript := preload("res://scenes/levels/l2/components/file_cabinet.gd")
const ScannerScript := preload("res://scenes/levels/l2/components/scanner.gd")
const ArmScript := preload("res://scenes/levels/l2/components/arm.gd")
const CabinetScene := preload("res://scenes/levels/l2/components/file_cabinet.tscn")
const ScannerScene := preload("res://scenes/levels/l2/components/scanner.tscn")
const ArmScene := preload("res://scenes/levels/l2/components/arm.tscn")

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
	await _t02_scene()
	await _t03_full_flow()
	_t04_run_json_carriers()
	_t05_locked_cell()
	_t06_marks_in_world()
	_t07_tune_differs()
	_t08_score_sentences()
	await _t09_wrong_tool_head()
	_t10_tune_phase()
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

	var cab := CabinetScene.instantiate()
	root.add_child(cab)
	cab.setup_files([
		{"name": "report.txt", "permission": "write", "content": "a 错误 b 错误 c"},
		{"name": "data.csv", "permission": "read", "content": "1,2"},
		{"name": "notes.md", "permission": "read", "content": "n"},
		{"name": "secret.txt", "permission": "lock", "content": "s"},
		{"name": "out.txt", "permission": "write", "content": ""},
		{"name": "config.yaml", "permission": "write", "content": "theme: light"},
	])
	# 三态灯与门开合（作用域来自声明）
	ok = ok and cab.get_cell_permission(0) == CabinetScript.PERM_WRITE and cab.is_door_open(0)
	ok = ok and cab.get_cell_permission(1) == CabinetScript.PERM_READ and not cab.is_door_open(1)
	ok = ok and cab.get_cell_permission(3) == CabinetScript.PERM_LOCK and cab.is_locked(3) and not cab.is_door_open(3)
	ok = ok and (cab.get_cell_lamp_material(3).emission).is_equal_approx(CabinetScript.PERM_LAMP_COLORS[CabinetScript.PERM_LOCK])
	ok = ok and (cab.get_cell_lamp_material(0).emission).is_equal_approx(CabinetScript.PERM_LAMP_COLORS[CabinetScript.PERM_WRITE])
	ok = ok and str(cab.get_node("Cell0/FileName").text) == "report.txt"
	# 扫描淡痕（读不留物：淡出参数化时长）与机械臂落点标记（写留物，颜色区分）
	cab.show_scan_mark(0, 60.0)
	ok = ok and cab.has_scan_mark(0) and not cab.has_scan_mark(1)
	cab.show_write_mark(4, "add")
	cab.show_write_mark(5, "modify")
	ok = ok and cab.has_write_mark(4) and cab.get_write_mark_mode(4) == "add"
	ok = ok and cab.has_write_mark(5) and cab.get_write_mark_mode(5) == "modify"
	# 四态灯
	cab.set_state_visual(CabinetScript.STATE_DONE)
	ok = ok and (cab.get_lamp_material().emission).is_equal_approx(CabinetScript.STATE_COLORS[CabinetScript.STATE_DONE])
	ok = ok and str(cab.get_node("StateCaption").text) == "完成"
	cab.free()

	var sc := ScannerScene.instantiate()
	root.add_child(sc)
	sc.set_state_visual(ScannerScript.STATE_RUNNING)
	sc.pulse()
	ok = ok and sc.has_node("Lamp") and sc.has_node("StateCaption")
	ok = ok and (sc.get_lamp_material().emission).is_equal_approx(ScannerScript.STATE_COLORS[ScannerScript.STATE_RUNNING])
	sc.free()

	var ar := ArmScene.instantiate()
	root.add_child(ar)
	ar.set_state_visual(ArmScript.STATE_ERROR)
	ar.pulse()
	ok = ok and ar.has_node("Lamp") and ar.has_node("StateCaption") and ar.has_node("Shoulder/Wrist/Forearm")
	ok = ok and (ar.get_lamp_material().emission).is_equal_approx(ArmScript.STATE_COLORS[ArmScript.STATE_ERROR])
	ok = ok and str(ar.get_node("StateCaption").text) == "出错"
	ar.free()

	_check(ok, "T1 三件组件可实例化：柜格三态灯/门开合/淡痕/落点标记（新增与修改并存）、扫描器与机械臂四态灯")


func _t02_scene() -> void:
	_scene = L2Scene.instantiate()
	root.add_child(_scene)
	for i in 5:
		await create_timer(0.02).timeout
	var ok: bool = _scene.has_node("Camera") and (_scene.get_node("Camera") as Camera3D).current
	ok = ok and _scene.has_node("WorldEnvironment") and _scene.has_node("Sun") and _scene.has_node("Fill")
	ok = ok and _scene.has_node("Terrain")
	ok = ok and _scene.has_node("Workstation/CodexCart")
	ok = ok and _scene.has_node("Workstation/CabinetMount") and _scene.has_node("Workstation/ScannerMount") and _scene.has_node("Workstation/ArmMount")
	ok = ok and _scene.has_node("Workstation/Workbench") and _scene.has_node("Workstation/PlayerScreen")
	# 工具头切换可见
	_scene.set_tool_head("scanner")
	ok = ok and _scene.get_node("Workstation/CodexCart/HeadMount/MiniScannerHead").visible
	ok = ok and not _scene.get_node("Workstation/CodexCart/HeadMount/MiniArmHead").visible
	_scene.set_tool_head("arm")
	ok = ok and not _scene.get_node("Workstation/CodexCart/HeadMount/MiniScannerHead").visible
	ok = ok and _scene.get_node("Workstation/CodexCart/HeadMount/MiniArmHead").visible
	_check(ok, "T2 L2 场景可实例化：相机就位且为当前、光影/体素地面/工位小车/三安装位/工作台/幕布齐、工具头切换可见")


func _t03_full_flow() -> void:
	var tools := _fresh_tools()
	_flow = L2FlowScript.new()
	_flow.tools = tools
	_flow.view = _scene
	_flow.slow_step_seconds = 0.02   # 测试提速（mini-codex 默认 0.6 秒/步）
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


func _t04_run_json_carriers() -> void:
	var run: Dictionary = _doc.get("run", {})
	var ok := str(run.get("kind", "")) == "task" and int(run.get("episode", -1)) == 51
	var reads := 0
	var writes := 0
	var switches := 0
	var carriers_ok := true
	for s in _doc.get("steps", []):
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		if tool == "fs.read":
			reads += 1
			carriers_ok = carriers_ok and str(action.get("carrier", "")) == "scanner"
		elif tool == "fs.write":
			writes += 1
			carriers_ok = carriers_ok and str(action.get("carrier", "")) == "arm"
		elif tool == "world.switch_tool_head":
			switches += 1
	ok = ok and carriers_ok and reads >= 2 and writes >= 2 and switches >= 2
	_check(ok, "T4 run JSON：kind=task、episode=51；读取步 %d 个载体全是扫描器、写入步 %d 个载体全是机械臂、switch_tool_head 步 %d 个存在" % [reads, writes, switches])


func _t05_locked_cell() -> void:
	var steps: Array = _doc.get("steps", [])
	var denied := false
	var never_ok := true
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == "fs.read":
			var args: Dictionary = action.get("args", {})
			var output: Dictionary = step.get("output", {})
			if str(args.get("path", "")) == "secret.txt":
				if not bool(output.get("ok", true)) and str(output.get("error", {}).get("code", "")) == "locked":
					denied = true
				if bool(output.get("ok", true)):
					never_ok = false
	var failures: Array = _doc.get("failures", [])
	var has_failure := false
	for f in failures:
		if str((f as Dictionary).get("code", "")) == "locked":
			has_failure = true
	# 柜门灯为锁（可视面从同一份声明派生）
	var cab: Node = _scene.get_file_cabinet()
	var lamp_locked: bool = cab.get_cell_permission(3) == CabinetScript.PERM_LOCK \
		and cab.is_locked(3) and not cab.is_door_open(3) \
		and (cab.get_cell_lamp_material(3).emission).is_equal_approx(CabinetScript.PERM_LAMP_COLORS[CabinetScript.PERM_LOCK])
	var ok: bool = denied and never_ok and has_failure and lamp_locked and bool(_verdict.get("lockedNeverRead", false))
	_check(ok, "T5 禁读格 secret.txt：读取被拒（code=locked 且在 failures）、从未读成功、柜门灯为锁（红锁、门关）")


func _t06_marks_in_world() -> void:
	var steps: Array = _doc.get("steps", [])
	var scan_marks := 0
	var landing_marks := 0
	var add_write := ""
	var modify_write := ""
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		var ok := bool(step.get("output", {}).get("ok", false))
		var world: Dictionary = step.get("world", {})
		var marks: Array = world.get("marks", []) if world.get("marks", []) is Array else []
		if tool == "fs.read" and ok:
			var m: Dictionary = marks[0] if marks.size() > 0 and marks[0] is Dictionary else {}
			if str(m.get("kind", "")) == "scan_fade" and not bool(m.get("persist", true)) and float(m.get("fadeSeconds", 0.0)) > 0.0:
				scan_marks += 1
		elif tool == "fs.write" and ok:
			var m: Dictionary = marks[0] if marks.size() > 0 and marks[0] is Dictionary else {}
			if str(m.get("kind", "")) == "arm_landing" and bool(m.get("persist", false)) and int(m.get("heightCells", 0)) == 1:
				landing_marks += 1
				var mode := str(step.get("output", {}).get("result", {}).get("mode", ""))
				if str((action.get("args", {}) as Dictionary).get("path", "")) == "out.txt":
					add_write = mode
				elif str((action.get("args", {}) as Dictionary).get("path", "")) == "config.yaml":
					modify_write = mode
	var ok: bool = scan_marks >= 2 and landing_marks >= 2
	ok = ok and add_write == "add" and modify_write == "modify"
	_check(ok, "T6 步记录 world 摘要带留痕：scan_fade 淡痕 %d 条（不常驻）、arm_landing 落点 %d 条（常驻一格高）；out.txt=新增、config.yaml=修改可分辨" % [scan_marks, landing_marks])


func _t07_tune_differs() -> void:
	var steps: Array = _doc.get("steps", [])
	var targets: Array = []
	var read_paths: Array = []
	var tune_level: Dictionary = {}
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		var args: Dictionary = action.get("args", {})
		if tool == WorldToolsCore.TOOL_SET_PARAM and str(args.get("key", "")) == "target_file":
			targets.append(str(args.get("value", "")))
		elif tool == "fs.read" and bool(step.get("output", {}).get("ok", false)):
			read_paths.append(str(args.get("path", "")))
		elif tool == "level.stage" and str(args.get("stage", "")) == "tune":
			tune_level = args
	var ok: bool = targets.size() == 2 and str(targets[0]) == "report.txt" and str(targets[1]) == "notes.md"
	ok = ok and read_paths.has("report.txt") and read_paths.has("notes.md")
	# 每个 set_param(target_file) 之后都有一次对同目标文件的读取
	var followed := true
	var last_target_i := -1
	for i in steps.size():
		var step: Dictionary = steps[i]
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM and str(action.get("args", {}).get("key", "")) == "target_file":
			last_target_i = i
			var want := str(action.get("args", {}).get("value", ""))
			var found := false
			for j in range(i + 1, steps.size()):
				var sj: Dictionary = steps[j]
				var aj: Dictionary = sj.get("action", {})
				if str(aj.get("tool", "")) == "fs.read" and str(aj.get("args", {}).get("path", "")) == want:
					found = true
					break
			followed = followed and found
	ok = ok and followed and last_target_i >= 0
	ok = ok and str(tune_level.get("oldTarget", "")) == "report.txt" and str(tune_level.get("newTarget", "")) == "notes.md"
	# 可视面：两次写落点都在（新增/修改颜色区分）
	var cab: Node = _scene.get_file_cabinet()
	ok = ok and cab.has_write_mark(4) and cab.get_write_mark_mode(4) == "add"
	ok = ok and cab.has_write_mark(5) and cab.get_write_mark_mode(5) == "modify"
	_check(ok, "T7 改参生效：两次 run 扫描目标不同（report.txt → notes.md，tune 记录 oldValue≠newValue），每次其后都有对该文件的读取；两处落点并存")


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
	# 效率句含本次实测 ops 与基线对照；正确性句确认读→写模式全命中（goal 校准生效）
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
	_check(ok, "T8 评分五句（rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含实测 %d ops 与基线对照、正确性句确认目标达成；score 步 output 带 sentences/evidence/scorer（llm 回退在案、args.dimensions 旧形状兼容）" % ops_sum)


## T9 负路径：读的动作只经扫描器、写的动作只经机械臂由防御强制（l2_flow 读前/写前查头）。
## 构造独立 flow：arm 头下去调 _fs_read、scanner 头下去调 _fs_write，双双被拒——
## ok=false、code=wrong_tool_head、failures 新增对应条目，且世界没被写（文件内容不变）。
func _t09_wrong_tool_head() -> void:
	var tools := _fresh_tools()
	var flow: Node = L2FlowScript.new()
	flow.tools = tools
	flow.view = null
	flow.slow_step_seconds = 0.02
	_garbage.append(flow)
	root.add_child(flow)
	flow.setup_world()
	flow.begin()
	flow.stage_install()
	var failures_before: int = (tools.recorder().get_doc().get("failures", []) as Array).size()

	# 当前头是 arm → 直接调 _fs_read：被拒（读必须经扫描器）
	await flow._switch_head(flow.CARRIER_ARM)
	var read_res: Dictionary = await flow._fs_read("report.txt")

	# 当前头是 scanner → 直接调 _fs_write：被拒（写必须经机械臂），世界不留痕
	await flow._switch_head(flow.CARRIER_SCANNER)
	var content_before := _world_file_content(flow, "config.yaml")
	var write_res: Dictionary = await flow._fs_write("config.yaml", "不应落进柜格")

	var read_denied: bool = not bool(read_res.get("ok", true)) \
		and str(read_res.get("error", {}).get("code", "")) == "wrong_tool_head"
	var write_denied: bool = not bool(write_res.get("ok", true)) \
		and str(write_res.get("error", {}).get("code", "")) == "wrong_tool_head"
	var failures: Array = tools.recorder().get_doc().get("failures", [])
	var read_fail := false
	var write_fail := false
	for f in failures:
		if str((f as Dictionary).get("code", "")) == "wrong_tool_head":
			if str((f as Dictionary).get("failId", "")) == "tool:fs.read":
				read_fail = true
			elif str((f as Dictionary).get("failId", "")) == "tool:fs.write":
				write_fail = true
	var world_intact: bool = content_before == "theme: light\nversion: 1" \
		and _world_file_content(flow, "config.yaml") == content_before \
		and _world_file_content(flow, "out.txt") == ""
	var ok: bool = read_denied and write_denied and read_fail and write_fail and world_intact \
		and failures.size() == failures_before + 2
	_check(ok, "T9 wrong_tool_head 负路径：arm 头读 / scanner 头写均 ok=false（code=wrong_tool_head）、failures 各 +1（%d→%d）、世界未被写（config.yaml 内容不变）" % [failures_before, failures.size()])


## T10 phase 分段：tune 段的 fs 步与换头步 phase=="tune"（phase 参数化后进步记录），
## run 段的 fs 步 phase 仍为 "run"。
func _t10_tune_phase() -> void:
	var fs_tune := 0
	var fs_run := 0
	var switch_tune := 0
	for s in _doc.get("steps", []):
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		var phase := str(step.get("phase", ""))
		if tool == "fs.read" or tool == "fs.write":
			if phase == "tune":
				fs_tune += 1
			elif phase == "run":
				fs_run += 1
		elif tool == "world.switch_tool_head" and phase == "tune":
			switch_tune += 1
	var ok: bool = fs_tune >= 2 and switch_tune >= 2 and fs_run >= 2
	_check(ok, "T10 phase 分段正确：tune 段 fs 步 %d 个、换头步 %d 个 phase==tune；run 段 fs 步 %d 个 phase==run" % [fs_tune, switch_tune, fs_run])


## 世界态里某文件的当前内容（柜格文件真身，写入生效与否以此为准）。
func _world_file_content(flow: Node, path: String) -> String:
	for entry in flow._cabinet_files():
		if str((entry as Dictionary).get("name", "")) == path:
			return str((entry as Dictionary).get("content", ""))
	return ""
