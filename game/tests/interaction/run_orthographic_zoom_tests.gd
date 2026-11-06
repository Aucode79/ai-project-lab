extends SceneTree
const Camera := preload("res://scripts/interaction/orbit_camera.gd")

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var camera := Camera.new()
	root.add_child(camera)
	camera.set_process_unhandled_input(false)
	camera.snap_preset("iso")
	var before := camera.size
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	camera.feed(wheel)
	var ok := camera.size < before and is_equal_approx(camera.size, before * 0.88)
	print("ORTHOGRAPHIC WHEEL: before=%s after=%s %s" % [before, camera.size, "PASS" if ok else "FAIL"])
	camera.free()
	quit(0 if ok else 1)
