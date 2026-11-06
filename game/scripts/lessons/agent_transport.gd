extends Node3D

## 第一课的可操作环境。模型只能调用单段移动、装卸和观测；没有寻路器。
## 复用 schema v6 StepRecorder，独立回环端口避免改变已有 MCP 工具契约。
const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const Catalog := preload("res://scripts/asset_lib/component_catalog.gd")
const Recorder := preload("res://scripts/core/step_recorder_core.gd")
const BASE := preload("res://scripts/asset_lib/asset_node.gd")
const Menu := preload("res://scripts/scene/scene_menu.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
const TextTile := preload("res://scripts/asset_lib/text_tile.gd")
const U := BASE.STANDARD_CUBE_SIZE
const NODES := {"A": [-4, 0], "B": [-2, 0], "C": [2, 0], "D": [4, 0], "E": [-2, 3], "F": [2, 3]}
const EDGES := [["A", "B"], ["B", "C"], ["C", "D"], ["B", "E"], ["E", "F"], ["F", "C"]]
const MODULES := ["agent_model_well", "agent_tool_rack", "agent_observation_tray", "agent_message_table", "agent_loop_table"]
var recorder := Recorder.new()
var server := TCPServer.new()
var peers: Array = []
var location := "A"
var carrying := ""
var crates := {"货物": "A", "蓝方块": "E", "黄方块": "F"}
var blocked := false
var move_count := 0
var tick := 0.0
var carrier: Node3D
var barrier: Node3D
var crate_meshes := {}
var modules: Array[Node3D] = []
var log_label: RichTextLabel
var input_box: LineEdit
var send_button: Button
var http: HTTPRequest
var busy := false
var active_tween: Tween

func _ready() -> void:
	add_child(recorder)
	recorder.begin_run("production", 1)
	_build_world()
	_build_ui()
	add_child(Menu.new())
	var err := server.listen(7321, "127.0.0.1")
	if err != OK:
		push_error("第一课端口 7321 被占用")
		get_tree().quit(1)
		return
	print("LESSON READY 127.0.0.1:7321")

func _process(delta: float) -> void:
	tick += delta
	while server.is_connection_available():
		peers.append({"peer": server.take_connection(), "buffer": ""})
	for conn in peers.duplicate():
		var peer: StreamPeerTCP = conn.peer
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_NONE or peer.get_status() == StreamPeerTCP.STATUS_ERROR:
			peers.erase(conn)
			continue
		var count := peer.get_available_bytes()
		if count == 0: continue
		var received := peer.get_partial_data(count)
		if received[0] != OK: continue
		# Client sends ensure_ascii JSON, so chunk boundaries never split UTF-8 glyphs.
		conn.buffer += received[1].get_string_from_utf8()
		while "\n" in conn.buffer:
			var end: int = conn.buffer.find("\n")
			var line: String = conn.buffer.substr(0, end)
			conn.buffer = conn.buffer.substr(end + 1)
			var request: Variant = JSON.parse_string(line)
			var answer := {"ok": false, "error": "invalid JSON"}
			if request is Dictionary: answer = _request(request)
			peer.put_data((JSON.stringify(answer) + "\n").to_utf8_buffer())

func _snapshot() -> Dictionary:
	return {"nodes": NODES, "edges": EDGES, "blocked_edges": [["B", "C"]] if blocked else [],
		"carrier": location, "carrying": carrying, "crates": crates.duplicate(), "destination": "D"}

func _record(tool: String, args: Dictionary, result: Dictionary, phase := "run", actor := "agent") -> int:
	if recorder.state_name() != "recording": recorder.begin_run("production", 1)
	return recorder.record_step({"t": tick, "phase": phase, "actor": actor,
		"action": {"tool": tool, "args": args}, "output": result,
		"world": {"entities": _snapshot(), "highlight": [location]},
		"ops": 1 if phase == "observe" else 20})

func _request(req: Dictionary) -> Dictionary:
	var tool := str(req.get("tool", ""))
	var args: Dictionary = req.get("args", {})
	if tool == "status":
		var positions := {}
		for item in crate_meshes: positions[item] = str(crate_meshes[item].position)
		return {"ok": true, "state": _snapshot(), "busy": busy, "cratePositions": positions}
	if tool == "trace": return recorder.get_doc()
	if tool == "save": return recorder.end_run()
	if tool == "capture":
		_capture.call_deferred()
		return {"ok": true, "path": "res://shots/video3d/lesson-live.png"}
	if tool == "task":
		busy = true
		_log("任务：" + str(args.get("text", "")))
		_record("dialogue.submit", args, {"ok": true}, "observe", "player")
		return {"ok": true}
	if tool == "model":
		_record("model.generate", args, {"ok": true, "result": args.get("response", {})}, "plan")
		_flash(0)
		return {"ok": true}
	if tool == "reply":
		busy = false
		send_button.disabled = false
		_log(str(args.get("text", "")))
		_record("dialogue.reply", args, {"ok": true}, "observe")
		return {"ok": true}
	var result := {"ok": true}
	var should_block := false
	match tool:
		"observe":
			result["state"] = _snapshot()
			_flash(2)
		"move":
			var target := str(args.get("node", ""))
			var pair := [location, target]
			var reverse := [target, location]
			if not EDGES.has(pair) and not EDGES.has(reverse): result = {"ok": false, "error": "not_adjacent"}
			elif blocked and (pair == ["B", "C"] or reverse == ["B", "C"]): result = {"ok": false, "error": "road_blocked"}
			else:
				location = target
				move_count += 1
				if carrying != "": crates[carrying] = target
				should_block = move_count == 1
				if active_tween: active_tween.kill()
				active_tween = create_tween().set_parallel(true)
				active_tween.tween_property(carrier, "position", _pos(location) + Vector3(0, U, 0), 0.7)
				if carrying != "": active_tween.tween_property(crate_meshes[carrying], "position", _pos(location) + Vector3(0, U * 2, 0), 0.7)
		"pickup":
			var item := str(args.get("crate", ""))
			if carrying != "": result = {"ok": false, "error": "carrier_full"}
			elif not crates.has(item) or crates[item] != location: result = {"ok": false, "error": "crate_not_here"}
			else:
				_finish_motion()
				carrying = item
				crate_meshes[item].position = _pos(location) + Vector3(0, U * 2, 0)
		"drop":
			if carrying == "": result = {"ok": false, "error": "carrier_empty"}
			else:
				_finish_motion()
				var slot := crates.keys().find(carrying)
				crate_meshes[carrying].position = _pos(location) + Vector3((slot - 1) * 0.75, U, -1.25)
				carrying = ""
		_:
			return {"ok": false, "error": "unknown_tool"}
	var i := _record(tool, args, result, "observe" if tool == "observe" else "run")
	if should_block:
		blocked = true
		barrier.visible = true
		_record("environment.close_road", {"edge": ["B", "C"]}, {"ok": true}, "build", "player")
		_log("环境变化：B—C 已封路")
	result["state"] = _snapshot()
	# Returned observation and recorded output must be identical, including the new road state.
	_record("tool.observation", {"callStep": i}, result, "observe")
	_log(tool + " " + JSON.stringify(args) + (" ✓" if result.ok else " × " + str(result.error)))
	if tool != "observe": _flash(1)
	return result

func _pos(node: String) -> Vector3:
	return Vector3(NODES[node][0], 0, NODES[node][1])

func _finish_motion() -> void:
	if active_tween: active_tween.kill()
	carrier.position = _pos(location) + Vector3(0, U, 0)
	if carrying != "": crate_meshes[carrying].position = _pos(location) + Vector3(0, U * 2, 0)

func _box(parent: Node3D, name_str: String, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.name = name_str
	mesh.mesh = Surface.mesh(size)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	mesh.material_override = mat
	mesh.position = pos
	parent.add_child(mesh)
	return mesh

func _build_world() -> void:
	var env := WorldEnvironment.new()
	env.environment = Environment.new()
	env.environment.background_mode = Environment.BG_COLOR
	env.environment.background_color = Color("f7f0d8")
	env.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.environment.ambient_light_color = Color.WHITE
	env.environment.ambient_light_energy = 0.65
	add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	add_child(sun)
	_box(self, "Sandbox", Vector3(13, U, 12), Vector3(0, -U / 2, -1), Color("b9cbcb"))
	var roads: Array = []
	for edge in EDGES:
		var a := _pos(edge[0])
		var b := _pos(edge[1])
		var size := Vector3(absf(a.x - b.x) + 1, U / 2, absf(a.z - b.z) + 1)
		var center := (a + b) / 2 + Vector3(0, U / 4, 0)
		roads.append({"pos": center, "half": size / 2})
		_box(self, "Road", size, center, Color("f7f0d8")).set_meta("transport_road", true)
	for node in NODES:
		# 站点名脚前贴地字砖（spec §2.3）；落进路段脚印（板顶 0.25）的 B/C 抬到路面上表面免被掩埋。
		var spot := _pos(node) + Vector3(0, 0.01, 0.75)
		for road in roads:
			var d: Vector3 = (spot - road.pos).abs()
			if d.x < road.half.x + 0.625 and d.z < road.half.z + 0.25:
				spot.y = U / 2 + 0.01
				break
		TextTile.ground_label(self, "StationTile", node + (" 终点" if node == "D" else ""),
			spot, Vector2(1.25, 0.5)).set_meta("px", Vector2i(256, 128))
	_box(self, "DeliveryBay", Vector3(3, U / 2, 1), Vector3(4, U / 4, -1.25), Color("68ab5d"))
	carrier = _box(self, "Carrier", Vector3(1, U, 1), _pos("A") + Vector3(0, U, 0), Color("536b73"))
	for item in crates:
		var color := Color("ef743b") if item == "货物" else (Color("24b9cf") if item == "蓝方块" else Color("f2c43d"))
		crate_meshes[item] = _box(self, item, Vector3.ONE * U, _pos(crates[item]) + Vector3(0, U, -U), color)
	barrier = _box(self, "Roadblock", Vector3(U, 1, 1.5), Vector3(0, U, 0), Color("db6268"))
	barrier.visible = false
	for idx in MODULES.size():
		for j in Catalog.MACHINES.size():
			if Catalog.MACHINES[j].id != MODULES[idx]: continue
			var assembly := Catalog.build_machine(j)
			var span := Catalog.footprint(j)
			var center := Vector3(-5.5 + idx * 2.75, 0, -4.25)
			assembly.position = center - Vector3(span.x / 2, 0, span.y / 2)
			add_child(assembly)
			modules.append(assembly)
	var camera := Camera3D.new()
	camera.position = Vector3(11, 15, 17)
	add_child(camera)
	camera.look_at(Vector3(0, 0, -1.5))
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 18
	camera.current = true
	TextTile.bake_all(self)

func _build_ui() -> void:
	var canvas := CanvasLayer.new()
	add_child(canvas)
	var panel := PanelContainer.new()
	panel.theme = Style.ui_theme()
	panel.position = Vector2(25, 25)
	panel.custom_minimum_size = Vector2(520, 270)
	canvas.add_child(panel)
	var rows := VBoxContainer.new()
	panel.add_child(rows)
	var title := Label.new()
	title.text = "第一课 · 真实 Agent 运输环境"
	title.add_theme_font_size_override("font_size", 26)
	rows.add_child(title)
	log_label = RichTextLabel.new()
	log_label.custom_minimum_size = Vector2(520, 180)
	log_label.add_theme_font_size_override("normal_font_size", 18)
	log_label.scroll_following = true
	rows.add_child(log_label)
	input_box = LineEdit.new()
	input_box.text = "把货物从 A 运到 D。"
	input_box.placeholder_text = "给智能体一个任务"
	input_box.text_submitted.connect(func(_text: String): _submit())
	rows.add_child(input_box)
	send_button = Button.new()
	send_button.text = "发送任务"
	send_button.pressed.connect(_submit)
	rows.add_child(send_button)
	http = HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(func(_result: int, code: int, _headers: PackedStringArray, _body: PackedByteArray):
		if code != 202:
			busy = false
			send_button.disabled = false
			_log("模型服务未连接；请启动 tools/lesson/run_agent.py --serve"))
	_log("对话框 → 模型 → 工具 → 观测")

func _submit() -> void:
	if busy or input_box.text.strip_edges().is_empty(): return
	send_button.disabled = true
	var err := http.request("http://127.0.0.1:7322/task", ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify({"text": input_box.text}))
	if err != OK:
		send_button.disabled = false
		_log("无法连接模型服务")

func _log(text: String) -> void:
	log_label.append_text(text + "\n")

func _flash(index: int) -> void:
	if index >= modules.size(): return
	var module := modules[index]
	var tween := create_tween()
	tween.tween_property(module, "position:y", 0.25, 0.15)
	tween.tween_property(module, "position:y", 0.0, 0.3)

func _capture() -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://shots/video3d")
	get_viewport().get_texture().get_image().save_png("res://shots/video3d/lesson-live.png")
