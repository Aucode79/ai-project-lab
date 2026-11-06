extends SceneTree

# 真实沙盒里的目录取证（窗口运行；headless 出不了图）。
# $G --path game scenes/sandbox/sandbox.tscn --resolution 1600x1000 -s res://tests/sandbox/capture_sandbox_catalog.gd -- --capture
const Sandbox := preload("res://scenes/sandbox/sandbox.tscn")
const OUTPUT := "res://shots/art-upgrade/bright-loop/"


func _initialize() -> void:
	root.size = Vector2i(1600, 1000)
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() == "headless":
		push_error("Window rendering required; headless capture is forbidden.")
		quit(2)
		return
	_run.call_deferred()


func _run() -> void:
	var sb: Node3D = Sandbox.instantiate()
	root.add_child(sb)
	if not "--capture" in OS.get_cmdline_user_args():
		return
	for i in 20:
		await create_timer(0.05).timeout
	var key := InputEventKey.new()
	key.keycode = sb.CATALOG_KEY
	key.pressed = true
	sb._unhandled_input(key)
	for frame in 6:
		await process_frame
	var view = sb._hub.open_view
	if not view.is_open() or not view._label.text.contains("第 1 层"):
		push_error("Catalog did not open in the sandbox.")
		quit(3)
		return
	await RenderingServer.frame_post_draw
	var error := _save("sandbox-catalog-level1.png")
	for i in 2:
		view.feed(_key(KEY_1))
		for frame in 3:
			await process_frame
	await RenderingServer.frame_post_draw
	error = _save("sandbox-catalog-source.png")
	print("SANDBOX CATALOG CAPTURE: level1 + source; last error ", error)
	sb.queue_free()
	await process_frame
	quit(0 if error == OK else 4)


func _key(keycode: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event


func _save(name: String) -> Error:
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Empty window viewport: " + name)
		return ERR_CANT_CREATE
	var error := image.save_png(OUTPUT + name)
	if error == OK:
		print("WINDOW CAPTURE %s: %dx%d" % [name, image.get_width(), image.get_height()])
	return error
