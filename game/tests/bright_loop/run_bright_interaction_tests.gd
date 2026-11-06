extends SceneTree

const STAGE := "res://scripts/interaction/bright_workbench.gd"
var passed := 0
var failed := 0

func _initialize() -> void:
	root.size = Vector2i(1600, 1000)
	_run.call_deferred()

func check(ok: bool, message: String) -> void:
	if ok:
		passed += 1
		print("PASS: " + message)
	else:
		failed += 1
		print("FAIL: " + message)


## 走真实按键事件（经 OpenController → key_provider），不是直接调内部函数。
func _press(hub, keycode: int) -> bool:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	hub.open_view.feed(event)
	return true


## 当前阅读对象：取首行「功能：」之后的对象名（首行前缀对所有对象都相同）。
func _current_reader_object(hub) -> String:
	var text: String = hub.open_view._label.text
	var first := text.split("\n")[0]
	var marker := "功能："
	var at := first.find(marker)
	return first.substr(at + marker.length()) if at >= 0 else first

func _run() -> void:
	check(FileAccess.file_exists(STAGE), "interactive workbench exists")
	if not FileAccess.file_exists(STAGE):
		finish()
		return
	var script = load(STAGE)
	var stage = script.new()
	root.add_child(stage)
	for i in 4:
		await physics_frame
	check(stage.items.size() == 26, "all 26 specimens exist in the workbench scene")
	check(stage.labels.size() == 26, "all 26 ground text tiles attached")
	var meta = load("res://tests/bright_loop/bright_specimens.gd")
	for label in stage.labels:
		check(label.get_child_count() == 1 and (label.get_child(0) as MeshInstance3D).mesh is QuadMesh, "ground label is a flat 6x3 text tile")
		check(not meta.scene_has_label3d(label), "ground label adds no floating Label3D")
	var body: RigidBody3D = stage.items[0]
	var home := body.global_transform
	var hub = stage.hub
	var screen: Vector2 = stage.camera.unproject_position(body.global_position)
	hub._queue_tap(screen)
	await physics_frame
	await physics_frame
	check(hub.open_view.open_target() == body, "screen ray tap opens loop specimen")
	var level1_text: String = hub.open_view._label.text
	check(level1_text.contains("第 1 层") and level1_text.contains("跑圈台"), "reader opens at level 1 function")
	check(level1_text.contains("agents.py"), "level 1 names the real external source file")
	# Drill down through the four levels with real keys.
	check(_press(hub, KEY_1), "digit selects first process")
	var process_text: String = hub.open_view._label.text
	check(process_text.contains("第 2 层") and process_text.contains("第 3 层"), "level 2 expands into level 3 statements")
	check(process_text.contains("agents.py:468"), "statements carry real file:line anchors")
	check(_press(hub, KEY_1), "digit selects first statement")
	var source_text: String = hub.open_view._label.text
	check(source_text.contains("第 4 层"), "level 4 shows the real source window")
	check(source_text.contains("max_steps = max_steps or self.max_steps"), "level 4 shows the exact real source line")
	check(source_text.contains("▶") and source_text.contains("反向定位"), "target line is marked and reverse-located")
	check(_press(hub, KEY_B) and _press(hub, KEY_B), "B walks back up the levels")
	check(hub.open_view._label.text.contains("第 1 层"), "back at level 1 after two B presses")
	var scroll := hub.open_view._overlay.get_node_or_null("SourceScroll") as ScrollContainer
	check(scroll != null, "source has scroll container for every actual line")
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	hub.open_view.feed(wheel)
	check(hub.open_view.is_open(), "scroll wheel does not close source view")
	if scroll != null:
		for i in 4:
			await process_frame
		wheel.position = scroll.get_global_rect().get_center()
		wheel.global_position = wheel.position
		var motion := InputEventMouseMotion.new()
		motion.position = wheel.position
		motion.global_position = wheel.position
		root.notify_mouse_entered()
		root.push_input(motion, true)
		var before_scroll := scroll.scroll_vertical
		root.push_input(wheel, true)
		await process_frame
		check(hub.open_view.is_open() and scroll.scroll_vertical > before_scroll, "viewport wheel input scrolls without closing source")
		scroll.scroll_vertical = 100000
		await process_frame
		var content: Label = hub.open_view._label
		check(scroll.scroll_vertical > 0, "source scroll reaches beyond first page")
		check(content.get_global_rect().end.y <= scroll.get_global_rect().end.y + 2.0, "last actual source line can enter viewport")
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	hub.open_view.feed(escape)
	check(not hub.open_view.is_open(), "Escape returns to workbench")
	# Every specimen reaches its own layer 4 — real source (external .py or in-repo .gd)
	# or an explicitly declared gap. Pages are switched so the item is in frame first.
	for slot in stage.items.size():
		stage._show_page(slot / (stage.COLUMNS * stage.ROWS_PER_PAGE))
		await physics_frame
		var item: RigidBody3D = stage.items[slot]
		var item_screen: Vector2 = stage.camera.unproject_position(item.global_position + Vector3(0, 0.3, 0))
		hub._queue_tap(item_screen)
		await physics_frame
		await physics_frame
		check(hub.open_view.open_target() == item, "tap opens %s" % item.name)
		var opened: String = hub.open_view._label.text
		check(opened.contains("第 1 层"), "%s opens at level 1" % item.name)
		var has_source := opened.contains(".py 第 ") or opened.contains(".gd 第 ")
		check(has_source or opened.contains("尚未实现"), "%s names a real source span or declares the gap" % item.name)
		_press(hub, KEY_1)
		var expanded: String = hub.open_view._label.text
		var has_lines := expanded.contains(".py:") or expanded.contains(".gd:") or expanded.contains("（未实现）")
		check(expanded.contains("第 3 层") and has_lines, "%s expands to statements with file:line or a gap" % item.name)
		if has_source:
			_press(hub, KEY_1)
			check(hub.open_view._label.text.contains("第 4 层"), "%s reaches a real source line" % item.name)
	stage._show_page(0)
	await physics_frame
	var escape2 := InputEventKey.new()
	escape2.keycode = KEY_ESCAPE
	escape2.pressed = true
	hub.open_view.feed(escape2)
	check(not hub.open_view.is_open(), "reader closed before drag checks")
	# Reader doubles as a catalog: Tab walks every mapped object, always at level 1.
	hub._queue_tap(screen)
	await physics_frame
	await physics_frame
	var mapped: Array = load("res://scripts/interaction/unfolding_map.gd").objects()
	var seen := {}
	for i in mapped.size():
		_press(hub, KEY_TAB)
		var text: String = hub.open_view._label.text
		seen[_current_reader_object(hub)] = true
		check(text.contains("第 1 层"), "Tab target %d opens at level 1" % i)
		# 有实现的件给出真实文件与行段；没实现的件必须写明「尚未实现」，不能假装有源码。
		check(text.contains("第 " ) and (text.contains(".py 第 ") or text.contains(".gd 第 ") or text.contains("尚未实现")), "Tab target %d names a real source span or declares the gap" % i)
	check(seen.size() == mapped.size(), "Tab reaches all %d mapped objects (got %d)" % [mapped.size(), seen.size()])
	_press(hub, KEY_ESCAPE)
	check(not hub.open_view.is_open(), "reader closed after catalog walk")
	hub._queue_drag_start(screen)
	await physics_frame
	await physics_frame
	check(hub.drag.state() == hub.drag.DragState.LIFTING, "screen ray starts drag through hub")
	check(hub.predictor.prediction_in_flight(), "drag starts real ghost prediction")
	# Move to clear floor, then stop the hand before release (no throw impulse).
	var target := home.origin + Vector3(-3.13, 1.0, 0.12)
	for i in 90:
		hub.drag.update_hand(target, float(Time.get_ticks_msec()))
		await physics_frame
	hub._on_drag_drop(screen)
	check(not body.freeze, "release hands body to physics")
	for i in 600:
		await physics_frame
		if hub.drag.state() == hub.drag.DragState.IDLE:
			break
	check(hub.drag.land_report_count() == 1, "real relocation accepted, not merely rolled back")
	check(body.global_position.distance_to(home.origin) > 2.0 and body.freeze, "specimen relocated and frozen")
	var bounds: AABB = body.global_transform * hub.drag._bounds
	check(bounds.position.distance_to(bounds.position.snapped(Vector3.ONE * 0.25)) < 0.0001 and bounds.end.distance_to(bounds.end.snapped(Vector3.ONE * 0.25)) < 0.0001, "relocated six outer faces on q grid")
	var accepted := body.global_transform
	# Rejection exercises the same commit path and must not produce a second success.
	hub.drag.validator = func(_pose: Transform3D) -> bool: return false
	hub.drag.begin_drag(body, "loop", body.global_position)
	body.position += Vector3(1.12, 0.31, 0.12)
	hub.drag._finish_drop()
	check(body.global_transform == accepted and hub.drag.land_report_count() == 1, "invalid placement restores accepted pose without success report")
	# Real input updates velocity only on mouse motion; a pause before release must not throw.
	hub.drag.validator = Callable()
	hub.drag.begin_drag(body, "loop", body.global_position)
	hub.drag.update_hand(body.global_position + Vector3(2.4, 0.4, 0.0), float(Time.get_ticks_msec()))
	hub.drag._last_hand_ms = float(Time.get_ticks_msec()) - 600.0
	hub.drag.release()
	check(body.linear_velocity.length() < 0.001, "paused hand does not release with stale throw velocity")
	for i in 600:
		await physics_frame
		if hub.drag.state() == hub.drag.DragState.IDLE:
			break
	check(hub.drag.state() == hub.drag.DragState.IDLE and body.global_position.y > -1.0, "paused release settles on stage instead of flying off")
	stage.queue_free()
	await process_frame
	finish()

func finish() -> void:
	print("BRIGHT INTERACTION TOTAL: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
