extends SceneTree
# 诊断探针（非测试套件：文件名不带 run_ 前缀，run_tests.sh 不会收）。
# 回答：真实生成台部件落到甲板新位置，_placement_valid 三个子检查各自怎么说。
const Drag := preload("res://scripts/interaction/drag_controller.gd")
const Sandbox := preload("res://scenes/sandbox/sandbox.tscn")
const Q := 0.25
const EPS := 0.0001

func _initialize() -> void:
	_run.call_deferred()

func _union(boxes: Array) -> AABB:
	var out := AABB()
	for i in boxes.size():
		out = boxes[i] if i == 0 else out.merge(boxes[i])
	return out

func _collect(node: Node, xf: Transform3D, boxes: Array) -> void:
	if node is MeshInstance3D and node.mesh != null:
		boxes.append(xf * node.get_aabb())
	for c in node.get_children():
		if c is Node3D:
			_collect(c, xf * c.transform, boxes)

func _hits(sb: Node3D, item: RigidBody3D, pose: Transform3D, bounds: AABB) -> Array:
	var shape := BoxShape3D.new()
	shape.size = bounds.size - Vector3.ONE * EPS * 2.0
	if shape.size.x <= 0 or shape.size.y <= 0 or shape.size.z <= 0:
		return [{"error": "degenerate"}]
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = pose * Transform3D(Basis.IDENTITY, bounds.get_center())
	query.collision_mask = item.collision_mask
	var excluded: Array[RID] = []
	var stack: Array[Node] = [item]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is CollisionObject3D:
			excluded.append(node.get_rid())
		stack.append_array(node.get_children())
	query.exclude = excluded
	var raw: Array = sb.get_world_3d().direct_space_state.intersect_shape(query, 8)
	var names: Array = []
	for h in raw:
		var col: Object = h.get("collider")
		var n := "?"
		if col is Node:
			names.append("%s/%s" % [str((col as Node).get_parent().name), str((col as Node).name)])
	names.sort()
	return names

func _six_ok(pose: Transform3D, boxes: Array) -> bool:
	for b in boxes:
		var e: AABB = pose * b
		for c in [e.position, e.end]:
			if c.distance_to(c.snapped(Vector3.ONE * Q)) > EPS:
				return false
	return true

func _probe(sb: Node3D, item: RigidBody3D, tag: String, rest_origin: Vector3, rest_basis: Basis, upright_start: bool) -> void:
	var home: Transform3D = item.global_transform
	var drag := Drag.new()
	sb.add_child(drag)
	await physics_frame
	if upright_start:
		drag.begin_drag(item, "probe", home.origin)
		item.global_transform = Transform3D(rest_basis, rest_origin)
	else:
		item.global_transform = Transform3D(rest_basis, rest_origin)
		drag.begin_drag(item, "probe", rest_origin)
	var boxes: Array = []
	_collect(item, Transform3D.IDENTITY, boxes)
	var bounds := _union(boxes)
	var pose := Transform3D(home.basis, rest_origin)
	var extent: AABB = pose * bounds
	pose.origin += extent.position.snapped(Vector3.ONE * Q) - extent.position
	# 直接问生产谓词：candidate 六面落格 + 重叠查询会不会放行
	var ok := drag._placement_valid(pose)
	print("[%s %s] placement_valid=%s six_face=%s snap_origin=%s hits=%s" % [
		tag, str(rest_origin),
		"ACCEPT" if ok else "REJECT",
		"ok" if _six_ok(pose, boxes) else "BAD",
		str(pose.origin),
		str(_hits(sb, item, pose, bounds))])
	drag.queue_free()
	item.global_transform = home
	await physics_frame

func _run() -> void:
	var sb: Node3D = Sandbox.instantiate()
	root.add_child(sb)
	for i in 8:
		await create_timer(0.03).timeout
	await physics_frame
	var items: Array = sb.get_bench_items().filter(
		func(b): return str(b.get_meta("asset_id")) == "base_block")
	var item: RigidBody3D = items[0]
	var tilt := Basis(Vector3(1, 0, 0), 0.02)
	# A：理想格点姿态（grab 前已在落点、正朝向）
	await _probe(sb, item, "A-ideal    ", Vector3(-6.0, 23.0, 6.0), Basis.IDENTITY, false)
	# B：真实流镜像（grab 于正朝向原位 → 物理停稳带亚格残余+微倾）
	await _probe(sb, item, "B-residue  ", Vector3(-6.03, 23.004, 5.97), tilt, true)
	# C：落在别的部件基座上（应拒绝：重叠）
	await _probe(sb, item, "C-on-item  ", Vector3(-5.25, 23.0, -8.5), Basis.IDENTITY, false)
	# D：完整真实拖放流（合理手速：10 帧 update_hand 从原位挪到落点，再真落下）
	var home: Transform3D = item.global_transform
	var drag := Drag.new()
	sb.add_child(drag)
	await physics_frame
	var events := {"rejected": 0, "reported": 0}
	drag.landed_reporter = func(_eid, _cell) -> void: events["reported"] += 1
	drag.drop_rejected.connect(func(_eid, _reason) -> void: events["rejected"] += 1)
	drag.begin_drag(item, "probe-flow", home.origin)
	for i in 10:
		drag.update_hand(Vector3(-6.0, 23.0, 6.0), float(Time.get_ticks_msec()))
		await physics_frame
	drag.release()
	var last_pose := Transform3D.IDENTITY
	var saw_dropping := false
	for i in 600:
		await physics_frame
		if drag.state() == Drag.DragState.DROPPING:
			saw_dropping = true
			last_pose = item.global_transform
		if drag.state() == Drag.DragState.IDLE:
			break
	var fell_back: bool = item.global_transform.origin.distance_to(home.origin) < EPS
	# 复盘：物理实际停稳姿态 → 量化候选 → 生产谓词复跑
	var recon := Transform3D(home.basis, last_pose.origin)
	var bboxes: Array = []
	_collect(item, Transform3D.IDENTITY, bboxes)
	var rbounds := _union(bboxes)
	var rextent: AABB = recon * rbounds
	recon.origin += rextent.position.snapped(Vector3.ONE * Q) - rextent.position
	var recon_ok := drag._placement_valid(recon)
	print("[D-flow     ] rejected=%d reported=%d fell_back=%s" % [
		events["rejected"], events["reported"], fell_back])
	print("[D-replay   ] rest=%s cand=%s placement_valid=%s hits=%s" % [
		str(last_pose.origin), str(recon.origin),
		"ACCEPT" if recon_ok else "REJECT",
		str(_hits(sb, item, recon, rbounds))])
	drag.queue_free()
	item.global_transform = home
	await physics_frame
	sb.queue_free()
	await physics_frame
	quit(0)
