extends RefCounted

## 方块编译器 · 中间表示（IR）。
##
## 连接图 → IR（数据流 + 控制流）→ Python 源码（codegen_python.gd）。
## IR 是编译器内部结构，**不暴露给学员**（契约 §6.2）。
##
## 控制流节点五类（对应 docs/10-契约/方块体系.md §二 的五种拓扑）：
##   seq    —— 直线型：一路走到底
##   branch —— 分岔型：Y 形岔口（then/elif/else 支路）
##   loop   —— 带环型：回环，**必须显式出口**（exit 端口离开强连通分量）
##   fanout —— 扇出型：一发多路（parallel 端口，并发示意）
##   join   —— 汇聚型：多路归一（合并前驱结果）
##
## 确定性：同一连接图（与摆法、折叠层次无关）→ 唯一的 IR 与 canonical_text。

const GM := preload("res://scripts/compiler/graph_model.gd")

const K_SEQ := "seq"
const K_BRANCH := "branch"
const K_LOOP := "loop"
const K_FANOUT := "fanout"
const K_JOIN := "join"

## 支路发射顺序：then → elif → else → parallel → 其它按端口名。
const ARM_PRIORITY := {"then": 0, "elif": 1, "else": 2, "parallel": 3}


class IRNode extends RefCounted:
	var kind := K_SEQ
	## 主实体（seq/branch/fanout/join 的载体；loop 为空串）。
	var entity := ""
	## loop 体的子节点序列。
	var body: Array[IRNode] = []
	## branch/fanout 的支路：{label: String, port: String, entities: Array}。
	var arms: Array[Dictionary] = []
	## join 的前驱实体（按 id 排序）。
	var sources: Array[String] = []
	## loop 的显式出口目标实体。
	var exits: Array[String] = []
	## loop 的出口判定实体（持有 exit 端口、guard 语义的成员）。
	var guard := ""


class IRProgram extends RefCounted:
	var name := "graph"
	var statements: Array[IRNode] = []
	## 全部实体 id（规范化顺序）——codegen 据此发射函数。
	var entities: Array[String] = []
	## 规范化数据边（"a.out->b.in"）——IR 的数据流面。
	var data_flow: Array[String] = []

	func canonical_text() -> String:
		var lines: PackedStringArray = ["program|%s" % name]
		for e in entities:
			lines.append("ent|%s" % e)
		for d in data_flow:
			lines.append("data|%s" % d)
		for s in statements:
			for piece in _node_text(s, 1):
				lines.append(piece)
		return "\n".join(lines)

	func _node_text(n: IRNode, depth: int) -> PackedStringArray:
		var pad := "  ".repeat(depth)
		var lines: PackedStringArray = []
		match n.kind:
			K_SEQ:
				lines.append("%sseq|%s" % [pad, n.entity])
			K_BRANCH:
				var arm_strs: Array[String] = []
				for arm in n.arms:
					arm_strs.append("%s:%s" % [arm["label"], "+".join(PackedStringArray(arm["entities"]))])
				lines.append("%sbranch|%s|%s" % [pad, n.entity, "|".join(PackedStringArray(arm_strs))])
			K_FANOUT:
				var f_arm_strs: Array[String] = []
				for arm in n.arms:
					f_arm_strs.append("%s:%s" % [arm["label"], "+".join(PackedStringArray(arm["entities"]))])
				lines.append("%sfanout|%s|%s" % [pad, n.entity, "|".join(PackedStringArray(f_arm_strs))])
			K_JOIN:
				lines.append("%sjoin|%s|%s" % [pad, n.entity, "+".join(PackedStringArray(n.sources))])
			K_LOOP:
				lines.append("%sloop|guard=%s|exits=%s" % [pad, n.guard, ",".join(PackedStringArray(n.exits))])
				for child in n.body:
					for piece in _node_text(child, depth + 1):
						lines.append(piece)
		return lines


## 强连通分量（迭代版 Tarjan）。nodes 与 adj 的邻居表需已排序，输出确定。
static func strongly_connected(nodes: Array[String], adj: Dictionary) -> Array[Array]:
	var index := {}
	var low := {}
	var on_stack := {}
	var stack: Array[String] = []
	var counter := 0
	var result: Array[Array] = []
	var valid := {}
	for n in nodes:
		valid[n] = true
	for root in nodes:
		if index.has(root):
			continue
		var call_stack: Array = [[root, 0]]
		while not call_stack.is_empty():
			var frame: Array = call_stack[call_stack.size() - 1]
			var v: String = frame[0]
			if int(frame[1]) == 0:
				index[v] = counter
				low[v] = counter
				counter += 1
				stack.append(v)
				on_stack[v] = true
			var neighbors: Array = adj.get(v, [])
			var advanced := false
			while int(frame[1]) < neighbors.size():
				var w: String = neighbors[int(frame[1])]
				frame[1] = int(frame[1]) + 1
				if not valid.has(w):
					continue
				if not index.has(w):
					call_stack.append([w, 0])
					advanced = true
					break
				elif bool(on_stack.get(w, false)):
					low[v] = mini(int(low[v]), int(index[w]))
			if advanced:
				continue
			call_stack.pop_back()
			if not call_stack.is_empty():
				var parent: Array = call_stack[call_stack.size() - 1]
				low[parent[0]] = mini(int(low[parent[0]]), int(low[v]))
			if int(low[v]) == int(index[v]):
				var comp: Array[String] = []
				while true:
					var w: String = stack.pop_back()
					on_stack[w] = false
					comp.append(w)
					if w == v:
						break
				comp.sort()
				result.append(comp)
	return result


## 控制邻接表：id -> 排序后的后继列表（仅含控制节点）。
static func control_adjacency(graph) -> Dictionary:
	var ctrl_nodes: Array[String] = []
	for id in graph.order:
		if graph.has_control(id):
			ctrl_nodes.append(id)
	ctrl_nodes.sort()
	var adj := {}
	var node_set := {}
	for id in ctrl_nodes:
		node_set[id] = true
	for id in ctrl_nodes:
		var ns: Array[String] = []
		for c in graph.ctrl_out_edges(id):
			if node_set.has(c.to_entity) and not ns.has(c.to_entity):
				ns.append(c.to_entity)
		ns.sort()
		adj[id] = ns
	return adj


## 控制图的强连通分量（loop 候选）。
static func control_components(graph) -> Array[Array]:
	var ctrl_nodes: Array[String] = []
	for id in graph.order:
		if graph.has_control(id):
			ctrl_nodes.append(id)
	ctrl_nodes.sort()
	return strongly_connected(ctrl_nodes, control_adjacency(graph))


## 图 → IR。识别五类控制子图；loop 强制要求显式出口（缺失由 validate 报错，
## 这里只负责识别与记录，不给 loop 凭空造出口）。
static func build(graph) -> IRProgram:
	var prog := IRProgram.new()
	prog.name = graph.name
	prog.entities = graph.order.duplicate()
	for c in graph.connections:
		if c.kind == GM.DATA:
			prog.data_flow.append("%s.%s->%s.%s" % [c.from_entity, c.from_port, c.to_entity, c.to_port])
	prog.data_flow.sort()

	var adjacency := control_adjacency(graph)
	var ctrl_nodes: Array[String] = []
	for id in adjacency.keys():
		ctrl_nodes.append(id)
	ctrl_nodes.sort()
	var comps := strongly_connected(ctrl_nodes, adjacency)
	var comp_of := {}
	for i in range(comps.size()):
		for m in comps[i]:
			comp_of[m] = i

	# 缩点 DAG + 入度（Kahn 拓扑，ready 按分量代表 id 排序，确定性）。
	var cadj: Array[Array] = []
	var indeg: Array[int] = []
	for i in range(comps.size()):
		cadj.append([])
		indeg.append(0)
	for i in range(comps.size()):
		var seen := {}
		for m in comps[i]:
			for w in adjacency.get(m, []):
				var j: int = comp_of[w]
				if j != i and not seen.has(j):
					seen[j] = true
					cadj[i].append(j)
					indeg[j] += 1
		cadj[i].sort()
	var ready: Array[int] = []
	for i in range(comps.size()):
		if indeg[i] == 0:
			ready.append(i)
	var topo: Array[int] = []
	var done := {}
	while topo.size() < comps.size():
		if ready.is_empty():
			for i in range(comps.size()):
				if not done.has(i):
					ready.append(i)
					break
		ready.sort()
		var i: int = ready.pop_front()
		if done.has(i):
			continue
		done[i] = true
		topo.append(i)
		for j in cadj[i]:
			if not done.has(j):
				indeg[j] -= 1
				if indeg[j] <= 0:
					ready.append(j)

	var visited := {}
	for ci in topo:
		var comp: Array[String] = comps[ci]
		if comp.size() > 1 or adjacency.get(comp[0], []).has(comp[0]):
			prog.statements.append(_build_loop(graph, comp, adjacency, visited))
		else:
			var e: String = comp[0]
			if visited.has(e):
				continue
			prog.statements.append(_build_node(graph, e, visited))
	return prog


static func _build_node(graph, eid: String, visited: Dictionary) -> IRNode:
	var ekind: String = graph.entity(eid).kind
	var outs: Array = graph.ctrl_out_edges(eid)
	# guard 实体无论出度多少都按步骤发射（出口判定走 if + break，
	# 它的 exit 边由 _build_loop 统一记录），否则会被误判成分岔。
	if outs.size() >= 2 and ekind != "guard":
		if _is_fanout(graph, eid, outs):
			return _build_fanout(graph, eid, outs, visited)
		return _build_branch(graph, eid, outs, visited)
	var ins: Array = graph.ctrl_in_edges(eid)
	if ins.size() >= 2 and ekind == "join":
		return _build_join(graph, eid, ins, visited)
	visited[eid] = true
	var n := IRNode.new()
	n.kind = K_SEQ
	n.entity = eid
	return n


static func _is_fanout(graph, eid: String, outs: Array) -> bool:
	var k: String = graph.entity(eid).kind
	if k == "split" or k == "fanout" or k == "parallel":
		return true
	for c in outs:
		var p = graph.port_of(eid, c.from_port)
		if p != null and p.type == "parallel":
			return true
	return false


static func _sorted_arms(graph, eid: String, outs: Array) -> Array:
	var arms: Array = []
	for c in outs:
		var p = graph.port_of(eid, c.from_port)
		var ptype: String = String(p.type) if p != null else "seq"
		var pname: String = c.from_port
		var label: String = ptype if ARM_PRIORITY.has(ptype) else pname
		arms.append({"conn": c, "label": label, "prio": int(ARM_PRIORITY.get(ptype, 9)), "pname": pname})
	arms.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a["prio"] != b["prio"]:
			return a["prio"] < b["prio"]
		if a["pname"] != b["pname"]:
			return a["pname"] < b["pname"]
		return a["conn"].to_entity < b["conn"].to_entity)
	return arms


static func _build_branch(graph, eid: String, outs: Array, visited: Dictionary) -> IRNode:
	var n := IRNode.new()
	n.kind = K_BRANCH
	n.entity = eid
	visited[eid] = true
	for arm in _sorted_arms(graph, eid, outs):
		var target: String = arm["conn"].to_entity
		var chain := _walk_chain(graph, target, visited)
		n.arms.append({"label": arm["label"], "port": arm["pname"], "entities": chain})
	return n


static func _build_fanout(graph, eid: String, outs: Array, visited: Dictionary) -> IRNode:
	var n := IRNode.new()
	n.kind = K_FANOUT
	n.entity = eid
	visited[eid] = true
	for arm in _sorted_arms(graph, eid, outs):
		var target: String = arm["conn"].to_entity
		var chain := _walk_chain(graph, target, visited)
		n.arms.append({"label": arm["label"], "port": arm["pname"], "entities": chain})
	return n


static func _build_join(graph, eid: String, ins: Array, visited: Dictionary) -> IRNode:
	var n := IRNode.new()
	n.kind = K_JOIN
	n.entity = eid
	visited[eid] = true
	var srcs: Array[String] = []
	for c in ins:
		if not srcs.has(c.from_entity):
			srcs.append(c.from_entity)
	srcs.sort()
	n.sources = srcs
	return n


static func _build_loop(graph, comp: Array[String], adjacency: Dictionary, visited: Dictionary) -> IRNode:
	var n := IRNode.new()
	n.kind = K_LOOP
	var members: Array[String] = comp.duplicate()
	members.sort()

	# 环内内部邻接（去掉自环）与入度。
	var inner := {}
	var indeg := {}
	for m in members:
		inner[m] = []
		indeg[m] = 0
	for m in members:
		for w in adjacency.get(m, []):
			if w != m and members.has(w):
				inner[m].append(w)
				indeg[w] = indeg[w] + 1

	# 环内拓扑：Kahn；全环（无零入度点）时以“有外部控制入边的最小成员”为起点，
	# 仍无则取最小 id——确定性优先。
	var ready: Array[String] = []
	for m in members:
		if int(indeg[m]) == 0:
			ready.append(m)
	if ready.is_empty():
		for m in members:
			var has_external := false
			for c in graph.ctrl_in_edges(m):
				if not members.has(c.from_entity):
					has_external = true
					break
			if has_external:
				ready.append(m)
				break
	if ready.is_empty():
		ready.append(members[0])
	var order: Array[String] = []
	var placed := {}
	while order.size() < members.size():
		if ready.is_empty():
			for m in members:
				if not placed.has(m):
					ready.append(m)
					break
		ready.sort()
		var v: String = ready.pop_front()
		if placed.has(v):
			continue
		placed[v] = true
		order.append(v)
		for w in inner[v]:
			if not placed.has(w):
				indeg[w] = indeg[w] - 1
				if int(indeg[w]) <= 0:
					ready.append(w)

	var local_visited := {}
	for m in order:
		if local_visited.has(m):
			continue
		n.body.append(_build_node(graph, m, local_visited))
	for m in members:
		local_visited[m] = true
	# 环体内支路吃到过的环外实体（如 else 支路接的出口节点）一并标记，
	# 否则它们会在环后被 condensation 再发射一次（重复调用）。
	for m in local_visited.keys():
		visited[m] = true

	# 显式出口：exit 端口的控制边离开环分量。guard = 持有 exit 端口的最小成员。
	var exits: Array[String] = []
	var guard := ""
	for m in members:
		for c in graph.ctrl_out_edges(m):
			if not members.has(c.to_entity):
				var p = graph.port_of(m, c.from_port)
				if p != null and p.type == "exit":
					if not exits.has(c.to_entity):
						exits.append(c.to_entity)
					if guard == "" or m < guard:
						guard = m
	exits.sort()
	n.exits = exits
	n.guard = guard
	for m in members:
		visited[m] = true
	return n


## 从支路入口沿控制边收集直链，直到：已访问 / 多后继 / 下一站是多入边的
## 汇合点 / 断头。链内成员标记 visited（含环外实体，如 else 支路接的出口节点）。
static func _walk_chain(graph, start: String, visited: Dictionary) -> Array[String]:
	var chain: Array[String] = []
	var cur := start
	while true:
		if visited.has(cur) or chain.has(cur):
			break
		chain.append(cur)
		var nexts: Array[String] = []
		for c in graph.ctrl_out_edges(cur):
			if not visited.has(c.to_entity) and not chain.has(c.to_entity):
				if not nexts.has(c.to_entity):
					nexts.append(c.to_entity)
		nexts.sort()
		if nexts.size() != 1:
			break
		var nxt: String = nexts[0]
		if graph.ctrl_in_edges(nxt).size() >= 2:
			break
		cur = nxt
	for id in chain:
		visited[id] = true
	return chain


static func sha256_hex(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()
