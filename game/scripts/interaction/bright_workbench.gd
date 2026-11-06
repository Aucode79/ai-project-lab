extends Node3D

# Component studio: the production visual catalog; teaching assets retain their runtime semantics.
const Specimens := preload("res://scripts/asset_lib/component_catalog.gd")
const Map := preload("res://scripts/interaction/unfolding_map.gd")
const Hub := preload("res://scripts/interaction/interaction_hub.gd")
const Orbit := preload("res://scripts/interaction/orbit_camera.gd")
var items: Array[RigidBody3D] = []
var labels: Array[Node3D] = []
var _hovered: RigidBody3D
var _hover_tick := 0.0
var _label_baking := false
var _labels_ready := false
var selected: RigidBody3D
var _homes := {}
var status_tile: MeshInstance3D
const Tiles := preload("res://scripts/asset_lib/text_tile.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
var hub: Hub
var camera: Orbit

## 全部 26 件常驻；每页两列两行，以实际包围盒取景。
## 这样 26 件都在场景里（可拾取、可点开），字砖仍保持可读字号。
const SPECIMEN_IDS := [
	"agent_loop_table", "agent_memory_rack", "agent_model_well", "agent_execution_table",
	"agent_task_dock", "agent_answer_dock", "agent_budget_rail", "agent_tool_rack",
	"agent_observation_tray", "agent_state_cabinet", "agent_plan_steps", "agent_argument_gate",
	"agent_message_table", "agent_parallel_bridge",
	"code_assign", "code_call", "code_branch", "code_loop",
	"code_define", "code_read", "code_guard", "code_return",
	"studio_session_walker", "studio_text_tile", "studio_flow_strip", "studio_lesson_screen",
]
const COLUMNS := 2
const SPACING := 10.0
const ROWS_PER_PAGE := 2

var page := 0
var page_count := 1

func _ready() -> void:
	add_child(preload("res://scripts/scene/scene_menu.gd").new())
	_build_floor()
	for slot in SPECIMEN_IDS.size():
		var index := Specimens.index_of(SPECIMEN_IDS[slot])
		if index < 0:
			continue
		var visual := Specimens.build_machine(index)
		var bounds := AABB()
		for i in visual.get_child_count():
			var part := visual.get_child(i) as MeshInstance3D
			var box := part.transform * part.get_aabb()
			bounds = box if i == 0 else bounds.merge(box)
		var body := RigidBody3D.new()
		body.name = Specimens.MACHINES[index].id
		body.set_meta("specimen_index", index)
		body.freeze = true
		body.lock_rotation = true
		# Center the single shape at the body origin: predictor copies only its size.
		visual.position = -bounds.get_center()
		body.add_child(visual)
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = bounds.size
		shape.shape = box
		body.add_child(shape)
		body.position = Vector3((slot % COLUMNS) * SPACING, 0, (slot / COLUMNS) * SPACING) + bounds.get_center()
		add_child(body)
		items.append(body)
		# Shared ground text facility: 6 x 3 m quad, four lines, no floating text.
		var label := Specimens.build_label(index)
		label.position = Vector3(body.position.x - Specimens.footprint(index).x * 0.5, 0.0,
			body.position.z - Specimens.footprint(index).y * 0.5)
		label.position -= body.position
		label.set_meta("placement_ignore", true)
		body.add_child(label)
		labels.append(label)
		_homes[str(body.name)] = body.transform
		# Pick-only proxy shares the moving body, but never blocks physics or placement.
		var proxy := StaticBody3D.new()
		proxy.name = "TextPick"
		proxy.collision_layer = 2
		proxy.collision_mask = 0
		proxy.set_meta("pick_target", body)
		proxy.set_meta("placement_ignore", true)
		var pick_shape := CollisionShape3D.new()
		var pick_box := BoxShape3D.new()
		pick_box.size = Vector3(6, 0.04, 3)
		pick_shape.shape = pick_box
		proxy.position = label.position + label.get_child(0).position
		proxy.add_child(pick_shape)
		body.add_child(proxy)
	var rows := int(ceil(float(SPECIMEN_IDS.size()) / float(COLUMNS)))
	page_count = maxi(1, int(ceil(float(rows) / float(ROWS_PER_PAGE))))
	var focus := Node3D.new()
	add_child(focus)
	camera = Orbit.new()
	camera.target = focus
	add_child(camera)
	camera.snap_preset("iso")
	camera.orbit_requires_middle = true
	camera.snap_pose(0.0, 0.96, 32.0)
	# Hub 是唯一输入所有者（否则相机移动会被处理两次）。
	camera.set_process_unhandled_input(false)
	hub = Hub.new()
	add_child(hub)
	hub.setup(self, camera)
	hub.open_view.scrollable_source = true
	hub.open_view.code_provider = _source_text
	hub.open_view.key_provider = _reader_key
	hub.open_view.open_hook = _on_reader_open
	hub.open_view.choices_provider = reader.choices
	hub.open_view.choice_handler = _reader_choice
	hub.drag.settled.connect(func(_id, _position): _status("已放好 · 外延对齐 0.25 m 网格"))
	hub.drag.drop_rejected.connect(func(_id, _reason): _status("无法放在这里 · 已放回原处"))
	hub.drag.dropped.connect(func(_id): _status("正在落下 · 等待物理落定"))
	hub.run.run_start = func(): _status("组件阅读与摆放 · 智能体运行尚未接入")
	hub.drag.validator = func(pose): return pose.origin.y > -0.1 and absf(pose.origin.x - 6) < 19 and absf(pose.origin.z - 60) < 74
	status_tile = Tiles.make("组件工坊 · 26 件\n点按阅读 · 长按搬运 · 中键旋转 · 右键平移\nPgUp / PgDn 翻页 · F1 场景 · H 帮助", Vector2(14, 3))
	status_tile.position = Vector3(6, 0.01, -3)
	status_tile.set_meta("px", Vector2i(1536, 330))
	add_child(status_tile)
	_show_page(0)
	bake_labels.call_deferred()
	get_viewport().size_changed.connect(_on_viewport_resize)
	_capture_if_requested.call_deferred()


## 机位停在某一页（连续 ROWS_PER_PAGE 行）上，只框住这一页的样件与字砖。
## 26 件都在场景里，但一次只看一页 —— 这样字砖不用为了塞下全部而缩小。
func _show_page(index: int) -> void:
	page = wrapi(index, 0, page_count)
	if status_tile != null: status_tile.position.z = page * ROWS_PER_PAGE * SPACING - 3.0
	var first_row := page * ROWS_PER_PAGE
	var last_row := first_row + ROWS_PER_PAGE
	_frame_content(func(slot: int) -> bool:
		var row := slot / COLUMNS
		return row >= first_row and row < last_row)


func next_page() -> void:
	_show_page(page + 1)


func previous_page() -> void:
	_show_page(page - 1)


func _unhandled_input(event: InputEvent) -> void:
	if get_meta("scene_menu_open", false): return
	if hub != null and hub.open_view != null and hub.open_view.is_open():
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F and is_instance_valid(selected):
			camera.focus_on(selected.global_position)
			camera.size = 9.0
		elif event.keycode == KEY_HOME: _show_page(page)
		elif event.keycode == KEY_H: _status("点按阅读 / 长按搬运 · 中键旋转 / 右键平移\n滚轮缩放 · Tab 视角 · F 聚焦 / Home 全页\nCtrl+S 保存布局 / Ctrl+O 读取布局")
		elif event.ctrl_pressed and event.keycode == KEY_S: save_layout()
		elif event.ctrl_pressed and event.keycode == KEY_O: load_layout()
	if event.is_action_pressed("ui_page_down") or event.is_action_pressed("ui_page_up"):
		if event.is_action_pressed("ui_page_down"):
			next_page()
		else:
			previous_page()
		get_viewport().set_input_as_handled()


## 按真实包围盒与相机基向量算正交视口尺寸。手工估算在等距投影下会裁掉边角
## （实测 12 件时右下角被切）；用几何算，增删对象都不用再调常数。
## filter 决定这一页包含哪些 slot。
func _frame_content(filter: Callable = Callable()) -> void:
	var boxes: Array[AABB] = []
	for slot in items.size():
		if filter.is_valid() and not bool(filter.call(slot)):
			continue
		_collect_world_boxes(items[slot], items[slot].transform, boxes)
		_collect_world_boxes(labels[slot], labels[slot].global_transform, boxes)
	if status_tile != null: boxes.append(status_tile.global_transform * status_tile.get_aabb())
	if boxes.is_empty():
		camera.size = 20.0
		return
	var content := boxes[0]
	for i in range(1, boxes.size()):
		content = content.merge(boxes[i])
	camera.focus_on(content.get_center())
	var basis := camera.global_transform.basis
	var pivot: Vector3 = camera.pivot_world()
	var half_w := 0.0
	var half_h := 0.0
	for i in 8:
		var corner := content.get_endpoint(i)
		var rel := corner - pivot
		half_w = maxf(half_w, absf(rel.dot(basis.x)))
		half_h = maxf(half_h, absf(rel.dot(basis.y)))
	var aspect := 1.6
	var viewport := get_viewport()
	if viewport != null and viewport.get_visible_rect().size.y > 1.0:
		aspect = viewport.get_visible_rect().size.x / viewport.get_visible_rect().size.y
	camera.size = maxf(half_h, half_w / maxf(aspect, 0.5)) * 2.0 * 1.12


func _collect_world_boxes(node: Node, xf: Transform3D, boxes: Array[AABB]) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		boxes.append(xf * (node as MeshInstance3D).get_aabb())
	for child in node.get_children():
		if child is Node3D:
			_collect_world_boxes(child, xf * (child as Node3D).transform, boxes)

# ---------- 四层展开阅读器（逻辑在生产模块 unfolding_reader.gd，这里只做接线） ----------

const Reader := preload("res://scripts/interaction/unfolding_reader.gd")

var reader := Reader.new()


## 打开时重置一次阅读状态。渲染只读状态、不改状态，否则刷新会把层级覆盖回第 1 层。
func _on_reader_open(body: Node3D) -> void:
	selected = body as RigidBody3D
	reader.reset(str(body.name))


func _source_text(body: Node3D) -> String:
	if not reader.has_entry():
		return _flat_source_text(body)
	return reader.text()


func _reader_key(keycode: int) -> bool:
	if not reader.handle_key(keycode):
		return false
	hub.open_view.refresh()
	hub.open_view.reset_scroll()
	return true


## 没有四层映射的对象：退回整文件阅读，并写明这不是完整映射。
func _flat_source_text(body: Node3D) -> String:
	var index := int(body.get_meta("specimen_index", 0))
	var machine: Dictionary = Specimens.MACHINES[index]
	var path := "res://scripts/asset_lib/component_catalog.gd"
	var source := FileAccess.get_file_as_string(path)
	var text := "%s / %s — %s\n\n状态：静态样件，未连接智能体运行\n当前展示：样件几何与颜色的实际实现；不是完整智能体源码映射。\n%s\n\n" % [machine.zh, machine.en, machine.summary, path]
	text += "Esc 返回工作台；滚轮阅读全部源码。\n\n"
	var lines := source.split("\n")
	for line in lines.size():
		text += "%3d  %s\n" % [line + 1, lines[line]]
	return text

func _build_floor() -> void:
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("eeede7")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.52
	var world := WorldEnvironment.new()
	world.environment = environment
	add_child(world)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	add_child(sun)
	var floor_body := StaticBody3D.new()
	floor_body.position = Vector3(6, -0.25, 60)
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(44, 0.5, 156)
	shape.shape = box
	floor_body.add_child(shape)
	var mesh := MeshInstance3D.new()
	var visual := BoxMesh.new()
	visual.size = box.size
	mesh.mesh = visual
	var material := ShaderMaterial.new()
	material.shader = preload("res://scripts/interaction/workbench_floor.gdshader")
	mesh.material_override = material
	floor_body.add_child(mesh)
	add_child(floor_body)

## 文字走字砖：SubViewport + SystemFont 烘到地面牌面。渲染不可用时保持纸白底色。
func bake_labels() -> void:
	if DisplayServer.get_name() == "headless" or _labels_ready: return
	if _label_baking:
		while _label_baking: await get_tree().process_frame
		return
	_label_baking = true
	await Specimens.bake_glyph_textures(self)
	_label_baking = false
	_labels_ready = true


func _reader_choice(index: int) -> void:
	if reader.select_choice(index):
		hub.open_view.refresh()
		hub.open_view.reset_scroll()

func _status(text: String) -> void:
	if status_tile == null: return
	status_tile.set_meta("text", PackedStringArray(["组件工坊", text, "H 操作说明 · F 聚焦 · Home 全页"]))
	await Tiles.bake_all(status_tile)

func _physics_process(delta: float) -> void:
	_hover_tick += delta
	if _hover_tick < 0.1 or hub == null: return
	_hover_tick = 0.0
	var target: RigidBody3D = null
	if not hub.open_view.is_open() and hub.drag.state() == hub.drag.DragState.IDLE:
		target = hub._pick_body(get_viewport().get_mouse_position())
	if target == _hovered: return
	_set_highlight(_hovered, false)
	_hovered = target
	_set_highlight(_hovered, true)
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if target else Input.CURSOR_ARROW)

func _set_highlight(body: RigidBody3D, on: bool) -> void:
	if not is_instance_valid(body): return
	var material: StandardMaterial3D = null
	if on:
		material = StandardMaterial3D.new()
		material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		material.albedo_color = Color(1, 0.85, 0.4, 0.18)
		material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	for part in body.get_child(0).get_children():
		if part is MeshInstance3D: part.material_overlay = material

func save_layout(path := "user://component_layout.json") -> bool:
	var layout := {}
	for item in items:
		layout[str(item.name)] = [item.position.x, item.position.y, item.position.z]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return false
	file.store_string(JSON.stringify(layout))
	_status("布局已保存")
	return true

func load_layout(path := "user://component_layout.json") -> bool:
	if not FileAccess.file_exists(path):
		_status("还没有保存的布局")
		return false
	var layout: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not layout is Dictionary: return false
	# Validate every entry before moving anything.
	for item in items:
		var values: Variant = layout.get(str(item.name))
		if not values is Array or values.size() != 3: return false
		for value in values:
			if not (value is float or value is int) or not is_finite(float(value)): return false
	for item in items:
		var values: Array = layout[str(item.name)]
		item.position = Vector3(values[0], values[1], values[2])
	_show_page(page)
	_status("布局已恢复")
	return true

func _exit_tree() -> void:
	if get_viewport().size_changed.is_connected(_on_viewport_resize):
		get_viewport().size_changed.disconnect(_on_viewport_resize)
	Input.set_default_cursor_shape(Input.CURSOR_ARROW)

func _on_viewport_resize() -> void:
	_show_page(page)

func _capture_if_requested() -> void:
	if not "--shot" in OS.get_cmdline_user_args(): return
	if DisplayServer.get_name() == "headless":
		push_error("截图需要窗口渲染")
		get_tree().quit(2)
		return
	await bake_labels()
	var output := "res://shots/world.png"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--out="): output = arg.substr(6)
	for frame in 10: await get_tree().process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var error := get_viewport().get_texture().get_image().save_png(output)
	print("STUDIO SHOT: ", output, " error=", error)
	get_tree().quit(0 if error == OK else 1)
