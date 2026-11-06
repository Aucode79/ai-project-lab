extends RefCounted

## 方块编译器 · 编译期校验（docs/10-契约/方块体系.md §6.2）。
##
## 五条硬校验（拼装即时反馈的数据源）：
##   PORT_TYPE_MISMATCH        端口类型不匹配
##   REQUIRED_PORT_UNCONNECTED 必需端口未连接
##   PARAM_OUT_OF_RANGE        参数越界（或类型不符）
##   IMPLICIT_DEPENDENCY_CYCLE 隐式依赖成环（数据环不在任何显式循环内）
##   LOOP_MISSING_EXIT         循环缺显式出口
##
## 另有编译期**告警**（不阻断产码）：
##   MULTI_DATA_IN_EDGE        非 join 实体的同一数据入端口接 >=2 条边
##                             （codegen 会聚合为 sources 实参，语义无损，
##                              但建议用 join 显式汇聚）。告警条目带
##                             severity:"warning" 字段，只经 warnings() /
##                             validate_with_warnings() 返回，不进 validate()。
##
## 一次编译返回**全部**错误而非首个；每条错误结构化：
##   {code: String, entity_id: String, port_ref: String, message: String}
## （entity_id 与 port_ref 至少其一非空；port_ref 形如 "实体.端口"。）
## 混合清单里无 severity 字段 = error（阻断产码）。
## 运行期校验（物理是否卡住、输入是否坏）与此分开，不在这里。

const GM := preload("res://scripts/compiler/graph_model.gd")
const IRB := preload("res://scripts/compiler/ir.gd")

const PORT_TYPE_MISMATCH := "PORT_TYPE_MISMATCH"
const REQUIRED_PORT_UNCONNECTED := "REQUIRED_PORT_UNCONNECTED"
const PARAM_OUT_OF_RANGE := "PARAM_OUT_OF_RANGE"
const IMPLICIT_DEPENDENCY_CYCLE := "IMPLICIT_DEPENDENCY_CYCLE"
const LOOP_MISSING_EXIT := "LOOP_MISSING_EXIT"
const MULTI_DATA_IN_EDGE := "MULTI_DATA_IN_EDGE"


static func validate(graph) -> Array[Dictionary]:
	var errors: Array[Dictionary] = []
	_check_port_types(graph, errors)
	_check_required_ports(graph, errors)
	_check_params(graph, errors)
	_check_implicit_cycles(graph, errors)
	_check_loop_exits(graph, errors)
	errors.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _err_key(a) < _err_key(b))
	return errors


## 只返回告警（severity:"warning"，不阻断产码）。compile() 走 validate()
## 拿硬错误，不会因告警拒绝产码；需要"错误+告警"混合清单的调用方用
## validate_with_warnings()。
static func warnings(graph) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	_check_multi_data_in_edges(graph, result)
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _err_key(a) < _err_key(b))
	return result


## errors + warnings 一次返回：无 severity 字段 = error（阻断产码），
## severity=="warning" = 告警（不阻断）。
static func validate_with_warnings(graph) -> Array[Dictionary]:
	var all := validate(graph)
	all.append_array(warnings(graph))
	all.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return _err_key(a) < _err_key(b))
	return all


static func _err(eid: String, port_ref: String, code: String, message: String) -> Dictionary:
	return {"code": code, "entity_id": eid, "port_ref": port_ref, "message": message}


static func _warn(eid: String, port_ref: String, code: String, message: String) -> Dictionary:
	var e := _err(eid, port_ref, code, message)
	e["severity"] = "warning"
	return e


static func _check_multi_data_in_edges(graph, warns: Array[Dictionary]) -> void:
	for eid in graph.order:
		var e = graph.entity(eid)
		if e.kind == "join":
			continue  # join 的多路数据入边是设计语义（results 列表聚合）
		var by_port := {}
		for c in graph.data_in_edges(eid):
			if not by_port.has(c.to_port):
				by_port[c.to_port] = []
			if not (by_port[c.to_port] as Array).has(c.from_entity):
				(by_port[c.to_port] as Array).append(c.from_entity)
		var ports: Array = by_port.keys()
		ports.sort()
		for pname in ports:
			var srcs: Array = by_port[pname]
			if srcs.size() < 2:
				continue
			srcs.sort()
			warns.append(_warn(
				eid, "%s.%s" % [eid, pname], MULTI_DATA_IN_EDGE,
				"多路数据入边：%s.%s 接到 %d 条边（来自 %s），多路来源已聚合为 sources 实参（语义无损，建议用 join 显式汇聚）" % [eid, pname, srcs.size(), "、".join(PackedStringArray(srcs))]))


static func _err_key(e: Dictionary) -> String:
	return "%s|%s|%s" % [e.get("code", ""), e.get("entity_id", ""), e.get("port_ref", "")]


static func _check_port_types(graph, errors: Array[Dictionary]) -> void:
	for c in graph.connections:
		if c.kind != GM.DATA:
			continue  # 控制端口的 type 是结构角色（then/parallel/exit…），不做数据类型校验
		var sp = graph.port_of(c.from_entity, c.from_port)
		var tp = graph.port_of(c.to_entity, c.to_port)
		if sp == null or tp == null:
			continue
		if sp.type == "any" or tp.type == "any" or sp.type == tp.type:
			continue
		errors.append(_err(
			c.to_entity, "%s.%s" % [c.to_entity, c.to_port], PORT_TYPE_MISMATCH,
			"端口类型不匹配：%s.%s(%s) -> %s.%s(%s)" % [
				c.from_entity, c.from_port, sp.type,
				c.to_entity, c.to_port, tp.type]))


static func _check_required_ports(graph, errors: Array[Dictionary]) -> void:
	for eid in graph.order:
		var e = graph.entity(eid)
		for p in e.ports:
			if not p.required:
				continue
			var connected := false
			if p.dir == "in":
				for c in graph.data_in_edges(eid):
					if c.to_port == p.name:
						connected = true
						break
				for c in graph.ctrl_in_edges(eid):
					if c.to_port == p.name:
						connected = true
						break
			else:
				for c in graph.data_out_edges(eid):
					if c.from_port == p.name:
						connected = true
						break
				for c in graph.ctrl_out_edges(eid):
					if c.from_port == p.name:
						connected = true
						break
			if not connected:
				errors.append(_err(
					eid, "%s.%s" % [eid, p.name], REQUIRED_PORT_UNCONNECTED,
					"必需端口未连接：%s.%s（%s 端口，required=true）" % [eid, p.name, p.dir]))


static func _check_params(graph, errors: Array[Dictionary]) -> void:
	for eid in graph.order:
		var e = graph.entity(eid)
		var keys: Array = e.params.keys()
		keys.sort()
		for pname in keys:
			var spec: Dictionary = e.params[pname]
			var v: Variant = spec.get("value", null)
			var t := String(spec.get("type", ""))
			var problems: Array[String] = []
			match t:
				"int":
					if not (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) or absf(float(v) - roundf(float(v))) > 0.000001:
						problems.append("应为整数，得到 %s" % str(v))
				"number":
					if not (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT):
						problems.append("应为数值，得到 %s" % str(v))
				"string":
					if typeof(v) != TYPE_STRING:
						problems.append("应为字符串，得到 %s" % str(v))
				"bool":
					if typeof(v) != TYPE_BOOL:
						problems.append("应为布尔，得到 %s" % str(v))
				"list":
					if typeof(v) != TYPE_ARRAY:
						problems.append("应为列表，得到 %s" % str(v))
			if spec.get("min", null) != null and (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT):
				if float(v) < float(spec["min"]):
					problems.append("低于下限 %s" % str(spec["min"]))
			if spec.get("max", null) != null and (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT):
				if float(v) > float(spec["max"]):
					problems.append("高于上限 %s" % str(spec["max"]))
			if not problems.is_empty():
				errors.append(_err(
					eid, "", PARAM_OUT_OF_RANGE,
					"参数越界：%s.%s = %s（%s）" % [eid, pname, str(v), "；".join(PackedStringArray(problems))]))


static func _check_implicit_cycles(graph, errors: Array[Dictionary]) -> void:
	# 数据依赖环：若环上所有实体同处一个显式控制环（控制强连通分量）内，
	# 则是合法的递推（由 while 驱动）；否则是隐式依赖成环，编译期拒绝。
	var nodes: Array[String] = []
	for c in graph.connections:
		if c.kind != GM.DATA:
			continue
		if not nodes.has(c.from_entity):
			nodes.append(c.from_entity)
		if not nodes.has(c.to_entity):
			nodes.append(c.to_entity)
	if nodes.is_empty():
		return
	nodes.sort()
	var adj := {}
	var node_set := {}
	for n in nodes:
		node_set[n] = true
		adj[n] = []
	for c in graph.connections:
		if c.kind != GM.DATA:
			continue
		if node_set.has(c.from_entity) and node_set.has(c.to_entity):
			if not adj[c.from_entity].has(c.to_entity):
				adj[c.from_entity].append(c.to_entity)
	for n in nodes:
		(adj[n] as Array).sort()

	var comps := IRB.strongly_connected(nodes, adj)
	var ctrl_comps := IRB.control_components(graph)
	var ctrl_adj := IRB.control_adjacency(graph)
	var comp_of := {}
	for i in range(ctrl_comps.size()):
		for m in ctrl_comps[i]:
			comp_of[m] = i

	for comp in comps:
		var is_data_loop := comp.size() > 1 or (adj[comp[0]] as Array).has(comp[0])
		if not is_data_loop:
			continue
		var ok := false
		var all_known := true
		var first_ci: int = -1
		for m in comp:
			var ci: int = int(comp_of.get(m, -1))
			if ci < 0:
				all_known = false
				break
			if first_ci < 0:
				first_ci = ci
			elif ci != first_ci:
				first_ci = -2
				break
		if all_known and first_ci >= 0:
			var ccomp: Array = ctrl_comps[first_ci]
			if ccomp.size() > 1 or (ctrl_adj.get(ccomp[0], []) as Array).has(ccomp[0]):
				ok = true  # 数据环整体落在显式控制环内：合法递推
		if not ok:
			var chain: String = " -> ".join(PackedStringArray(comp)) + " -> " + String(comp[0])
			errors.append(_err(
				comp[0], "", IMPLICIT_DEPENDENCY_CYCLE,
				"隐式依赖成环（不在任何显式循环内）：%s" % chain))


static func _check_loop_exits(graph, errors: Array[Dictionary]) -> void:
	var comps := IRB.control_components(graph)
	var adj := IRB.control_adjacency(graph)
	for comp in comps:
		var is_loop := comp.size() > 1 or (adj.get(comp[0], []) as Array).has(comp[0])
		if not is_loop:
			continue
		var has_exit := false
		for m in comp:
			for c in graph.ctrl_out_edges(m):
				if comp.has(c.to_entity):
					continue
				var p = graph.port_of(m, c.from_port)
				if p != null and p.type == "exit":
					has_exit = true
					break
			if has_exit:
				break
		if not has_exit:
			errors.append(_err(
				comp[0], "", LOOP_MISSING_EXIT,
				"循环缺显式出口：{%s} 成环但没有 exit 端口的控制边离开" % ", ".join(PackedStringArray(comp))))
