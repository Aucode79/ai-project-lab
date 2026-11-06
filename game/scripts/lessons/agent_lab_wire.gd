extends RefCounted

## Pickable cable paths, selection highlighting and the 3D unlink control for Agent Lab.
const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
const MachineView := preload("res://scripts/lessons/machine_view.gd")
const MachineCable := preload("res://scripts/lessons/machine_cable.gd")
const AgentLabGrab := preload("res://scripts/lessons/agent_lab_grab.gd")


static func add_pick_bodies(lab: Variant, view: Dictionary) -> void:
	if lab.sample_mode: return
	for wire in view.get("wires", []):
		var path: Array = wire.get("path", [])
		if path.size() < 2: continue
		var body := StaticBody3D.new()
		body.name = "PickWire_" + str(wire.get("from", ""))
		body.set_meta("wire", wire)
		for i in path.size() - 1:
			var start: Vector3 = path[i]
			var finish: Vector3 = path[i + 1]
			var delta := (finish - start).abs()
			if delta.length() < 0.05: continue
			var shape := BoxShape3D.new()
			shape.size = Vector3(maxf(delta.x, 0.45), maxf(delta.y, 0.45), maxf(delta.z, 0.45))
			var collision := CollisionShape3D.new()
			collision.shape = shape
			collision.position = (start + finish) * 0.5
			body.add_child(collision)
		lab.machine_root.add_child(body)


static func update_drag_preview(lab: Variant, screen_pos: Vector2) -> void:
	if not lab.port_positions.has(lab.drag_port.node + "." + lab.drag_port.pin): return
	for child in lab.drag_preview.get_children(): child.queue_free()
	var start: Vector3 = lab.port_positions[lab.drag_port.node + "." + lab.drag_port.pin]["position"]
	var camera := lab.get_viewport().get_camera_3d()
	var origin := camera.project_ray_origin(screen_pos)
	var ray := camera.project_ray_normal(screen_pos)
	# 拖动面取过起点、法线朝上的水平面；相机近水平时退回过起点垂直于视线的平面。
	var point: Variant = Plane(Vector3.UP, start.y).intersects_ray(origin, ray)
	if point == null:
		point = Plane(-ray.cross(Vector3.UP).normalized(), start).intersects_ray(origin, ray)
	if point == null: return
	var color := MachineView.EXEC_WIRE_COLOR if lab.drag_port.type == "control" else MachineView.DATA_WIRE_COLOR
	var view_module: Dictionary = lab.program.get("modules", {}).get(lab.view_mid, {})
	var compact_python: bool = str(view_module.get("kind", "")) == "expression" \
		or str(view_module.get("language", "")) == "python"
	var preview_path := MachineView.channel_path(start, point,
		MachineView.WIRE_Y - 0.25 if compact_python else MachineView.WIRE_Y)
	MachineCable.build_wire(lab.drag_preview, preview_path, color, Vector3.ZERO, Vector3.ZERO, false)


static func finish_drag(lab: Variant, event: InputEvent) -> void:
	var from_port: Dictionary = lab.drag_port.duplicate()
	lab.drag_port = {}
	if is_instance_valid(lab.drag_preview): lab.drag_preview.queue_free(); lab.drag_preview = null
	if lab.sample_mode: return
	if not lab.program.get("modules", {}).has(lab.view_mid): return
	var hit := AgentLabGrab.ray_hit(lab, event)
	var target_port: Dictionary = {}
	if not hit.is_empty() and hit.collider.has_meta("port"):
		target_port = hit.collider.get_meta("port")
	var edges: Array = lab.program.modules[lab.view_mid].edges
	if target_port.is_empty():
		if from_port.dir == "in":
			var key: String = str(from_port.node) + "." + str(from_port.pin)
			var kept := edges.filter(func(edge): return str(edge.get("to", "")) != key)
			if kept.size() < edges.size():
				lab._save_machine_program(kept, "已断开 " + key + "，下一次运行生效")
		return
	if from_port.dir == target_port.dir: return
	var out_port := from_port if from_port.dir == "out" else target_port
	var in_port := target_port if from_port.dir == "out" else from_port
	var out_key: String = str(out_port.node) + "." + str(out_port.pin)
	var in_key: String = str(in_port.node) + "." + str(in_port.pin)
	if not MachineView.ports_compatible(out_port.pin, in_port.pin):
		lab._log("连线被拒绝：控制端口与数据端口不能混接")
		return
	# 单驱动替换：该输入口已有的入线、该控制出口已有的出线先移除。
	var new_edges: Array = edges.filter(func(edge: Dictionary):
		var replaced_input: bool = str(edge.get("to", "")) == in_key
		var replaced_output: bool = str(edge.get("from", "")) == out_key and in_port.pin == "exec"
		return not replaced_input and not replaced_output)
	if not new_edges.has({"from": out_key, "to": in_key}):
		new_edges.append({"from": out_key, "to": in_key})
	lab._save_machine_program(new_edges, "已连线 " + out_key + " → " + in_key + "，下一次运行生效")


static func select(lab: Variant, wire: Dictionary) -> void:
	clear(lab)
	lab.selected_wire = wire
	var holder: Node3D = wire.get("node")
	if not is_instance_valid(holder):
		lab.selected_wire = {}
		return
	for part in _wire_meshes(holder):
		if not part is MeshInstance3D or not part.material_override is StandardMaterial3D: continue
		var original := part.material_override as StandardMaterial3D
		lab.selected_wire_materials.append(original)
		var highlighted := original.duplicate() as StandardMaterial3D
		highlighted.albedo_color = Color("ffe08a")
		highlighted.emission_enabled = true
		highlighted.emission = Color("ffb84d")
		highlighted.emission_energy_multiplier = 0.7
		part.material_override = highlighted
	_add_disconnect_handle(wire)


static func _add_disconnect_handle(wire: Dictionary) -> void:
	var holder: Node3D = wire.get("node")
	var path: Array = wire.get("path", [])
	if not is_instance_valid(holder) or path.is_empty(): return
	var handle := Node3D.new()
	handle.name = "DisconnectHandle"
	var midpoint: Vector3 = path[path.size() / 2]
	handle.position = midpoint + Vector3(0, 0.7, 0)
	for angle in [PI / 4.0, -PI / 4.0]:
		var bar := MeshInstance3D.new()
		bar.mesh = Surface.mesh(Vector3(0.5, 0.125, 0.125))
		bar.material_override = Style.matte(Color("dc6457"))
		bar.rotation.y = angle
		handle.add_child(bar)
	var hitbox := StaticBody3D.new()
	hitbox.set_meta("wire_disconnect", true)
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.8, 0.5, 0.8)
	var collision := CollisionShape3D.new()
	collision.shape = shape
	hitbox.add_child(collision)
	handle.add_child(hitbox)
	holder.add_child(handle)


static func clear(lab: Variant) -> void:
	if not lab.selected_wire.is_empty():
		var holder: Node3D = lab.selected_wire.get("node")
		if is_instance_valid(holder):
			var index := 0
			for part in _wire_meshes(holder):
				if index < lab.selected_wire_materials.size():
					part.material_override = lab.selected_wire_materials[index]
				index += 1
			var handle := holder.get_node_or_null("DisconnectHandle")
			if handle != null: handle.queue_free()
	lab.selected_wire = {}
	lab.selected_wire_materials.clear()


static func _wire_meshes(holder: Node3D) -> Array:
	var meshes: Array = []
	for part in holder.find_children("*", "MeshInstance3D", true, false):
		if part.get_parent() != null and part.get_parent().name == "DisconnectHandle": continue
		meshes.append(part)
	return meshes


static func disconnect_selected(lab: Variant) -> void:
	if lab.selected_wire.is_empty() or lab.sample_mode: return
	var from_key := str(lab.selected_wire.get("from", ""))
	var to_key := str(lab.selected_wire.get("to", ""))
	var edges: Array = lab.program.get("modules", {}).get(lab.view_mid, {}).get("edges", [])
	var remaining: Array = edges.filter(func(edge: Dictionary) -> bool:
		return str(edge.get("from", "")) != from_key or str(edge.get("to", "")) != to_key)
	if remaining.size() == edges.size(): return
	clear(lab)
	lab._save_machine_program(remaining, "已断开 " + from_key + " → " + to_key + "，下一次运行生效")
