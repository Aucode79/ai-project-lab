extends SceneTree

## 评分器测试（五维诊断 / 另一实例结构 / goals / LLM 预留接口）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/scoring/run_scoring_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 输入：合成的一份 L1 形状 run JSON（16 步 / 220 ops / 2 次 world.run，
## 与 runs/e49 实测同构）；若 runs/e49 有真实 run JSON 则加测一份（T11）。
## 覆盖（验收标准）：
##  1  L1 形状 run → 五句、每句有 dim 与至少一个 stepRef（且指向存在的步号）
##  2  缺 phase 的 run → 正确性句点名缺失阶段
##  3  高 ops 的 run → 效率句含数字对比（实际 vs 基线）
##  4  有 failures 的 run → 鲁棒性句指向失败步
##  5  干净 run → 无编话（中性句；句中"第 N 步"都在记录里）
##  6  llm_bridge 报 NOT_IMPLEMENTED 后回退规则评分成功
##  7  五关 goal 全部非空且键合法
##  8  输出可 JSON 序列化（将来进步记录用）
##  9  可读性机制：任务描述缺关键词 / caption 缺失被点名
## 本测试不写任何文件。

const Scorer := preload("res://scripts/scoring/five_dim_scorer.gd")
const Service := preload("res://scripts/scoring/scorer_service.gd")
const Bridge := preload("res://scripts/scoring/llm_bridge.gd")
const Goals := preload("res://scripts/scoring/goals.gd")

const BOARD := "conc_task_board#1"
const PLATE := "conc_nameplate#1"
const TASK_1 := "读取 report.txt 并数出'错误'出现次数"
const TASK_2 := "把 report.txt 里的'错误'全部替换成'warning'，另存为 report_fixed.txt"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("== 评分器测试（五维诊断 / rule_v1）==")
	var run := _l1_run()
	var goal: Dictionary = Goals.goal_for("L1")
	var out: Dictionary = Scorer.new().score(run, goal)
	for s in out["sentences"]:
		var d: Dictionary = s
		print("  [%s] %s" % [d["dim"], d["text"]])
	_t01_five_sentences(out)
	_t02_evidence_valid(out, run)
	_t03_missing_phase(run, goal)
	_t04_high_ops(run, goal)
	_t05_failures(run, goal)
	_t06_clean_run(out)
	_t07_llm_bridge(run, goal)
	_t08_goals()
	_t09_json_serializable(out)
	_t10_readability(run, goal)
	_t11_real_run_if_any()
	print("")
	print("结果：PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(cond: bool, label: String) -> bool:
	if cond:
		_pass += 1
		print("PASS: " + label)
	else:
		_fail += 1
		print("FAIL: " + label)
	return cond


# ---------- 合成输入（与 runs/e49 实测同构） ----------

func _step(i: int, phase: String, actor: String, tool: String, args: Dictionary,
		caption: String, ops: int) -> Dictionary:
	return {
		"i": i,
		"t": 0.0,
		"phase": phase,
		"actor": actor,
		"causes": [i - 1] if i > 0 else [],
		"input": {},
		"action": {"tool": tool, "args": args},
		"output": {"ok": true},
		"tokens": 0,
		"ops": ops,
		"costMs": 0.01,
		"world": {"entities": {}, "highlight": []},
		"caption": caption,
		"formula": "",
	}


func _l1_run() -> Dictionary:
	var steps: Array = [
		_step(0, "build", "level", "world.place",
			{"assetId": "player_screen", "pos": [4, 0, -2]},
			"幕布方块就位（player_ 展示方块，占位内容）", 20),
		_step(1, "video", "level", "level.stage",
			{"stage": "video", "episode": 49, "content": "placeholder"},
			"幕布亮起：L1 · E49 占位视频（占位内容，不引真视频）", 0),
		_step(2, "build", "player", "world.place",
			{"assetId": "conc_task_board", "pos": [-2, 0, -1]},
			"装上任务牌（conc_task_board）", 20),
		_step(3, "build", "player", "world.place",
			{"assetId": "conc_nameplate", "pos": [-3, 0, -2]},
			"装上角色铭牌（conc_nameplate，任务牌背面）", 20),
		_step(4, "build", "player", "world.connect",
			{"from": PLATE + ":identity_out", "to": BOARD + ":task_in"},
			"连线：identity_out -> task_in", 20),
		_step(5, "install", "level", "level.stage",
			{"stage": "install", "components": ["conc_task_board", "conc_nameplate"]},
			"两件组件装上：任务牌 + 角色铭牌，绑定表就位", 0),
		_step(6, "build", "player", "world.set_param",
			{"entityId": BOARD, "key": "task_text", "value": TASK_1},
			"学员给 codex 下了一条任务", 20),
		_step(7, "build", "codex", "world.set_param",
			{"entityId": PLATE, "key": "@identity_out", "value": 1.0},
			"codex 报身份：铭牌 identity_out=1", 20),
		_step(8, "build", "codex", "world.set_param",
			{"entityId": BOARD, "key": "@task_out", "value": 1.0},
			"codex 接活：任务牌 task_out=1（灯翻'正在'）", 20),
		_step(9, "run", "codex", "world.run", {},
			"codex 在任务牌前执行：任务沿连线被接下（task_in=1.0）", 20),
		_step(10, "run", "level", "level.stage",
			{"stage": "run", "taskText": TASK_1},
			"任务被接下：task_in=1.0，任务牌翻'完成'", 0),
		_step(11, "build", "player", "world.set_param",
			{"entityId": BOARD, "key": "task_text", "value": TASK_2},
			"改一个参数：换一条任务", 20),
		_step(12, "tune", "level", "level.stage",
			{"stage": "tune", "taskText": TASK_2},
			"改参重跑：task_text 已换，看两版差异", 0),
		_step(13, "build", "codex", "world.set_param",
			{"entityId": BOARD, "key": "@task_out", "value": 0.0},
			"上一单交付，task_out 复位", 20),
		_step(14, "run", "codex", "world.run", {},
			"换参后再跑一遍：同一装置，不同任务", 20),
		_step(15, "score", "level", "level.score",
			{"stub": true, "dimensions": []},
			"五维诊断已出（评分 stub：真实评分器后续接入）", 0),
	]
	return {
		"schemaVersion": 6,
		"run": {
			"runId": "rTEST-001", "kind": "task", "episode": 49,
			"seed": 20260914, "rulesetVersion": "world-kernel/1",
			"engineHash": "godot-4.7.2-stable-test", "startedAt": "2026-09-14T00:00:00Z",
		},
		"steps": steps,
		"failures": [],
	}


func _sentence_of(out: Dictionary, dim: String) -> String:
	for s in out.get("sentences", []):
		var d: Dictionary = s
		if str(d.get("dim", "")) == dim:
			return str(d.get("text", ""))
	return ""


func _evidence_of(out: Dictionary, dim: String) -> Array:
	return (out.get("evidence", {}) as Dictionary).get(dim, [])


func _valid_step_numbers(run: Dictionary) -> Array:
	var out: Array = []
	for s in run.get("steps", []):
		out.append(int((s as Dictionary).get("i", -1)))
	return out


# ---------- 测试 ----------

func _t01_five_sentences(out: Dictionary) -> void:
	var sentences: Array = out.get("sentences", [])
	var ok := sentences.size() == 5 and str(out.get("scorer", "")) == "rule_v1"
	var want := ["正确性", "结构", "效率", "鲁棒性", "可读性"]
	for i in sentences.size():
		var d: Dictionary = sentences[i]
		ok = ok and str(d.get("dim", "")) == str(want[i])
		ok = ok and str(d.get("text", "")).length() >= 12
	_check(ok, "T1 五句诊断：五维齐全有序、每句 ≥12 字、scorer=rule_v1")


func _t02_evidence_valid(out: Dictionary, run: Dictionary) -> void:
	var valid := _valid_step_numbers(run)
	var ok := true
	for dim in ["正确性", "结构", "效率", "鲁棒性", "可读性"]:
		var ev := _evidence_of(out, str(dim))
		ok = ok and not ev.is_empty()
		for r in ev:
			ok = ok and valid.has(int(r))
	_check(ok, "T2 证据绑定：每维至少一个 stepRef 且全部指向存在的步号")


func _t03_missing_phase(run: Dictionary, goal: Dictionary) -> void:
	var broken: Dictionary = run.duplicate(true)
	var kept: Array = []
	for s in broken["steps"]:
		if str((s as Dictionary).get("phase", "")) != "run":
			kept.append(s)
	broken["steps"] = kept
	var out: Dictionary = Scorer.new().score(broken, goal)
	var text := _sentence_of(out, "正确性")
	var ok := text.contains("没有跑完") and text.contains("run")
	_check(ok, "T3 缺 phase：正确性句点名缺失阶段 run（%s）" % text)


func _t04_high_ops(run: Dictionary, goal: Dictionary) -> void:
	var fat: Dictionary = run.duplicate(true)
	for s in fat["steps"]:
		var step: Dictionary = s
		step["ops"] = int(step.get("ops", 0)) * 3  # 220 × 3 = 660
	var out: Dictionary = Scorer.new().score(fat, goal)
	var text := _sentence_of(out, "效率")
	var ok := text.contains("660") and text.contains("220") and text.contains("基线")
	_check(ok, "T4 高 ops：效率句含数字对比 660 vs 基线 220（%s）" % text)


func _t05_failures(run: Dictionary, goal: Dictionary) -> void:
	var bad: Dictionary = run.duplicate(true)
	bad["failures"] = [{
		"stepRef": 14, "failId": "tool:world.run",
		"code": "bad_input", "diagnosis": "坏输入直接进了执行",
	}]
	var out: Dictionary = Scorer.new().score(bad, goal)
	var text := _sentence_of(out, "鲁棒性")
	var ev := _evidence_of(out, "鲁棒性")
	var ok := text.contains("第 14 步") and text.contains("校验") and not text.contains("重试接上")
	ok = ok and ev.has(14)
	_check(ok, "T5 有 failures：鲁棒性句指向失败步第 14 步且给出校验指引（%s）" % text)


func _t06_clean_run(out: Dictionary) -> void:
	var ok := true
	var neutral_count := 0
	for s in out.get("sentences", []):
		var text := str((s as Dictionary).get("text", ""))
		if text.contains("看不出"):
			neutral_count += 1
		if text.contains("崩") or text.contains("缺"):
			ok = false
	ok = ok and neutral_count >= 1
	ok = ok and _sentence_of(out, "正确性").contains("任务跑完了")
	ok = ok and _sentence_of(out, "效率").contains("220")
	_check(ok, "T6 干净 run：无编话（无『崩/缺』、有中性句）、正确性确认跑完、效率句含实测 220 ops")


func _t07_llm_bridge(run: Dictionary, goal: Dictionary) -> void:
	var bridge := Bridge.new()
	var direct: Dictionary = bridge.score_with_llm(run, goal)
	var ok := not bool(direct.get("ok", true)) and str(direct.get("code", "")) == "NOT_IMPLEMENTED"
	var svc_out: Dictionary = Service.new().score(run, goal)
	var llm_info: Dictionary = svc_out.get("llm", {})
	ok = ok and (svc_out.get("sentences", []) as Array).size() == 5
	ok = ok and str(svc_out.get("scorer", "")) == "rule_v1"
	ok = ok and bool(llm_info.get("fallback", false))
	ok = ok and str(llm_info.get("reason", "")) == "NOT_IMPLEMENTED"
	_check(ok, "T7 llm_bridge 报 NOT_IMPLEMENTED 后 ScorerService 回退规则评分成功（5 句、scorer=rule_v1）")


func _t08_goals() -> void:
	var ok := (Goals.LEVEL_IDS as Array).size() == 5
	for id in Goals.LEVEL_IDS:
		var g: Dictionary = Goals.goal_for(str(id))
		ok = ok and not g.is_empty() and g.size() >= 15
		var problems: Array = Goals.validate(g)
		if not problems.is_empty():
			print("    %s 校验问题：%s" % [str(id), "；".join(problems)])
			ok = false
	_check(ok, "T8 五关 goal（L1–L5）全部非空且键合法（validate 零问题）")


func _t09_json_serializable(out: Dictionary) -> void:
	var text := JSON.stringify(out)
	var back = JSON.parse_string(text)
	var ok: bool = back is Dictionary
	if ok:
		var b: Dictionary = back
		var sentences: Array = b.get("sentences", [])
		ok = sentences.size() == 5
		for i in sentences.size():
			var orig: Dictionary = (out["sentences"] as Array)[i]
			var rt: Dictionary = sentences[i]
			ok = ok and str(orig.get("dim", "")) == str(rt.get("dim", ""))
			ok = ok and str(orig.get("text", "")) == str(rt.get("text", ""))
		ok = ok and str(b.get("scorer", "")) == "rule_v1"
		ok = ok and (b.get("evidence", {}) as Dictionary).size() == 5
	_check(ok, "T9 输出可 JSON 序列化：序列化→回读同形状（5 句 / evidence 5 键 / scorer）")


func _t10_readability(run: Dictionary, goal: Dictionary) -> void:
	# a) 任务描述缺关键短语被点名
	var g2: Dictionary = goal.duplicate(true)
	g2["task_must_mention"] = ["输出写到哪"]
	var out_kw: Dictionary = Scorer.new().score(run, g2)
	var kw_text := _sentence_of(out_kw, "可读性")
	var ok_a := kw_text.contains("输出写到哪") and kw_text.contains("接手的人要猜")
	_check(ok_a, "T10a 可读性关键词：任务描述没说『输出写到哪』被点名（%s）" % kw_text)
	# b) caption 覆盖率不足被点名
	var bare: Dictionary = run.duplicate(true)
	for s in bare["steps"]:
		var step: Dictionary = s
		if int(step.get("i", -1)) >= 7 and int(step.get("i", -1)) <= 11:
			step["caption"] = ""
	var out_cap: Dictionary = Scorer.new().score(bare, goal)
	var cap_text := _sentence_of(out_cap, "可读性")
	var cap_ev := _evidence_of(out_cap, "可读性")
	var ok_b := cap_text.contains("说明文字") and cap_ev.size() == 5
	_check(ok_b, "T10b caption 覆盖率：5 步无说明被点名且证据指向这 5 步（%s）" % cap_text)


func _t11_real_run_if_any() -> void:
	# 真实 run JSON（运行时产物，可能不存在）：存在则加测一份，不存在跳过。
	var dir_path := "res://runs/e49"
	var names: Array = []
	var dir := DirAccess.open(dir_path)
	if dir != null:
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if name.ends_with(".json"):
				names.append(name)
			name = dir.get_next()
		dir.list_dir_end()
	if names.is_empty():
		print("SKIP: T11 runs/e49 无真实 run JSON（运行时产物未生成），跳过")
		return
	names.sort()
	var text := FileAccess.get_file_as_string(dir_path + "/" + str(names[0]))
	var run = JSON.parse_string(text)
	if not (run is Dictionary):
		_check(false, "T11 真实 run JSON 可解析（%s）" % str(names[0]))
		return
	var out: Dictionary = Scorer.new().score(run, Goals.goal_for("L1"))
	var valid := _valid_step_numbers(run)
	var ok: bool = (out.get("sentences", []) as Array).size() == 5
	for dim in ["正确性", "结构", "效率", "鲁棒性", "可读性"]:
		for r in _evidence_of(out, str(dim)):
			ok = ok and valid.has(int(r))
	_check(ok, "T11 真实 run JSON（%s）也能出五句且证据指向存在的步号" % str(names[0]))
