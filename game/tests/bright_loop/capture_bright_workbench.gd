extends SceneTree

# Windowed evidence entry for the interactive workbench.
# $G --path game --resolution 1600x1000 -s res://tests/bright_loop/capture_bright_workbench.gd -- --capture
const Workbench := preload("res://scripts/interaction/bright_workbench.gd")
const OUTPUT := "res://shots/art-upgrade/bright-loop/"

func _initialize() -> void:
	root.size = Vector2i(1600, 1000)
	root.title = "Bright workbench — interactive specimens"
	if "--capture" in OS.get_cmdline_user_args() and DisplayServer.get_name() == "headless":
		push_error("Window rendering required; headless capture is forbidden.")
		quit(2)
		return
	_run.call_deferred()

func _run() -> void:
	var stage := Workbench.new()
	root.add_child(stage)
	if not "--capture" in OS.get_cmdline_user_args():
		return
	await stage.bake_labels()
	for frame in 14:
		await process_frame
	await RenderingServer.frame_post_draw
	var error := _save("workbench-folded.png")
	if error != OK:
		quit(3)
		return
	# 第二页：26 件都在场景里，但机位按页停，字砖不缩小。
	stage.next_page()
	for frame in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var page_error := _save("workbench-page2.png")
	if page_error != OK:
		quit(17)
		return
	stage.previous_page()
	# Orthographic: apparent size follows `size`, not distance.
	stage.camera.size = 6.5
	for frame in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	error = _save("workbench-label.png")
	if error != OK:
		quit(4)
		return
	stage.camera.snap_preset("iso")
	stage.camera.size = 14.0
	var target: RigidBody3D = stage.items[0]
	stage.hub._queue_tap(stage.camera.unproject_position(target.global_position))
	for frame in 6:
		await physics_frame
	if stage.hub.open_view.open_target() != target:
		push_error("Tap did not open the loop specimen; refusing to save a folded frame as source.")
		quit(5)
		return
	await RenderingServer.frame_post_draw
	error = _save("workbench-source-top.png")
	if error != OK:
		quit(6)
		return
	# Walk the four levels: function -> process -> statement -> real source line.
	_press(stage, KEY_1)
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	error = _save("workbench-unfold-process.png")
	if error != OK:
		quit(7)
		return
	_press(stage, KEY_1)
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	error = _save("workbench-unfold-source.png")
	if error != OK:
		quit(8)
		return
	var scroll := stage.hub.open_view._overlay.get_node_or_null("SourceScroll") as ScrollContainer
	if scroll == null:
		push_error("No source scroll container.")
		quit(9)
		return
	for frame in 4:
		await process_frame
	scroll.scroll_vertical = 100000
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	error = _save("workbench-source-bottom.png")
	if error != OK:
		quit(10)
		return
	# A second object proves the four-level reader is not hardcoded to the loop.
	_press(stage, KEY_ESCAPE)
	var execution: RigidBody3D = null
	for item in stage.items:
		if item.name == "agent_execution_table":
			execution = item
	if execution == null:
		push_error("Execution specimen missing.")
		quit(11)
		return
	stage.camera.snap_preset("iso")
	stage.camera.size = 14.0
	stage.hub._queue_tap(stage.camera.unproject_position(execution.global_position))
	for frame in 6:
		await physics_frame
	if stage.hub.open_view.open_target() != execution:
		push_error("Second specimen did not open.")
		quit(12)
		return
	_press(stage, KEY_1)
	_press(stage, KEY_1)
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	error = _save("workbench-unfold-execution.png")
	if error != OK:
		quit(13)
		return
	# Tab walks every mapped object inside the reader (catalog, no scene change needed).
	_press(stage, KEY_TAB)
	for frame in 4:
		await process_frame
	await RenderingServer.frame_post_draw
	error = _save("workbench-catalog.png")
	if error != OK:
		quit(14)
		return
	# 走到一个尚未实现的设施：它必须写明缺口，而不是假装有源码。
	for i in 40:
		if stage.hub.open_view._label.text.contains("尚未实现"):
			break
		_press(stage, KEY_TAB)
		await process_frame
	if not stage.hub.open_view._label.text.contains("尚未实现"):
		push_error("No unmapped facility reached while walking the catalogue.")
		quit(15)
		return
	await RenderingServer.frame_post_draw
	error = _save("workbench-gap-declared.png")
	print("WORKBENCH CAPTURE: folded + label + four levels + second object + catalog + declared gap; last error ", error)
	stage.queue_free()
	await process_frame
	quit(0 if error == OK else 16)


func _press(stage: Node3D, keycode: int) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	stage.hub.open_view.feed(event)

func _save(name: String) -> Error:
	var image := root.get_texture().get_image()
	if image == null or image.is_empty():
		push_error("Empty window viewport: " + name)
		return ERR_CANT_CREATE
	var error := image.save_png(OUTPUT + name)
	if error == OK:
		print("WINDOW CAPTURE %s: %dx%d" % [name, image.get_width(), image.get_height()])
	return error
