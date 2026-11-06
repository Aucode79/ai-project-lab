class_name WorldStateCore
extends Node

## 世界侧状态层内核（autoload 薄壳：autoload/world_state.gd）。
##
## 职责（spec §4.5 / §5 / §6 / §7.1 / §7.2）：
##   * 实体注册表：entityId = {assetId}#{序号}；装饰实体 fx:{assetId}#{序号}
##   * 实例绑定表 bindings: {assetId -> entityId}；**未绑定的实例不参与操作与高亮**
##   * 判定实体的位置与存在由本层管理（离散格点 Vector3i 语义，存 JSON 原生数组）
##   * 端口实例寻址 portRef = {entityId}:{portId}
##   * 端口模型：默认布尔；模拟量是显式端口类型（枚举 BOOL / ANALOG，序列化为字符串）
##   * 连接表 + 沿边传播（run / step 把 out 端口值写进 in 端口）
##   * 物理→逻辑事件入口 apply_physics_event：物理层把事件**上报一次**，
##     本层据此改逻辑状态。单向、显式；本层绝不反向触碰物理（见 core/physics_bridge.gd）
##
## 本层不知道渲染与物理引擎的存在：logical_snapshot() 只取状态层，
## 不掺任何物理内部量（速度、冲量、变换一概没有）。步记录里的 world 摘要也来自这里，
## 这是"同一份记录读两次、逻辑结论一致"（spec §7.3）的地基。

const WORLD_DT := 0.05

## 端口类型枚举。序列化形式是 "BOOL" / "ANALOG" 字符串（JSON 里明写，
## 对应 spec §7.2"模拟量做成连线上可见的显式端口类型"）。
enum PortKind { BOOL, ANALOG }

const KIND_PARAMETRIC := "parametric"
const KIND_EXHIBIT := "exhibit"
const KIND_DECO := "deco"

const PORT_DIR_IN := "in"
const PORT_DIR_OUT := "out"
const PORT_DIR_IO := "io"

const _ENTITY_FIELDS := ["entityId", "assetId", "index", "kind", "pos", "exists", "params", "ports", "signals"]

var _assets: Dictionary = {}       # assetId -> {kind, defaults, ports:{portId -> {kind,dir,value}}}
var _entities: Dictionary = {}     # entityId -> 实体（字段见 _ENTITY_FIELDS）
var _bindings: Dictionary = {}     # assetId -> entityId
var _edges: Array = []             # [{from: portRef, to: portRef}]
var _observes: Array = []          # [{observeId, targetRef, kind, expect}]（spec §4.4）
var _place_counts: Dictionary = {} # assetId -> 已放实例数
var _watchers: Dictionary = {}     # watchId -> {ref}（可观测性订阅，不进快照）
var _watch_seq := 0
var _applied_events: Dictionary = {} # 去重键 -> true（物理事件只生效一次）
var _tick := 0


static func port_kind_name(k: int) -> String:
	return "BOOL" if k == PortKind.BOOL else "ANALOG"


static func parse_port_kind(s: String) -> int:
	return PortKind.ANALOG if s == "ANALOG" else PortKind.BOOL


# ---------- 世界初始化（run 记录之外的环境声明） ----------

## 注册资产模板。ports 每项 {id, kind("BOOL"|"ANALOG", 默认 BOOL), dir("in"|"out"|"io", 默认 io), value?}。
## 默认参数值以这里为唯一来源（spec §4.3 defaults）。
func register_asset(asset_id: String, kind: String, defaults: Dictionary, ports: Array) -> Dictionary:
	if asset_id == "" or asset_id.contains(":") or asset_id.contains("#"):
		return _err("bad_asset_id", "资产 id 非法（空、含 ':' 或 '#'）：%s" % asset_id)
	if _assets.has(asset_id):
		return _err("duplicate_asset", "资产已注册：%s" % asset_id)
	if not [KIND_PARAMETRIC, KIND_EXHIBIT, KIND_DECO].has(kind):
		return _err("bad_kind", "资产类别必须是 parametric/exhibit/deco，得到：%s" % kind)
	var port_map: Dictionary = {}
	for p in ports:
		var pid := str(p.get("id", ""))
		if pid == "" or pid.contains(":"):
			return _err("bad_port", "端口 id 非法：%s" % pid)
		if port_map.has(pid):
			return _err("bad_port", "端口 id 重复：%s" % pid)
		var pk := str(p.get("kind", "BOOL"))
		if pk != "BOOL" and pk != "ANALOG":
			return _err("bad_port_kind", "端口类型必须是 BOOL/ANALOG，得到：%s" % pk)
		var dir := str(p.get("dir", PORT_DIR_IO))
		if not [PORT_DIR_IN, PORT_DIR_OUT, PORT_DIR_IO].has(dir):
			return _err("bad_port_dir", "端口方向必须是 in/out/io，得到：%s" % dir)
		var value: Variant = p.get("value", false if pk == "BOOL" else 0.0)
		port_map[pid] = {"kind": pk, "dir": dir, "value": value}
	_assets[asset_id] = {"kind": kind, "defaults": defaults.duplicate(true), "ports": port_map}
	return {"ok": true}


## 声明 observe 列表（spec §4.4：结构化，不是散文）。highlight 由它推导，不手工填。
func set_observes(observes: Array) -> void:
	_observes = observes.duplicate(true)


## 显式改绑：绑定表由世界初始化或练习场任务声明（spec §4.5）。
func bind(asset_id: String, entity_id: String) -> Dictionary:
	if not _entities.has(entity_id):
		return _err("unknown_entity", "改绑目标不存在：%s" % entity_id)
	var e: Dictionary = _entities[entity_id]
	if str(e["assetId"]) != asset_id:
		return _err("asset_mismatch", "实体 %s 属于资产 %s，不能绑给 %s" % [entity_id, e["assetId"], asset_id])
	if str(e["kind"]) == KIND_DECO:
		return _err("deco_not_bindable", "装饰实体不参与操作与高亮：%s" % entity_id)
	_bindings[asset_id] = entity_id
	return {"ok": true}


# ---------- 放置与实体 ----------

## 放置一个资产实例，返回 entityId。首个非装饰实例自动绑定到绑定表（之后保持，
## 直到显式 bind 改绑）——这是"世界初始化声明绑定表"的默认实现。
func place(asset_id: String, pos: Array) -> Dictionary:
	if not _assets.has(asset_id):
		return _err("unknown_asset", "未注册的资产：%s（先由世界初始化 register_asset）" % asset_id)
	var cell := _normalize_cell(pos)
	if cell.is_empty():
		return _err("bad_pos", "pos 必须是 [x, y, z] 三个数字，得到：%s" % str(pos))
	var tpl: Dictionary = _assets[asset_id]
	var index := int(_place_counts.get(asset_id, 0)) + 1
	_place_counts[asset_id] = index
	var eid := ("fx:%s#%d" % [asset_id, index]) if str(tpl["kind"]) == KIND_DECO else ("%s#%d" % [asset_id, index])
	_entities[eid] = {
		"entityId": eid,
		"assetId": asset_id,
		"index": index,
		"kind": tpl["kind"],
		"pos": cell,
		"exists": true,
		"params": tpl["defaults"].duplicate(true),
		"ports": tpl["ports"].duplicate(true),
		"signals": {},
	}
	var bound := false
	if str(tpl["kind"]) != KIND_DECO and not _bindings.has(asset_id):
		_bindings[asset_id] = eid
		bound = true
	return {"ok": true, "entityId": eid, "bound": bound}


func has_entity(entity_id: String) -> bool:
	return _entities.has(entity_id)


## 该实例是否被绑定表选中：只有被选中的实例参与操作与高亮（spec §4.5 第 4 条）。
## 装饰实体永远不参与（它由物理驱动，不服务概念）。
func is_bound(entity_id: String) -> bool:
	if not _entities.has(entity_id):
		return false
	var e: Dictionary = _entities[entity_id]
	if str(e["kind"]) == KIND_DECO:
		return false
	return str(_bindings.get(str(e["assetId"]), "")) == entity_id


# ---------- 操作（写） ----------

## 设参数。demo 约定：key 以 "@" 开头时写该实体的 out/io 端口值（如 "@batch_out"），
## 让 run 的连接传播有数据源；普通 key 写 params（必须在资产 defaults 里声明过）。
func set_param(entity_id: String, key: String, value: Variant) -> Dictionary:
	if not _entities.has(entity_id):
		return _err("unknown_entity", "实体不存在：%s" % entity_id)
	var e: Dictionary = _entities[entity_id]
	if not is_bound(entity_id):
		return _err("entity_not_bound", "实例 %s 未被绑定表选中，不参与操作（spec §4.5）" % entity_id)
	if str(e["kind"]) != KIND_PARAMETRIC:
		return _err("not_parametric", "实体 %s 是 %s，不能 set_param" % [entity_id, e["kind"]])
	if key.begins_with("@"):
		var pid := key.substr(1)
		var ports: Dictionary = e["ports"]
		if not ports.has(pid):
			return _err("unknown_port", "实体 %s 没有端口 %s" % [entity_id, pid])
		var port: Dictionary = ports[pid]
		if not [PORT_DIR_OUT, PORT_DIR_IO].has(str(port["dir"])):
			return _err("port_direction", "端口 %s 是 %s 向，参数写不进去（in 端口由连线驱动）" % [pid, port["dir"]])
		var old_value: Variant = port["value"]
		port["value"] = _coerce_port_value(str(port["kind"]), value)
		return {"ok": true, "oldValue": old_value}
	var params: Dictionary = e["params"]
	if not params.has(key):
		return _err("unknown_param", "实体 %s 没有参数 %s（资产 defaults 未声明）" % [entity_id, key])
	var old_v: Variant = params[key]
	params[key] = value
	return {"ok": true, "oldValue": old_v}


## 连接两个端口实例（不叫 connect：那是 Object 的内置信号方法名）。
## from 必须可出（out/io），to 必须可入（in/io）；两端实体都必须被绑定表选中。
func connect_ports(from_ref: String, to_ref: String) -> Dictionary:
	if from_ref == to_ref:
		return _err("self_connection", "不能把端口接给自己：%s" % from_ref)
	for edge in _edges:
		if str(edge["from"]) == from_ref and str(edge["to"]) == to_ref:
			return _err("duplicate_edge", "连接已存在：%s -> %s" % [from_ref, to_ref])
	var from_port := _lookup_port(from_ref)
	if from_port.is_empty():
		return _err("unknown_port", "源端口不存在：%s" % from_ref)
	var to_port := _lookup_port(to_ref)
	if to_port.is_empty():
		return _err("unknown_port", "目标端口不存在：%s" % to_ref)
	if not is_bound(_entity_id_of(from_ref)):
		return _err("entity_not_bound", "源实例 %s 未被绑定表选中，不参与操作" % _entity_id_of(from_ref))
	if not is_bound(_entity_id_of(to_ref)):
		return _err("entity_not_bound", "目标实例 %s 未被绑定表选中，不参与操作" % _entity_id_of(to_ref))
	if not [PORT_DIR_OUT, PORT_DIR_IO].has(str(from_port["dir"])):
		return _err("port_direction", "源端口 %s 是 %s 向，不能作为连线起点" % [from_ref, from_port["dir"]])
	if not [PORT_DIR_IN, PORT_DIR_IO].has(str(to_port["dir"])):
		return _err("port_direction", "目标端口 %s 是 %s 向，不能作为连线终点" % [to_ref, to_port["dir"]])
	_edges.append({"from": from_ref, "to": to_ref})
	return {"ok": true}


# ---------- 演化（run / step 的状态侧实现） ----------

## 沿边把 out 端口值传播进 in 端口。类型规则（每个端口明写语义）：
## 同类型直传；BOOL 可以驱动 ANALOG（false→0.0 / true→1.0）；
## ANALOG 驱动 BOOL 是配置错误，返回 failure 而不是静默截断。
func propagate() -> Array:
	var errs: Array = []
	for edge in _edges:
		var from_port := _lookup_port(str(edge["from"]))
		var to_port := _lookup_port(str(edge["to"]))
		if from_port.is_empty() or to_port.is_empty():
			continue
		var fk := str(from_port["kind"])
		var tk := str(to_port["kind"])
		if fk == tk:
			to_port["value"] = from_port["value"]
		elif fk == "BOOL" and tk == "ANALOG":
			to_port["value"] = 1.0 if bool(from_port["value"]) else 0.0
		else:
			errs.append({
				"from": edge["from"],
				"to": edge["to"],
				"code": "port_type_mismatch",
				"message": "ANALOG 端口不能驱动 BOOL 端口：%s -> %s" % [edge["from"], edge["to"]],
			})
	return errs


func advance(seconds: float) -> void:
	var n := int(round(seconds / WORLD_DT))
	_tick += maxi(1, n)


func step_once() -> void:
	_tick += 1


func world_t() -> float:
	return float(_tick) * WORLD_DT


func tick() -> int:
	return _tick


# ---------- 物理→逻辑事件（单向入口） ----------

## 物理层事件上报的**唯一入口**。每个事件对象只生效一次（按 type+entityId+cell 去重），
## 生效后改的是逻辑状态：优先写实体声明过的 "touched" 之类的 in 端口，
## 没有就记进 signals。不推 tick（事件是瞬时作用，不占世界秒）。
func apply_physics_event(event: Dictionary) -> Dictionary:
	var etype := str(event.get("type", ""))
	var eid := str(event.get("entityId", ""))
	if etype == "" or eid == "":
		return _err("bad_event", "物理事件缺 type 或 entityId：%s" % str(event))
	if not _entities.has(eid):
		return _err("unknown_entity", "事件指向的实体不存在：%s" % eid)
	if etype != "contact":
		return _err("unknown_event_type", "demo 只实现 contact 事件，得到：%s" % etype)
	var dedup := "%s:%s:%s" % [etype, eid, str(event.get("cell", []))]
	if _applied_events.has(dedup):
		return _err("duplicate_event", "该事件已上报过，状态层只接受一次：%s" % dedup)
	_applied_events[dedup] = true
	var e: Dictionary = _entities[eid]
	var ports: Dictionary = e["ports"]
	if ports.has("touched") and [PORT_DIR_IN, PORT_DIR_IO].has(str(ports["touched"]["dir"])):
		ports["touched"]["value"] = true
	else:
		e["signals"]["contact"] = true
	return {"ok": true, "applied": dedup}


# ---------- 读取（只读查询） ----------

## 状态层快照：只取逻辑状态，不含物理内部量，也不含 watchers（订阅不是世界状态）。
func logical_snapshot() -> Dictionary:
	var entities: Dictionary = {}
	for eid in _entities:
		entities[eid] = _entity_digest(eid)
	return {
		"schema": "world-state/1",
		"t": world_t(),
		"tick": _tick,
		"entities": entities,
		"bindings": _bindings.duplicate(),
		"edges": _edges.duplicate(true),
	}


## steps[].world 用的摘要：entities + highlight（spec §6）。
func state_digest() -> Dictionary:
	return {"entities": logical_snapshot()["entities"], "highlight": resolve_highlight()}


## observe.targetRef 模板（{assetId} 或 {assetId}:{portId}）经绑定表解析成实例引用，
## 解析失败的跳过（没有对应对象时 highlight 为空——spec §4.4）。
func resolve_highlight() -> Array:
	var out: Array = []
	for ob in _observes:
		var resolved := resolve_target_ref(str(ob.get("targetRef", "")))
		if resolved != "":
			out.append(resolved)
	return out


func resolve_target_ref(ref: String) -> String:
	var asset_id := ref
	var port_id := ""
	if ref.contains(":"):
		var parts := ref.split(":")
		asset_id = parts[0]
		port_id = parts[1]
	var eid := str(_bindings.get(asset_id, ""))
	if eid == "" or not _entities.has(eid):
		return ""
	if port_id != "":
		if not _entities[eid]["ports"].has(port_id):
			return ""
		return "%s:%s" % [eid, port_id]
	return eid


## 读一个引用：portRef 读端口，entityId 读实体的参数与端口。
func read_ref(ref: String) -> Dictionary:
	if ref.contains(":"):
		var port := _lookup_port(ref)
		if port.is_empty():
			return _err("unknown_ref", "引用不存在：%s" % ref)
		return {"ok": true, "type": "port", "ref": ref, "kind": str(port["kind"]), "dir": str(port["dir"]), "value": port["value"]}
	if not _entities.has(ref):
		return _err("unknown_ref", "引用不存在：%s" % ref)
	var digest := _entity_digest(ref)
	digest["ok"] = true
	digest["type"] = "entity"
	digest["entityId"] = ref
	return digest


func inspect_entity(entity_id: String) -> Dictionary:
	if not _entities.has(entity_id):
		return _err("unknown_entity", "实体不存在：%s" % entity_id)
	var digest := _entity_digest(entity_id)
	var wired := edges_for(entity_id)
	digest["ok"] = true
	digest["entityId"] = entity_id
	digest["bound"] = is_bound(entity_id)
	digest["out_edges"] = wired["out"]
	digest["in_edges"] = wired["in"]
	return digest


func edges_for(entity_id: String) -> Dictionary:
	var outs: Array = []
	var ins: Array = []
	for edge in _edges:
		if _entity_id_of(str(edge["from"])) == entity_id:
			outs.append(edge)
		if _entity_id_of(str(edge["to"])) == entity_id:
			ins.append(edge)
	return {"out": outs, "in": ins}


## 连接图的文本 netlist：实体一行、端口缩进一行、连线一行。只读，确定性输出。
func netlist_text() -> String:
	var lines: Array = []
	lines.append("# world netlist v1")
	lines.append("# entities %d / edges %d" % [_entities.size(), _edges.size()])
	for eid in _entities:
		var e: Dictionary = _entities[eid]
		var pos: Array = e["pos"]
		lines.append("ENTITY %s %s @ (%d,%d,%d)" % [eid, e["kind"], int(pos[0]), int(pos[1]), int(pos[2])])
		for key in e["params"]:
			lines.append("  PARAM %s = %s" % [key, str(e["params"][key])])
		for pid in e["ports"]:
			var port: Dictionary = e["ports"][pid]
			lines.append("  PORT %s %s %s = %s" % [pid, port["kind"], port["dir"], str(port["value"])])
		for sig in e["signals"]:
			lines.append("  SIGNAL %s = %s" % [sig, str(e["signals"][sig])])
	for edge in _edges:
		lines.append("CONN %s -> %s" % [edge["from"], edge["to"]])
	return "\n".join(lines)


# ---------- 可观测性订阅（watch） ----------

func add_watch(ref: String) -> String:
	_watch_seq += 1
	var wid := "w%d" % _watch_seq
	_watchers[wid] = {"ref": ref}
	return wid


func watchers() -> Dictionary:
	return _watchers.duplicate(true)


# ---------- diff（比较两份 entities 摘要） ----------

static func diff_entities(a: Dictionary, b: Dictionary) -> Dictionary:
	var added: Array = []
	var removed: Array = []
	var changed: Dictionary = {}
	for eid in b:
		if not a.has(eid):
			added.append(eid)
	for eid in a:
		if not b.has(eid):
			removed.append(eid)
	for eid in a:
		if not b.has(eid):
			continue
		var fields: Dictionary = {}
		for field in ["pos", "params", "ports", "signals", "exists"]:
			var va: Variant = a[eid].get(field)
			var vb: Variant = b[eid].get(field)
			if JSON.stringify(va) != JSON.stringify(vb):
				fields[field] = {"from": va, "to": vb}
		if not fields.is_empty():
			changed[eid] = fields
	return {"added": added, "removed": removed, "changed": changed}


func reset() -> void:
	_assets = {}
	_entities = {}
	_bindings = {}
	_edges = []
	_observes = []
	_place_counts = {}
	_watchers = {}
	_watch_seq = 0
	_applied_events = {}
	_tick = 0


# ---------- 内部 ----------

func _entity_digest(entity_id: String) -> Dictionary:
	var e: Dictionary = _entities[entity_id]
	var out: Dictionary = {}
	for field in _ENTITY_FIELDS:
		var v: Variant = e[field]
		if v is Dictionary:
			out[field] = (v as Dictionary).duplicate(true)
		elif v is Array:
			out[field] = (v as Array).duplicate(true)
		else:
			out[field] = v
	return out


func _lookup_port(port_ref: String) -> Dictionary:
	var eid := _entity_id_of(port_ref)
	if not _entities.has(eid):
		return {}
	var pid := port_ref.substr(eid.length() + 1)
	var ports: Dictionary = _entities[eid]["ports"]
	if not ports.has(pid):
		return {}
	return ports[pid]


func _entity_id_of(ref: String) -> String:
	var cut := ref.find(":")
	return ref if cut < 0 else ref.substr(0, cut)


func _coerce_port_value(kind: String, value: Variant) -> Variant:
	if kind == "ANALOG":
		if value is bool:
			return 1.0 if value else 0.0
		return float(value) if (value is int or value is float) else 0.0
	return bool(value) if (value is bool or value is int or value is float) else false


func _normalize_cell(pos: Array) -> Array:
	if pos.size() != 3:
		return []
	var cell: Array = []
	for v in pos:
		if v is int:
			cell.append(int(v))
		elif v is float:
			cell.append(int(round(v)))
		else:
			return []
	return cell


func _err(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
