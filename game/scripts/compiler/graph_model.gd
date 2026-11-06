extends RefCounted

## 方块编译器 · 图数据结构（docs/10-契约/方块体系.md §6.2 编译器契约）。
##
## 契约要点（硬约束）：
## - 输入：连接图 + 参数 + 装配层次（实体/端口/连接/参数/折叠组）。
## - **不读位置与朝向**：parse 阶段即丢弃坐标类字段，同一逻辑不同摆法
##   必须编译出字节级相同的代码（位置无关）。
## - **折叠不变量**（§6.3）：fold_groups 只是视图标记，本模块原样保留、
##   语义上不使用；fold/unfold 绝不动连接与参数。
## - 可从 Dictionary（JSON 反序列化的形状）构建；未知字段一律忽略。
##
## 本模块不使用 class_name，消费方一律 preload（见 compiler.gd），
## 避免新建脚本的全局类名缓存问题。

const DATA := "data"
const CONTROL := "control"


class PortDef extends RefCounted:
	## 端口：kind=data|control；dir=in|out；type 对 data 是
	## any|json|text|number|bool|list（用于类型校验），对 control 是
	## seq|then|elif|else|parallel|exit（用于拓扑识别：分岔/扇出/显式出口）。
	var name := ""
	var kind := DATA
	var dir := "in"
	var required := false
	var type := "any"


class EntityDef extends RefCounted:
	## 实体（一个代码结构方块）。kind 是语义角色，见 codegen_python.gd 的模板注册表。
	var id := ""
	var kind := "step"
	var ports: Array[PortDef] = []
	## 参数名 -> {value, type, min, max}（type: int|number|string|bool|list）
	var params: Dictionary = {}
	var fold_group := ""


class Connection extends RefCounted:
	## 一条连接：端口引用形如 "实体id.端口名"。kind 取来源端口的 kind。
	var from_entity := ""
	var from_port := ""
	var to_entity := ""
	var to_port := ""
	var kind := DATA


class BlockGraph extends RefCounted:
	var name := "graph"
	## id -> EntityDef
	var entities: Dictionary = {}
	## 规范化实体顺序（按 id 排序）——一切迭代都以它为准，保证确定性。
	var order: Array[String] = []
	var connections: Array[Connection] = []
	## [{id: String, members: [String]}]——只读视图标记，编译语义不使用。
	var fold_groups: Array[Dictionary] = []

	func entity(id: String) -> EntityDef:
		return entities.get(id)

	func port_of(eid: String, pname: String) -> PortDef:
		var e := entity(eid)
		if e == null:
			return null
		for p in e.ports:
			if p.name == pname:
				return p
		return null

	func has_control(eid: String) -> bool:
		for c in connections:
			if c.kind == CONTROL and (c.from_entity == eid or c.to_entity == eid):
				return true
		return false

	func ctrl_out_edges(eid: String) -> Array:
		var res: Array = []
		for c in connections:
			if c.kind == CONTROL and c.from_entity == eid:
				res.append(c)
		return res

	func ctrl_in_edges(eid: String) -> Array:
		var res: Array = []
		for c in connections:
			if c.kind == CONTROL and c.to_entity == eid:
				res.append(c)
		return res

	func data_out_edges(eid: String) -> Array:
		var res: Array = []
		for c in connections:
			if c.kind == DATA and c.from_entity == eid:
				res.append(c)
		return res

	func data_in_edges(eid: String) -> Array:
		var res: Array = []
		for c in connections:
			if c.kind == DATA and c.to_entity == eid:
				res.append(c)
		return res


## 从 Dictionary 构建（JSON 反序列化后的形状即此形状）。
## 位置/朝向等字段在这里被显式丢弃——编译器不读几何（契约 §6.2）。
static func parse(dict: Dictionary) -> BlockGraph:
	if not (dict is Dictionary):
		push_error("graph_model: 输入必须是 Dictionary")
		return null
	var g := BlockGraph.new()
	g.name = String(dict.get("name", "graph"))

	var ents: Array = dict.get("entities", [])
	for e in ents:
		if not (e is Dictionary):
			continue
		var def := EntityDef.new()
		def.id = String(e.get("id", ""))
		def.kind = String(e.get("kind", "step"))
		def.fold_group = String(e.get("fold_group", ""))
		if def.id == "":
			push_error("graph_model: 实体缺少 id，已跳过")
			continue
		var known_ports := {}
		for p in e.get("ports", []):
			if not (p is Dictionary):
				continue
			var pd := PortDef.new()
			pd.name = String(p.get("name", ""))
			pd.dir = String(p.get("dir", "in"))
			pd.kind = String(p.get("kind", DATA))
			pd.required = bool(p.get("required", false))
			pd.type = String(p.get("type", "seq" if pd.kind == CONTROL else "any"))
			if pd.name == "" or known_ports.has(pd.name):
				continue
			known_ports[pd.name] = true
			def.ports.append(pd)
		var raw_params: Dictionary = e.get("params", {})
		for pname in raw_params.keys():
			def.params[pname] = _normalize_param(raw_params[pname])
		if g.entities.has(def.id):
			push_error("graph_model: 实体 id 重复 %s，后者覆盖前者" % def.id)
		g.entities[def.id] = def

	for id in g.entities.keys():
		g.order.append(id)
	g.order.sort()

	var ent_ids := {}
	for id in g.order:
		ent_ids[id] = true
	for c in dict.get("connections", []):
		if not (c is Dictionary):
			continue
		var conn := Connection.new()
		var f := String(c.get("from", "")).split(".", false, 1)
		var t := String(c.get("to", "")).split(".", false, 1)
		if f.size() != 2 or t.size() != 2:
			continue
		conn.from_entity = f[0]
		conn.from_port = f[1]
		conn.to_entity = t[0]
		conn.to_port = t[1]
		if not ent_ids.has(conn.from_entity) or not ent_ids.has(conn.to_entity):
			push_warning("graph_model: 连接引用未知实体，已跳过 %s" % [c])
			continue
		var sp := g.port_of(conn.from_entity, conn.from_port)
		if sp != null:
			conn.kind = sp.kind
		g.connections.append(conn)

	# 连接规范化排序：同逻辑不同声明顺序 → 相同的连接序列。
	g.connections.sort_custom(func(a: Connection, b: Connection) -> bool:
		return _conn_key(a) < _conn_key(b))

	for grp in dict.get("fold_groups", []):
		if grp is Dictionary and String(grp.get("id", "")) != "":
			var members: Array = []
			for m in grp.get("members", []):
				if ent_ids.has(m) and not members.has(m):
					members.append(m)
			members.sort()
			g.fold_groups.append({"id": String(grp["id"]), "members": members})
	g.fold_groups.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"]))
	return g


## JSON 文本直接构建（等价于 JSON.parse_string 后再 parse）。
static func from_json(text: String) -> BlockGraph:
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary:
		return parse(parsed)
	push_error("graph_model: JSON 解析失败")
	return null


static func _conn_key(c: Connection) -> String:
	return "%s.%s->%s.%s" % [c.from_entity, c.from_port, c.to_entity, c.to_port]


## 参数规范化：紧凑形式（直接是值）与完整形式（{value,type,min,max}）统一。
## 数值无显式 type 时按“是否整数”归一为 int/number——这样 JSON 往返
## （4 变 4.0）后编译输出仍然字节级相同。
static func _normalize_param(raw: Variant) -> Dictionary:
	var spec := {"value": null, "type": "", "min": null, "max": null}
	if raw is Dictionary:
		spec["value"] = raw.get("value", null)
		var t := String(raw.get("type", ""))
		spec["type"] = t if t != "" else _infer_type(spec["value"])
		if raw.get("min", null) != null:
			spec["min"] = raw["min"]
		if raw.get("max", null) != null:
			spec["max"] = raw["max"]
	else:
		spec["value"] = raw
		spec["type"] = _infer_type(raw)
	return spec


static func _infer_type(v: Variant) -> String:
	match typeof(v):
		TYPE_BOOL:
			return "bool"
		TYPE_INT, TYPE_FLOAT:
			return "int" if absf(float(v) - roundf(float(v))) < 0.000001 else "number"
		TYPE_STRING:
			return "string"
		TYPE_ARRAY:
			return "list"
	return "string"
