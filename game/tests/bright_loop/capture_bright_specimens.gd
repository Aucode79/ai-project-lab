extends SceneTree

# Windowed reproducible entry. No tscn/main-scene/asset-registry changes.
# $G --path game --resolution 1600x1000 -s res://tests/bright_loop/capture_bright_specimens.gd
# Captures loop first, then all four overview/top/mono and each remaining close view.
const Specimens := preload("res://tests/bright_loop/bright_specimens.gd")
const OUTPUT := "res://shots/art-upgrade/bright-loop/"
const VIEWS := ["loop", "overview", "top", "mono", "memory", "model", "execution"]
var stage: Node3D

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("Window rendering required; headless capture is forbidden.")
		quit(2)
		return
	root.title = "Bright function-color specimens — isolated study"
	root.size = Vector2i(1600, 1000)
	root.msaa_3d = Viewport.MSAA_4X
	capture_views.call_deferred()

func capture_views() -> void:
	var error := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUTPUT))
	if error != OK:
		push_error("Cannot create output directory: %s" % error)
		quit(3)
		return
	for view in VIEWS:
		if is_instance_valid(stage):
			stage.free()
		build_stage(view)
		# Real window render pipeline, allow shadows/materials to settle.
		for frame in 12:
			await process_frame
		await RenderingServer.frame_post_draw
		var image := root.get_texture().get_image()
		if image == null or image.is_empty():
			push_error("Empty window viewport: " + view)
			quit(4)
			return
		error = image.save_png(OUTPUT + view + ".png")
		if error != OK:
			push_error("PNG save failed: %s" % error)
			quit(5)
			return
		print("WINDOW CAPTURE %s: %dx%d -> %s%s.png" % [view, image.get_width(), image.get_height(), OUTPUT, view])
	stage.free()
	quit(0)

func build_stage(view: String) -> void:
	stage = Node3D.new()
	root.add_child(stage)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color("eeede7")
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = 0.52
	environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	environment.glow_enabled = false
	environment.fog_enabled = false
	var world := WorldEnvironment.new()
	world.environment = environment
	stage.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.name = "WhiteDirectionalKey"
	sun.rotation_degrees = Vector3(-48, -35, 0)
	sun.light_color = Color.WHITE
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	sun.shadow_bias = 0.015
	sun.shadow_normal_bias = 0.35
	sun.directional_shadow_max_distance = 35
	stage.add_child(sun)
	var ground := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(200, 200)
	ground.mesh = plane
	ground.position.y = -0.015
	var ground_material := StandardMaterial3D.new()
	ground_material.albedo_color = Color("deddd6")
	ground_material.roughness = 1.0
	ground.material_override = ground_material
	stage.add_child(ground)
	var overview := view in ["overview", "top", "mono"]
	var index := 0
	if not overview:
		for i in Specimens.MACHINES.size():
			if Specimens.MACHINES[i].id == view:
				index = i
	var slots: Array = Specimens.original_indices() if overview else [index]
	for slot in slots.size():
		var machine_index: int = slots[slot]
		var machine := Specimens.build_machine(machine_index, view == "mono")
		if overview:
			machine.position = Vector3((slot % 2) * 4.0, 0, (slot / 2) * 4.0)
		stage.add_child(machine)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 9.4 if overview else 3.65
	camera.near = 0.05
	camera.far = 100
	stage.add_child(camera)
	var target := Vector3(3.2, 0.45, 3.0) if overview else Vector3(1.1, 0.45, 1.0)
	camera.position = target + (Vector3(6, 10, 12) if overview else Vector3(3.4, 4.5, 5.4))
	if view == "loop":
		camera.size = 3.25
	if view == "top":
		camera.size = 8.5
		camera.position = target + Vector3(0, 16, 0)
		camera.look_at(target, Vector3.FORWARD)
	else:
		camera.look_at(target, Vector3.UP)
	camera.current = true
