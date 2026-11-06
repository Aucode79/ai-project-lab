extends SceneTree

const Editor := preload("res://scripts/interaction/module_editor.gd")
const LabScene := preload("res://scripts/lessons/agent_lab.gd")
const PythonImport := preload("res://scripts/lessons/agent_lab_python_import.gd")
const Compiler := preload("res://scripts/compiler/compiler.gd")

class ImportHarness:
	extends Node
	var sample_mode := false
	var run_status := "idle"
	var revision := 1
	var view_mid := "main"
	var program := {"exampleTask": {"count": 1}, "modules": {"main": {"nodes": [
		{"id": "constant", "op": "const", "params": {"value": 1}}]}}}
	var selected_node_ids: Array[String] = ["selected"]
	var crumb: Array[String] = ["main"]
	var response := {"ok": true, "revision": 2}
	var request_path := ""
	var request_payload: Dictionary = {}
	var request_body := ""
	var load_count := 0
	var last_constant: Variant

	func api(path: String, payload: Variant = null, raw_body: String = "") -> Dictionary:
		request_path = path
		request_payload = payload if payload is Dictionary else {}
		request_body = raw_body
		return response

	func load_program() -> void:
		load_count += 1

	func _set_selected_constant(value: Variant, _numbers_only := false) -> void:
		last_constant = value

func _init() -> void:
	_run.call_deferred()

func _run() -> void:
	var python := OS.get_environment("AGENT_LAB_PYTHON")
	if python.is_empty(): python = "D:/smolagents/.venv/Scripts/python.exe"
	var failed := 0
	for filename in ["test_agent_lab.py", "test_comprehension.py", "test_cli_utf8.py"]:
		var output: Array = []
		var rc := OS.execute(python, ["-X", "utf8", ProjectSettings.globalize_path("res://../tools/lesson/" + filename)], output, true)
		for line in output: print(line)
		if rc != 0: failed += 1
	var p := {"formatVersion": "module/1", "entry": "main", "modules": {
		"main": {"inputs": [], "entry": "r", "nodes": [{"id": "c", "op": "const", "params": {"value": 42}}, {"id": "r", "op": "return"}],
		"edges": [{"from": "c.value", "to": "r.value"}]}}}
	var compiled: Dictionary = Compiler.compile(p)
	if not compiled.get("ok", false) or not "def module_main" in compiled.get("python", ""): failed += 1
	var visual := Editor.new()
	visual.program = p.duplicate(true)
	visual.program.layout = {}
	root.add_child(visual)
	await process_frame
	visual.disconnect_ports("c", 0, "r", 1)
	if not visual.program.modules.main.edges.is_empty(): failed += 1
	visual.connect_ports("c", 0, "r", 1)
	if visual.program.modules.main.edges.size() != 1: failed += 1
	visual.duplicate_module()
	var duplicate_id: String = visual.current
	visual.program.modules[duplicate_id].nodes[0].params.value = 99
	if visual.program.modules.main.nodes[0].params.value != 42: failed += 1
	visual.new_module()
	if not Compiler.compile(visual.program).get("ok", false): failed += 1
	visual.program = {"formatVersion": "module/1", "entry": "main", "layout": {}, "modules": {"main": {
		"inputs": [], "entry": "result", "nodes": [{"id": "result", "op": "nop"}, {"id": "constant", "op": "const", "params": {"value": 42}}, {"id": "done", "op": "return"}],
		"edges": [{"from": "result.next", "to": "done.exec"}, {"from": "constant.value", "to": "done.value"}]}}}
	visual.current = "main"
	visual.rebuild()
	visual.selected = ["result"]
	visual.extract_selection()
	if visual.program.modules.size() != 2 or not Compiler.compile(visual.program).get("ok", false): failed += 1
	visual.queue_free()
	await process_frame
	failed += await _test_python_import_ui()
	print("MODULE PROGRAM: ", "PASS" if failed == 0 else "FAIL", " failures=", failed)
	quit(0 if failed == 0 else 1)

func _test_python_import_ui() -> int:
	var failed := 0
	var harness := ImportHarness.new()
	root.add_child(harness)
	var controller := PythonImport.new()
	harness.add_child(controller)
	await process_frame
	failed += _check(controller.picker.file_mode == FileDialog.FILE_MODE_OPEN_FILE, "picker file mode")
	failed += _check(controller.picker.access == FileDialog.ACCESS_FILESYSTEM, "picker filesystem access")
	failed += _check(controller.picker.get_signal_connection_list("file_selected").size() == 1, "picker selection signal")
	var source := "def main(count):\n    return count + 1\n"
	var path := OS.get_cache_dir().path_join("agent-lab-import-%d.py" % Time.get_ticks_usec())
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		failed += 1
	else:
		file.store_string(source)
		file.close()
		controller.picker.file_selected.emit(path)
		await process_frame
		failed += _check(harness.request_path == "/import" and harness.request_payload.get("source") == source, "picker selection sends source")
		failed += _check(harness.request_payload.get("filename") == path.get_file() and harness.load_count == 1, "successful import reloads program")
		failed += _check(harness.selected_node_ids.is_empty() and harness.crumb.is_empty() and not controller.importing, "successful import resets navigation")
		harness.selected_node_ids = ["keep"]
		harness.crumb = ["main"]
		harness.load_count = 0
		controller._files_dropped(PackedStringArray([path]))
		await process_frame
		failed += _check(harness.load_count == 1 and harness.request_payload.get("source") == source, "drop imports and reloads")
		controller.run_field.text = "{\"count\": 3}"
		controller._run_input_confirmed()
		await process_frame
		failed += _check(harness.request_path == "/run" and harness.request_body == "{\"task\":{\"count\": 3}}", "integer input keeps its JSON token")
		controller.run_field.text = "{\"count\": 3.5}"
		controller._run_input_confirmed()
		await process_frame
		failed += _check(harness.request_body == "{\"task\":{\"count\": 3.5}}", "float input keeps its JSON token")
		controller.constant_field.text = "3"
		controller._constant_edit_confirmed()
		failed += _check(typeof(harness.last_constant) == TYPE_INT and harness.last_constant == 3, "integer constant edit stays int")
		controller.constant_field.text = "3.5"
		controller._constant_edit_confirmed()
		failed += _check(typeof(harness.last_constant) == TYPE_FLOAT and harness.last_constant == 3.5, "float constant edit stays float")
		harness.response = {"ok": false, "error": "Unknown endpoint"}
		harness.selected_node_ids = ["keep"]
		harness.crumb = ["main"]
		harness.load_count = 0
		controller._files_dropped(PackedStringArray([path]))
		await process_frame
		failed += _check(harness.load_count == 0 and harness.selected_node_ids == ["keep"] and harness.crumb == ["main"], "failed import leaves current view intact")
		failed += _check(controller.error_dialog.dialog_text == "当前 Agent Lab 后台服务是旧版本。请关闭旧 lab_service.py 后重新启动 Agent Lab。", "stale service error is actionable")
		DirAccess.remove_absolute(path)
	controller.queue_free()
	harness.queue_free()
	await process_frame
	return failed

func _check(condition: bool, label: String) -> int:
	if condition: return 0
	print("IMPORT UI: ", label)
	return 1
