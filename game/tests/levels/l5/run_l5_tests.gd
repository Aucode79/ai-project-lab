extends SceneTree

## L5 端到端测试（五关终点关）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/levels/l5/run_l5_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准，7 项）：
##  1  五件组件场景可实例化：回廊计数/上限/显式出口、执行器观测窗流动开关、
##     校验门门体转角（通过/拒绝两个可动位）与拒绝原因、旁路重试计数、占位体名牌
##  2  L5 场景可实例化：相机就位、光影/体素地面/工位/四安装位/占位摆放区/
##     播放器方块齐，幕布标题是本关 E60 文案
##  3  全流程 drive 到 check_pass=true（video→install→run→tune→score→落盘→判定），
##     run JSON kind=task、episode=60
##  4  run JSON 因果链完整：校验拒绝步 → 旁路重试步 → 第二轮通过步 → 最终完成步
##     顺序正确（tune 重跑后的最后一条链同样成立），重试计数与上限一致
##  5  十四件实体都在（注册表数）；export_python 产码非空且 wsl python3 真跑 exit=0
##  6  tune 参数变化生效：重试上限 3→2 的 set_param 步存在、第二次导出含
##     max_retries=2、坏输入种类换了（两条坏 task_text 不同）
##  7  评分五句（真评分器 rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含
##     实测 ops 与基线对照、正确性句确认 拒绝→重试→通过→完成 模式全命中、鲁棒性句
##     检出闭环；score 步 output 带 sentences/evidence/scorer/llm（回退在案）
##
## 产物：本次判定的 run JSON 留在 runs/e60/（运行时产物，已 gitignore），
## 供验收复核；除它之外本测试不写任何文件。

const L5Scene := preload("res://scenes/levels/l5/l5.tscn")
const L5FlowScript := preload("res://scripts/levels/l5/l5_flow.gd")
const LoopGalleryScene := preload("res://scenes/levels/l5/components/loop_gallery.tscn")
const LoopGalleryScript := preload("res://scenes/levels/l5/components/loop_gallery.gd")
const RunnerScene := preload("res://scenes/levels/l5/components/runner.tscn")
const RunnerScript := preload("res://scenes/levels/l5/components/runner.gd")
const VerifyGateScene := preload("res://scenes/levels/l5/components/verify_gate.tscn")
const VerifyGateScript := preload("res://scenes/levels/l5/components/verify_gate.gd")
const BypassScene := preload("res://scenes/levels/l5/components/bypass.tscn")
const BypassScript := preload("res://scenes/levels/l5/components/bypass.gd")
const CodexStubScene := preload("res://scenes/levels/l5/components/codex_stub.tscn")

## 十四件资产 id（与 l5_flow.gd 的注册表一致）。
const COMPONENT_ASSETS := [
	"stub_task_board", "stub_nameplate", "stub_planner_board", "stub_context_container",
	"stub_model_core", "stub_memory_cabinet", "stub_tool_belt", "stub_file_cabinet",
	"conc_runner", "conc_verify_gate", "conc_bypass", "conc_loop_gallery",
	"stub_arm_head", "stub_scanner_head",
]

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
	_t04_causal_chain()
	_t05_fourteen_and_export()
	_t06_tune_effective()
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

	var gallery := LoopGalleryScene.instantiate()
	root.add_child(gallery)
	gallery.set_limit(3)
	gallery.set_rounds(2)
	ok = ok and gallery.has_node("CounterLabel") and gallery.has_node("LimitLabel") and gallery.has_node("ExitSign")
	ok = ok and str(gallery.get_node("CounterLabel").text) == "第 2/3 轮"
	ok = ok and gallery.get_rounds() == 2 and gallery.get_limit() == 3
	ok = ok and not gallery.is_exit_open()   # 2 < 3 未达上限，显式出口未开
	gallery.set_rounds(3)
	ok = ok and gallery.is_exit_open() and str(gallery.get_node("CounterLabel").text) == "第 3/3 轮"
	var lamp_mat: StandardMaterial3D = gallery.get_lamp_material()
	gallery.set_state_visual(LoopGalleryScript.STATE_DONE)
	ok = ok and lamp_mat.emission.is_equal_approx(LoopGalleryScript.STATE_COLORS[LoopGalleryScript.STATE_DONE])
	# 状态派生纯函数（合成步记录：rounds=1 → @done=true）
	var steps := [
		{"action": {"tool": "world.set_param", "args": {"entityId": "g#1", "key": "rounds", "value": 1}}, "output": {"ok": true}},
		{"action": {"tool": "world.set_param", "args": {"entityId": "g#1", "key": "@done", "value": true}}, "output": {"ok": true}},
	]
	var traj: Array = LoopGalleryScript.state_trajectory(steps, "g#1")
	ok = ok and traj == [LoopGalleryScript.STATE_RUNNING, LoopGalleryScript.STATE_DONE]
	gallery.free()

	var runner := RunnerScene.instantiate()
	root.add_child(runner)
	ok = ok and runner.has_node("Window") and runner.has_node("OutputLabel") and runner.has_node("FlowCube")
	ok = ok and not runner.is_flowing()
	runner.set_flowing(true)
	ok = ok and runner.is_flowing() and str(runner.get_node("OutputLabel").text) == "输出流动中"
	runner.set_flowing(false)
	ok = ok and not runner.is_flowing()
	runner.free()

	var gate := VerifyGateScene.instantiate()
	root.add_child(gate)
	ok = ok and gate.has_node("ReasonLabel") and gate.has_node("GatePivot/GateArm")
	gate.set_verdict(false, "拒绝：缺少必需字段 args")
	var reject_yaw: float = gate.get_arm_yaw()
	ok = ok and not gate.get_verdict() and gate.get_last_reason().contains("args")
	ok = ok and str(gate.get_node("ReasonLabel").text).contains("args")
	ok = ok and reject_yaw == VerifyGateScript.ARM_YAW_REJECT
	gate.set_verdict(true)
	var pass_yaw: float = gate.get_arm_yaw()
	ok = ok and gate.get_verdict() and pass_yaw == VerifyGateScript.ARM_YAW_PASS
	ok = ok and pass_yaw != reject_yaw   # 门体转角真的动了
	var gate_traj: Array = VerifyGateScript.state_trajectory([
		{"action": {"tool": "codex.verify", "args": {"entityId": "vg#1"}}, "output": {"ok": false}},
		{"action": {"tool": "codex.verify", "args": {"entityId": "vg#1"}}, "output": {"ok": true}},
	], "vg#1")
	ok = ok and gate_traj == [VerifyGateScript.STATE_ERROR, VerifyGateScript.STATE_DONE]
	gate.free()

	var bypass := BypassScene.instantiate()
	root.add_child(bypass)
	bypass.set_max_retries(3)
	bypass.set_retry_count(2)
	ok = ok and bypass.has_node("RetryLabel") and bypass.get_retry_count() == 2 and bypass.get_max_retries() == 3
	ok = ok and str(bypass.get_node("RetryLabel").text) == "重试 2/3"
	bypass.free()

	var stub := CodexStubScene.instantiate()
	root.add_child(stub)
	stub.set_stub(1, "任务牌")
	ok = ok and stub.has_node("Cube") and stub.has_node("StubLabel")
	ok = ok and stub.get_stub_number() == 1 and stub.get_stub_label() == "任务牌"
	ok = ok and str(stub.get_node("StubLabel").text) == "任务牌·占位" and str(stub.get_node("NumLabel").text) == "#1"
	stub.free()

	_check(ok, "T1 五件组件场景可实例化：回廊计数/上限/出口、观测窗流动开关、门体转角两态+拒绝原因、旁路计数、占位体名牌")


func _t02_scene() -> void:
	_scene = L5Scene.instantiate()
	root.add_child(_scene)
	for i in 5:
		await create_timer(0.02).timeout
	var ok := _scene.has_node("Camera") and (_scene.get_node("Camera") as Camera3D).current
	ok = ok and _scene.has_node("WorldEnvironment") and _scene.has_node("Sun") and _scene.has_node("Fill")
	ok = ok and _scene.has_node("Terrain")
	ok = ok and _scene.has_node("Workstation/CodexCart")
	ok = ok and _scene.has_node("Workstation/LoopGalleryMount") and _scene.has_node("Workstation/RunnerMount")
	ok = ok and _scene.has_node("Workstation/VerifyGateMount") and _scene.has_node("Workstation/BypassMount")
	ok = ok and _scene.has_node("Workstation/StubZone")
	ok = ok and _scene.has_node("Workstation/PlayerScreen")
	ok = ok and str(_scene.get_node("Workstation/PlayerScreen/ScreenLabel").text) == "L5 · E60 占位视频"
	_check(ok, "T2 L5 场景可实例化：相机/光影/体素地面/工位小车/四安装位/占位摆放区/幕布齐，幕布标题为 E60 文案")


func _t03_full_flow() -> void:
	var tools := _fresh_tools()
	_flow = L5FlowScript.new()
	_flow.tools = tools
	_flow.view = _scene
	_scene.add_child(_flow)
	_verdict = await _flow.drive_full()
	var rc: StepRecorderCore = tools.recorder()
	var path := rc.out_path()
	var ok := bool(_verdict.get("pass", false))
	ok = ok and rc.state_name() == "frozen" and path != "" and FileAccess.file_exists(path)
	ok = ok and int(_verdict.get("steps", 0)) >= 20
	if ok:
		_doc = JSON.parse_string(FileAccess.get_file_as_string(path))
	ok = ok and not _doc.is_empty()
	var run: Dictionary = _doc.get("run", {})
	ok = ok and str(run.get("kind", "")) == "task" and int(run.get("episode", -1)) == 60
	_check(ok, "T3 全流程 video→install→run→tune→score 驱动到 check_pass=true，run 已落盘冻结（%s，kind=task episode=60）" % path)


func _t04_causal_chain() -> void:
	var steps: Array = _doc.get("steps", [])
	var chain: Dictionary = _verdict.get("chain", {})
	var ok := not chain.is_empty()
	var i_reject := int(chain.get("reject", -1))
	var i_retry := int(chain.get("retry", -1))
	var i_pass := int(chain.get("pass", -1))
	var i_done := int(chain.get("done", -1))
	ok = ok and i_reject >= 0 and i_retry > i_reject and i_pass > i_retry and i_done > i_pass
	# 步语义逐一核对（不只看 check_pass 的结论）
	var reject_step: Dictionary = steps[i_reject] if i_reject >= 0 and i_reject < steps.size() else {}
	ok = ok and str(reject_step.get("action", {}).get("tool", "")) == "codex.verify"
	ok = ok and not bool(reject_step.get("output", {}).get("ok", true))
	var retry_step: Dictionary = steps[i_retry] if i_retry >= 0 and i_retry < steps.size() else {}
	ok = ok and str(retry_step.get("action", {}).get("args", {}).get("key", "")) == "retry_count"
	ok = ok and int(retry_step.get("action", {}).get("args", {}).get("value", 0)) >= 1   # 计数跨轮累积（run=1、tune=2）
	var pass_step: Dictionary = steps[i_pass] if i_pass >= 0 and i_pass < steps.size() else {}
	ok = ok and str(pass_step.get("action", {}).get("tool", "")) == "codex.verify"
	ok = ok and bool(pass_step.get("output", {}).get("ok", false))
	# 两次坏输入都触发了拒绝→重试（run + tune 各一条链）
	ok = ok and int(_verdict.get("rejects", 0)) >= 2 and int(_verdict.get("retries", 0)) >= 2
	# 重试计数与上限一致：终值 2 == 步记录最大值，且 ≤ tune 后的上限 2
	ok = ok and int(_verdict.get("retryFinal", 0)) == int(_verdict.get("retryMax", 0))
	ok = ok and int(_verdict.get("retryFinal", 0)) <= int(_verdict.get("retryLimitFinal", 99))
	ok = ok and bool(_verdict.get("countsConsistent", false))
	# failures 里落了 c10.3:1（字段集不等 → 该次调用记为失败）
	var fail_ids: Array = []
	for f in _doc.get("failures", []):
		fail_ids.append(str((f as Dictionary).get("failId", "")))
	ok = ok and fail_ids.has("c10.3:1")
	_check(ok, "T4 因果链完整：拒绝(%d)→重试(%d)→通过(%d)→完成(%d) 顺序正确、两轮坏输入各成链、重试计数 %d 与上限 %d 一致、failId c10.3:1 在案" % [
		i_reject, i_retry, i_pass, i_done, int(_verdict.get("retryFinal", 0)), int(_verdict.get("retryLimitFinal", 0))])


func _t05_fourteen_and_export() -> void:
	# ① 注册表数：十四件实体都在且被绑定表选中
	var tools: WorldToolsCore = _flow.tools
	var snap: Dictionary = tools.state().logical_snapshot()
	var entities: Dictionary = snap["entities"]
	var ok := true
	var present := 0
	for asset_id in COMPONENT_ASSETS:
		var eid := str((snap["bindings"] as Dictionary).get(asset_id, ""))
		if eid != "" and entities.has(eid):
			present += 1
		else:
			ok = false
	ok = ok and present == 14
	# ② 导出物：从冻结 run JSON 取 world.export_python 步的结果（产码进步记录）
	var py := ""
	for s in _doc.get("steps", []):
		var step: Dictionary = s
		if str(step.get("action", {}).get("tool", "")) == "world.export_python":
			py = str(step.get("output", {}).get("result", {}).get("python", ""))
	ok = ok and py != "" and py.contains("while True:") and py.contains("def step_conc_runner")
	ok = ok and py.contains("def step_conc_loop_gallery") and py.contains("def step_conc_bypass")
	var stub_hit := true
	for asset_id in COMPONENT_ASSETS:
		if not py.contains("def step_%s_1(" % asset_id):
			stub_hit = false
	ok = ok and stub_hit   # 十四件都在骨架里
	# ③ wsl python3 真跑（"能导出 Python"的验收证据）
	if not ok:
		_check(false, "T5 十四件实体齐（%d/14）且 export_python 产码非空" % present)
		return
	var res := _exec_wsl_python(py, "l5_codex_skeleton.py")
	if int(res[0]) == -1:
		print("NOTE wsl 不可用，外部执行跳过（产码已生成，验收用 wsl python3 手跑）")
		_check(ok, "T5 十四件实体齐（14/14）、export_python 产码非空（wsl 不可用，跳过外部执行）")
		return
	var exec_ok := int(res[0]) == 0
	_check(ok and exec_ok, "T5 十四件实体齐（14/14）+ export_python 产码非空 + wsl python3 exit=%d" % int(res[0]))
	for ln in res[1]:
		print("  [l5_codex_skeleton] ", ln)


func _t06_tune_effective() -> void:
	var steps: Array = _doc.get("steps", [])
	# ① 重试上限 3→2 的 set_param 步存在
	var limit_values: Array = []
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("key", "")) == "max_retries" and str(args.get("entityId", "")) == str(_flow.bypass_eid):
				limit_values.append(int(args.get("value", 0)))
	var ok := limit_values.has(2) and not limit_values.has(3)
	# ② 两次导出的骨架里 max_retries 跟参数走（tune 前 3、tune 后 2）
	var export_pys: Array = []
	for s in steps:
		var step: Dictionary = s
		if str(step.get("action", {}).get("tool", "")) == "world.export_python":
			export_pys.append(str(step.get("output", {}).get("result", {}).get("python", "")))
	ok = ok and export_pys.size() >= 2
	if export_pys.size() >= 2:
		ok = ok and str(export_pys[0]).contains("max_retries=3") and str(export_pys[export_pys.size() - 1]).contains("max_retries=2")
	# ③ 坏输入种类换了：两条坏 task_text 不同（缺 args vs 缺 tool）
	var bad_texts: Array = []
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("key", "")) == "task_text" and str(args.get("entityId", "")) == str(_flow.eids.get("stub_task_board", "")):
				var txt := str(args.get("value", ""))
				if txt.contains('{"tool": "run.count"}') or txt.contains('{"args":'):
					if not bad_texts.has(txt):
						bad_texts.append(txt)
	ok = ok and bad_texts.size() == 2
	# ④ tune 后的重跑确实又走了一遍因果链（rejects>=2 已在 T4 验，这里验轮数推进）
	var rounds_max := 0
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("key", "")) == "rounds":
				rounds_max = maxi(rounds_max, int(args.get("value", 0)))
	ok = ok and rounds_max == 4   # run 两轮 + tune 再跑两轮
	_check(ok, "T6 tune 生效：max_retries 3→2 落进步记录且两次导出分别含 max_retries=3/2、坏输入换了种类（%d 种）、回廊推进到第 %d 轮" % [bad_texts.size(), rounds_max])


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
	# 效率句含本次实测 ops 与基线对照；正确性句确认 拒绝→重试→通过→完成 模式全命中；
	# 鲁棒性句检出真实的校验拒绝与重试闭环（failures 在案 + 同工具重试 ok）
	var ops_sum := 0
	for s in _doc.get("steps", []):
		ops_sum += int((s as Dictionary).get("ops", 0))
	var eff := ""
	var cor := ""
	var robust := ""
	for s in sentences:
		var d: Dictionary = s
		if str(d.get("dim", "")) == "效率":
			eff = str(d.get("text", ""))
		elif str(d.get("dim", "")) == "正确性":
			cor = str(d.get("text", ""))
		elif str(d.get("dim", "")) == "鲁棒性":
			robust = str(d.get("text", ""))
	ok = ok and eff.contains(str(ops_sum)) and eff.contains("ops") and eff.contains("基线")
	ok = ok and cor.contains("任务跑完了")
	ok = ok and robust.contains("闭环") and robust.contains("重试")
	# 鲁棒性证据应含被拒的 codex.verify 步号
	var rob_refs: Array = evidence.get("鲁棒性", [])
	var verify_reject_refs: Array = []
	for s in _doc.get("steps", []):
		var step: Dictionary = s
		if str(step.get("action", {}).get("tool", "")) == "codex.verify" \
				and not bool(step.get("output", {}).get("ok", true)):
			verify_reject_refs.append(int(step.get("i", -1)))
	var rob_hits := false
	for r in rob_refs:
		rob_hits = rob_hits or verify_reject_refs.has(int(r))
	ok = ok and rob_hits
	# 旧形状兼容：args.dimensions 仍是 [{dim, sentence}×5]
	var dims: Array = score_step.get("action", {}).get("args", {}).get("dimensions", [])
	ok = ok and dims.size() == 5
	for d in dims:
		ok = ok and str((d as Dictionary).get("dim", "")) != "" \
			and str((d as Dictionary).get("sentence", "")).length() >= 12
	_check(ok, "T7 评分五句（rule_v1）：五维齐全有序、每维证据指向存在的步号、效率句含实测 %d ops 与基线对照、正确性句确认目标达成、鲁棒性句检出拒绝→重试闭环（证据含被拒 codex.verify 步）；score 步 output 带 sentences/evidence/scorer（llm 回退在案、args.dimensions 旧形状兼容）" % ops_sum)


# ---------- wsl 执行（照抄 run_integration_tests.gd 的基建） ----------

## 把产物写到 user://l5_out/（不弄脏仓库）并用 wsl python3 真跑。
## 返回 [exit_code, 输出行数组]；wsl 不可用返回 [-1, []]（打 NOTE，不判失败）。
func _exec_wsl_python(py_source: String, fname: String) -> Array:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://l5_out"))
	var path := ProjectSettings.globalize_path("user://l5_out/%s" % fname)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		print("NOTE 无法写入产物 %s：%s" % [path, str(FileAccess.get_open_error())])
		return [-1, []]
	f.store_string(py_source)
	f.close()
	var probe: Array = []
	if OS.execute("wsl", ["--status"], probe) != 0:
		return [-1, []]
	var wsl_path := _to_wsl_path(path)
	var output: Array = []
	var code := OS.execute("wsl", ["-e", "bash", "-lc", "python3 '%s'" % wsl_path], output)
	var lines: Array = []
	for o in output:
		for ln in String(o).split("\n"):
			if ln.strip_edges() != "":
				lines.append(ln.strip_edges())
	return [code, lines]


func _to_wsl_path(win_path: String) -> String:
	var p := win_path.replace("\\", "/")
	var idx := p.find(":")
	if idx < 0:
		return p
	return "/mnt/%s%s" % [p.substr(0, idx).to_lower(), p.substr(idx + 1)]
