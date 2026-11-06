extends "res://scripts/lessons/agent_transport.gd"

## One scene owns transport state, executable-program views and document objects.
## 三维整机由 machine_view 构建；端口可直接拖线（连/断），编辑立即保存回后端。
const MachineView := preload("res://scripts/lessons/machine_view.gd")
const MachineAnim := preload("res://scripts/lessons/machine_anim.gd")
const MachineNav := preload("res://scripts/lessons/machine_nav.gd")
const SelectionMarquee := preload("res://scripts/lessons/selection_marquee.gd")
const AgentComponentsView := preload("res://scripts/lessons/agent_components_view.gd")
const AgentLabGrab := preload("res://scripts/lessons/agent_lab_grab.gd")
const AgentLabWire := preload("res://scripts/lessons/agent_lab_wire.gd")
const AgentLabSandboxWorld := preload("res://scripts/lessons/agent_lab_sandbox_world.gd")
const PythonImport := preload("res://scripts/lessons/agent_lab_python_import.gd")
var program: Dictionary = {}
var sample_mode := false
var revision := 0
var polling := false
var poll_time := 0.0
var event_cursor := 0
var run_id := ""
var run_status := "idle"
var document_entries: Array = []
var machine_root: Node3D
var machine_nodes := {}
var port_positions := {}
var drag_port := {}
var drag_preview: Node3D
var document_root: Node3D
var last_event := {}
var node_positions := {}
var execution_events: Array = []
var tools_catalog: Array = []
var anim_state: Dictionary = MachineAnim.new_state()
var anim_hooks := {}
var cursor: Node3D = null
var cursor_path: Array = []
var cursor_progress := 0.0
var view_mid := ""
var last_active := ""
var prev_active: Array = []
var prev_calls: Array = []
var call_modules := {}
var crumb: Array = []
var camera_orbiting := false
var camera_yaw := 0.0
var camera_pitch := 0.0
var camera_distance := 0.0
var camera_focus := Vector3(0, 0, -4)
var selected_node_ids: Array[String] = []
var pressed_node_id := ""
var pending_wire_port := {}
var press_position := Vector2.ZERO
var move_start_positions := {}
var moving_nodes := false
var holding_nodes := false
var hold_elapsed := 0.0
var grab_offset := Vector3.ZERO
var drop_velocity := {}
var drop_targets := {}
var drop_ghosts := {}
var drop_save_pending := false
var held_mouse_position := Vector2.ZERO
var marquee_layer: CanvasLayer
var marquee: SelectionMarquee
var marquee_base_selection: Array[String] = []
var selected_wire: Dictionary = {}
var selected_wire_materials: Array[Material] = []

func _ready() -> void:
	sample_mode = OS.get_environment("AGENT_LAB_SAMPLE") == "linear_search"
	add_child(recorder)
	recorder.begin_run("explore", 1)
	add_child(Menu.new())
	var import_controller := PythonImport.new()
	import_controller.name = "PythonImport"
	add_child(import_controller)
	_build_world()
	var camera := get_viewport().get_camera_3d()
	camera_focus = AgentLabSandboxWorld.PROGRAM_STAGE_CENTER + Vector3(0, 1.5, 0)
	camera.position = camera_focus + Vector3(14, 19, 22)
	camera.look_at(camera_focus)
	var camera_offset := camera.position - camera_focus
	camera_distance = camera_offset.length()
	camera_yaw = atan2(camera_offset.x, camera_offset.z)
	camera_pitch = atan2(camera_offset.y, Vector2(camera_offset.x, camera_offset.z).length())
	camera.size = 28.0
	camera.h_offset = 0.0
	machine_root = Node3D.new()
	add_child(machine_root)
	document_root = Node3D.new()
	document_root.name = "AgentDocuments"
	document_root.position = AgentLabSandboxWorld.TRANSPORT_STAGE_ORIGIN
	add_child(document_root)
	AgentLabGrab.create_marquee(self)
	if not sample_mode and OS.get_environment("AGENT_LAB_NO_WORLD_SERVER") != "1":
		if server.listen(7331, "127.0.0.1") != OK:
			_log("7331 已被占用")
			return
		print("AGENT LAB WORLD READY 7331")
	elif sample_mode:
		print("AGENT LAB LINEAR SEARCH VISUAL SAMPLE READY")
	load_program()
	if OS.get_cmdline_user_args().has("--shot"):
		_capture.call_deferred()

## Reuse the real transport behavior while the integration helper replaces its
## temporary presentation world with the free sandbox island.
func _build_world() -> void:
	super._build_world()
	AgentLabSandboxWorld.integrate(self, modules)

func open_python_picker() -> void:
	get_node("PythonImport").call("open_picker")

func _process(delta: float) -> void:
	if not sample_mode:
		super._process(delta)
		poll_time += delta
		if poll_time > 0.5 and not polling:
			poll_time = 0.0
			poll_state()
	_step_anim(delta)
	AgentLabGrab.step(self, delta)

func api(path: String, payload: Variant = null, raw_body: String = "") -> Dictionary:
	var req := HTTPRequest.new()
	add_child(req)
	req.timeout = 8
	var method := HTTPClient.METHOD_GET if payload == null and raw_body.is_empty() else HTTPClient.METHOD_POST
	var body := ""
	if method == HTTPClient.METHOD_POST: body = raw_body if not raw_body.is_empty() else JSON.stringify(payload)
	var api_url := OS.get_environment("AGENT_LAB_API_URL")
	if api_url.is_empty(): api_url = "http://127.0.0.1:7332"
	var err := req.request(api_url + path, ["Content-Type: application/json"], method, body)
	if err != OK: req.queue_free(); return {"ok": false, "error": "后端未连接"}
	var reply: Array = await req.request_completed
	req.queue_free()
	var parsed: Variant = JSON.parse_string((reply[3] as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Dictionary else {"ok": false, "error": "后端未连接"}

func load_program() -> void:
	if sample_mode:
		_load_sample_program()
		return
	var result := await api("/program")
	if result.get("ok", false):
		program = result.get("program", program)
		revision = result.revision
		tools_catalog = result.get("tools", [])
		set_meta("run_input", program.get("exampleTask", null))
		var entry_mid := str(program.get("entry", ""))
		if program.get("modules", {}).has(entry_mid):
			crumb = MachineNav.push([], entry_mid, _module_label(entry_mid))
		build_machine()
	else: _log("请启动 tools/lesson/start_agent_lab.ps1")

func _load_sample_program() -> void:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://lesson_samples/linear_search.json"))
	if not parsed is Dictionary or not bool(parsed.get("displayOnly", false)):
		push_error("Linear search teaching sample is missing or is not display-only")
		return
	program = parsed
	revision = 0
	var entry_mid := str(program.get("entry", ""))
	crumb = MachineNav.push([], entry_mid, _module_label(entry_mid))
	build_machine(entry_mid)

func poll_state() -> void:
	polling = true
	var result := await api("/state?after=" + str(event_cursor))
	if result.get("ok", false):
		if result.runId != run_id:
			run_id = result.runId
			event_cursor = 0
			execution_events.clear()
			execution_events.clear()
		else:
			for event in result.events:
				event_cursor = int(event.seq) + 1
				last_event = event
				execution_events.append(event)
				if event.kind == "tool.start": _log(event.tool + " " + JSON.stringify(event.args))
				if event.kind == "model.start": _log("模型正在处理上下文…")
		if result.status != run_status:
			run_status = result.status
			if run_status in ["complete", "failed", "cancelled"]: _log(JSON.stringify(result.result))
		if result.documents != document_entries: update_documents(result.documents)
		if program.is_empty(): load_program()
	polling = false

func _submit() -> void:
	if sample_mode or run_status == "running": return
	var entry: Dictionary = program.get("modules", {}).get(str(program.get("entry", "")), {})
	if str(entry.get("language", "")) == "python":
		var input_value: Variant = get_meta("run_input", program.get("exampleTask", null))
		if not has_meta("run_input"):
			set_meta("run_input", input_value)
			build_machine(view_mid)
		run_task(input_value)
		return
	run_task(program.get("exampleTask", "读取任务.md，完成后把结果写入报告.md"))

func run_task(task: Variant) -> void:
	if sample_mode or run_status == "running": return
	var result := await api("/run", {"task": task})
	if not result.get("ok", false):
		_log(JSON.stringify(result))

func _log(_message: String) -> void:
	pass

func build_machine(mid := "") -> void:
	AgentLabGrab.clear_ghosts(self)
	AgentLabWire.clear(self)
	pressed_node_id = ""
	pending_wire_port = {}
	move_start_positions.clear()
	holding_nodes = false
	moving_nodes = false
	hold_elapsed = 0.0
	drop_velocity.clear()
	drop_targets.clear()
	drop_save_pending = false
	view_mid = mid if mid != "" else str(program.get("entry", ""))
	for c in machine_root.get_children(): machine_root.remove_child(c); c.queue_free()
	machine_nodes.clear()
	node_positions.clear()
	port_positions.clear()
	# 重建即重置回放：旧视图的包、游标、事件队列一并作废，防悬空引用。
	anim_state = MachineAnim.new_state()
	anim_hooks = {}
	cursor = null
	cursor_path = []
	cursor_progress = 0.0
	last_active = ""
	prev_active = []
	prev_calls = []
	call_modules = {}
	# 视图模块被编辑器删掉时退回入口，防止 hooks 填充踩空。
	if not program.get("modules", {}).has(view_mid):
		view_mid = str(program.get("entry", ""))
	if program.is_empty() or not program.get("modules", {}).has(str(program.get("entry", ""))):
		_log("程序入口缺失，暂不搭建整机")
		return
	var display_program := AgentComponentsView.project(program, view_mid)
	var summary_view := AgentComponentsView.is_summary(view_mid)
	var python_source := str(program.get("modules", {}).get(str(program.get("entry", "")), {}).get("language", "")) == "python"
	if python_source and view_mid == str(program.get("entry", "")):
		var input_value: Variant = get_meta("run_input", program.get("exampleTask", null))
		for node in display_program.modules[view_mid].nodes:
			if str(node.get("op", "")) != "input": continue
			var params: Dictionary = node.get("params", {})
			if str(params.get("name", "")) != "task": continue
			params["previewValue"] = input_value
	var view := MachineView.build(machine_root, display_program, view_mid, not summary_view,
		false, sample_mode or python_source, summary_view)
	node_positions = view.positions
	port_positions = view.ports
	machine_nodes = view.nodes
	AgentComponentsView.decorate(program, view_mid, machine_nodes)
	# 以布局包围盒中心对齐到平台中心；手动编辑后保持保存的机器原点。
	var saved_machine_layout: Dictionary = display_program.get("machineLayout", {}).get(view_mid, {})
	var saved_origin: Array = saved_machine_layout.get("origin", [])
	if saved_origin.size() == 3:
		machine_root.position = Vector3(float(saved_origin[0]),
			maxf(float(saved_origin[1]), AgentLabSandboxWorld.DECK_TOP_Y), float(saved_origin[2]))
	elif not node_positions.is_empty():
		var min_p: Vector3 = node_positions.values()[0]
		var max_p: Vector3 = min_p
		for p in node_positions.values():
			min_p = min_p.min(p)
			max_p = max_p.max(p)
		machine_root.position = AgentLabSandboxWorld.PROGRAM_STAGE_CENTER - (min_p + max_p) / 2
	_fit_machine_stage(display_program, summary_view)
	for n in program.modules[view_mid].nodes:
		if not machine_nodes.has(n.id): continue
		var holder: Node3D = machine_nodes[n.id]
		var ext := MachineView.extents(n) * holder.scale
		if summary_view: ext.y = maxf(ext.y, 3.25)
		_pick_body(holder, {"node": n.id, "module": n.get("module", view_mid)},
			ext + Vector3(0.25, 0.25, 0.25), Vector3.ZERO)
	if summary_view:
		MachineView.build_wires(machine_root, display_program.modules[view_mid], view)
	AgentLabWire.add_pick_bodies(self, view)
	_fill_anim_hooks(view)
	AgentLabGrab.refresh_selection(self)

func _fit_machine_stage(display_program: Dictionary, summary_view: bool) -> void:
	if node_positions.is_empty(): return
	var module: Dictionary = display_program.modules[view_mid]
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var max_y := 1.0
	for n in module.nodes:
		if not node_positions.has(str(n.id)): continue
		var pos: Vector3 = node_positions[str(n.id)]
		var ext: Vector3 = MachineView.extents(n) * machine_nodes[str(n.id)].scale
		if summary_view: ext.y = maxf(ext.y, 3.25)
		min_x = minf(min_x, pos.x - ext.x)
		max_x = maxf(max_x, pos.x + ext.x)
		min_z = minf(min_z, pos.z - ext.z)
		max_z = maxf(max_z, pos.z + ext.z)
		max_y = maxf(max_y, pos.y + ext.y)
		# Keep the final Python statement inside the fitted stage.
		if str(n.get("op", "")) == "return":
			min_x = minf(min_x, pos.x - 2.25)
			max_x = maxf(max_x, pos.x + 2.25)
			min_z = minf(min_z, pos.z - 0.375)
			max_z = maxf(max_z, pos.z + 0.375)
	var world_min_x := machine_root.position.x + min_x
	var world_max_x := machine_root.position.x + max_x
	var world_min_z := machine_root.position.z + min_z
	var world_max_z := machine_root.position.z + max_z
	var imported_python := str(program.get("modules", {}).get(str(program.get("entry", "")), {}).get("language", "")) == "python"
	var frame_world := summary_view or (view_mid == str(program.get("entry", "")) and not imported_python)
	if frame_world:
		var transport_center := AgentLabSandboxWorld.TRANSPORT_STAGE_CENTER
		var transport_half := AgentLabSandboxWorld.TRANSPORT_HALF_EXTENTS
		world_min_x = minf(world_min_x, transport_center.x - transport_half.x)
		world_max_x = maxf(world_max_x, transport_center.x + transport_half.x)
		world_min_z = minf(world_min_z, transport_center.z - transport_half.y)
		world_max_z = maxf(world_max_z, transport_center.z + transport_half.y)
		max_y = maxf(max_y, AgentLabSandboxWorld.TRANSPORT_MAX_HEIGHT)
	var padding := 1.25
	var width := maxf(5.5, world_max_x - world_min_x + padding * 2.0)
	var depth := maxf(4.5, world_max_z - world_min_z + padding * 2.0)
	var center := Vector3((world_min_x + world_max_x) * 0.5, 0.0,
		(world_min_z + world_max_z) * 0.5)
	var camera := get_viewport().get_camera_3d()
	var stage_center := Vector3(center.x, machine_root.position.y + maxf(1.25, max_y * 0.5), center.z)
	var focus_delta := stage_center - camera_focus
	camera_focus = stage_center
	camera.position += focus_delta
	camera.look_at(camera_focus)
	var horizontal_projection := absf(cos(camera_yaw)) * width + absf(sin(camera_yaw)) * depth
	var vertical_projection := sin(camera_pitch) * horizontal_projection + cos(camera_pitch) * (max_y + 1.0)
	camera.size = clampf(vertical_projection + 1.75, 9.0, 32.0)

## 执行回放挂钩：走线折线（键 "from->to"）、节点 holder、工具名→节点、
## 包父级；tool_target 取世界台缺省（fs.* 目标在事件到达时单独算）。
func _fill_anim_hooks(view: Dictionary) -> void:
	var wires := {}
	for w in view.wires:
		wires[str(w.from) + "->" + str(w.to)] = w.path
	var tools := {}
	for n in program.modules[view_mid].nodes:
		if n.op == "tool": tools[str(n.get("params", {}).get("name", ""))] = n.id
	anim_hooks = {"wires": wires, "nodes": machine_nodes, "tools": tools,
		"tool_target": machine_root.to_local(AgentLabSandboxWorld.WORLD_TOOL_TARGET),
		"packet_root": machine_root}

func _pick_body(parent: Node3D, metadata: Dictionary, size: Vector3, pos: Vector3) -> void:
	var body := StaticBody3D.new()
	body.set_meta("lab", metadata)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	var scale := parent.scale.abs()
	shape.size = size / scale
	collision.shape = shape
	body.add_child(collision)
	body.position = pos + Vector3(0, shape.size.y / 2, 0)
	parent.add_child(body)

func _save_machine_layout() -> void:
	if sample_mode: return
	if not program.has("machineLayout"): program["machineLayout"] = {}
	var saved: Dictionary = program.machineLayout.get(view_mid, {})
	var positions: Dictionary = saved.get("positions", {}).duplicate(true)
	for id in machine_nodes:
		var p: Vector3 = machine_nodes[id].position
		positions[id] = [p.x, p.y, p.z]
	saved["positions"] = positions
	saved["origin"] = [machine_root.position.x, machine_root.position.y, machine_root.position.z]
	if AgentComponentsView.is_summary(view_mid):
		saved["componentLayoutVersion"] = AgentComponentsView.COMPONENT_LAYOUT_VERSION
	program.machineLayout[view_mid] = saved
	var result := await api("/program", {"program": program, "revision": revision})
	if result.get("ok", false):
		program = result.get("program", program)
		revision = result.revision
		build_machine(view_mid)
	else:
		load_program()

func _set_selected_constant(value: Variant, numbers_only := false) -> void:
	if sample_mode: return
	var changed := false
	var global_names: Array[String] = []
	for node in program.get("modules", {}).get(view_mid, {}).get("nodes", []):
		if str(node.get("id", "")) not in selected_node_ids or str(node.get("op", "")) != "const": continue
		var params: Dictionary = node.get("params", {})
		if numbers_only and typeof(params.get("value", null)) not in [TYPE_INT, TYPE_FLOAT]: continue
		var global_name := str(params.get("globalName", ""))
		if global_name != "":
			if global_name not in global_names: global_names.append(global_name)
		else:
			params["value"] = value
			if typeof(value) in [TYPE_INT, TYPE_FLOAT]:
				params["literalType"] = "int" if typeof(value) == TYPE_INT else "float"
			else:
				params.erase("literalType")
		changed = true
	for module in program.get("modules", {}).values():
		for node in module.get("nodes", []):
			if str(node.get("op", "")) != "const": continue
			var params: Dictionary = node.get("params", {})
			if str(params.get("globalName", "")) in global_names:
				if numbers_only and typeof(params.get("value", null)) not in [TYPE_INT, TYPE_FLOAT]: continue
				params["value"] = value
				if typeof(value) in [TYPE_INT, TYPE_FLOAT]:
					params["literalType"] = "int" if typeof(value) == TYPE_INT else "float"
				else:
					params.erase("literalType")
				changed = true
	if changed: await _save_program_changes()

func _save_program_changes() -> void:
	if sample_mode: return
	var result := await api("/program", {"program": program, "revision": revision})
	if result.get("ok", false):
		program = result.get("program", program)
		revision = result.revision
		build_machine(view_mid)
	else:
		load_program()

## 输出端口拖到输入端口可连线；点击通道选中后点红色断开钮或按 Delete 可断线。
## 类型不匹配即时拒绝，成功后立即保存到后端。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if not sample_mode and event.keycode >= KEY_0 and event.keycode <= KEY_9:
			_set_selected_constant(event.keycode - KEY_0, true)
			get_viewport().set_input_as_handled()
			return
		match event.keycode:
			KEY_SPACE: _submit()
			KEY_DELETE:
				if not selected_wire.is_empty(): AgentLabWire.disconnect_selected(self)
				else: return
			KEY_F2:
				if not sample_mode: get_node("PythonImport").call("open_constant_editor")
			KEY_ESCAPE:
				if not sample_mode: await api("/stop", {})
			KEY_BACKSPACE:
				if crumb.size() > 1: go_to(crumb.size() - 2)
			KEY_F5: load_program()
			KEY_R:
				if not sample_mode and run_status != "running": reset_world()
			_: return
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			camera_orbiting = event.pressed
			get_viewport().set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP or event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			var camera := get_viewport().get_camera_3d()
			camera.size = clampf(camera.size * (0.88 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.14), 8.0, 40.0)
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion and camera_orbiting:
		camera_yaw = wrapf(camera_yaw - deg_to_rad(event.relative.x) * 0.25, -PI, PI)
		camera_pitch = clampf(camera_pitch + deg_to_rad(event.relative.y) * 0.25, 0.05, 1.48)
		var horizontal := cos(camera_pitch) * camera_distance
		var camera := get_viewport().get_camera_3d()
		camera.position = camera_focus + Vector3(sin(camera_yaw) * horizontal, sin(camera_pitch) * camera_distance, cos(camera_yaw) * horizontal)
		camera.look_at(camera_focus)
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and drag_port.is_empty():
			var hit := AgentLabGrab.ray_hit(self, event)
			press_position = event.position
			held_mouse_position = event.position
			if hit.is_empty():
				AgentLabWire.clear(self)
				pressed_node_id = ""
				pending_wire_port = {}
				moving_nodes = false
				holding_nodes = false
				hold_elapsed = 0.0
				move_start_positions.clear()
				marquee_base_selection.assign(selected_node_ids if Input.is_key_pressed(KEY_SHIFT) else [])
				selected_node_ids.assign(marquee_base_selection)
				marquee.set_drag_rect(event.position, event.position)
				get_viewport().set_input_as_handled()
				return
			if hit.collider.has_meta("wire_disconnect"):
				AgentLabWire.disconnect_selected(self)
				get_viewport().set_input_as_handled()
				return
			if hit.collider.has_meta("wire"):
				selected_node_ids.clear()
				AgentLabGrab.refresh_selection(self)
				AgentLabWire.select(self, hit.collider.get_meta("wire"))
				get_viewport().set_input_as_handled()
				return
			if hit.collider.has_meta("port"):
				AgentLabWire.clear(self)
				pending_wire_port = hit.collider.get_meta("port")
				AgentLabGrab.begin_from_hit(self, str(pending_wire_port.node))
			elif hit.collider.has_meta("lab"):
				AgentLabWire.clear(self)
				var data: Dictionary = hit.collider.get_meta("lab")
				if data.has("action"):
					match str(data.action):
						"run": _submit()
						"stop":
							if not sample_mode: await api("/stop", {})
						"reset":
							if not sample_mode and run_status != "running": reset_world()
					get_viewport().set_input_as_handled()
					return
				elif data.has("node"):
					AgentLabGrab.begin_from_hit(self, str(data.node))
					if event.double_click: drill_in(str(data.get("module", view_mid)))
					else: get_viewport().set_input_as_handled()
					return
		elif not event.pressed and not drag_port.is_empty():
			AgentLabWire.finish_drag(self, event)
		elif not event.pressed and (pressed_node_id != "" or marquee.active):
			if holding_nodes: AgentLabGrab.release_held(self)
			marquee.clear_drag_rect()
			pressed_node_id = ""
			pending_wire_port = {}
			move_start_positions.clear()
			moving_nodes = false
			holding_nodes = false
			hold_elapsed = 0.0
			AgentLabGrab.refresh_selection(self)
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		held_mouse_position = event.position
		if not drag_port.is_empty():
			AgentLabWire.update_drag_preview(self, event.position)
		elif not pending_wire_port.is_empty() and event.position.distance_to(press_position) > 5.0:
			drag_port = pending_wire_port.duplicate()
			pending_wire_port = {}
			pressed_node_id = ""
			drag_preview = Node3D.new()
			machine_root.add_child(drag_preview)
			AgentLabWire.update_drag_preview(self, event.position)
		elif pressed_node_id != "":
			if holding_nodes: AgentLabGrab.move_selected(self, event.position)
		elif marquee.active:
			marquee.set_drag_rect(press_position, event.position)
			AgentLabGrab.select_inside(self, Rect2(press_position, event.position - press_position).abs())
			AgentLabGrab.refresh_selection(self)
			get_viewport().set_input_as_handled()


func _save_machine_program(new_edges: Array, message: String) -> void:
	if sample_mode: return
	program.modules[view_mid].edges = new_edges
	var result := await api("/program", {"program": program, "revision": revision})
	if result.get("ok", false):
		program = result.program
		revision = result.revision
		_log(message)
		if not result.get("validation", {}).get("ok", false):
			_log("已保存为草稿，校验未过：" + JSON.stringify(result.validation.errors))
	else:
		_log("保存失败（" + str(result.get("error", "")) + "），已重新加载服务器版本")
		load_program()
		return
	build_machine(view_mid)

func update_documents(entries: Array) -> void:
	document_entries = entries
	for c in document_root.get_children(): document_root.remove_child(c); c.queue_free()
	var idx := 0
	for entry in entries:
		var pos := AgentLabSandboxWorld.DOCUMENT_LOCAL_TARGET + Vector3(0, 0, idx * 0.75)
		var color := Color("e8be73") if int(entry.get("bytes", 0)) > 0 else Color("dbe8df")
		_box(document_root, "Document", Vector3(1, 1, 0.5), pos, color)
		idx += 1

func reset_world() -> void:
	location = "A"
	carrying = ""
	crates = {"货物": "A", "蓝方块": "E", "黄方块": "F"}
	blocked = false
	move_count = 0
	barrier.visible = false
	_finish_motion()
	for item in crates: crate_meshes[item].position = _pos(crates[item]) + Vector3(0, U, -U)

func _request(req: Dictionary) -> Dictionary:
	var tool: String = req.get("tool", "")
	var args: Dictionary = req.get("args", {})
	if tool == "documents.sync":
		update_documents(args.get("documents", []))
		return {"ok": true}
	if tool == "lab.begin":
		if recorder.state_name() == "recording": recorder.end_run()
		recorder.begin_run("task", 1)
		_record("program.begin", args, {"ok": true}, "build", "player")
		busy = true
		return {"ok": true}
	if tool == "lab.end":
		_record("program.end", args, {"ok": true}, "observe")
		recorder.end_run()
		busy = false
		return recorder.get_doc()
	if tool == "external":
		return {"ok": true, "step": _record(args.tool, args.args, args.result)}
	if tool == "execution":
		var e: Dictionary = args.get("event", {})
		var kind := str(e.get("kind", ""))
		if kind == "enter": call_modules[str(e.get("callId", ""))] = str(e.get("moduleId", ""))
		# 推送路径独家的入队口：本模块 node/value 走包动画，enter/leave 全收
		# （深度配对推导要用）；tool.start 到达即发包，不进限速队列。轮询路径不在此入队。
		if kind in ["node", "value"] and str(e.get("moduleId", "")) == view_mid:
			MachineAnim.queue_events(anim_state, [e])
		elif kind in ["enter", "leave"]:
			MachineAnim.queue_events(anim_state, [e])
		elif kind == "tool.start":
			_pulse_tool(e)
		return {"ok": true}
	if tool == "world.snapshot":
		var snapshot := _snapshot()
		snapshot["documents"] = document_entries
		return {"ok": true, "state": snapshot, "step": _record(tool, args, {"ok": true, "state": snapshot}, "observe")}
	if tool == "world.inspect":
		var id: String = args.get("id", "")
		return {"ok": true, "id": id, "location": crates.get(id, location if id == "carrier" else null)}
	if tool == "lab.reset": reset_world(); return {"ok": true}
	if tool == "lab.program": return {"ok": true, "program": program}
	if tool == "lab.screenshot":
		_capture.call_deferred()
		return {"ok": true}
	if tool.begins_with("world."):
		return super._request({"tool": tool.trim_prefix("world."), "args": args})
	return super._request(req)

func _capture() -> void:
	var terrain := get_node_or_null("Terrain") as VoxelTerrain
	if terrain != null:
		var block := terrain.voxel_to_data_block(Vector3i(0, 20, 0))
		var terrain_ready := false
		for frame in 900:
			if terrain.has_data_block(block):
				terrain_ready = true
				break
			await get_tree().process_frame
		if not terrain_ready:
			push_error("Agent Lab screenshot timed out waiting for sandbox terrain data")
			if OS.get_cmdline_user_args().has("--shot"):
				get_tree().quit(1)
			return
		for frame in 120:
			await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var screenshot := OS.get_cmdline_user_args().has("--shot")
	var target := "res://shots/agent-lab"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(target))
	var image_path := target + ("/unified-world.png" if screenshot else "/live.png")
	get_viewport().get_texture().get_image().save_png(image_path)
	if screenshot:
		print("AGENT LAB SHOT: " + image_path)
		get_tree().quit()

## —— 执行回放（machine_anim 接线） ——

## 每帧推进限速回放：激活节点点灯/熄灯、游标走线、深度叠板。
func _step_anim(delta: float) -> void:
	if anim_hooks.is_empty(): return
	var activated: Array = MachineAnim.update(anim_state, delta, anim_hooks)
	for node_id in activated:
		if machine_nodes.has(node_id): MachineAnim.set_working(machine_nodes[node_id], true)
		_cursor_to(str(node_id))
	for node_id in prev_active:
		if not activated.has(node_id) and machine_nodes.has(node_id):
			MachineAnim.set_working(machine_nodes[node_id], false)
	prev_active = activated
	_step_depth()
	if cursor == null or cursor_progress >= 1.0 or cursor_path.size() < 2: return
	var total := _wire_length(cursor_path)
	if total <= 0.0: return
	cursor_progress = minf(cursor_progress + MachineAnim.PACKET_SPEED * delta / total, 1.0)
	MachineAnim.step_cursor(cursor, cursor_path, cursor_progress)
## 游标推进：有 prev.next→cur.exec 控制线就沿该线走，否则瞬移到节点顶。
func _cursor_to(node_id: String) -> void:
	if not machine_nodes.has(node_id): return
	var target: Vector3 = machine_nodes[node_id].position + Vector3(0, 0.75, 0)
	if cursor == null:
		cursor = MachineAnim.build_cursor(machine_root, MachineView.EXEC_COLOR)
		last_active = ""
	var wire: Array = anim_hooks.get("wires", {}).get(last_active + ".next->" + node_id + ".exec", [])
	if last_active != "" and wire.size() >= 2:
		cursor_path = wire
		cursor_progress = 0.0
	else:
		cursor_path = [target]
		cursor_progress = 1.0
		MachineAnim.step_cursor(cursor, cursor_path, 1.0)
	last_active = node_id
## enter/leave 配对回放后按 anim_state 深度刷新叠板：开/闭的 callId 对应
## 当前视图里引用该模块的 call 节点。
func _step_depth() -> void:
	var now_calls: Array = anim_state["calls"].keys()
	for call_id in now_calls:
		if not prev_calls.has(call_id): _apply_depth(str(call_id))
	for call_id in prev_calls:
		if not now_calls.has(call_id): _apply_depth(str(call_id))
	prev_calls = now_calls
func _apply_depth(call_id: String) -> void:
	var mid: String = call_modules.get(call_id, "")
	for n in program.modules[view_mid].nodes:
		if n.op in ["call", "trycall"] and str(n.get("module", "")) == mid and machine_nodes.has(n.id):
			MachineAnim.depth_plates(machine_nodes[n.id], int(anim_state["depth"]))
func _wire_length(path: Array) -> float:
	var total := 0.0
	for i in path.size() - 1:
		total += (path[i + 1] - path[i]).length()
	return total

## tool.start 到达即发金色脉冲包：fs.* 飞文档堆、其余飞世界台
## （机器局部坐标 = 世界目标 − machine_root.position）；包交给 anim_state 随帧推进释放。
func _pulse_tool(e: Dictionary) -> void:
	var tool_id: String = anim_hooks.get("tools", {}).get(str(e.get("tool", "")), "")
	if tool_id == "" or not machine_nodes.has(tool_id): return
	var world_target: Vector3 = document_root.to_global(AgentLabSandboxWorld.DOCUMENT_LOCAL_TARGET) \
		if str(e.get("tool", "")).begins_with("fs.") else carrier.global_position + Vector3(0, 0.75, 0)
	var from: Node3D = machine_nodes[tool_id]
	var path := MachineView.channel_path(from.position + Vector3(0, 0.5, 0), machine_root.to_local(world_target))
	anim_state["packets"].append(MachineAnim.spawn_packet(machine_root, path, MachineAnim.TOOL_PULSE_COLOR))

## —— 三维嵌套导航（machine_nav 接线） ——

func _module_label(mid: String) -> String:
	return str(program.get("modules", {}).get(mid, {}).get("label", mid))

## 下钻：面包屑入栈，相机 0.4 s 推近后重建该模块视图（headless 不跑 tween，
## 仅窗口态有意义）。
func drill_in(mid: String) -> void:
	if program.is_empty() or mid == view_mid: return
	var target := MachineNav.drill_target(program, mid)
	if not target.ok:
		_log("找不到模块 " + mid)
		return
	view_mid = mid
	crumb = MachineNav.push(crumb, mid, _module_label(mid))
	_fly_camera(true, func() -> void:
		build_machine(mid)
		pass)

## 面包屑跳回第 i 段；回到入口段时相机复原到整机全景。
func go_to(i: int) -> void:
	if crumb.is_empty() or i < 0 or i >= crumb.size(): return
	crumb = MachineNav.pop_to(crumb, i)
	var cur: Dictionary = crumb[crumb.size() - 1]
	if str(cur.mid) == view_mid: return
	view_mid = str(cur.mid)
	_fly_camera(view_mid != str(program.get("entry", "")), func() -> void:
		build_machine(view_mid))

func _fly_camera(close_up: bool, then: Callable) -> void:
	var camera := get_viewport().get_camera_3d()
	var tween := create_tween()
	tween.tween_property(camera, "size", 13.0 if close_up else 28.0, 0.4)
	tween.tween_callback(then)
