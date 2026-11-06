extends RefCounted

## Physical block selection, long-press pickup, fixed landing ghosts and drop settling.
const MachineView := preload("res://scripts/lessons/machine_view.gd")
const SelectionMarquee := preload("res://scripts/lessons/selection_marquee.gd")
const AgentComponentsView := preload("res://scripts/lessons/agent_components_view.gd")
const GRAB_DELAY := 0.28
const GRAB_LIFT := 1.0
const DROP_GRAVITY := 18.0

static func create_marquee(lab: Variant) -> void:
	if is_instance_valid(lab.marquee_layer): return
	lab.marquee_layer = CanvasLayer.new()
	lab.marquee_layer.layer = 20
	lab.add_child(lab.marquee_layer)
	lab.marquee = SelectionMarquee.new()
	lab.marquee.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	lab.marquee.mouse_filter = Control.MOUSE_FILTER_IGNORE
	lab.marquee_layer.add_child(lab.marquee)


static func step(lab: Variant, delta: float) -> void:
	_step_drops(lab, delta)
	if lab.pressed_node_id == "" or lab.holding_nodes: return
	lab.hold_elapsed += delta
	if lab.hold_elapsed >= GRAB_DELAY:
		_begin_grab(lab)
		if lab.holding_nodes: move_selected(lab, lab.held_mouse_position)


static func refresh_selection(lab: Variant) -> void:
	for id in lab.machine_nodes:
		var holder: Node3D = lab.machine_nodes[id]
		var mark := holder.get_node_or_null("SelectionGroundMark") as Node3D
		if lab.selected_node_ids.has(str(id)):
			if lab.holding_nodes and mark != null:
				mark.queue_free()
			elif mark == null and not lab.holding_nodes:
				mark = Node3D.new()
				mark.name = "SelectionGroundMark"
				var ext := MachineView.extents(_node_by_id(lab, str(id)))
				var material := StandardMaterial3D.new()
				material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				material.albedo_color = Color("58d4db")
				for side in 4:
					var strip := MeshInstance3D.new()
					var box := BoxMesh.new()
					var along_x := side < 2
					box.size = Vector3(ext.x + 0.2, 0.05, 0.05) if along_x else Vector3(0.05, 0.05, ext.z + 0.2)
					strip.mesh = box
					strip.material_override = material
					var edge := -1.0 if side % 2 == 0 else 1.0
					strip.position = Vector3(0, 0.04, edge * (ext.z / 2 + 0.1)) if along_x else Vector3(edge * (ext.x / 2 + 0.1), 0.04, 0)
					mark.add_child(strip)
				holder.add_child(mark)
		elif mark != null:
			mark.queue_free()


static func _node_by_id(lab: Variant, id: String) -> Dictionary:
	for node in lab.program.get("modules", {}).get(lab.view_mid, {}).get("nodes", []):
		if str(node.get("id", "")) == id: return node
	return {}


static func select_inside(lab: Variant, rect: Rect2) -> void:
	lab.selected_node_ids.assign(lab.marquee_base_selection)
	var camera: Camera3D = lab.get_viewport().get_camera_3d()
	for id in lab.node_positions:
		var screen: Vector2 = camera.unproject_position(lab.machine_root.to_global(lab.node_positions[id]))
		if rect.has_point(screen) and not lab.selected_node_ids.has(str(id)):
			lab.selected_node_ids.append(str(id))


static func begin_from_hit(lab: Variant, node_id: String) -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		if lab.selected_node_ids.has(node_id):
			lab.selected_node_ids.erase(node_id)
			refresh_selection(lab)
			return
		lab.selected_node_ids.append(node_id)
	elif not lab.selected_node_ids.has(node_id):
		lab.selected_node_ids.assign([node_id])
	lab.pressed_node_id = node_id
	lab.hold_elapsed = 0.0
	lab.held_mouse_position = lab.press_position
	lab.move_start_positions.clear()
	for id in lab.selected_node_ids:
		if lab.machine_nodes.has(id): lab.move_start_positions[id] = lab.machine_nodes[id].position
	refresh_selection(lab)


static func _begin_grab(lab: Variant) -> void:
	if lab.pressed_node_id == "" or not lab.move_start_positions.has(lab.pressed_node_id): return
	lab.pending_wire_port = {}
	lab.holding_nodes = true
	lab.moving_nodes = true
	var held_anchor: Vector3 = lab.move_start_positions[lab.pressed_node_id] + Vector3.UP * GRAB_LIFT
	for id in lab.move_start_positions:
		lab.move_start_positions[id] += Vector3.UP * GRAB_LIFT
		lab.machine_nodes[id].position = lab.move_start_positions[id]
	var camera: Camera3D = lab.get_viewport().get_camera_3d()
	var plane := Plane(Vector3.UP, lab.machine_root.global_position.y + GRAB_LIFT)
	var point: Variant = plane.intersects_ray(camera.project_ray_origin(lab.press_position), camera.project_ray_normal(lab.press_position))
	if point != null: lab.grab_offset = held_anchor - lab.machine_root.to_local(point)
	for id in lab.move_start_positions:
		_update_ghost(lab, str(id), lab.machine_nodes[id].position)
	refresh_selection(lab)


static func move_selected(lab: Variant, screen_pos: Vector2) -> void:
	var camera: Camera3D = lab.get_viewport().get_camera_3d()
	var plane := Plane(Vector3.UP, lab.machine_root.global_position.y + GRAB_LIFT)
	var point: Variant = plane.intersects_ray(camera.project_ray_origin(screen_pos), camera.project_ray_normal(screen_pos))
	if point == null: return
	var local_point: Vector3 = lab.machine_root.to_local(point)
	var target_anchor: Vector3 = local_point + lab.grab_offset
	var delta: Vector3 = target_anchor - lab.move_start_positions[lab.pressed_node_id]
	for id in lab.move_start_positions:
		var p: Vector3 = lab.move_start_positions[id]
		lab.machine_nodes[id].position = p + delta
		lab.node_positions[id] = lab.machine_nodes[id].position
		_update_ghost(lab, str(id), lab.machine_nodes[id].position)


static func release_held(lab: Variant) -> void:
	lab.drop_velocity.clear()
	lab.drop_targets.clear()
	for id in lab.move_start_positions:
		if not lab.machine_nodes.has(id): continue
		var holder: Node3D = lab.machine_nodes[id]
		var p := holder.position
		p.x = roundf(p.x / 0.25) * 0.25
		p.z = roundf(p.z / 0.25) * 0.25
		holder.position = p
		lab.node_positions[id] = p
		lab.drop_velocity[id] = 0.0
		lab.drop_targets[id] = 0.0
		_update_ghost(lab, str(id), p)
	lab.drop_save_pending = not lab.drop_velocity.is_empty()
	lab.held_mouse_position = Vector2.ZERO


static func clear_ghosts(lab: Variant) -> void:
	_clear_ghosts(lab)


static func _clear_ghosts(lab: Variant) -> void:
	for ghost in lab.drop_ghosts.values():
		if is_instance_valid(ghost): ghost.queue_free()
	lab.drop_ghosts.clear()


static func _create_ghost(lab: Variant, id: String, at: Vector3) -> void:
	var ghost := MeshInstance3D.new()
	ghost.name = "DropGhost_" + id
	var box := BoxMesh.new()
	box.size = MachineView.extents(_node_by_id(lab, id)) * lab.machine_nodes[id].scale
	if AgentComponentsView.is_summary(lab.view_mid): box.size.y = maxf(box.size.y, 3.25)
	ghost.mesh = box
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.wireframe = true
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.albedo_color = Color("58d4db", 0.58)
	ghost.material_override = material
	ghost.position = at + Vector3.UP * box.size.y / 2
	lab.machine_root.add_child(ghost)
	lab.drop_ghosts[id] = ghost


static func _update_ghost(lab: Variant, id: String, at: Vector3) -> void:
	var landing_x := roundf(at.x / 0.25) * 0.25
	var landing_z := roundf(at.z / 0.25) * 0.25
	if not lab.drop_ghosts.has(id) or not is_instance_valid(lab.drop_ghosts[id]):
		_create_ghost(lab, id, Vector3(landing_x, 0.0, landing_z))
		return
	var ghost: MeshInstance3D = lab.drop_ghosts[id]
	ghost.position.x = landing_x
	ghost.position.z = landing_z


static func _step_drops(lab: Variant, delta: float) -> void:
	if lab.drop_velocity.is_empty(): return
	for id in lab.drop_velocity.keys():
		if not lab.machine_nodes.has(id):
			lab.drop_velocity.erase(id)
			lab.drop_targets.erase(id)
			continue
		var velocity: float = float(lab.drop_velocity[id]) + DROP_GRAVITY * delta
		var holder: Node3D = lab.machine_nodes[id]
		var next_y := holder.position.y - velocity * delta
		if next_y <= float(lab.drop_targets[id]):
			next_y = float(lab.drop_targets[id])
			lab.drop_velocity.erase(id)
			lab.drop_targets.erase(id)
		else:
			lab.drop_velocity[id] = velocity
		holder.position.y = next_y
		lab.node_positions[id] = holder.position
	if lab.drop_velocity.is_empty() and lab.drop_save_pending:
		lab.drop_save_pending = false
		_clear_ghosts(lab)
		lab._save_machine_layout()


static func ray_hit(lab: Variant, event: InputEvent) -> Dictionary:
	var camera: Camera3D = lab.get_viewport().get_camera_3d()
	var start: Vector3 = camera.project_ray_origin(event.position)
	var finish: Vector3 = start + camera.project_ray_normal(event.position) * 200
	var query := PhysicsRayQueryParameters3D.create(start, finish)
	var excluded: Array[RID] = []
	for _attempt in 128:
		query.exclude = excluded
		var hit: Dictionary = lab.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty(): return {}
		var collider: Object = hit.collider
		if collider.has_meta("port") or collider.has_meta("lab") or collider.has_meta("wire") \
				or collider.has_meta("wire_disconnect"): return hit
		excluded.append(collider.get_rid())
	return {}
