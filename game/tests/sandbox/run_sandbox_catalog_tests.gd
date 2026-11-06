extends SceneTree

# 沙盒接入契约：K 打开组件目录，四层展开到真实源码；普通物件点开仍是资产描述。
const Sandbox := preload("res://scenes/sandbox/sandbox.tscn")
const Map := preload("res://scripts/interaction/unfolding_map.gd")
var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func check(ok: bool, message: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: " + message)


func press(sandbox: Node, keycode: int) -> void:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	sandbox._unhandled_input(event)


func _run() -> void:
	var sb: Node3D = Sandbox.instantiate()
	root.add_child(sb)
	for i in 8:
		await create_timer(0.03).timeout
	var view = sb._hub.open_view
	check(not view.is_open(), "sandbox starts with no open view")
	# K 打开目录
	press(sb, sb.CATALOG_KEY)
	check(view.is_open(), "catalog key opens the reader in the real sandbox")
	var level1: String = view._label.text
	var first_id := String(Map.objects()[0])
	check(level1.contains("第 1 层"), "catalog reader opens at level 1")
	check(level1.contains(".py 第 ") or level1.contains(".gd 第 "), "level 1 names a real source span")
	# 逐层展开
	view.feed(_key(KEY_1))
	check(view._label.text.contains("第 3 层"), "digit expands into statements")
	view.feed(_key(KEY_1))
	check(view._label.text.contains("第 4 层") and view._label.text.contains("反向定位"), "reader reaches a real source line with reverse lookup")
	# Tab 换对象
	view.feed(_key(KEY_B))
	view.feed(_key(KEY_B))
	var before: String = view._label.text
	view.feed(_key(KEY_TAB))
	check(view._label.text != before and view._label.text.contains("第 1 层"), "Tab switches to another catalog object")
	# Esc 关闭并退出目录模式
	view.feed(_key(KEY_ESCAPE))
	check(not view.is_open() and not sb._catalog.active, "Escape closes the catalog and leaves catalog mode")
	# 回归：普通物件点开仍是资产描述，不会被目录接管
	var body: Node3D = null
	for node in sb.find_children("*", "RigidBody3D", true, false):
		if node.has_meta("asset_id"):
			body = node
			break
	check(body != null, "sandbox still has pickable asset bodies")
	if body != null:
		var described: String = sb._describe_target(body)
		check(not described.contains("第 1 层"), "ordinary asset open is not hijacked by the catalog reader")
		check(described.length() > 0, "ordinary asset still returns its description")
	check(first_id != "", "catalog has objects to browse")
	sb.queue_free()
	await process_frame
	print("SANDBOX CATALOG TOTAL: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)


func _key(keycode: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.pressed = true
	return event
