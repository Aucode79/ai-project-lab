extends Node3D

## Three graspable, textless 3D readings of the imported A+1 function.
const Style := preload("res://scripts/asset_lib/asset_style.gd")
const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const HOLD_DELAY := 0.28
const LIFT := 1.0
const GRAVITY := 18.0

var camera: Camera3D
var camera_focus := Vector3(0, 0, -8)
var camera_yaw := 0.0
var camera_pitch := 0.78
var camera_distance := 34.0
var orbiting := false
var mouse_position := Vector2.ZERO
var pressed_body: StaticBody3D
var holding := false
var hold_elapsed := 0.0
var grab_offset := Vector3.ZERO
var drop_velocity := {}
var drop_targets := {}
var drop_ghosts := {}
var bodies := {}
var base_heights := {}


func _ready() -> void:
	_build_world()
	_build_options()
	_place_camera()
	if OS.get_cmdline_user_args().has("--shot"):
		_capture_preview.call_deferred()


func _process(delta: float) -> void:
	if is_instance_valid(pressed_body) and not holding:
		hold_elapsed += delta
		if hold_elapsed >= HOLD_DELAY:
			_begin_grab()
	if holding:
		_move_held(mouse_position)
	_step_drops(delta)


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_RIGHT:
			orbiting = event.pressed
			mouse_position = event.position
		elif event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			camera.size = clampf(camera.size * 0.9, 12.0, 28.0)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			camera.size = clampf(camera.size * 1.1, 12.0, 28.0)
		elif event.button_index == MOUSE_BUTTON_LEFT:
			mouse_position = event.position
			if event.pressed:
				pressed_body = _ray_pick(event.position)
				hold_elapsed = 0.0
				holding = false
			elif is_instance_valid(pressed_body):
				if holding: _release_grab()
				pressed_body = null
				get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		mouse_position = event.position
		if orbiting:
			camera_yaw -= event.relative.x * 0.006
			camera_pitch = clampf(camera_pitch + event.relative.y * 0.004, 0.35, 1.3)
			_place_camera()
		elif holding:
			_move_held(event.position)


func _build_world() -> void:
	var world := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_material := ProceduralSkyMaterial.new()
	sky_material.sky_top_color = Color("e7eeea")
	sky_material.sky_horizon_color = Color("f8f4e8")
	sky.sky_material = sky_material
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color("d9e5df")
	environment.ambient_light_energy = 0.8
	world.environment = environment
	add_child(world)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-48, -28, 0)
	light.light_energy = 1.1
	light.shadow_enabled = true
	add_child(light)
	camera = Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 20.0
	add_child(camera)
	var ground := MeshInstance3D.new()
	var ground_box := BoxMesh.new()
	ground_box.size = Vector3(32, 0.5, 13)
	ground.mesh = ground_box
	ground.material_override = Style.matte(Color("aec5c5"))
	ground.position = Vector3(0, -0.25, -8)
	Surface.apply(ground)
	add_child(ground)


func _build_options() -> void:
	for center_x in [-10.5, 0.0, 10.5]:
		var pad := MeshInstance3D.new()
		var box := BoxMesh.new()
		box.size = Vector3(9.0, 0.2, 8.2)
		pad.mesh = box
		pad.material_override = Style.matte(Color("c6d8d4"))
		pad.position = Vector3(center_x, 0.0, -8.0)
		Surface.apply(pad)
		add_child(pad)
	_build_pipeline()
	_build_expression_tree()
	_build_nested_module()
	_build_statement()


func _build_pipeline() -> void:
	var x := -10.5
	var z := -8.0
	_add_block("pipe_input", Vector3(x - 3.0, 0.65, z), Vector3(1.35, 1.3, 1.35), Style.SIGNAL, "input")
	_add_block("pipe_one", Vector3(x - 1.55, 0.4, z - 1.15), Vector3(0.65, 0.8, 0.65), Style.CORE, "one")
	_add_block("pipe_add", Vector3(x, 0.8, z), Vector3(1.8, 1.6, 1.8), Style.LOOP, "add")
	_add_block("pipe_output", Vector3(x + 3.0, 0.65, z), Vector3(1.35, 1.3, 1.35), Style.SUCCESS, "output")
	_add_bar(Vector3(x - 2.0, 0.13, z), Vector3(0.8, 0.16, 0.35), Style.SIGNAL)
	_add_bar(Vector3(x - 1.55, 0.13, z - 0.55), Vector3(0.2, 0.16, 0.85), Style.CORE)
	_add_bar(Vector3(x - 1.2, 0.13, z - 0.15), Vector3(0.7, 0.16, 0.2), Style.CORE)
	_add_bar(Vector3(x + 2.0, 0.13, z), Vector3(0.8, 0.16, 0.35), Style.SUCCESS)
	_add_cross("pipe_add", Vector3(0, 0.95, 0), 0.85, Style.PAPER)
	_add_stud("pipe_one", Vector3(0, 0.48, 0), Style.INK)
	_add_stud("pipe_input", Vector3(0, 0.72, 0), Style.PAPER)
	_add_output_marks("pipe_output")
	_add_number_marker(-13.95, 1)


func _build_expression_tree() -> void:
	var x := 0.0
	var z := -8.0
	_add_block("tree_input", Vector3(x - 2.4, 0.65, z - 1.15), Vector3(1.3, 1.3, 1.3), Style.SIGNAL, "input")
	_add_block("tree_one", Vector3(x + 2.4, 0.4, z - 1.15), Vector3(0.65, 0.8, 0.65), Style.CORE, "one")
	_add_block("tree_add", Vector3(x, 0.8, z + 0.25), Vector3(1.8, 1.6, 1.8), Style.LOOP, "add")
	_add_block("tree_output", Vector3(x, 0.65, z + 2.25), Vector3(1.4, 1.3, 1.4), Style.SUCCESS, "output")
	_add_bar(Vector3(x - 1.1, 0.12, z - 0.35), Vector3(1.4, 0.14, 0.2), Style.SIGNAL)
	_add_bar(Vector3(x + 1.1, 0.12, z - 0.35), Vector3(1.4, 0.14, 0.2), Style.CORE)
	_add_bar(Vector3(x, 0.12, z + 1.45), Vector3(0.2, 0.14, 1.15), Style.SUCCESS)
	_add_cross("tree_add", Vector3(0, 0.95, 0), 0.85, Style.PAPER)
	_add_stud("tree_one", Vector3(0, 0.48, 0), Style.INK)
	_add_stud("tree_input", Vector3(0, 0.72, 0), Style.PAPER)
	_add_output_marks("tree_output")
	_add_number_marker(-1.15, 2)


func _build_nested_module() -> void:
	var x := 10.5
	var z := -8.0
	# Open frame gives the nested function a visible boundary without hiding its contents.
	_add_bar(Vector3(x - 3.65, 0.42, z), Vector3(0.25, 0.65, 5.5), Style.STRUCTURE)
	_add_bar(Vector3(x + 3.65, 0.42, z), Vector3(0.25, 0.65, 5.5), Style.STRUCTURE)
	_add_bar(Vector3(x, 0.42, z - 2.65), Vector3(7.55, 0.65, 0.25), Style.STRUCTURE)
	_add_bar(Vector3(x, 0.42, z + 2.65), Vector3(7.55, 0.65, 0.25), Style.STRUCTURE)
	_add_block("module_input", Vector3(x - 2.35, 0.58, z), Vector3(1.25, 1.15, 1.25), Style.SIGNAL, "input")
	_add_block("module_add", Vector3(x, 0.78, z), Vector3(1.6, 1.55, 1.6), Style.LOOP, "add")
	_add_block("module_one", Vector3(x - 0.7, 0.3, z - 1.2), Vector3(0.55, 0.6, 0.55), Style.CORE, "one")
	_add_block("module_output", Vector3(x + 2.35, 0.58, z), Vector3(1.25, 1.15, 1.25), Style.SUCCESS, "output")
	_add_bar(Vector3(x - 1.25, 0.12, z), Vector3(0.65, 0.14, 0.2), Style.SIGNAL)
	_add_bar(Vector3(x + 1.25, 0.12, z), Vector3(0.65, 0.14, 0.2), Style.SUCCESS)
	_add_cross("module_add", Vector3(0, 0.95, 0), 0.75, Style.PAPER)
	_add_stud("module_one", Vector3(0, 0.36, 0), Style.INK)
	_add_stud("module_input", Vector3(0, 0.64, 0), Style.PAPER)
	_add_output_marks("module_output")
	_add_number_marker(9.35, 3)


func _add_block(id: String, at: Vector3, size: Vector3, color: Color, _role: String) -> void:
	var body := StaticBody3D.new()
	body.name = id
	body.position = at
	body.set_meta("component_id", id)
	var collision := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	collision.shape = shape
	body.add_child(collision)
	_add_box(body, size, Vector3.ZERO, color)
	add_child(body)
	bodies[id] = body
	base_heights[id] = at.y


func _add_box(parent: Node3D, size: Vector3, offset: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	mesh.mesh = box
	mesh.material_override = Style.matte(color)
	mesh.position = offset
	Surface.apply(mesh)
	parent.add_child(mesh)
	return mesh


func _add_bar(at: Vector3, size: Vector3, color: Color) -> void:
	var bar := MeshInstance3D.new()
	var box := BoxMesh.new()
	box.size = size
	bar.mesh = box
	bar.material_override = Style.matte(color)
	bar.position = at
	Surface.apply(bar)
	add_child(bar)


func _add_cross(id: String, at: Vector3, length: float, color: Color) -> void:
	var body: Node3D = bodies[id]
	_add_box(body, Vector3(length, 0.18, 0.2), at, color)
	_add_box(body, Vector3(0.2, 0.18, length), at, color)


func _add_stud(id: String, at: Vector3, color: Color) -> void:
	_add_box(bodies[id], Vector3(0.22, 0.16, 0.22), at, color)


func _add_output_marks(id: String) -> void:
	var body: Node3D = bodies[id]
	for z in [-0.28, 0.0, 0.28]:
		_add_box(body, Vector3(0.18, 0.12, 0.18), Vector3(0, 0.72, z), Style.PAPER)


func _add_number_marker(center_x: float, count: int) -> void:
	var spacing := 0.28
	for i in count:
		_add_box(self, Vector3(0.14, 0.1, 0.14),
			Vector3(center_x + float(i) * spacing, 0.13, -4.3), Style.INK)


func _build_statement() -> void:
	var plaque := MeshInstance3D.new()
	var plaque_box := BoxMesh.new()
	plaque_box.size = Vector3(5.0, 0.12, 0.9)
	plaque.mesh = plaque_box
	plaque.material_override = Style.matte(Style.PAPER)
	plaque.position = Vector3(0, 0.055, -3.5)
	Surface.apply(plaque)
	add_child(plaque)
	var label := Label3D.new()
	label.text = "return A + 1"
	label.font_size = 64
	label.pixel_size = 0.006
	label.modulate = Style.INK
	label.outline_size = 0
	label.rotation.x = -PI / 2.0
	label.position = Vector3(0, 0.12, -3.5)
	add_child(label)


func _ray_pick(screen: Vector2) -> StaticBody3D:
	var origin := camera.project_ray_origin(screen)
	var finish := origin + camera.project_ray_normal(screen) * 200.0
	var query := PhysicsRayQueryParameters3D.create(origin, finish)
	var excluded: Array[RID] = []
	for _i in 64:
		query.exclude = excluded
		var hit := get_world_3d().direct_space_state.intersect_ray(query)
		if hit.is_empty(): return null
		var collider: Object = hit.collider
		if collider.has_meta("component_id"):
			return collider as StaticBody3D
		excluded.append(collider.get_rid())
	return null


func _begin_grab() -> void:
	holding = true
	var held_center: Vector3 = pressed_body.position + Vector3.UP * LIFT
	pressed_body.position = held_center
	var plane := Plane(Vector3.UP, held_center.y)
	var point: Variant = plane.intersects_ray(camera.project_ray_origin(mouse_position), camera.project_ray_normal(mouse_position))
	if point != null: grab_offset = held_center - point


func _move_held(screen: Vector2) -> void:
	if not is_instance_valid(pressed_body): return
	var y: float = float(base_heights[pressed_body.name]) + LIFT
	var plane := Plane(Vector3.UP, y)
	var point: Variant = plane.intersects_ray(camera.project_ray_origin(screen), camera.project_ray_normal(screen))
	if point != null:
		var target: Vector3 = point + grab_offset
		target.y = y
		pressed_body.position = target


func _release_grab() -> void:
	var id := pressed_body.name
	var p := pressed_body.position
	p.x = roundf(p.x / 0.25) * 0.25
	p.z = roundf(p.z / 0.25) * 0.25
	pressed_body.position = p
	drop_velocity[id] = 0.0
	drop_targets[id] = float(base_heights[id])
	_create_ghost(pressed_body)
	pressed_body = null
	holding = false


func _create_ghost(body: StaticBody3D) -> void:
	var id := body.name
	if drop_ghosts.has(id): drop_ghosts[id].queue_free()
	var ghost := MeshInstance3D.new()
	var box := BoxMesh.new()
	var collision := body.get_node("CollisionShape3D") as CollisionShape3D
	box.size = (collision.shape as BoxShape3D).size
	ghost.mesh = box
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	material.wireframe = true
	material.albedo_color = Color("24b9cf", 0.55)
	ghost.material_override = material
	ghost.position = Vector3(body.position.x, float(base_heights[id]), body.position.z)
	add_child(ghost)
	drop_ghosts[id] = ghost


func _step_drops(delta: float) -> void:
	for id in drop_velocity.keys():
		var velocity: float = float(drop_velocity[id]) + GRAVITY * delta
		var body: StaticBody3D = bodies[id]
		var y := body.position.y - velocity * delta
		if y <= float(drop_targets[id]):
			y = float(drop_targets[id])
			drop_velocity.erase(id)
			drop_targets.erase(id)
			if drop_ghosts.has(id): drop_ghosts[id].queue_free(); drop_ghosts.erase(id)
		else: drop_velocity[id] = velocity
		body.position.y = y
	if drop_velocity.is_empty():
		holding = false


func _place_camera() -> void:
	var horizontal := cos(camera_pitch) * camera_distance
	camera.position = camera_focus + Vector3(sin(camera_yaw) * horizontal,
		sin(camera_pitch) * camera_distance, cos(camera_yaw) * horizontal)
	camera.look_at(camera_focus)


func _capture_preview() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	await get_tree().process_frame
	var image := get_viewport().get_texture().get_image()
	var directory := ProjectSettings.globalize_path("res://shots/agent-viz-options")
	DirAccess.make_dir_recursive_absolute(directory)
	image.save_png(directory.path_join("preview.png"))
	print("AGENT VIZ OPTIONS SHOT SAVED ", directory.path_join("preview.png"))
