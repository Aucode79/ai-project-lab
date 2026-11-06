extends SceneTree

const LabScene := preload("res://scenes/lessons/agent_lab.tscn")

func _init() -> void:
	_run.call_deferred()
	_watchdog.call_deferred()

func _watchdog() -> void:
	await create_timer(120.0).timeout
	push_error("showcase timed out")
	quit(124)

func _wait_until(condition: Callable, timeout_ms := 10000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call(): return true
		await process_frame
	return condition.call()

func _module_path(program: Dictionary, start: String, target: String) -> Array:
	var queue: Array[Dictionary] = [{"mid": start, "path": []}]
	var visited := {}
	while not queue.is_empty():
		var item: Dictionary = queue.pop_front()
		var mid := str(item.mid)
		if visited.has(mid): continue
		visited[mid] = true
		for node in program.get("modules", {}).get(mid, {}).get("nodes", []):
			var child := str(node.get("module", ""))
			if child.is_empty() or not program.get("modules", {}).has(child): continue
			var path: Array = item.path.duplicate()
			path.append(child)
			if child == target: return path
			queue.append({"mid": child, "path": path})
	return []

func _capture(path: String, wait_for_terrain := false) -> void:
	if wait_for_terrain:
		var terrain := root.get_node_or_null("AgentLab/Terrain") as VoxelTerrain
		if terrain != null:
			var block := terrain.voxel_to_data_block(Vector3i(0, 20, 0))
			var ready := false
			for frame in 900:
				if terrain.has_data_block(block):
					ready = true
					break
				await process_frame
			if not ready:
				push_error("showcase timed out waiting for island terrain")
				quit(1)
				return
			for frame in 90: await process_frame
	else:
		for frame in 12: await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_viewport().get_texture().get_image().save_png(path)
	if error != OK:
		push_error("could not save showcase image: " + path)
		quit(1)
		return
	print("SHOWCASE IMAGE: " + path)

func _constant_value(program: Dictionary, mid: String, node_id: String) -> Variant:
	for node in program.get("modules", {}).get(mid, {}).get("nodes", []):
		if str(node.get("id", "")) == node_id:
			return node.get("params", {}).get("value", null)
	return null

func _run() -> void:
	var source_path := OS.get_environment("AGENT_LAB_DEMO_FILE")
	var output_dir := OS.get_environment("AGENT_LAB_DEMO_OUTPUT")
	if source_path.is_empty() or output_dir.is_empty() or OS.get_environment("AGENT_LAB_API_URL").is_empty():
		push_error("isolated service, source file and output folder are required")
		quit(2)
		return
	var lab: Variant = LabScene.instantiate()
	root.add_child(lab)
	if not await _wait_until(func() -> bool: return not lab.program.is_empty()):
		push_error("isolated service did not load the program")
		quit(1)
		return
	var controller: Variant = lab.get_node("PythonImport")
	controller.picker.file_selected.emit(source_path)
	if not await _wait_until(func() -> bool: return not controller.importing):
		push_error("Python import did not finish")
		quit(1)
		return
	var entry_mid := str(lab.program.get("entry", ""))
	await _capture(output_dir.path_join("01-imported-3d-program.png"), true)
	var multiplier_mid := ""
	var multiplier_id := ""
	for mid in lab.program.get("modules", {}):
		for node in lab.program.modules[mid].get("nodes", []):
			var value: Variant = node.get("params", {}).get("value", null)
			if str(node.get("op", "")) == "const" \
					and typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_equal_approx(float(value), 2.0):
				multiplier_mid = str(mid)
				multiplier_id = str(node.get("id", ""))
	if multiplier_mid.is_empty():
		push_error("showcase program has no editable multiplier")
		quit(1)
		return
	for mid in _module_path(lab.program, entry_mid, multiplier_mid):
		lab.drill_in(str(mid))
		if not await _wait_until(func() -> bool:
			return lab.view_mid == str(mid) and lab.machine_nodes.has(multiplier_id), 5000):
			push_error("could not open the editable 3D expression")
			quit(1)
			return
	var selected: Array[String] = [multiplier_id]
	lab.selected_node_ids = selected
	var old_revision := int(lab.revision)
	var f2 := InputEventKey.new()
	f2.pressed = true
	f2.keycode = KEY_F2
	lab._unhandled_input(f2)
	if controller.constant_field.text != "2":
		push_error("F2 did not show the selected integer constant")
		quit(1)
		return
	controller.constant_field.text = "3"
	controller.constant_dialog.get_ok_button().pressed.emit()
	if not await _wait_until(func() -> bool:
		return int(lab.revision) > old_revision and _constant_value(lab.program, multiplier_mid, multiplier_id) == 3):
		push_error("edited constant was not saved")
		quit(1)
		return
	await _capture(output_dir.path_join("02-editable-expression.png"))
	var space := InputEventKey.new()
	space.pressed = true
	space.keycode = KEY_SPACE
	lab._unhandled_input(space)
	controller.run_field.text = "[1, -2, 3]"
	controller.run_dialog.get_ok_button().pressed.emit()
	if not await _wait_until(func() -> bool:
		return not lab.anim_state.get("queue", []).is_empty() or lab.run_status == "complete", 10000):
		push_error("program produced no visible execution activity")
		quit(1)
		return
	await _capture(output_dir.path_join("03-execution-in-progress.png"))
	if not await _wait_until(func() -> bool:
		return lab.run_status in ["complete", "failed", "cancelled"]):
		push_error("program execution timed out")
		quit(1)
		return
	var state: Dictionary = await lab.api("/state?after=0")
	print("SHOWCASE RESULT: " + JSON.stringify({
		"status": state.get("status", ""),
		"result": state.get("result", null),
		"events": state.get("totalEvents", -1),
		"runId": state.get("runId", "")
	}))
	lab.queue_free()
	await process_frame
	quit(0 if state.get("status", "") == "complete" else 1)
