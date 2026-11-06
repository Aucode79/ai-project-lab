extends SceneTree

## machine_view 回归：确定性布局、0.25 网格、端口表、类型判定、走线与整机组装。
## 纯 GDScript，不依赖后端与窗口。

const MachineView := preload("res://scripts/lessons/machine_view.gd")
const Catalog := preload("res://scripts/asset_lib/component_catalog.gd")

var failed := 0

func _init() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed += 1
		print("FAIL: " + message)

func _preset_root() -> Dictionary:
	var nodes: Array = [
		{"id": "task", "op": "input", "params": {"name": "task"}},
		{"id": "t0", "op": "tool", "params": {"name": "world.snapshot"}},
		{"id": "t1", "op": "tool", "params": {"name": "fs.read"}},
		{"id": "tools", "op": "tools", "params": {"fields": ["t0", "t1"]}},
		{"id": "start", "op": "call", "module": "agent", "label": "Agent"},
		{"id": "done", "op": "return"},
	]
	var edges: Array = [
		{"from": "task.value", "to": "start.task"},
		{"from": "t0.value", "to": "tools.t0"},
		{"from": "t1.value", "to": "tools.t1"},
		{"from": "tools.value", "to": "start.tools"},
		{"from": "start.value", "to": "done.value"},
		{"from": "start.next", "to": "done.exec"},
	]
	return {"formatVersion": "module/1", "entry": "main", "modules": {
		"main": {"inputs": ["task"], "entry": "start", "nodes": nodes, "edges": edges},
		"agent": {"inputs": ["task", "tools"], "entry": "r", "nodes": [
			{"id": "i", "op": "input", "params": {"name": "task"}},
			{"id": "r", "op": "return"}],
			"edges": [{"from": "i.value", "to": "r.value"}]}}}

func _run() -> void:
	var program := _preset_root()
	var module: Dictionary = program.modules.main
	var first := MachineView.layout(module, program.modules)
	var second := MachineView.layout(module, program.modules)
	_check(first.hash() == second.hash(), "layout must be deterministic")
	_check(first.size() == module.nodes.size(), "layout covers every node")
	var custom_pose := MachineView.layout(module, program.modules, {"task": [1.25, 0.0, -2.5]})
	_check(custom_pose["task"] == Vector3(1.25, 0.0, -2.5),
		"3D editor saved position overrides preserve node identity")
	for id in first:
		var p: Vector3 = first[id]
		_check(fmod(absf(p.x), 0.25) < 0.001 and fmod(absf(p.z), 0.25) < 0.001,
			"placement on 0.25 grid: " + id + " " + str(p))
	var seen := {}
	for id in first:
		var key := str(first[id].x) + "," + str(first[id].z)
		_check(not seen.has(key), "no overlapping rows: " + id)
		seen[key] = true
	var entry_x: float = first[module.entry].x
	for n in module.nodes:
		if n.op in MachineView.PURE: continue
		_check(first[n.id].x >= entry_x - 0.001, "entry sits leftmost among effect nodes: " + n.id)
	var loop := {"entry": "a", "inputs": [], "nodes": [
		{"id": "a", "op": "nop"}, {"id": "b", "op": "nop"}, {"id": "c", "op": "return"}],
		"edges": [{"from": "a.next", "to": "b.exec"}, {"from": "b.next", "to": "a.exec"},
			{"from": "b.next", "to": "c.exec"}]}
	var looped := MachineView.layout(loop, {})
	_check(looped.size() == 3, "cyclic control graph still lays out every node")
	_check(MachineView.pins({"id": "s", "op": "call", "module": "agent"}, program.modules) == ["task", "tools"],
		"call pins come from the referenced definition")
	_check(MachineView.pins({"id": "t", "op": "tools", "params": {"fields": ["a", "b"]}}, {}) == ["a", "b"],
		"collection pins come from fields")
	_check(MachineView.outputs({"id": "b", "op": "branch"}) == ["then", "else", "value"], "branch outputs")
	_check(MachineView.ports_compatible("next", "exec"), "control out connects to exec")
	_check(not MachineView.ports_compatible("value", "exec"), "data out cannot enter exec")
	_check(not MachineView.ports_compatible("next", "task"), "control out cannot enter a data pin")
	_check(MachineView.ports_compatible("value", "task"), "data out connects to a data pin")
	var path := MachineView.wire_path(Vector3(0, 0.5, 0), Vector3(2, 0.3, 1))
	_check(path.size() == 4 and path[0] == Vector3(0, 0.5, 0) and path[3] == Vector3(2, 0.3, 1),
		"wire path keeps both endpoints")
	_check(absf(path[1].y - MachineView.WIRE_Y) < 0.001 and absf(path[2].y - MachineView.WIRE_Y) < 0.001,
		"wire rises to WIRE_Y")
	var holder := Node3D.new()
	root.add_child(holder)
	var view := MachineView.build(holder, program, "main", true, false)
	await process_frame
	_check(view.nodes.size() == 6, "machine builds every node")
	for edge in module.edges:
		_check(view.ports.has(edge.from) and view.ports.has(edge.to),
			"ports exist for edge " + edge.from + " -> " + edge.to)
	_check(view.wires.size() == module.edges.size(), "one wire per edge")
	var port_bodies := 0
	for node_holder in holder.get_children():
		if not str(node_holder.name).begins_with("N_"): continue
		for part in node_holder.get_children():
			if part is MeshInstance3D and str(part.name).begins_with("P_"):
				for body in part.get_children():
					if body is StaticBody3D and body.has_meta("port"): port_bodies += 1
	_check(port_bodies >= 10, "pickable port bodies present, got " + str(port_bodies))
	# —— 追加：形状与走线升级回归 ——
	# ④ wire_path 两参默认调用：首尾点仍为 a/b，缺省车道仍是 WIRE_Y。
	var legacy := MachineView.wire_path(Vector3(1, 0.4, 2), Vector3(3, 0.2, 4))
	_check(legacy.size() == 4 and legacy[0] == Vector3(1, 0.4, 2) and legacy[3] == Vector3(3, 0.2, 4),
		"wire_path(a, b) two-arg call keeps both endpoints")
	_check(absf(legacy[1].y - MachineView.WIRE_Y) < 0.001, "wire_path default lane stays at WIRE_Y")
	# ①③ 依据 build 产物检查：同类型线水平段同车道不重叠、线段不穿节点 AABB。
	# 端口中心可落半格（0.125 m），方向标应沿线中心，不能强制吸到 0.25 m 而脱线。
	var boxes: Array = []
	for n in module.nodes:
		var np: Vector3 = view.positions[n.id]
		var ne: Vector3 = MachineView.extents(n)
		boxes.append({"min": np - ne / 2, "max": np + ne / 2})
	var lanes_seen := {}
	var chevron_count := 0
	for wire_holder in holder.get_children():
		if not str(wire_holder.name).begins_with("W_"): continue
		var wire_type: String = "control" if str(wire_holder.name).split("__")[1].ends_with(".exec") else "data"
		for part in wire_holder.get_children():
			var pname := str(part.name)
			if pname.begins_with("C_"):
				chevron_count += 1
				var cp: Vector3 = part.position
				_check(fmod(absf(cp.x), 0.125) < 0.001 and fmod(absf(cp.y), 0.25) < 0.001
					and fmod(absf(cp.z), 0.125) < 0.001, "chevron follows wire center lattice: " + str(cp))
			elif pname.begins_with("S_"):
				var span: AABB = part.global_transform * part.mesh.get_aabb()
				var slo: Vector3 = span.position
				var shi: Vector3 = span.end
				for box in boxes:
					_check(not (shi.x > box.min.x and slo.x < box.max.x
						and shi.y > box.min.y and slo.y < box.max.y
						and shi.z > box.min.z and slo.z < box.max.z),
						"wire segment clears node AABB: " + str(wire_holder.name))
				# 水平段恒为 path 第 2 段（S_1，两端同在车道高）；起落段不算车道占用。
				if pname == "S_1" and (span.size.x > 0.2 or span.size.z > 0.2):
					var lane_key := wire_type + "@" + str(snappedf(part.position.y, 0.001))
					var seg := {"lo": slo.x, "hi": shi.x, "zlo": slo.z, "zhi": shi.z}
					for other in lanes_seen.get(lane_key, []):
						_check(not (seg.hi > other.lo and seg.lo < other.hi
							and seg.zhi > other.zlo and seg.zlo < other.zhi),
							"same-type wires keep lanes apart: " + lane_key)
					lanes_seen[lane_key] = lanes_seen.get(lane_key, []) + [seg]
	_check(chevron_count >= 4, "direction chevrons placed, got " + str(chevron_count))
	# —— Agent Lab 节点以形状表达；整机上不显示任何文字标签 ——
	var labeled_holder := Node3D.new()
	root.add_child(labeled_holder)
	var labeled := MachineView.build(labeled_holder, program, "main", true, true)
	_check(not Catalog.scene_has_label3d(labeled_holder),
		"machine build embeds no Label3D anywhere in the holder tree")
	for n in module.nodes:
		_check(labeled.labels.has(n.id) and str(labeled.labels[n.id]) == str(n.get("label", n.id)),
			"semantic labels remain available to the statement output: " + str(n.id))
		var tile: Node = labeled.nodes[n.id].get_node_or_null("NameTile")
		_check(tile == null, "node names are not rendered in the 3D machine: " + str(n.id))
	labeled_holder.free()
	var generator_node := {"id": "generate", "op": "generator", "params": {
		"target": "value", "filterCount": 1, "fields": ["items", "element", "filter_0"],
		"visualExtent": [2.0, 0.75, 1.5]}}
	var generator_module := {"entry": "return", "inputs": ["values"], "nodes": [
		{"id": "values", "op": "input", "params": {"name": "values"}},
		{"id": "item", "op": "generator_input", "params": {"name": "value"}},
		{"id": "two", "op": "const", "params": {"value": 2}},
		{"id": "double", "op": "mul"}, {"id": "zero", "op": "const", "params": {"value": 0}},
		{"id": "positive", "op": "gt"}, generator_node, {"id": "return", "op": "return"}],
		"edges": [{"from": "values.value", "to": "generate.items"},
			{"from": "item.value", "to": "double.a"}, {"from": "two.value", "to": "double.b"},
			{"from": "double.value", "to": "generate.element"}, {"from": "item.value", "to": "positive.a"},
			{"from": "zero.value", "to": "positive.b"}, {"from": "positive.value", "to": "generate.filter_0"},
			{"from": "generate.value", "to": "return.value"}]}
	_check(MachineView.kind(generator_node) == "loop", "generator renders as a repeater machine")
	_check(MachineView.pins(generator_node) == ["items", "element", "filter_0"],
		"generator exposes iterator, yield value, and filter ports")
	_check(MachineView.outputs({"id": "item", "op": "generator_input"}) == ["value"],
		"generator-local item is a data source")
	var generator_holder := Node3D.new()
	root.add_child(generator_holder)
	var generator_view := MachineView.build(generator_holder,
		{"formatVersion": "module/1", "entry": "generator", "modules": {"generator": generator_module}},
		"generator", true, false)
	await process_frame
	_check(generator_view.nodes.has("generate") and generator_view.wires.size() == generator_module.edges.size(),
		"generator and all lazy data channels build in the 3D machine")
	generator_holder.free()
	var listcomp_node := generator_node.duplicate(true)
	listcomp_node.op = "listcomp"
	_check(MachineView.kind(listcomp_node) == "loop", "list comprehension renders as an eager repeater machine")
	_check(MachineView.pins(listcomp_node) == ["items", "element", "filter_0"],
		"list comprehension exposes iterator, element, and filter ports")
	var listcomp_module: Dictionary = generator_module.duplicate(true)
	for node in listcomp_module.nodes:
		if node.op == "generator": node.op = "listcomp"
	var listcomp_holder := Node3D.new()
	root.add_child(listcomp_holder)
	var listcomp_view := MachineView.build(listcomp_holder,
		{"formatVersion": "module/1", "entry": "generator", "modules": {"generator": listcomp_module}},
		"generator", true, false)
	await process_frame
	_check(listcomp_view.nodes.has("generate") and listcomp_view.wires.size() == listcomp_module.edges.size(),
		"list comprehension and all eager data channels build in the 3D machine")
	listcomp_holder.free()
	var format_node := {"id": "formatted", "op": "format", "params": {"conversion": -1, "formatSpec": "04d"}}
	_check(MachineView.kind(format_node) == "pure", "formatted value renders as a data transform")
	_check(MachineView.pins(format_node) == ["value"], "formatted value exposes its editable input")
	var format_module := {"entry": "return", "inputs": ["value"], "nodes": [
		{"id": "value", "op": "input", "params": {"name": "value"}}, format_node,
		{"id": "return", "op": "return"}],
		"edges": [{"from": "value.value", "to": "formatted.value"}, {"from": "formatted.value", "to": "return.value"}]}
	var format_holder := Node3D.new()
	root.add_child(format_holder)
	var format_view := MachineView.build(format_holder,
		{"formatVersion": "module/1", "entry": "formatting", "modules": {"formatting": format_module}},
		"formatting", true, false)
	await process_frame
	_check(format_view.nodes.has("formatted") and format_view.wires.size() == format_module.edges.size(),
		"format node and its input/output channels build in the 3D machine")
	format_holder.free()
	var dictcomp_node := {"id": "collect", "op": "dictcomp", "params": {
		"target": "value", "itemNode": "item", "filterCount": 0,
		"fields": ["items", "key", "value"], "visualExtent": [2.0, 0.75, 1.5]}}
	var dictcomp_module := {"entry": "return", "inputs": ["values"], "nodes": [
		{"id": "values", "op": "input", "params": {"name": "values"}},
		{"id": "item", "op": "generator_input", "params": {"name": "value"}},
		dictcomp_node, {"id": "return", "op": "return"}],
		"edges": [{"from": "values.value", "to": "collect.items"},
			{"from": "item.value", "to": "collect.key"}, {"from": "item.value", "to": "collect.value"},
			{"from": "collect.value", "to": "return.value"}]}
	_check(MachineView.kind(dictcomp_node) == "loop", "dictionary comprehension renders as a repeater machine")
	_check(MachineView.pins(dictcomp_node) == ["items", "key", "value"],
		"dictionary comprehension exposes iterable, key, and value inputs")
	var dictcomp_holder := Node3D.new()
	root.add_child(dictcomp_holder)
	var dictcomp_view := MachineView.build(dictcomp_holder,
		{"formatVersion": "module/1", "entry": "dictionary", "modules": {"dictionary": dictcomp_module}},
		"dictionary", true, false)
	await process_frame
	_check(dictcomp_view.nodes.has("collect") and dictcomp_view.wires.size() == dictcomp_module.edges.size(),
		"dictionary comprehension and all data channels build in the 3D machine")
	dictcomp_holder.free()
	holder.free()
	await process_frame
	print("MACHINE VIEW: ", "PASS" if failed == 0 else "FAIL", " failures=", failed)
	quit(0 if failed == 0 else 1)
