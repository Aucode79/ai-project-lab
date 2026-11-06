extends SceneTree
const Drag := preload("res://scripts/interaction/drag_controller.gd")
const Sandbox := preload("res://scenes/sandbox/sandbox.tscn")
const Predictor := preload("res://scripts/interaction/ghost_predictor.gd")
var passed := 0
var failed := 0

func _initialize() -> void:
	_run.call_deferred()

func check(ok: bool, label: String) -> void:
	if ok:
		passed += 1
		print("PASS: " + label)
	else:
		failed += 1
		print("FAIL: " + label)

func on_grid(v: Vector3) -> bool:
	return v.distance_to(v.snapped(Vector3.ONE * 0.25)) < 0.0001

func items_ok(items: Array, minimum: int) -> bool:
	return items.size() >= minimum

func _run() -> void:
	# 真落下，盒体中心允许 .125；CollisionShape 的本地偏心必须计入。
	for x in [1.19, -1.19]:
		var scene := Node3D.new()
		root.add_child(scene)
		var floor_body := StaticBody3D.new()
		var floor_shape := CollisionShape3D.new()
		var floor_box := BoxShape3D.new()
		floor_box.size = Vector3(20, 1, 20)
		floor_shape.shape = floor_box
		floor_body.add_child(floor_shape)
		floor_body.position.y = -0.5
		scene.add_child(floor_body)
		var body := RigidBody3D.new()
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(0.75, 0.5, 0.25)
		shape.shape = box
		shape.position = Vector3(0.125, 0.25, -0.125)
		body.add_child(shape)
		body.position = Vector3(x, 2, x)
		scene.add_child(body)
		var drag := Drag.new()
		var predictor := Predictor.new()
		scene.add_child(predictor)
		scene.add_child(drag)
		drag.attach_predictor(predictor)
		# 预测空间也要有地板（与 T2 同一套物理前推口径），预测才是可信落点。
		predictor.add_static_box(Vector3(20, 1, 20),
			Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))
		await physics_frame
		drag.begin_drag(body, "test", body.position)
		# 真实预测：同一套物理前推的落点（不注入；可能未停稳，预览非权威）。
		for i in 400:
			await physics_frame
			if str(drag.ghost_visual_state()["phase"]) == "ready":
				break
		check(str(drag.ghost_visual_state()["phase"]) == "ready", "ghost prediction arrived")
		# 只验证：虚影画在量化后的锚点姿态上；预览与真实落点在同一容差内
		#（预测是近似，最终落定才是权威；容差沿 T2 虚影对账口径 0.35 m）。
		var ghost_pos: Vector3 = drag.ghost_visual_state()["position"]
		check(ghost_pos.distance_to(drag._ghost_pose.origin) < 0.0001, "preview shows quantized anchor")
		drag.release()
		check(not body.freeze, "release retains physical fall")
		for i in 600:
			await physics_frame
			if drag.state() == Drag.DragState.IDLE:
				break
		var center := body.global_transform * shape.position
		check(body.freeze and on_grid(center - box.size * 0.5) and on_grid(center + box.size * 0.5),
			"signed drop box six faces on q=.25 x=%s actual=%s" % [x, center])
		check(absf(fmod(absf(center.z), 0.25) - 0.125) < 0.0001, "legal .125 center survives")
		check((body.global_position - ghost_pos).length() < 0.35, "preview within physics tolerance of final")
		check(box.size == Vector3(0.75, 0.5, 0.25), "size unchanged")
		scene.queue_free()
		await physics_frame
	# 无效归位不得调用 reporter 或发成功 settled；恢复拖前姿态。
	var scene := Node3D.new()
	root.add_child(scene)
	var body := RigidBody3D.new()
	var cs := CollisionShape3D.new()
	cs.shape = BoxShape3D.new()
	body.add_child(cs)
	body.freeze = true
	scene.add_child(body)
	var drag := Drag.new()
	scene.add_child(drag)
	await physics_frame
	var before := body.transform
	drag.validator = func(_xf: Transform3D) -> bool: return false
	drag.begin_drag(body, "invalid", Vector3.ZERO)
	body.position = Vector3(3.12, 2.2, -4.13)
	drag._finish_drop()
	check(body.transform == before and drag.land_report_count() == 0, "invalid snap rolls back without report")
	scene.queue_free()
	await physics_frame
	# 真实 gameplay 路径：沙盒生成台的小件拖回甲板空地，终态要么归位、要么回滚。
	var sb: Node3D = Sandbox.instantiate()
	root.add_child(sb)
	for i in 8:
		await create_timer(0.03).timeout
	await physics_frame
	var items: Array = sb.get_bench_items().filter(
		func(b): return str(b.get_meta("asset_id")).begins_with("base_"))
	check(items_ok(items, 1), "sandbox bench items available")
	var events := {"rejected": 0, "reported": 0}
	for item in items:
		var home: Transform3D = item.global_transform
		var drag2 := Drag.new()
		var predictor2 := Predictor.new()
		sb.add_child(predictor2)
		sb.add_child(drag2)
		drag2.attach_predictor(predictor2)
		predictor2.capture_statics_from(sb, Vector3(5.0, 24.0, 6.0), 24.0)
		drag2.landed_reporter = func(_eid, _cell) -> void: events["reported"] += 1
		drag2.drop_rejected.connect(func(_eid, _reason) -> void: events["rejected"] += 1)
		await physics_frame
		drag2.begin_drag(item, str(item.get_meta("entity_id")), Vector3(5.0, 23.3, 6.0))
		drag2.update_hand(Vector3(5.0, 23.3, 6.0), float(Time.get_ticks_msec()))
		drag2.release()
		for i in 600:
			await physics_frame
			if drag2.state() == Drag.DragState.IDLE:
				break
		var fell_back: bool = item.global_transform.origin.distance_to(home.origin) < 0.0001
		var on_deck: bool = item.global_position.y >= 23.0 - 0.001 and item.global_position.y <= 23.6
		var done: bool = drag2.land_report_count() <= 1 and item.freeze
		check(done and on_deck and ((events["reported"] > 0) == (fell_back == false)) \
			and (fell_back == (events["rejected"] > 0)),
			"sandbox %s ends legal: %s" % [str(item.get_meta("asset_id")),
			"snapped on deck" if not fell_back else "rolled back"])
		drag2.queue_free()
		predictor2.queue_free()
		events = {"rejected": 0, "reported": 0}
	sb.queue_free()
	await physics_frame
	print("TOTAL: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
