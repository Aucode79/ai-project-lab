class_name FiveDimScorer
extends RefCounted

## 五维诊断评分器（rule_v1）——纯逻辑，不挂场景，headless 可测。
##
## 输入只有两样冻结数据（mini-codex §4.1：评分 = 拿步记录与任务目标比对）：
##   run        完整 run JSON（spec §6 schema v6：run/steps/failures）
##   task_goal  本关目标的机器可读描述（goals.gd 的形状，键义见其头注）
## 输出（可直接 JSON 序列化，将来进步记录用）：
##   { sentences: [{dim, text} × 5], evidence: {dim: [stepRef…]}, scorer: "rule_v1" }
##
## 隔离铁律（交互方案 §七：评分不能自己判自己）：本文件与被评任务的执行代码
## （levels/、core/、compiler/）零共享——工具名等常量在本包自带字符串副本，
## 不 import 执行侧任何类；判定只读 run JSON 本身（spec §6：判定不需要重跑世界）。
##
## 五维口径 v1（确定性规则）：
##   正确性  必经 phase / 禁止工具 / 期望动作模式 / 期望遍数 → 终态是否达成
##   结构    install 组件齐不齐、阶段顺序、重复堆叠、一锅烩
##   效率    ops 总量（从 steps 逐条实算）对比基线、重复读取定位
##   鲁棒性  failures 与重试闭环、坏输入是否先过校验门
##   可读性  task_text 具体性、caption 覆盖率
## 拿不出证据的维度给中性句（"这一版看不出问题"），绝不编话；
## 每句至少绑定一个存在的步号（stepRef 取步记录的 i 字段）。

const Templates := preload("res://scripts/scoring/sentence_templates.gd")

const DIMS := ["正确性", "结构", "效率", "鲁棒性", "可读性"]
const SCORER_ID := "rule_v1"

# 工具名副本：执行侧 kernel 有同名常量，这里自带字符串副本以维持零共享。
const TOOL_PLACE := "world.place"
const TOOL_SET_PARAM := "world.set_param"
const TOOL_RUN := "world.run"
const TOOL_PYTHON := "run.python"
const READ_TOOLS := ["fs.read", "world.read", "world.inspect", "world.snapshot"]

const STACK_REPEAT_MIN := 3
const CAPTION_COVER_MIN := 0.8
const MIN_TASK_TEXT_LEN := 6


## 主入口：run + task_goal → 五句诊断 + 证据。
func score(run: Dictionary, task_goal: Dictionary) -> Dictionary:
	var steps: Array = run.get("steps", [])
	var sentences: Array = []
	var evidence: Dictionary = {}
	for dim in DIMS:
		var d: Dictionary = _score_dim(str(dim), run, steps, task_goal)
		var refs: Array = _clean_refs(d.get("refs", []), steps)
		if refs.is_empty() and not steps.is_empty():
			# 中性句也绑定一个存在的步号：绑定整份记录的最后一步。
			refs = [_ref_of(steps[steps.size() - 1], steps.size() - 1)]
		evidence[str(dim)] = refs
		sentences.append({"dim": str(dim), "text": str(d.get("text", ""))})
	return {"sentences": sentences, "evidence": evidence, "scorer": SCORER_ID}


# ---------- 维度分派 ----------

func _score_dim(dim: String, run: Dictionary, steps: Array, goal: Dictionary) -> Dictionary:
	match dim:
		"正确性":
			return _dim_correctness(run, steps, goal)
		"结构":
			return _dim_structure(run, steps, goal)
		"效率":
			return _dim_efficiency(run, steps, goal)
		"鲁棒性":
			return _dim_robustness(run, steps, goal)
		"可读性":
			return _dim_readability(run, steps, goal)
	return _out(Templates.NEUTRAL.format({"dim": dim, "hint": ""}), [])


# ---------- 正确性 ----------

func _dim_correctness(run: Dictionary, steps: Array, goal: Dictionary) -> Dictionary:
	if steps.is_empty():
		return _out(Templates.COR_EMPTY, [])
	# 1) 必经 phase
	for ph in goal.get("required_phases", []):
		if _first_phase_index(steps, str(ph)) < 0:
			var last := _ref_of(steps[steps.size() - 1], steps.size() - 1)
			return _out(Templates.COR_MISSING_PHASE.format({"phase": str(ph), "last": last}), [last])
	# 2) 禁止工具
	for s in steps:
		var step: Dictionary = s
		if (goal.get("forbidden_tools", []) as Array).has(_tool_of(step)):
			var at := _ref_of(step, 0)
			return _out(Templates.COR_FORBIDDEN.format({"at": at, "tool": _tool_of(step)}), [at])
	# 3) 期望动作模式（含先后依赖与"值要不同"约束）
	var pres := _resolve_patterns(steps, goal.get("required_patterns", []))
	if not (pres["missing"] as Array).is_empty():
		var p0: Dictionary = (pres["missing"] as Array)[0]
		var last := _ref_of(steps[steps.size() - 1], steps.size() - 1)
		var desc := str(p0.get("desc", str(p0.get("tool", "目标动作"))))
		return _out(Templates.COR_MISSING_PATTERN.format({"desc": desc, "last": last}), [last])
	# 4) 期望遍数（world.run 的次数，含改参后重跑）
	var want_runs := int(goal.get("expect_runs", 0))
	var run_refs: Array = []
	for s in steps:
		var step: Dictionary = s
		if _tool_of(step) == TOOL_RUN:
			run_refs.append(_ref_of(step, 0))
	if want_runs > 0 and run_refs.size() < want_runs:
		return _out(Templates.COR_RUNS_SHORT.format({
			"want": want_runs, "got": run_refs.size()}), run_refs)
	# 5) 达成：取最早/最晚命中的模式步做首尾证据
	var matched: Dictionary = pres["matched"]
	if matched.is_empty():
		return _out(Templates.NEUTRAL.format({
			"dim": "正确性", "hint": Templates.HINT_CORRECTNESS}), [])
	var idx: Array = matched.values()
	var first_i := int(idx[0])
	var key_i := int(idx[0])
	for v in idx:
		if int(v) < first_i:
			first_i = int(v)
		if int(v) > key_i:
			key_i = int(v)
	var first := _ref_of(steps[first_i], first_i)
	var key := _ref_of(steps[key_i], key_i)
	return _out(Templates.COR_DONE.format({
		"summary": str(goal.get("summary", "")), "first": first, "key": key}), [first, key])


# ---------- 结构 ----------

func _dim_structure(run: Dictionary, steps: Array, goal: Dictionary) -> Dictionary:
	if steps.is_empty():
		return _out(Templates.NEUTRAL.format({
			"dim": "结构", "hint": Templates.HINT_STRUCTURE}), [])
	# 1) install 的组件齐不齐（world.place 的 assetId）
	var placed := {}
	var first_place := -1
	for i in steps.size():
		var step: Dictionary = steps[i]
		if _tool_of(step) == TOOL_PLACE:
			if first_place < 0:
				first_place = i
			var aid := str(_args_of(step).get("assetId", ""))
			if aid != "" and not placed.has(aid):
				placed[aid] = true
	var missing_assets: Array = []
	for aid in goal.get("required_assets", []):
		if not placed.has(str(aid)):
			missing_assets.append(str(aid))
	if not missing_assets.is_empty():
		var anchor := first_place if first_place >= 0 else 0
		var ref := _ref_of(steps[anchor], anchor)
		return _out(Templates.STR_MISSING_ASSETS.format({
			"assets": "、".join(missing_assets), "ref": ref}), [ref])
	# 2) 阶段顺序：required_phases 的首次出现应按列出顺序递增
	var firsts: Array = []
	for ph in goal.get("required_phases", []):
		var fi := _first_phase_index(steps, str(ph))
		if fi >= 0:
			firsts.append({"phase": str(ph), "idx": fi})
	for j in range(1, firsts.size()):
		var prev: Dictionary = firsts[j - 1]
		var cur: Dictionary = firsts[j]
		if int(cur["idx"]) < int(prev["idx"]):
			var a := _ref_of(steps[int(cur["idx"])], int(cur["idx"]))
			var b := _ref_of(steps[int(prev["idx"])], int(prev["idx"]))
			return _out(Templates.STR_ORDER.format({
				"late": str(cur["phase"]), "early": str(prev["phase"]),
				"a": a, "b": b}), [a, b])
	# 3) 重复堆叠（连续同 tool + 同参数 ≥ 3 次）
	var stack := _find_stacked(steps)
	if int(stack["n"]) >= STACK_REPEAT_MIN:
		var a := _ref_of(steps[int(stack["start"])], int(stack["start"]))
		var b := _ref_of(steps[int(stack["end"])], int(stack["end"]))
		return _out(Templates.STR_STACKED.format({
			"a": a, "b": b, "n": int(stack["n"])}), [a, b])
	# 4) 一锅烩：动作全挤在一个 phase 里
	var phase_set := {}
	for s in steps:
		var ph := str((s as Dictionary).get("phase", ""))
		if ph != "":
			phase_set[ph] = true
	if phase_set.size() <= 1 and (goal.get("required_phases", []) as Array).size() >= 2:
		var phase_name := "observe" if phase_set.is_empty() else str(phase_set.keys()[0])
		var a := _ref_of(steps[0], 0)
		return _out(Templates.STR_CROWDED.format({"phase": phase_name, "a": a}), [a])
	return _out(Templates.NEUTRAL.format({
		"dim": "结构", "hint": Templates.HINT_STRUCTURE}), _structure_neutral_refs(steps, goal))


func _structure_neutral_refs(steps: Array, goal: Dictionary) -> Array:
	# 结构没问题时绑定"最后一个必经 phase"的落点作证据。
	var phases: Array = goal.get("required_phases", [])
	if not phases.is_empty():
		var fi := _first_phase_index(steps, str(phases[phases.size() - 1]))
		if fi >= 0:
			return [_ref_of(steps[fi], fi)]
	return [_ref_of(steps[steps.size() - 1], steps.size() - 1)]


# ---------- 效率 ----------

func _dim_efficiency(run: Dictionary, steps: Array, goal: Dictionary) -> Dictionary:
	if steps.is_empty():
		return _out(Templates.NEUTRAL.format({
			"dim": "效率", "hint": Templates.HINT_EFFICIENCY}), [])
	var total := 0
	var top_i := -1
	var top_ops := -1
	for i in steps.size():
		var step: Dictionary = steps[i]
		var o := int(step.get("ops", 0))
		total += o
		if o > top_ops:
			top_ops = o
			top_i = i
	var baseline := int(goal.get("baseline_ops", 0))
	if total > baseline and baseline > 0:
		# 超基线：先找重复读取（读类工具同参数多次），没有再点名 ops 大头。
		var waste := _find_repeated_reads(steps)
		if not waste.is_empty():
			return _out(Templates.EFF_OVER_REPEAT.format({
				"total": total, "baseline": baseline,
				"refs": _refs_text(waste, steps)}), waste)
		var tops := _top_ops_refs(steps, 2)
		return _out(Templates.EFF_OVER_TOP.format({
			"total": total, "baseline": baseline,
			"refs": _refs_text(tops, steps)}), tops)
	if top_i >= 0 and top_ops > 0:
		var top := _ref_of(steps[top_i], top_i)
		if baseline > 0:
			return _out(Templates.EFF_OK.format({
				"total": total, "baseline": baseline, "top": top}), [top])
		return _out(Templates.EFF_NO_BASELINE.format({
			"total": total, "top": top}), [top])
	return _out(Templates.NEUTRAL.format({
		"dim": "效率", "hint": Templates.HINT_EFFICIENCY}), [])


# ---------- 鲁棒性 ----------

func _dim_robustness(run: Dictionary, steps: Array, goal: Dictionary) -> Dictionary:
	var failures: Array = run.get("failures", [])
	if not failures.is_empty():
		var f0: Dictionary = failures[0]
		var fail_ref := int(f0.get("stepRef", -1))
		var code := str(f0.get("code", ""))
		var fail_refs: Array = []
		for f in failures:
			fail_refs.append(int((f as Dictionary).get("stepRef", -1)))
		var retry_ref := _retry_closed_ref(steps, fail_ref)
		if retry_ref >= 0:
			return _out(Templates.ROB_FAIL_CLOSED.format({
				"fail": fail_ref, "code": code, "retry": retry_ref}),
				fail_refs + [retry_ref])
		return _out(Templates.ROB_FAIL_OPEN.format({
			"fail": fail_ref, "code": code}), fail_refs)
	if steps.is_empty():
		return _out(Templates.NEUTRAL.format({
			"dim": "鲁棒性", "hint": Templates.HINT_ROBUSTNESS}), [])
	# 本关期望"先过校验门再执行"，但记录里一个校验步都没有。
	if bool(goal.get("expect_validation", false)):
		var validators: Array = goal.get("validation_tools", [])
		var has_v := false
		for s in steps:
			if validators.has(_tool_of(s as Dictionary)):
				has_v = true
				break
		if not has_v:
			var exec_i := -1
			for i in steps.size():
				var t := _tool_of(steps[i])
				if t == TOOL_PYTHON or t == TOOL_RUN:
					exec_i = i
					break
			var anchor := exec_i if exec_i >= 0 else 0
			var ref := _ref_of(steps[anchor], anchor)
			return _out(Templates.ROB_NO_VALIDATION.format({"exec": ref}), [ref])
	return _out(Templates.NEUTRAL.format({
		"dim": "鲁棒性", "hint": Templates.HINT_ROBUSTNESS}), _last_run_refs(steps))


# ---------- 可读性 ----------

func _dim_readability(run: Dictionary, steps: Array, goal: Dictionary) -> Dictionary:
	if steps.is_empty():
		return _out(Templates.NEUTRAL.format({
			"dim": "可读性", "hint": Templates.HINT_READABILITY}), [])
	var task_key := str(goal.get("task_param_key", "task_text"))
	var task_texts: Array = []
	for i in steps.size():
		var step: Dictionary = steps[i]
		if _tool_of(step) == TOOL_SET_PARAM and str(_args_of(step).get("key", "")) == task_key:
			task_texts.append({"ref": _ref_of(step, i), "text": str(_args_of(step).get("value", ""))})
	var anchor_ref := _first_place_ref(steps)
	if task_texts.is_empty():
		return _out(Templates.REA_NO_TASK.format({"ref": anchor_ref}), [anchor_ref])
	var last_task: Dictionary = task_texts[task_texts.size() - 1]
	var last_ref := int(last_task["ref"])
	var text := str(last_task["text"])
	if text.strip_edges().length() < MIN_TASK_TEXT_LEN:
		return _out(Templates.REA_NO_TASK.format({"ref": last_ref}), [last_ref])
	# 任务描述应说清的关键短语（如"输出写到哪"）——goal 侧逐条字面匹配。
	for kw in goal.get("task_must_mention", []):
		if not text.contains(str(kw)):
			return _out(Templates.REA_MISSING_KW.format({
				"kw": str(kw), "ref": last_ref}), [last_ref])
	# caption 覆盖率
	var no_cap: Array = []
	for i in steps.size():
		var step: Dictionary = steps[i]
		if str(step.get("caption", "")).strip_edges() == "":
			no_cap.append(_ref_of(step, i))
	if float(no_cap.size()) / float(steps.size()) > 1.0 - CAPTION_COVER_MIN:
		return _out(Templates.REA_CAPTIONS.format({
			"n": no_cap.size(), "refs": _refs_text(no_cap, steps)}), no_cap)
	return _out(Templates.REA_OK.format({"text": text}), [last_ref])


# ---------- 模式解析（正确性 3） ----------

## patterns: [{id, tool, actor?, paramKey?, after?, value_differs_from?, desc}]
## after=必须排在所引模式之后；value_differs_from=set_param 的 value 必须与所引模式不同。
## 返回 {matched: {id: 数组下标}, missing: [pattern…], values: {id: value 字符串}}。
func _resolve_patterns(steps: Array, patterns: Array) -> Dictionary:
	var matched := {}
	var values := {}
	var missing: Array = []
	for p in patterns:
		var pat: Dictionary = p
		var pid := str(pat.get("id", ""))
		var start := 0
		if pat.has("after"):
			var after_id := str(pat["after"])
			if not matched.has(after_id):
				missing.append(pat)
				continue
			start = int(matched[after_id]) + 1
		var found := -1
		for i in range(start, steps.size()):
			if _pattern_step_matches(steps[i], pat, values):
				found = i
				break
		if found >= 0:
			matched[pid] = found
			values[pid] = str(_args_of(steps[found]).get("value", ""))
		else:
			missing.append(pat)
	return {"matched": matched, "missing": missing, "values": values}


func _pattern_step_matches(step: Dictionary, pat: Dictionary, values: Dictionary) -> bool:
	if _tool_of(step) != str(pat.get("tool", "")):
		return false
	if pat.has("actor") and str(step.get("actor", "")) != str(pat["actor"]):
		return false
	var args := _args_of(step)
	if pat.has("paramKey") and str(args.get("key", "")) != str(pat["paramKey"]):
		return false
	if pat.has("value_differs_from"):
		var other := str(pat["value_differs_from"])
		if not values.has(other):
			return false
		if str(args.get("value", "")) == str(values[other]):
			return false
	return true


# ---------- 证据与杂项 ----------

func _out(text: String, refs: Array) -> Dictionary:
	return {"text": text, "refs": refs}


func _tool_of(step: Dictionary) -> String:
	return str((step.get("action", {}) as Dictionary).get("tool", ""))


func _args_of(step: Dictionary) -> Dictionary:
	return (step.get("action", {}) as Dictionary).get("args", {})


func _ref_of(step: Dictionary, fallback: int) -> int:
	return int(step.get("i", fallback))


func _first_phase_index(steps: Array, phase: String) -> int:
	for i in steps.size():
		if str((steps[i] as Dictionary).get("phase", "")) == phase:
			return i
	return -1


func _first_place_ref(steps: Array) -> int:
	for i in steps.size():
		if _tool_of(steps[i]) == TOOL_PLACE:
			return _ref_of(steps[i], i)
	return _ref_of(steps[0], 0)


## 校验 stepRef 都指向存在的步号（步记录的 i），去重排序。
func _clean_refs(refs: Array, steps: Array) -> Array:
	var valid := {}
	for i in steps.size():
		valid[_ref_of(steps[i], i)] = true
	var out: Array = []
	var seen := {}
	for r in refs:
		var n := int(r)
		if valid.has(n) and not seen.has(n):
			seen[n] = true
			out.append(n)
	out.sort()
	return out


## 步号列表 → "第 4、7 步"（最多列 3 个，多的加"等"）。
func _refs_text(refs: Array, steps: Array) -> String:
	var clean := _clean_refs(refs, steps)
	if clean.is_empty():
		return "记录里没有可指的步"
	var parts: Array = []
	for r in clean.slice(0, 3):
		parts.append(str(int(r)))
	var txt := "第 " + "、".join(parts) + " 步"
	if clean.size() > 3:
		txt += "等"
	return txt


func _find_stacked(steps: Array) -> Dictionary:
	var best := {"start": -1, "end": -1, "n": 0}
	var i := 0
	while i < steps.size():
		var j := i
		while j + 1 < steps.size() and _same_action(steps[j], steps[j + 1]):
			j += 1
		var n := j - i + 1
		if n >= STACK_REPEAT_MIN and n > int(best["n"]):
			best = {"start": i, "end": j, "n": n}
		i = j + 1
	return best


func _same_action(a: Dictionary, b: Dictionary) -> bool:
	if _tool_of(a) != _tool_of(b):
		return false
	return JSON.stringify(_args_of(a)) == JSON.stringify(_args_of(b))


## 读类工具（扫描器语义）同参数出现 ≥2 次即算重复读取。
func _find_repeated_reads(steps: Array) -> Array:
	var groups := {}
	for i in steps.size():
		var step: Dictionary = steps[i]
		var tool := _tool_of(step)
		if not READ_TOOLS.has(tool):
			continue
		var key := tool + "|" + JSON.stringify(_args_of(step))
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(i)
	for key in groups:
		var idxs: Array = groups[key]
		if idxs.size() >= 2:
			var refs: Array = []
			for idx in idxs:
				refs.append(_ref_of(steps[int(idx)], int(idx)))
			return refs
	return []


func _top_ops_refs(steps: Array, count: int) -> Array:
	var entries: Array = []
	for i in steps.size():
		var step: Dictionary = steps[i]
		var o := int(step.get("ops", 0))
		if o > 0:
			entries.append({"ops": o, "idx": i})
	entries.sort_custom(func(a, b) -> bool: return int(a["ops"]) > int(b["ops"]))
	var refs: Array = []
	for e in entries.slice(0, count):
		var idx := int((e as Dictionary)["idx"])
		refs.append(_ref_of(steps[idx], idx))
	refs.sort()
	return refs


## 失败步之后是否出现同工具且 ok 的步（重试闭环）；返回该步的步号，无则 -1。
func _retry_closed_ref(steps: Array, fail_ref: int) -> int:
	var fail_tool := ""
	for s in steps:
		var step: Dictionary = s
		if _ref_of(step, -1) == fail_ref:
			fail_tool = _tool_of(step)
			break
	if fail_tool == "":
		return -1
	for s in steps:
		var step: Dictionary = s
		if _ref_of(step, -1) > fail_ref and _tool_of(step) == fail_tool:
			var output: Dictionary = step.get("output", {})
			if bool(output.get("ok", false)):
				return _ref_of(step, -1)
	return -1


func _last_run_refs(steps: Array) -> Array:
	var refs: Array = []
	for s in steps:
		var step: Dictionary = s
		if _tool_of(step) == TOOL_RUN:
			refs = [_ref_of(step, 0)]
	if refs.is_empty() and not steps.is_empty():
		refs = [_ref_of(steps[steps.size() - 1], steps.size() - 1)]
	return refs
