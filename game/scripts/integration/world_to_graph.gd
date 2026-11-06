extends RefCounted

## 世界 → 方块编译器桥（spec §11「方块编译器」交付物的世界侧入口）。
##
## 职责：把 WorldState 里拼好的装置（实体/端口/连接/参数/折叠组）投影成
## 编译器的图 Dictionary（字段形状对齐 graph_model.gd 的 parse 白名单），
## 再交 COMPILER.compile 产出可搬运 Python——「世界里拼的东西和带进考场的
## 东西是同一份文件」（docs/10-契约/方块体系.md §6）。
##
## 契约红线（docs/10-契约/方块体系.md §6.2）：
## - 只读连接与参数：位置、朝向、端口仿真值（BOOL/ANALOG 的 value）、
##   tick/world_t 一概不进图——同装置换摆法必须导出逐字节相同。
## - 装饰实体（物理驱动，不服务概念）与未被绑定表选中的实例不参与导出
##   （spec §4.5：未绑定实例不参与操作）。
##
## 投影约定（世界资产声明 → 编译器图；v1，世界侧要让资产可编译时按此声明）：
## - 实体 kind：实体参数的保留键 "block"（string）是编译器方块 kind
##   （entry/think/decide/guard/split/join/...），缺省 "step"。
## - 折叠组：保留参数 "fold"（string）→ 实体 fold_group + 顶层 fold_groups
##   （视图标记，编译语义不使用，折叠不变量由编译器保证）。
## - 端口：端口 id 命中控制词汇表 → 控制端口（ctl=in/seq；next、loop=out/seq；
##   done=out/exit；then/elif/else=out/同名；parallel 与 fan_* 前缀=out/parallel）。
##   其余端口 → 数据端口（dir：in→in，out/io→out；type 统一 any——世界端口的
##   BOOL/ANALOG 是仿真值类型，编译器数据面承载步骤间传递的 dict，导出骨架的
##   运行期值由模板体产生；any 不让仿真值类型误伤编译期类型校验）。
## - 连接：{entityId}:{portId} → {entityId}.{portId}；data/control 由源端口
##   的词汇表归属决定（graph_model.parse 按源端口 kind 复核，规则一致）。
## - 保留参数 "block"/"fold" 由桥消费，不转发为编译器参数。

const COMPILER := preload("res://scripts/compiler/compiler.gd")

const PARAM_BLOCK := "block"
const PARAM_FOLD := "fold"

const CTRL_IN_SEQ := "ctl"
const CTRL_OUT_TYPES := {
	"next": "seq",
	"loop": "seq",
	"done": "exit",
	"then": "then",
	"elif": "elif",
	"else": "else",
	"parallel": "parallel",
}
const CTRL_FAN_PREFIX := "fan_"

const GRAPH_NAME := "world_export"


## WorldState → 编译器图 Dictionary（键：name/entities/connections/fold_groups，
## 与 graph_model.parse 白名单一致；未知字段编译器侧一律忽略）。
static func build_graph(world_state: WorldStateCore) -> Dictionary:
	var snap: Dictionary = world_state.logical_snapshot()
	var ents_in: Dictionary = snap["entities"]
	var included := {}
	var entities_out: Array = []
	var fold_members := {}
	for eid in ents_in.keys():
		var e: Dictionary = ents_in[eid]
		if str(e["kind"]) == WorldStateCore.KIND_DECO:
			continue
		if not world_state.is_bound(str(eid)):
			continue
		included[str(eid)] = true
		var params_in: Dictionary = e["params"]
		var params_out := {}
		for k in params_in.keys():
			if str(k) == PARAM_BLOCK or str(k) == PARAM_FOLD:
				continue
			params_out[k] = params_in[k]
		var ports_out: Array = []
		for pid in (e["ports"] as Dictionary).keys():
			ports_out.append(_port_def(str(pid), e["ports"][pid]))
		var fold := str(params_in.get(PARAM_FOLD, ""))
		entities_out.append({
			"id": str(eid),
			"kind": str(params_in.get(PARAM_BLOCK, "step")),
			"params": params_out,
			"ports": ports_out,
			"fold_group": fold,
		})
		if fold != "":
			if not fold_members.has(fold):
				fold_members[fold] = []
			(fold_members[fold] as Array).append(str(eid))
	entities_out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return String(a["id"]) < String(b["id"]))
	var connections_out: Array = []
	for edge in (snap["edges"] as Array):
		var f := _split_ref(str(edge["from"]))
		var t := _split_ref(str(edge["to"]))
		if f.size() != 2 or t.size() != 2:
			continue
		if not included.has(f[0]) or not included.has(t[0]):
			continue
		connections_out.append({"from": "%s.%s" % [f[0], f[1]], "to": "%s.%s" % [t[0], t[1]]})
	connections_out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return "%s->%s" % [a["from"], a["to"]] < "%s->%s" % [b["from"], b["to"]])
	var fold_groups: Array = []
	var fold_ids: Array = fold_members.keys()
	fold_ids.sort()
	for fid in fold_ids:
		var members: Array = fold_members[fid]
		members.sort()
		fold_groups.append({"id": str(fid), "members": members})
	return {
		"name": GRAPH_NAME,
		"entities": entities_out,
		"connections": connections_out,
		"fold_groups": fold_groups,
	}


## 一键导出：建图 → COMPILER.compile。
## 返回 {ok, python, errors, warnings, ir_hash}（errors 阻断产码，warnings 不阻断）。
static func export_python(world_state: WorldStateCore) -> Dictionary:
	var r: Dictionary = COMPILER.compile(build_graph(world_state))
	return {
		"ok": bool(r.get("ok", false)),
		"python": String(r.get("python", "")),
		"errors": r.get("errors", []),
		"warnings": r.get("warnings", []),
		"ir_hash": String(r.get("ir_hash", "")),
	}


static func _port_def(pid: String, world_port: Dictionary) -> Dictionary:
	if pid == CTRL_IN_SEQ:
		return {"name": pid, "dir": "in", "kind": "control", "type": "seq", "required": false}
	if CTRL_OUT_TYPES.has(pid):
		return {"name": pid, "dir": "out", "kind": "control", "type": String(CTRL_OUT_TYPES[pid]), "required": false}
	if pid.begins_with(CTRL_FAN_PREFIX):
		return {"name": pid, "dir": "out", "kind": "control", "type": "parallel", "required": false}
	var dir := "in" if str(world_port["dir"]) == WorldStateCore.PORT_DIR_IN else "out"
	return {"name": pid, "dir": dir, "kind": "data", "type": "any", "required": false}


static func _split_ref(ref: String) -> PackedStringArray:
	return ref.split(":", false, 1)
