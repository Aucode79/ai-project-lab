extends SceneTree

const LabScene := preload("res://scenes/lessons/agent_lab.tscn")

var failures: Array[String] = []

func _init() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)

func _wait_until(condition: Callable, timeout_ms := 10000) -> bool:
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		if condition.call(): return true
		await process_frame
	return condition.call()

func _find_module_path(program: Dictionary, start: String, target: String) -> Array:
	var queue: Array[Dictionary] = [{"mid": start, "path": []}]
	var visited := {}
	while not queue.is_empty():
		var item: Dictionary = queue.pop_front()
		var mid := str(item.mid)
		if visited.has(mid): continue
		visited[mid] = true
		var module: Dictionary = program.get("modules", {}).get(mid, {})
		for node in module.get("nodes", []):
			var child := str(node.get("module", ""))
			if child.is_empty() or not program.get("modules", {}).has(child): continue
			var path: Array = item.path.duplicate()
			path.append(child)
			if child == target: return path
			queue.append({"mid": child, "path": path})
	return []

func _constant_value(program: Dictionary, mid: String, node_id: String) -> Variant:
	for node in program.get("modules", {}).get(mid, {}).get("nodes", []):
		if str(node.get("id", "")) == node_id:
			return node.get("params", {}).get("value", null)
	return null

func _run() -> void:
	var api_url := OS.get_environment("AGENT_LAB_API_URL")
	var source_path := OS.get_environment("AGENT_LAB_ACCEPTANCE_FILE")
	if api_url.is_empty() or source_path.is_empty() \
			or OS.get_environment("AGENT_LAB_NO_WORLD_SERVER") != "1":
		push_error("isolated API URL, source path and world-server skip flag are required")
		quit(2)
		return
	var lab: Variant = LabScene.instantiate()
	root.add_child(lab)
	print("IMPORT ASSET ACCEPTANCE: wait for isolated service")
	if not await _wait_until(func() -> bool: return not lab.program.is_empty()):
		push_error("initial program did not load from isolated service")
		quit(1)
		return
	var controller: Variant = lab.get_node("PythonImport")
	print("IMPORT ASSET ACCEPTANCE: import selected file")
	controller.picker.file_selected.emit(source_path)
	if not await _wait_until(func() -> bool: return not controller.importing):
		push_error("file selection callback did not complete")
		quit(1)
		return
	var entry_mid := str(lab.program.get("entry", ""))
	var modules: Dictionary = lab.program.get("modules", {})
	var entry_module: Dictionary = modules.get(entry_mid, {})
	_check(str(entry_module.get("language", "")) == "python", "imported module is marked as Python")
	_check(lab.view_mid == entry_mid and not lab.machine_nodes.is_empty(),
		"successful import rebuilds the 3D program machine")
	for node in entry_module.get("nodes", []):
		_check(lab.machine_nodes.has(str(node.get("id", ""))),
			"entry node exists in the 3D machine: " + str(node.get("id", "")))
	var multiplier_mid := ""
	var multiplier_id := ""
	for mid in modules:
		for node in modules[mid].get("nodes", []):
			var value: Variant = node.get("params", {}).get("value", null)
			if str(node.get("op", "")) == "const" \
					and typeof(value) in [TYPE_INT, TYPE_FLOAT] and value == 2:
				multiplier_mid = str(mid)
				multiplier_id = str(node.get("id", ""))
	_check(not multiplier_mid.is_empty(), "editable multiplier constant exists")
	if multiplier_mid.is_empty():
		push_error("imported program has no editable multiplier")
		quit(1)
		return
	var module_path := _find_module_path(lab.program, entry_mid, multiplier_mid)
	for mid in module_path:
		lab.drill_in(str(mid))
		var deadline := Time.get_ticks_msec() + 3000
		while Time.get_ticks_msec() < deadline:
			if lab.view_mid == str(mid) and lab.machine_nodes.has(multiplier_id): break
			await process_frame
		_check(lab.view_mid == str(mid) and lab.machine_nodes.has(multiplier_id),
			"nested expression is visible as a 3D machine: " + str(mid))
		if not lab.machine_nodes.has(multiplier_id):
			push_error("nested expression did not build the editable 3D node")
			quit(1)
			return
	_check(lab.machine_nodes.has(multiplier_id), "multiplier has a 3D node holder")
	var selected: Array[String] = [multiplier_id]
	lab.selected_node_ids = selected
	var revision_before_edit := int(lab.revision)
	var edit_key := InputEventKey.new()
	edit_key.pressed = true
	edit_key.keycode = KEY_F2
	lab._unhandled_input(edit_key)
	var editor_has_two: bool = controller.constant_field.text == "2"
	_check(editor_has_two, "F2 editor reads the selected 3D constant")
	if not editor_has_two:
		push_error("F2 did not open the selected constant in the editor; view=" + lab.view_mid
			+ " selected=" + str(lab.selected_node_ids) + " node=" + str(lab.program.modules.get(lab.view_mid, {}).get("nodes", []))
			+ " field=" + controller.constant_field.text + " dialog=" + controller.error_dialog.dialog_text)
		quit(1)
		return
	controller.constant_field.text = "3"
	controller.constant_dialog.get_ok_button().pressed.emit()
	_check(not controller.constant_dialog.visible, "confirming F2 closes its modal editor")
	print("IMPORT ASSET ACCEPTANCE: wait for F2 save")
	var saved_condition := func() -> bool:
		return int(lab.revision) > revision_before_edit \
			and _constant_value(lab.program, multiplier_mid, multiplier_id) == 3
	var edit_saved := await _wait_until(saved_condition, 10000)
	if not edit_saved:
		push_error("F2 edit did not update the live graph")
		quit(1)
		return
	var saved: Dictionary = await lab.api("/program")
	_check(_constant_value(saved.get("program", {}), multiplier_mid, multiplier_id) == 3,
		"F2 edit is saved through the actual 3D editor API path")
	_check(int(saved.get("revision", 0)) > revision_before_edit,
		"saved program revision advances")
	var run_key := InputEventKey.new()
	run_key.pressed = true
	run_key.keycode = KEY_SPACE
	lab._unhandled_input(run_key)
	controller.run_field.text = "[1, -2, 3]"
	controller.run_dialog.get_ok_button().pressed.emit()
	_check(not controller.run_dialog.visible, "confirming run input closes its modal dialog")
	print("IMPORT ASSET ACCEPTANCE: wait for execution")
	var run_started_condition := func() -> bool:
		return str(lab.run_status) in ["running", "complete", "failed", "cancelled"] \
			or controller.error_dialog.visible
	var run_started := await _wait_until(run_started_condition, 8000)
	if controller.error_dialog.visible:
		push_error("run dialog request failed: " + controller.error_dialog.dialog_text)
		quit(1)
		return
	_check(run_started, "run dialog sends a request to the isolated service")
	var execution_finished := await _wait_until(func() -> bool:
		return str(lab.run_status) in ["complete", "failed", "cancelled"], 20000)
	var state: Dictionary = await lab.api("/state?after=0")
	_check(execution_finished, "run status finishes within the acceptance timeout")
	_check(state.get("status", "") == "complete", "imported program finishes through the run dialog")
	var score_map: Variant = state.get("result", null)
	var score_map_matches: bool = score_map is Dictionary and score_map.size() == 2 \
		and is_equal_approx(float(score_map.get("value-01", -1)), 3.0) \
		and is_equal_approx(float(score_map.get("value-03", -1)), 9.0)
	_check(score_map_matches,
		"edited imported program returns the expected score map")
	if not failures.is_empty():
		print("IMPORT ASSET ACCEPTANCE STATE: " + JSON.stringify(state))
	for failure in failures: print("IMPORT ASSET ACCEPTANCE: " + failure)
	lab.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
