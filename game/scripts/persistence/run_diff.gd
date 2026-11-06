extends RefCounted

## 跨 run diff（docs/10-契约/交互方案.md §九 双轨之「回上一版」）。
##
## 同一任务的两次运行做 diff：配置差、结果差、评分差各在哪——
## 「我改了什么 → 结果怎么变」一眼可读，重试才是几秒的事。
##
## 与 world.diff 的分工（语义不同，互不替代）：
##   * world.diff（world_tools_core.gd）：**同一次运行内**两步之间的
##     状态层差异（steps[from].world vs steps[to].world）；
##   * 本类：**两次运行之间**的结构化差异，输入是两份冻结的 run JSON
##     （schema v6，step_recorder_core.gd 的落盘形状），判定不需要重跑世界。
##
## 纯逻辑、只读入参；不碰世界、不碰文件、不 import levels / scoring。
## 不使用 class_name，消费方一律 preload（同 compiler/graph_model.gd，
## 避开新建脚本的全局类名缓存问题）。
##
## 数值比较口径：JSON 往返会把 4 变 4.0，一律按数值比较
## （bool 除外——BOOL 端口的 true 不能等于 1，否则布尔灯的差会被吞掉）。

const TOOL_SET_PARAM := "world.set_param"
const SCORE_TOOL_PREFIX := "level.score"
const SCORE_PHASE := "score"
## 浮点容差：run JSON 里的数值都是量出来的，按位相等太脆。
const EPS := 1e-9


# ---------- 主入口 ----------

## diff 两份 run JSON，输出：
##   { ok, runA, runB,
##     config_changes: [{entityId, key, from, to}],        # set_param 终值对齐比较
##     result_changes: [{kind, entityId, portId?, from, to}],  # 末步 world 摘要对比
##     score_changes:  [{dim, from, to}],                  # score 步五句逐维对比
##     totals: { steps: {a, b, delta}, ops: {a, b, delta} } }
## from / to 为 null 表示该侧记录里根本没出现过这个键 / 维度。
func diff(run_a: Dictionary, run_b: Dictionary) -> Dictionary:
	for d in [run_a, run_b]:
		if not (d is Dictionary) or not ((d as Dictionary).get("steps", {}) is Array):
			return _err("bad_run_doc", "入参必须是 run JSON（{schemaVersion, run, steps, failures}），得到：%s" % str(typeof(d)))
	return {
		"ok": true,
		"runA": _run_id(run_a),
		"runB": _run_id(run_b),
		"config_changes": _diff_config(run_a, run_b),
		"result_changes": _diff_results(run_a, run_b),
		"score_changes": _diff_scores(run_a, run_b),
		"totals": {
			"steps": _triple((run_a["steps"] as Array).size(), (run_b["steps"] as Array).size()),
			"ops": _triple(_total_ops(run_a), _total_ops(run_b)),
		},
	}


## 给人看的中文版：每处差异一句（「参数 task_text 从 A 改成 B」），
## 末行合计步数与 ops。无差异时明说无差异，不编话。
func format_text(d: Dictionary) -> String:
	if not bool(d.get("ok", false)):
		return "无法比较：%s" % str(d.get("message", "输入不是合法的 diff 结果"))
	var lines: Array[String] = []
	lines.append("两次运行对比：%s vs %s" % [str(d.get("runA", "?")), str(d.get("runB", "?"))])

	var config: Array = d.get("config_changes", [])
	lines.append("配置差（%d 处）：" % config.size())
	for c in config:
		lines.append("  参数 %s:%s 从 %s 改成 %s" % [
			str(c.get("entityId", "?")), str(c.get("key", "?")),
			_show(c.get("from")), _show(c.get("to"))])

	var results: Array = d.get("result_changes", [])
	lines.append("结果差（%d 处）：" % results.size())
	for r in results:
		var kind := str(r.get("kind", "port_value"))
		if kind == "entity_added":
			lines.append("  实体 %s 是新出现的（上一版没有）" % str(r.get("entityId", "?")))
		elif kind == "entity_removed":
			lines.append("  实体 %s 在上一版有、这一版没有了" % str(r.get("entityId", "?")))
		elif kind == "exists":
			lines.append("  实体 %s 的存在性从 %s 变到 %s" % [
				str(r.get("entityId", "?")), _show(r.get("from")), _show(r.get("to"))])
		else:
			lines.append("  端口 %s:%s 从 %s 变到 %s" % [
				str(r.get("entityId", "?")), str(r.get("portId", "?")),
				_show(r.get("from")), _show(r.get("to"))])

	var scores: Array = d.get("score_changes", [])
	lines.append("评分差（%d 处）：" % scores.size())
	for s in scores:
		lines.append("  维度「%s」的句子变了：从「%s」改为「%s」" % [
			str(s.get("dim", "?")), _show(s.get("from")), _show(s.get("to"))])

	var totals: Dictionary = d.get("totals", {})
	var steps_t: Dictionary = totals.get("steps", {})
	var ops_t: Dictionary = totals.get("ops", {})
	lines.append("合计：步数 %s → %s，ops %s → %s" % [
		_show(steps_t.get("a")), _show(steps_t.get("b")),
		_show(ops_t.get("a")), _show(ops_t.get("b"))])

	if config.is_empty() and results.is_empty() and scores.is_empty():
		lines.append("两次运行在配置、结果、评分上没有差异。")
	return "\n".join(PackedStringArray(lines))


# ---------- 配置差：set_param 序列对齐比较 ----------

## 取每次运行里**成功**的 set_param，按 (entityId, key) 对齐后比终值
## （同一键多次写入取最后一次——学员最后留在装置上的才是配置）。
## key 含 @ 前缀（端口写也是 set_param，同序列对齐）。
func _diff_config(run_a: Dictionary, run_b: Dictionary) -> Array:
	var finals_a := _set_param_finals(run_a) # {entityId -> {key -> 终值}}
	var finals_b := _set_param_finals(run_b)
	var out: Array = []
	var eids: Array = finals_a.keys()
	for eid in finals_b.keys():
		if not eids.has(eid):
			eids.append(eid)
	eids.sort()
	for eid in eids:
		var keys_a: Dictionary = finals_a.get(eid, {})
		var keys_b: Dictionary = finals_b.get(eid, {})
		var keys: Array = keys_a.keys()
		for key in keys_b.keys():
			if not keys.has(key):
				keys.append(key)
		keys.sort()
		for key in keys:
			var has_a := keys_a.has(key)
			var has_b := keys_b.has(key)
			if has_a and has_b and _values_equal(keys_a[key], keys_b[key]):
				continue
			out.append({
				"entityId": str(eid),
				"key": str(key),
				"from": keys_a[key] if has_a else null,
				"to": keys_b[key] if has_b else null,
			})
	return out


func _set_param_finals(run: Dictionary) -> Dictionary:
	var finals: Dictionary = {}
	for s in run.get("steps", []):
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		if str(action.get("tool", "")) != TOOL_SET_PARAM:
			continue
		if not bool((step.get("output", {}) as Dictionary).get("ok", false)):
			continue # 没写进去的不算配置
		var args: Dictionary = action.get("args", {})
		var eid := str(args.get("entityId", ""))
		var key := str(args.get("key", ""))
		if eid == "" or key == "":
			continue
		if not finals.has(eid):
			finals[eid] = {}
		(finals[eid] as Dictionary)[key] = args.get("value")
	return finals


# ---------- 结果差：末步 world 摘要对比 ----------

## 各取最后一次记录的 world.entities，逐实体逐端口比终值；实体增删、
## 存在性翻转也点名。params 不在这里比——那是配置，归 config_changes。
func _diff_results(run_a: Dictionary, run_b: Dictionary) -> Array:
	var ea := _final_entities(run_a)
	var eb := _final_entities(run_b)
	var out: Array = []
	var eids: Array = ea.keys()
	for k in eb.keys():
		if not eids.has(k):
			eids.append(k)
	eids.sort()
	for eid in eids:
		var in_a := ea.has(eid)
		var in_b := eb.has(eid)
		if not in_a:
			out.append({"kind": "entity_added", "entityId": eid})
			continue
		if not in_b:
			out.append({"kind": "entity_removed", "entityId": eid})
			continue
		var a: Dictionary = ea[eid]
		var b: Dictionary = eb[eid]
		var ex_a := bool(a.get("exists", true))
		var ex_b := bool(b.get("exists", true))
		if ex_a != ex_b:
			out.append({"kind": "exists", "entityId": eid, "from": ex_a, "to": ex_b})
		var pids: Array = (a.get("ports", {}) as Dictionary).keys()
		for pk in (b.get("ports", {}) as Dictionary).keys():
			if not pids.has(pk):
				pids.append(pk)
		pids.sort()
		for pid in pids:
			var pa: Dictionary = (a.get("ports", {}) as Dictionary).get(pid, {})
			var pb: Dictionary = (b.get("ports", {}) as Dictionary).get(pid, {})
			var has_pa := (a.get("ports", {}) as Dictionary).has(pid)
			var has_pb := (b.get("ports", {}) as Dictionary).has(pid)
			var va: Variant = pa.get("value")
			var vb: Variant = pb.get("value")
			if has_pa and has_pb and _values_equal(va, vb):
				continue
			out.append({
				"kind": "port_value",
				"entityId": eid,
				"portId": str(pid),
				"from": va if has_pa else null,
				"to": vb if has_pb else null,
			})
	return out


func _final_entities(run: Dictionary) -> Dictionary:
	var entities: Dictionary = {}
	for s in run.get("steps", []):
		var step: Dictionary = s
		var world: Dictionary = step.get("world", {})
		var ents: Dictionary = world.get("entities", {})
		if not ents.is_empty():
			entities = ents # 逐布覆盖，留在最后一次有实体摘要的步上
	return entities


# ---------- 评分差：score 步五句逐维对比 ----------

## 各取最后一次 score 步（phase==score 或 action.tool 以 level.score 开头），
## 兼容两种句子形状：关卡 stub 的 {dim, sentence} 与评分器的 {dim, text}。
func _diff_scores(run_a: Dictionary, run_b: Dictionary) -> Array:
	var sa := _score_sentences(run_a)
	var sb := _score_sentences(run_b)
	var out: Array = []
	var dims: Array = []
	for dim in sa.keys():
		if not dims.has(dim):
			dims.append(dim)
	for dim in sb.keys():
		if not dims.has(dim):
			dims.append(dim)
	for dim in dims:
		var ta: Variant = sa.get(dim)
		var tb: Variant = sb.get(dim)
		var has_a := sa.has(dim)
		var has_b := sb.has(dim)
		if has_a and has_b and str(ta) == str(tb):
			continue
		out.append({
			"dim": str(dim),
			"from": ta if has_a else null,
			"to": tb if has_b else null,
		})
	return out


func _score_sentences(run: Dictionary) -> Dictionary:
	var sentences: Dictionary = {}
	var steps: Array = run.get("steps", [])
	for i in range(steps.size() - 1, -1, -1): # 倒序找最后一次评分
		var step: Dictionary = steps[i]
		var action: Dictionary = step.get("action", {})
		var is_score := str(step.get("phase", "")) == SCORE_PHASE \
			or str(action.get("tool", "")).begins_with(SCORE_TOOL_PREFIX)
		if not is_score:
			continue
		var dims_v: Variant = (action.get("args", {}) as Dictionary).get("dimensions", [])
		if not (dims_v is Array) or (dims_v as Array).is_empty():
			dims_v = ((step.get("output", {}) as Dictionary).get("result", {}) as Dictionary).get("sentences", [])
		var dims: Array = dims_v if dims_v is Array else []
		for d in dims:
			if not (d is Dictionary):
				continue
			var dim := str((d as Dictionary).get("dim", ""))
			if dim == "":
				continue
			var text := str((d as Dictionary).get("sentence", (d as Dictionary).get("text", "")))
			sentences[dim] = text
		break # 只取最后一次 score 步
	return sentences


# ---------- 内部 ----------

func _run_id(run: Dictionary) -> String:
	return str((run.get("run", {}) as Dictionary).get("runId", "?"))


func _total_ops(run: Dictionary) -> int:
	var total := 0
	for s in run.get("steps", []):
		total += int((s as Dictionary).get("ops", 0))
	return total


func _triple(a: int, b: int) -> Dictionary:
	return {"a": a, "b": b, "delta": b - a}


## 数值相等口径：bool 严格按 bool 比（true 不等于 1，布尔灯的差不能被吞）；
## 两侧都是数值按浮点容差比（JSON 往返 4 与 4.0 相等）；其余按 JSON 字面比。
func _values_equal(a: Variant, b: Variant) -> bool:
	if a is bool or b is bool:
		return (a is bool) and (b is bool) and bool(a) == bool(b)
	if (a is int or a is float) and (b is int or b is float):
		return absf(float(a) - float(b)) < EPS
	if a is String or b is String:
		return (a is String) and (b is String) and str(a) == str(b)
	return JSON.stringify(a) == JSON.stringify(b)


func _show(v: Variant) -> String:
	if v == null:
		return "（该侧未出现）"
	return str(v)


func _err(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
