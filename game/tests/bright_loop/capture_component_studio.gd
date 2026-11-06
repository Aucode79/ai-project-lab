extends SceneTree

const Studio := preload("res://scripts/interaction/bright_workbench.gd")
const OUT := "res://shots/art-upgrade/unified-20260918/"

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		quit(2)
		return
	run.call_deferred()

func shot(name: String) -> void:
	for i in 8: await process_frame
	await RenderingServer.frame_post_draw
	var error := root.get_texture().get_image().save_png(OUT + name + ".png")
	if error != OK:
		push_error("Cannot save " + name)
		quit(3)
	print("CAPTURE ", name)

func run() -> void:
	root.size = Vector2i(1920, 1080)
	var stage := Studio.new()
	root.add_child(stage)
	await stage.bake_labels()
	for page in stage.page_count:
		stage._show_page(page)
		await shot("studio-page-%02d" % (page + 1))
	stage._show_page(0)
	stage.camera.snap_pose(0, 1.52, 32)
	stage._show_page(0)
	await shot("studio-top")
	stage.camera.snap_pose(0, 0.96, 32)
	stage._show_page(0)
	var body := stage.items[0]
	stage.hub.open_view.open(body)
	await shot("reader-function")
	stage.hub.open_view._choices.get_child(0).pressed.emit()
	await shot("reader-process")
	stage.hub.open_view._choices.get_child(0).pressed.emit()
	await shot("reader-source")
	stage.hub.open_view.close()
	stage.hub.predictor.clear_statics()
	stage.hub.predictor.capture_statics_from(stage, body.global_position, 24, body)
	stage.hub.drag.begin_drag(body, str(body.name), body.global_position + Vector3(-2, 0.5, 0))
	for i in 150: await physics_frame
	await shot("drag-predicted")
	stage.hub.drag.cancel_drag()
	await process_frame
	root.size = Vector2i(1280, 720)
	stage._show_page(0)
	await shot("studio-720")
	for child in stage.get_children():
		if child.has_method("show_menu"):
			child.show_menu()
			break
	await shot("scene-menu-720")
	stage.free()
	await process_frame
	quit()
