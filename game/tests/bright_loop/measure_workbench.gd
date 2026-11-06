extends SceneTree

const Workbench := preload("res://scripts/interaction/bright_workbench.gd")
var output := "res://shots/art-upgrade/unified-20260918/before"
var seconds := 60.0
var baseline := false

func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg == "--baseline": baseline = true
		if arg.begins_with("--out="): output = arg.substr(6)
		if arg.begins_with("--seconds="): seconds = float(arg.substr(10))
	if DisplayServer.get_name() == "headless":
		quit(2)
		return
	root.size = Vector2i(1920, 1080)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	run.call_deferred()

func run() -> void:
	root.size = Vector2i(1920, 1080)
	var started := Time.get_ticks_msec()
	var stage = load("res://shots/art-upgrade/unified-20260918/source-before/game/scripts/interaction/bright_workbench.gd").new() if baseline else Workbench.new()
	root.add_child(stage)
	await stage.bake_labels()
	var load_ms := Time.get_ticks_msec() - started
	for i in 120: await process_frame
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	root.get_texture().get_image().save_png(output + ".png")
	if root.get_texture().get_width() != 1920 or root.get_texture().get_height() != 1080:
		push_error("Expected real 1920 x 1080 framebuffer")
		quit(3)
		return
	var result := {"adapter": RenderingServer.get_video_adapter_name(), "resolution": [root.get_texture().get_width(),root.get_texture().get_height()], "geometry_baseline": baseline,
		"backend": RenderingServer.get_current_rendering_method(), "vsync": "disabled",
		"load_ms": load_ms, "seconds_per_mode": seconds, "modes": {},
		"engine_max_fps": Engine.max_fps, "msaa_3d": root.msaa_3d, "screen_space_aa": root.screen_space_aa}
	var framing: Dictionary = stage.camera.current_pose()
	var home: Vector3 = stage.items[0].global_position
	for mode in ["idle", "orbit", "drag"]:
		stage.camera.snap_pose(framing.yaw, framing.pitch, framing.distance)
		stage._show_page(0)
		var values: Array[float] = []
		var began := Time.get_ticks_usec()
		var last := began
		if mode == "drag":
			stage.hub.predictor.clear_statics()
			stage.hub.predictor.capture_statics_from(stage, home, 24, stage.items[0])
			stage.hub.drag.begin_drag(stage.items[0], "probe", home)
		while float(Time.get_ticks_usec() - began) / 1e6 < seconds:
			if mode == "orbit": stage.camera.orbit(0.002, 0.0)
			if mode == "drag":
				stage.hub.drag.update_hand(home + Vector3(0.75 * sin(Time.get_ticks_msec() * 0.001), 1, 0.5), Time.get_ticks_msec())
			await process_frame
			var now := Time.get_ticks_usec()
			values.append((now - last) / 1000.0)
			last = now
		values.sort()
		result.modes[mode] = {"frames": values.size(), "median_ms": values[values.size()/2],
			"p95_ms": values[int(values.size()*0.95)],
			"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
			"primitives": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
			"video_memory": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED)}
		print("MEASURE ", mode, " ", result.modes[mode])
	FileAccess.open(output + ".json", FileAccess.WRITE).store_string(JSON.stringify(result, "\t"))
	stage.free()
	await process_frame
	quit()
