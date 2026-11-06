extends RefCounted

## Presents the real executable Agent graph as a small set of graspable 3D modules.
## The source program is never edited here; summary nodes map to real call/message nodes.
const COMPONENT_LAYOUT_VERSION := 1

static func is_summary(module_id: String) -> bool:
	return module_id in ["main", "agent"]


static func project(program: Dictionary, module_id: String) -> Dictionary:
	var view_program: Dictionary = program.duplicate(true)
	if not is_summary(module_id): return view_program
	var source_module: Dictionary = view_program.get("modules", {}).get(module_id, {})
	var source_edges: Array = source_module.get("edges", [])
	var visible_ids: Array = ["task", "tools", "start", "done"] if module_id == "main" else [
		"init", "model", "branch", "execute", "observation"]
	source_module.nodes = source_module.get("nodes", []).filter(
		func(node: Dictionary) -> bool: return str(node.get("id", "")) in visible_ids)
	# Show direct visible relations, then contract hidden control-flow nodes so the
	# overview still explains how its large components hand work to one another.
	source_module.edges = _summary_edges(source_edges, visible_ids)
	var layouts: Dictionary = view_program.get("machineLayout", {})
	var saved: Dictionary = layouts.get(module_id, {})
	if int(saved.get("componentLayoutVersion", 0)) != COMPONENT_LAYOUT_VERSION:
		saved.erase("origin")
		saved["positions"] = _default_positions(module_id)
	layouts[module_id] = saved
	view_program["machineLayout"] = layouts
	return view_program


static func _summary_edges(source_edges: Array, visible_ids: Array) -> Array:
	var visible := {}
	for id in visible_ids:
		visible[str(id)] = true
	var outgoing_control := {}
	var result: Array = []
	var seen := {}
	for edge in source_edges:
		var from_key := str(edge.get("from", ""))
		var to_key := str(edge.get("to", ""))
		var from_id := from_key.get_slice(".", 0)
		var to_id := to_key.get_slice(".", 0)
		if visible.has(from_id) and visible.has(to_id):
			_append_summary_edge(result, seen, from_key, to_key)
		if to_key.ends_with(".exec") and _is_control_output(from_key):
			if not outgoing_control.has(from_id): outgoing_control[from_id] = []
			outgoing_control[from_id].append(edge)
	for source_id in visible_ids:
		for first_edge in outgoing_control.get(str(source_id), []):
			_trace_control_summary(first_edge, str(source_id), visible, outgoing_control, result, seen)
	return result


static func _trace_control_summary(first_edge: Dictionary, source_id: String, visible: Dictionary,
		outgoing_control: Dictionary, result: Array, seen: Dictionary) -> void:
	var from_key := str(first_edge.get("from", ""))
	var queue: Array[String] = [str(first_edge.get("to", "")).get_slice(".", 0)]
	var visited := {}
	while not queue.is_empty():
		var current_id: String = queue.pop_front()
		if current_id == source_id or visited.has(current_id): continue
		visited[current_id] = true
		if visible.has(current_id):
			_append_summary_edge(result, seen, from_key, current_id + ".exec")
			continue
		for edge in outgoing_control.get(current_id, []):
			queue.append(str(edge.get("to", "")).get_slice(".", 0))


static func _append_summary_edge(result: Array, seen: Dictionary, from_key: String, to_key: String) -> void:
	var key := from_key + "->" + to_key
	if seen.has(key): return
	seen[key] = true
	result.append({"from": from_key, "to": to_key})


static func _is_control_output(port_key: String) -> bool:
	return port_key.get_slice(".", 1) in ["next", "then", "else", "exit"]


static func default_positions(module_id: String) -> Dictionary:
	return _default_positions(module_id)


static func decorate(program: Dictionary, module_id: String, holders: Dictionary) -> void:
	if not is_summary(module_id): return
	var source_nodes: Array = program.get("modules", {}).get(module_id, {}).get("nodes", [])
	for node in source_nodes:
		var id := str(node.get("id", ""))
		if not holders.has(id): continue
		var holder: Node3D = holders[id]
		var factor := 1.0
		if node.get("op", "") in ["call", "trycall", "statement"]: factor = 1.25
		elif node.get("op", "") == "branch": factor = 1.1
		holder.scale = Vector3.ONE * factor


static func _default_positions(module_id: String) -> Dictionary:
	if module_id == "main":
		return {"task": [-3.0, 0.0, -2.5], "tools": [-3.0, 0.0, 2.5],
			"start": [1.0, 0.0, 0.0], "done": [5.0, 0.0, 0.0]}
	return {"init": [-4.0, 0.0, -2.5], "model": [0.0, 0.0, -2.5],
		"branch": [4.0, 0.0, -2.5], "execute": [4.0, 0.0, 2.5],
		"observation": [0.0, 0.0, 2.5]}
