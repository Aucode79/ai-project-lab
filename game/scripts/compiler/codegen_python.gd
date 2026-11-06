extends RefCounted

## 方块编译器 · IR → 普通 Python 源码（可搬运，非 DSL）。
##
## 输出契约（docs/10-契约/方块体系.md §6.2 + 原 spec §7 红线）：
## - 普通函数定义（每实体一个 step_* 函数，带 docstring）
## - 参数校验（显式 raise，越界即抛 ValueError）
## - try/except 错误恢复（图里有 recover 实体时走"记录→恢复→重试"，
##   否则记录后重抛）
## - 控制循环骨架（while True + 显式 break 出口）
## - 仅标准库；main() 自测入口，退出码 0 即通过
## - 确定性：同一 IR → 字节级相同输出（不掺时间戳/随机数/路径）
## - 非 join 实体的多路数据入边：同一入端口接 >=2 条边时，多路来源
##   聚合为单一 dict 实参 sources={"v_*": v_*}（语义无损；validate 会发
##   MULTI_DATA_IN_EDGE 告警）。join 的多入边仍走 results 列表聚合。
## - 扇出×sources：臂首实体命中 sources 签名时，pool.map 的单实参 item
##   不能直塞（会被错绑进 sources 解包，支路值与多路来源全丢）——改经
##   包装 lambda 聚合为 sources={"v_item": item, ...}（v_item=支路值，
##   其余键闭包捕获各数据入边来源），sources 序言把 v_item 并入臂首实体
##   首数据入端口的来源列表，与 fn(item) 的位置语义对齐。
## - 撞名硬错误：臂首的数据来源里已有 py_ident=="item" 的实体时，来源
##   变量 v_item 与扇出支路槽 v_item 同键，支路值会被静默丢弃——改为
##   编译期报 FANOUT_ITEM_NAME_COLLISION（不产码），不再静默错语义。

const GM := preload("res://scripts/compiler/graph_model.gd")

## 扇出×sources 撞名错误码（结构化 {code, entity_id, port_ref, message}，
## 由 compiler.gd 并入 compile 结果的 errors，阻断产码）。
const FANOUT_ITEM_NAME_COLLISION := "FANOUT_ITEM_NAME_COLLISION"

const KIND_NAMES := {
	"entry": "流程入口",
	"step": "通用步骤",
	"think": "思考一步",
	"decide": "分岔条件",
	"guard": "循环出口判定",
	"generate_call": "生成工具调用（示意）",
	"parse": "解析",
	"validate": "schema 校验",
	"recover": "错误恢复",
	"observe": "观察",
	"summarize": "汇总",
	"split": "扇出拆分",
	"join": "多路归一",
	"source": "数据源",
	"sink": "终点",
}

const KIND_RETURNS := {
	"entry": "dict",
	"step": "dict",
	"think": "dict",
	"decide": "str",
	"guard": "bool",
	"generate_call": "str",
	"parse": "dict",
	"validate": "None",
	"recover": "dict",
	"observe": "dict",
	"summarize": "dict",
	"split": "list",
	"join": "dict",
	"source": "dict",
	"sink": "dict",
}


## 入口：graph（graph_model.BlockGraph）+ ir（ir.IRProgram）→
## {python: String, errors: Array}。errors 非空（目前只有
## FANOUT_ITEM_NAME_COLLISION）时 python 为 ""——codegen 层硬错误同样
## 阻断产码，由 compiler.gd 并入 compile 结果的 errors 数组。
static func generate(graph, ir) -> Dictionary:
	var b := _Builder.new()
	b.graph = graph
	b.ir = ir
	var errors := b.check_errors()
	if not errors.is_empty():
		return {"python": "", "errors": errors}
	return {"python": b.build(), "errors": []}


class _Builder extends RefCounted:
	var graph
	var ir
	var lines: PackedStringArray = []
	var recover_id := ""
	var recover_args := ""
	## 扇出臂首实体集合（fanout 节点各支路的首实体）——它们的 sources
	## 序言要并入 v_item（支路值）来源。
	var fanout_heads := {}

	func build() -> String:
		_pick_recover()
		_collect_fanout_heads(ir.statements, fanout_heads)
		_emit_header()
		_emit_blank()
		_emit_imports()
		for eid in ir.entities:
			lines.append("")
			lines.append("")
			_emit_function(eid)
		lines.append("")
		lines.append("")
		_emit_run()
		lines.append("")
		lines.append("")
		_emit_main()
		return "\n".join(lines) + "\n"

	## codegen 层硬错误（阻断产码）：扇出臂首命中 sources 签名时，支路值
	## 要占 sources 的 "v_item" 槽；若臂首的数据来源里已有 py_ident=="item"
	## 的实体，该槽被真实来源占用，支路值会被静默丢弃——改为报
	## FANOUT_ITEM_NAME_COLLISION（结构化四字段），要求改名。
	func check_errors() -> Array[Dictionary]:
		var errors: Array[Dictionary] = []
		var heads := {}
		_collect_fanout_heads(ir.statements, heads)
		for eid in heads.keys():
			if not _uses_sources(eid):
				continue  # 非聚合臂首：pool.map 位置直传，无 v_item 槽
			var port := _first_data_in_port(graph.entity(eid))
			var colliders: Array[String] = []
			for c in graph.data_in_edges(eid):
				if py_ident(c.from_entity) == "item" and not colliders.has(c.from_entity):
					colliders.append(c.from_entity)
			if colliders.is_empty():
				continue
			colliders.sort()
			errors.append({
				"code": FANOUT_ITEM_NAME_COLLISION,
				"entity_id": eid,
				"port_ref": "%s.%s" % [eid, port],
				"message": "扇出撞名：来源实体 %s 的实体名 item 与扇出支路槽 v_item 撞名，%s.%s 的 sources 聚合里支路值会被丢弃，请给该实体改名" % [", ".join(colliders), eid, port],
			})
		errors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return _err_key(a) < _err_key(b))
		return errors

	func line(depth: int, text: String) -> void:
		lines.append("    ".repeat(depth) + text)

	func _emit_blank() -> void:
		lines.append("")

	func _pick_recover() -> void:
		for eid in graph.order:
			if graph.entity(eid).kind == "recover":
				recover_id = eid
				break
		if recover_id != "":
			recover_args = _call_args(recover_id)

	# ---------- 文件头与导入 ----------

	func _emit_header() -> void:
		var topo := _topology_labels()
		var conn_count: int = graph.connections.size()
		lines.append('"""%s —— 由方块编译器生成（普通 Python，仅标准库）。' % ir.name)
		lines.append("")
		lines.append("来源：连接图 + 参数 + 装配层次（位置与朝向不参与编译；折叠只改视图）。")
		lines.append("拓扑：%s    实体 %d 个    连接 %d 条" % ["、".join(PackedStringArray(topo)), ir.entities.size(), conn_count])
		lines.append("用法：python3 %s.py（main() 自测，退出码 0 即通过）。" % ir.name)
		lines.append('"""')

	func _topology_labels() -> Array[String]:
		var kinds := {}
		_collect_kinds(ir.statements, kinds)
		var labels: Array[String] = []
		if kinds.has("loop"):
			labels.append("带环")
		if kinds.has("branch"):
			labels.append("分岔")
		if kinds.has("fanout"):
			labels.append("扇出")
		if kinds.has("join"):
			labels.append("汇聚")
		if labels.is_empty():
			labels.append("直线")
		return labels

	func _collect_kinds(nodes: Array, out: Dictionary) -> void:
		for n in nodes:
			out[n.kind] = true
			if n.kind == "loop":
				_collect_kinds(n.body, out)

	func _emit_imports() -> void:
		var kinds := {}
		var has_fanout := false
		for eid in graph.order:
			kinds[graph.entity(eid).kind] = true
		for n in ir.statements:
			if n.kind == "fanout":
				has_fanout = true
		var imports: Array[String] = []
		if has_fanout:
			imports.append("concurrent.futures")
		if kinds.has("split"):
			imports.append("copy")
		imports.append("json")
		if kinds.has("generate_call"):
			imports.append("random")
		imports.sort()
		for m in imports:
			lines.append("import %s" % m)

	# ---------- 每实体一个函数 ----------

	func _emit_function(eid: String) -> void:
		var e = graph.entity(eid)
		var pyid := py_ident(eid)
		var doc := "%s：%s。" % [eid, String(KIND_NAMES.get(e.kind, "通用步骤"))]
		var sig := _signature(e)
		lines.append("def step_%s(%s) -> %s:" % [pyid, sig, String(KIND_RETURNS.get(e.kind, "dict"))])
		line(1, '"""%s"""' % doc)
		_emit_param_checks(e)
		if _uses_sources(eid):
			_emit_sources_prologue(eid, e)
		for l in _body_lines(eid, e):
			lines.append(l)

	func _signature(e) -> String:
		var parts: Array[String] = []
		if e.kind == "join":
			parts.append("results: list")
		elif e.kind == "entry":
			parts.append("payload=None")
		elif _uses_sources(e.id):
			parts.append("sources: dict = None")
		else:
			for p in e.ports:
				if p.kind != GM.DATA or p.dir != "in":
					continue
				var arg: String = "state" if p.name == "in" else p.name
				if e.kind == "summarize" and p.name == "context":
					parts.append("%s: dict = None" % arg)
				else:
					parts.append("%s: %s" % [arg, _port_ann(String(p.type))])
		var keys: Array = e.params.keys()
		keys.sort()
		for pname in keys:
			var spec: Dictionary = e.params[pname]
			parts.append("%s: %s = %s" % [pname, _py_ann(String(spec["type"])), _py_literal(spec["value"], String(spec["type"]))])
		return ", ".join(PackedStringArray(parts))

	func _emit_param_checks(e) -> void:
		var keys: Array = e.params.keys()
		keys.sort()
		for pname in keys:
			var spec: Dictionary = e.params[pname]
			var t := String(spec["type"])
			if t != "int" and t != "number":
				continue
			var has_min := spec.get("min", null) != null
			var has_max := spec.get("max", null) != null
			if not has_min and not has_max:
				continue
			var cond := ""
			if has_min and has_max:
				cond = "%s <= %s <= %s" % [_py_literal(spec["min"], t), pname, _py_literal(spec["max"], t)]
			elif has_min:
				cond = "%s <= %s" % [_py_literal(spec["min"], t), pname]
			else:
				cond = "%s <= %s" % [pname, _py_literal(spec["max"], t)]
			var rng := "[%s, %s]" % [str(spec.get("min", "")), str(spec.get("max", ""))]
			if not has_min:
				rng = "(-inf, %s]" % str(spec["max"])
			elif not has_max:
				rng = "[%s, +inf)" % str(spec["min"])
			line(1, 'if not (%s):' % cond)
			line(2, 'raise ValueError("%s.%s 超出范围 %s")' % [e.id, pname, rng])

	# ---------- 函数体模板（按 kind；全部标准库、确定性） ----------

	func _body_lines(eid: String, e) -> PackedStringArray:
		var l: PackedStringArray = []
		match e.kind:
			"entry":
				l.append("    base = payload if isinstance(payload, dict) else {}")
				l.append("    return {")
				l.append('        "seed": base.get("seed", 7),')
				l.append('        "attempt": 0,')
				l.append('        "bad_calls": 1,')
				l.append('        "turns": 0,')
				l.append('        "errors": 0,')
				l.append("    }")
			"step", "observe":
				l.append('    state["turns"] = state.get("turns", 0) + 1')
				l.append('    state.setdefault("log", []).append("%s")' % eid)
				l.append("    return state")
			"think":
				l.append('    state["max_turns"] = max_turns')
				l.append('    state["turns"] = state.get("turns", 0) + 1')
				l.append("    return state")
			"decide":
				var labels := _branch_labels(eid)
				var tup := "(%s)" % ", ".join(_quoted(labels))
				l.append("    if state.get(\"route\") in %s:" % tup)
				l.append('        return state["route"]')
				l.append('    if state.get("turns", 0) >= state.get("max_turns", 4):')
				l.append('        return "else"')
				l.append('    return "then"')
			"generate_call":
				l.append("    attempt = state.get(\"attempt\", 0)")
				l.append("    if attempt < state.get(\"bad_calls\", 0):")
				l.append('        return json.dumps({"tool": "scan"})  # 坏调用：缺 args，驱动校验→重试')
				l.append("    rng = random.Random(state.get(\"seed\", 0) + attempt)")
				l.append('    tools = ("scan", "write", "none")')
				l.append("    return json.dumps({")
				l.append('        "tool": rng.choice(tools),')
				l.append('        "args": {"path": "/tmp/report.txt", "slot": rng.randint(0, 9)},')
				l.append("    })")
			"parse":
				l.append("    try:")
				l.append("        value = json.loads(raw)")
				l.append("    except (TypeError, ValueError) as exc:")
				l.append('        raise ValueError("parse: 输入不是合法 JSON: %s" % exc) from exc')
				l.append("    if not isinstance(value, dict):")
				l.append('        raise ValueError("parse: 顶层必须是对象")')
				l.append("    return value")
			"validate":
				l.append("    missing = [k for k in required_keys if k not in payload]")
				l.append("    if missing:")
				l.append('        raise ValueError("validate: 缺少必需字段 %s" % ", ".join(missing))')
				l.append("    return None")
			"guard":
				l.append('    return bool(payload.get("tool")) or payload.get("turns", 0) >= payload.get("max_turns", 4)')
			"recover":
				l.append('    state["errors"] = state.get("errors", 0) + 1')
				l.append('    state["attempt"] = state.get("attempt", 0) + 1')
				l.append("    if state.get(\"attempt\", 0) > max_retries:")
				l.append('        state["route"] = "else"')
				l.append("    return state")
			"summarize":
				l.append("    data = payload if isinstance(payload, dict) else {}")
				l.append("    ctx = context if isinstance(context, dict) else {}")
				l.append("    return {")
				l.append('        "status": "ok" if data.get("tool") else "gave_up",')
				l.append('        "tool": data.get("tool"),')
				l.append('        "turns": ctx.get("turns", 0),')
				l.append('        "tool_calls": 1 if data.get("tool") else 0,')
				l.append('        "errors": ctx.get("errors", 0),')
				l.append("    }")
			"split":
				l.append("    return [copy.deepcopy(state) for _ in range(ways)]")
			"join":
				l.append("    merged: dict = {}")
				l.append("    for item in results:")
				l.append("        if isinstance(item, dict):")
				l.append("            for key, value in item.items():")
				l.append("                if key in merged and isinstance(merged[key], list) and isinstance(value, list):")
				l.append("                    merged[key].extend(value)")
				l.append("                else:")
				l.append("                    merged[key] = value")
				l.append("        else:")
				l.append('            merged.setdefault("items", []).append(item)')
				l.append("    return merged")
			"source":
				l.append('    return {"%s": tag}' % eid)
			"sink":
				l.append("    data = state if isinstance(state, dict) else {}")
				l.append('    print("[%s]", json.dumps(data, ensure_ascii=False, sort_keys=True, default=str))' % eid)
				l.append("    return data")
			_:
				l.append('    state.setdefault("log", []).append("%s")' % eid)
				l.append("    return state")
		return l

	func _branch_labels(eid: String) -> Array[String]:
		var labels: Array[String] = []
		_collect_branch_labels(ir.statements, eid, labels)
		if labels.is_empty():
			labels.append("then")
			labels.append("else")
		return labels

	func _collect_branch_labels(nodes: Array, eid: String, out: Array[String]) -> void:
		for n in nodes:
			if n.kind == "branch" and n.entity == eid:
				for arm in n.arms:
					out.append(String(arm["label"]))
			elif n.kind == "loop":
				_collect_branch_labels(n.body, eid, out)

	func _quoted(items: Array[String]) -> PackedStringArray:
		var q: PackedStringArray = []
		for s in items:
			q.append('"%s"' % s)
		return q

	# ---------- run()：主控制流 ----------

	func _emit_run() -> void:
		lines.append("def run(payload=None) -> dict:")
		lines.append('    """主控制流：由 IR 生成（拓扑：%s）。"""' % "、".join(PackedStringArray(_topology_labels())))
		line(1, "errors: list = []")
		var needs_v := false
		for eid in graph.order:
			if graph.data_out_edges(eid).size() > 0:
				needs_v = true
				line(1, "v_%s = None  # 预声明：支路可能未走到" % py_ident(eid))
		line(1, "state = {}")
		line(1, "try:")
		_emit_stmts(ir.statements, 2)
		line(1, "except Exception as exc:")
		line(2, 'errors.append({"entity": "run", "error": str(exc)})')
		if recover_id != "":
			line(2, "state = step_%s(%s)" % [py_ident(recover_id), recover_args])
		line(2, "raise")
		line(1, "return state")

	func _emit_stmts(nodes: Array, depth: int) -> void:
		for n in nodes:
			_emit_node(n, depth)

	func _emit_node(n, depth: int) -> void:
		match n.kind:
			"seq":
				_emit_step(n.entity, depth)
			"branch":
				_emit_branch(n, depth)
			"loop":
				_emit_loop(n, depth)
			"fanout":
				_emit_fanout(n, depth)
			"join":
				_emit_join(n, depth)

	func _emit_step(eid: String, depth: int) -> void:
		var e = graph.entity(eid)
		var call := "step_%s(%s)" % [py_ident(eid), _call_args(eid)]
		if e.kind == "guard":
			line(depth, "if %s:" % call)
			line(depth + 1, "break  # 显式出口")
			return
		if e.kind == "validate":
			line(depth, call)
			return
		if graph.data_out_edges(eid).size() > 0:
			line(depth, "v_%s = %s" % [py_ident(eid), call])
		else:
			line(depth, "state = %s" % call)

	func _emit_branch(n, depth: int) -> void:
		var eid: String = n.entity
		line(depth, "route_%s = step_%s(%s)" % [py_ident(eid), py_ident(eid), _call_args(eid)])
		var arm_count: int = n.arms.size()
		for i in range(arm_count):
			var arm: Dictionary = n.arms[i]
			var is_last: bool = i == arm_count - 1
			var label := String(arm["label"])
			if is_last and label == "else":
				line(depth, "else:")
			else:
				var kw := "if" if i == 0 else "elif"
				line(depth, '%s route_%s == "%s":' % [kw, py_ident(eid), label])
			var ents: Array = arm["entities"]
			if ents.is_empty():
				line(depth + 1, "pass  # %s：直达汇合点" % label)
			else:
				for sub in ents:
					_emit_step(sub, depth + 1)
				_exit_note(ents[ents.size() - 1], depth + 1)

	func _exit_note(eid: String, depth: int) -> void:
		# 支路末实体持有 exit 端口 → 显式 break（只应出现在循环体内）。
		# guard 实体的 break 已由 if-break 发射，这里跳过以免重复。
		if graph.entity(eid).kind == "guard":
			return
		for c in graph.ctrl_out_edges(eid):
			var p = graph.port_of(eid, c.from_port)
			if p != null and p.type == "exit":
				line(depth, "break  # 显式出口：%s.%s -> %s" % [eid, c.from_port, c.to_entity])
				return

	func _emit_loop(n, depth: int) -> void:
		line(depth, "while True:")
		line(depth + 1, "try:")
		_emit_stmts(n.body, depth + 2)
		line(depth + 1, "except Exception as exc:")
		line(depth + 2, 'errors.append({"loop": "%s", "error": str(exc)})' % ir.name)
		if recover_id != "":
			line(depth + 2, "state = step_%s(%s)" % [py_ident(recover_id), recover_args])
			line(depth + 2, "continue")
		else:
			line(depth + 2, "raise")

	func _emit_fanout(n, depth: int) -> void:
		var eid: String = n.entity
		line(depth, "branches = step_%s(%s)" % [py_ident(eid), _call_args(eid)])
		var arm_fns: Array[String] = []
		for arm in n.arms:
			var ents: Array = arm["entities"]
			if ents.is_empty():
				continue
			var head := String(ents[0])
			if _uses_sources(head):
				# 扇出×sources：pool.map 的单实参 item 不能直塞 sources 形参
				# （旧实现 fn(item) 会把支路值错绑进 sources 解包，多路来源全丢）。
				# 包装成显式 sources 聚合：v_item=支路值 + 各数据入边来源闭包捕获。
				var wrap := "_fan_%s" % py_ident(head)
				line(depth, '%s = lambda item: step_%s(sources={%s})' % [wrap, py_ident(head), _sources_pairs(head, true)])
				arm_fns.append(wrap)
			else:
				arm_fns.append("step_%s" % py_ident(head))
		line(depth, "arms = [%s]" % ", ".join(PackedStringArray(arm_fns)))
		line(depth, "with concurrent.futures.ThreadPoolExecutor(max_workers=len(arms)) as _pool:")
		line(depth + 1, "fan_results = list(_pool.map(lambda fn, item: fn(item), arms, branches))")
		for i in range(n.arms.size()):
			var ents: Array = n.arms[i]["entities"]
			if not ents.is_empty():
				line(depth, "v_%s = fan_results[%d]" % [py_ident(String(ents[0])), i])
		for i in range(n.arms.size()):
			var ents: Array = n.arms[i]["entities"]
			for j in range(1, ents.size()):
				_emit_step(String(ents[j]), depth)

	func _emit_join(n, depth: int) -> void:
		line(depth, "state = step_%s(%s)" % [py_ident(n.entity), _call_args(n.entity)])

	# ---------- 调用参数（数据流布线） ----------

	func _call_args(eid: String) -> String:
		var e = graph.entity(eid)
		if e.kind == "join":
			var srcs: Array[String] = []
			for c in graph.data_in_edges(eid):
				if not srcs.has(c.from_entity):
					srcs.append(c.from_entity)
			if srcs.is_empty():
				for c in graph.ctrl_in_edges(eid):
					if not srcs.has(c.from_entity):
						srcs.append(c.from_entity)
			srcs.sort()
			var vars: Array[String] = []
			for s in srcs:
				vars.append("v_%s" % py_ident(s))
			return "[%s]" % ", ".join(PackedStringArray(vars))
		var parts: Array[String] = []
		if _uses_sources(eid):
			# 多路数据入边：聚合为 sources={"v_*": v_*} 单一 dict 实参
			# （旧实现 conn_by_port 后写覆盖，实体只拿到排序最后一条边的值）。
			parts.append("sources={%s}" % _sources_pairs(eid, false))
		else:
			var conn_by_port := {}
			for c in graph.data_in_edges(eid):
				conn_by_port[c.to_port] = c
			for p in e.ports:
				if p.kind != GM.DATA or p.dir != "in":
					continue
				var c = conn_by_port.get(p.name)
				if c != null:
					parts.append("v_%s" % py_ident(c.from_entity))
				elif e.kind != "entry":
					parts.append("state")
		var keys: Array = e.params.keys()
		keys.sort()
		for pname in keys:
			var spec: Dictionary = e.params[pname]
			parts.append("%s=%s" % [pname, _py_literal(spec["value"], String(spec["type"]))])
		return ", ".join(PackedStringArray(parts))

	## sources 聚合实参的 "键": 值 对列表。with_item=true 时并入
	## "v_item": item——值表达式是扇出包装 lambda 的形参 item（支路值）；
	## 实体名恰为 item 的撞名场景由 check_errors 前置报
	## FANOUT_ITEM_NAME_COLLISION（不再静默丢支路值），此处 item_slot=false
	## 仅作防御性回退（正常流程到不了）。
	func _sources_pairs(eid: String, with_item: bool) -> String:
		var uniq := {}
		for c in graph.data_in_edges(eid):
			uniq["v_%s" % py_ident(c.from_entity)] = true
		var item_slot := with_item and not uniq.has("v_item")
		if item_slot:
			uniq["v_item"] = true
		var names: Array = uniq.keys()
		names.sort()
		var pairs: Array[String] = []
		for n in names:
			var val := String(n)
			if item_slot and String(n) == "v_item":
				val = "item"
			pairs.append('"%s": %s' % [String(n), val])
		return ", ".join(PackedStringArray(pairs))

	## 数据入边按端口分组：端口名 -> 排序去重的来源变量名（v_*）。
	func _in_port_sources(eid: String) -> Dictionary:
		var by_port := {}
		for c in graph.data_in_edges(eid):
			var v := "v_%s" % py_ident(c.from_entity)
			if not by_port.has(c.to_port):
				by_port[c.to_port] = []
			if not (by_port[c.to_port] as Array).has(v):
				(by_port[c.to_port] as Array).append(v)
		for pname in by_port.keys():
			(by_port[pname] as Array).sort()
		return by_port

	## 非 join/entry 实体且某数据入端口接 >=2 条边 → 该实体的数据实参
	## 聚合为 sources={...}（语义无损；validate 发 MULTI_DATA_IN_EDGE 告警）。
	func _uses_sources(eid: String) -> bool:
		var e = graph.entity(eid)
		if e == null or e.kind == "join" or e.kind == "entry":
			return false
		var by_port := _in_port_sources(eid)
		for pname in by_port.keys():
			if (by_port[pname] as Array).size() >= 2:
				return true
		return false

	## sources 解包：把聚合实参按端口重新绑定为各端口的形参名——
	## 多来源端口得到以来源变量名为键的子 dict，单来源端口取值，无来源为 None。
	## 扇出臂首实体额外把 v_item（支路值）并入首数据入端口的来源列表，
	## 与 pool.map 的位置语义对齐（fn(item) 本应绑到首个数据形参）。
	func _emit_sources_prologue(eid: String, e) -> void:
		var by_port := _in_port_sources(eid)
		var head_first := ""
		if fanout_heads.has(eid):
			head_first = _first_data_in_port(e)
		line(1, "_sources = sources if isinstance(sources, dict) else {}")
		for p in e.ports:
			if p.kind != GM.DATA or p.dir != "in":
				continue
			var arg: String = "state" if p.name == "in" else p.name
			var srcs: Array = (by_port.get(p.name, []) as Array).duplicate()
			if head_first != "" and p.name == head_first and not srcs.has("v_item"):
				srcs.append("v_item")
				srcs.sort()
			if srcs.is_empty():
				line(1, "%s = None" % arg)
			elif srcs.size() == 1:
				line(1, '%s = _sources.get("%s")' % [arg, String(srcs[0])])
			else:
				var quoted: Array[String] = []
				for s in srcs:
					quoted.append('"%s"' % String(s))
				line(1, '%s = {k: v for k, v in _sources.items() if k in (%s)}' % [arg, ", ".join(PackedStringArray(quoted))])

	## 收集扇出臂首实体（含 loop 体嵌套的 fanout；branch 臂内不再嵌 fanout，
	## _emit_branch 只发射直链步骤，与 _emit_stmts 的能力一致）。
	func _collect_fanout_heads(nodes: Array, out: Dictionary) -> void:
		for n in nodes:
			if n.kind == "fanout":
				for arm in n.arms:
					var ents: Array = arm["entities"]
					if not ents.is_empty():
						out[String(ents[0])] = true
			elif n.kind == "loop":
				_collect_fanout_heads(n.body, out)

	## 声明顺序上的首个数据入端口名（无则空串）——扇出 item 的位置落点。
	func _first_data_in_port(e) -> String:
		for p in e.ports:
			if p.kind == GM.DATA and p.dir == "in":
				return p.name
		return ""

	# ---------- main 自测 ----------

	func _emit_main() -> void:
		lines.append("def main() -> int:")
		lines.append('    """自测入口：跑一遍 run()，断言返回 dict 并打印结果。"""')
		lines.append("    result = run()")
		lines.append('    assert isinstance(result, dict), "run() 必须返回 dict"')
		lines.append('    print("%s ok:", json.dumps(result, ensure_ascii=False, sort_keys=True, default=str))' % ir.name)
		lines.append("    return 0")
		lines.append("")
		lines.append("")
		lines.append('if __name__ == "__main__":')
		lines.append("    raise SystemExit(main())")

	# ---------- 工具 ----------

	static func _err_key(e: Dictionary) -> String:
		return "%s|%s|%s" % [e.get("code", ""), e.get("entity_id", ""), e.get("port_ref", "")]

	func py_ident(eid: String) -> String:
		var out: String = eid.to_snake_case()
		var safe := ""
		for ch in out:
			var ok := (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_"
			safe += ch if ok else "_"
		if safe == "" or (safe[0] >= "0" and safe[0] <= "9"):
			safe = "e_" + safe
		return safe

	static func _port_ann(ptype: String) -> String:
		match ptype:
			"json":
				return "dict"
			"text":
				return "str"
			"number":
				return "float"
			"bool":
				return "bool"
			"list":
				return "list"
		return "dict"

	static func _py_ann(t: String) -> String:
		match t:
			"int":
				return "int"
			"number":
				return "float"
			"bool":
				return "bool"
			"list":
				return "tuple"
		return "str"

	static func _py_literal(v: Variant, t: String) -> String:
		match typeof(v):
			TYPE_BOOL:
				return "True" if bool(v) else "False"
			TYPE_INT, TYPE_FLOAT:
				if t == "int":
					return str(int(roundf(float(v))))
				return _py_float(float(v))
			TYPE_STRING:
				return '"%s"' % String(v).replace("\\", "\\\\").replace('"', '\\"')
			TYPE_ARRAY:
				var parts: Array[String] = []
				for item in v:
					parts.append(_py_literal(item, ""))
				return "(%s)" % ", ".join(PackedStringArray(parts))
		return "None"

	static func _py_float(v: float) -> String:
		return str(v)
