extends Node3D

## Opens the actual imported program graph without the editing UI for art review.
const MachineView := preload("res://scripts/lessons/machine_view.gd")
const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
var output_path := "res://shots/agent-lab/art-preview.png"

func _ready() -> void:
	var program_path := "res://agent-lab/program.json"
	var requested_module := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--program="): program_path = argument.trim_prefix("--program=")
		if argument.begins_with("--module="): requested_module = argument.trim_prefix("--module=")
		if argument.begins_with("--out="): output_path = argument.trim_prefix("--out=")
	var program: Variant = JSON.parse_string(FileAccess.get_file_as_string(program_path))
	if not program is Dictionary:
		push_error("Agent Lab program.json is not a dictionary")
		return
	_add_environment()
	var root := Node3D.new()
	root.name = "ProgramFactory"
	add_child(root)
	var entry := requested_module if requested_module != "" else str(program.get("entry", ""))
	var view: Dictionary = MachineView.build(root, program, entry, false, false,
		true)
	_fit_stage(program, entry, view)
	if OS.get_cmdline_user_args().has("--shot"):
		_capture.call_deferred()

func _add_environment() -> void:
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

func _fit_stage(program: Dictionary, entry: String, view: Dictionary) -> void:
	var module: Dictionary = program.get("modules", {}).get(entry, {})
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for node in module.get("nodes", []):
		var pos: Vector3 = view.positions.get(str(node.id), Vector3.ZERO)
		var ext := MachineView.extents(node)
		min_x = minf(min_x, pos.x - ext.x / 2.0)
		max_x = maxf(max_x, pos.x + ext.x / 2.0)
		min_z = minf(min_z, pos.z - ext.z / 2.0)
		max_z = maxf(max_z, pos.z + ext.z / 2.0)
	var center := Vector3((min_x + max_x) / 2.0, 0.0, (min_z + max_z) / 2.0)
	var width := maxf(5.5, max_x - min_x + 1.5)
	var depth := maxf(4.0, max_z - min_z + 1.5)
	var ground := MeshInstance3D.new()
	ground.mesh = Surface.mesh(Vector3(width, 0.5, depth))
	ground.material_override = Style.matte(Color("aec5c5"))
	ground.position = Vector3(center.x, -0.25, center.z)
	add_child(ground)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	var framing := maxf(depth * 1.6, width / 1.4)
	camera.size = framing
	var camera_position := center + Vector3(framing * 0.55, framing * 0.85, framing * 0.9)
	camera.look_at_from_position(camera_position, center)
	add_child(camera)

func _capture() -> void:
	await get_tree().process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output_path.get_base_dir()))
	get_viewport().get_texture().get_image().save_png(output_path)
	print("AGENT LAB ART PREVIEW SAVED ", ProjectSettings.globalize_path(output_path))
	get_tree().quit()
