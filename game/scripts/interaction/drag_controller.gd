class_name DragController
extends Node
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")
const GP := preload("res://scripts/interaction/ghost_predictor.gd")
const AssetNode := preload("res://scripts/asset_lib/asset_node.gd")
const DROP_QUANTUM := AssetNode.STANDARD_CUBE_SIZE * 0.5
const GRID_EPS := 0.0001

signal drop_rejected(entity_id: String, reason: String)
var _start_pose := Transform3D.IDENTITY
var _ghost_pose := Transform3D.IDENTITY
var _placement_boxes: Array[AABB] = []
var _bounds := AABB()

## 拖拽与虚影（docs/10-契约/交互方案.md §二）：长按抓起、跟手抬起（有重量感）、
## 松手真落下（物理接管）、落定上报一次后冻结（判定实体纪律）。
##
## 虚影展示在 ghost_predictor.gd 里算（独立 space 异步前推，同一套物理），
## 这里只消费结果：预测到达前"计算中"淡态，到达后半透明落点虚影。
## **合法性是另一回事**：端口不匹配/越界/重叠等编译期校验结果用外框颜色表达
## （绿=合法 红=不合法）。校验来源经 `validator` 回调注入（读 WorldTools 或
## compiler validate 均可），不硬依赖任何一侧。
##
## **物理→逻辑单向上报**：落定只调 `landed_reporter`（注入，真实场景接
## WorldState.apply_physics_event / PhysicsBridge.report_contact），状态层接管后
## 本件 freeze——"可以往下丢"与"判定不读物理"同时成立靠的就是这一次上报。

signal settled(entity_id: String, rest_position: Vector3)
signal dropped(entity_id: String)

enum DragState { IDLE, LIFTING, DROPPING }

var config: IC
var predictor: GP

## (Transform3D) -> bool：落点合法性。未注入时恒合法（只画落点不上色）。
var validator: Callable = Callable()
## (entity_id: String, cell: Vector3i) -> Dictionary：落定上报（一次）。
var landed_reporter: Callable = Callable()

var _state: DragState = DragState.IDLE
var _body: RigidBody3D = null
var _entity_id := ""
var _hand_target := Vector3.ZERO
var _hand_velocity := Vector3.ZERO
var _last_hand_pos := Vector3.INF
var _last_hand_ms := 0.0
var _settle_count := 0
var _stop_prediction_requested := false
var _drop_age := 0.0
var _reported := false
var _ghost: MeshInstance3D = null
var _ghost_phase := "hidden"   # hidden / computing / ready
var _ghost_valid := true
var _land_reports := 0
## 异步证据：单次 update_hand 同步段耗时（测试断言 < 16ms，含一次 request_prediction）。
var last_update_cost_us := 0.0


func _init(cfg: IC = null) -> void:
	config = cfg if cfg != null else IC.new()


func state() -> DragState:
	return _state


func land_report_count() -> int:
	return _land_reports


func ghost_visual_state() -> Dictionary:
	return {
		"phase": _ghost_phase,
		"valid": _ghost_valid,
		"position": _ghost.global_position if _ghost != null and is_instance_valid(_ghost) \
			else Vector3.INF,
	}


# ---------- 长按抓起 ----------

## 手势路由判出长按后由宿主调用。物件立即冻结改为跟手移动，虚影进入"计算中"。
func begin_drag(body: RigidBody3D, entity_id: String, hand_world_pos: Vector3) -> void:
	if _state != DragState.IDLE or body == null:
		return
	_body = body
	_entity_id = entity_id
	_start_pose = body.global_transform
	_placement_boxes.clear()
	# 逐级合成本地变换；文字不占格。真实资产用可见盒体，普通刚体用碰撞盒。
	_collect_placement_boxes(body, Transform3D.IDENTITY)
	if _placement_boxes.is_empty():
		for c in body.get_children():
			if c is CollisionShape3D and c.shape is BoxShape3D and not c.disabled:
				_placement_boxes.append(c.transform * AABB(-c.shape.size * 0.5, c.shape.size))
	_bounds = AABB()
	for i in _placement_boxes.size():
		_bounds = _placement_boxes[i] if i == 0 else _bounds.merge(_placement_boxes[i])
	_reported = false
	_settle_count = 0
	_body.freeze = true
	_hand_target = hand_world_pos + Vector3(0.0, config.lift_height_m, 0.0)
	_last_hand_pos = _hand_target
	_last_hand_ms = _now_ms()
	_hand_velocity = Vector3.ZERO
	_ghost_phase = "computing"
	_stop_prediction_requested = false
	_spawn_ghost_visual()
	_state = DragState.LIFTING
	# 拖拽开始即启动后台前推（不经降频门：第一次必须立刻算）
	if predictor != null:
		predictor.bind_source(_body)
		predictor.request_prediction(_release_pose(), _hand_velocity * config.carry_factor,
			Vector3.ZERO, _now_ms())


# ---------- 跟手（有重量感：缓动跟随） ----------

## 宿主每帧把手的世界坐标喂进来（真实场景=鼠标射线打到的世界点，测试直接注入）。
func update_hand(world_pos: Vector3, now_ms: float) -> void:
	var t0 := Time.get_ticks_usec()
	if _state != DragState.LIFTING:
		return
	var target := world_pos + Vector3(0.0, config.lift_height_m, 0.0)
	var dt := maxf(0.001, (now_ms - _last_hand_ms) / 1000.0)
	_stop_prediction_requested = false
	_hand_velocity = (target - _last_hand_pos) / dt
	_hand_target = target
	_last_hand_pos = target
	_last_hand_ms = now_ms
	# 虚影重算走降频门（移动阈值 + 世界变化 + 100ms 间隔）
	if predictor != null and predictor.should_recompute(target, now_ms):
		var id := predictor.request_prediction(_release_pose(),
			_hand_velocity * config.carry_factor, Vector3.ZERO, now_ms)
		if id > 0:
			_ghost_phase = "computing"
			_apply_ghost_material()
	last_update_cost_us = float(Time.get_ticks_usec() - t0)


## 世界变化（别的东西动了）→ 提醒预测器下次 gate 放行。
func notify_world_changed() -> void:
	if predictor != null:
		predictor.notify_world_changed()


# ---------- 松手：真落下 ----------

## 手势路由 drag_drop 后由宿主调用。物理接管，虚影隐藏，等落定。
func release() -> void:
	if _state != DragState.LIFTING or _body == null:
		return
	_body.freeze = false
	# 手已经停住时不再沿用陈旧速度，否则"移动→停顿→松手"照样把物件扔出去。
	var stale := _now_ms() - _last_hand_ms > config.hand_stop_ms
	_body.linear_velocity = Vector3.ZERO if stale else _hand_velocity * config.carry_factor
	_body.angular_velocity = Vector3.ZERO
	dropped.emit(_entity_id)
	_hide_ghost()
	_settle_count = 0
	_drop_age = 0.0
	_state = DragState.DROPPING


# ---------- 落定：上报一次 + 冻结 ----------

func _physics_process(_delta: float) -> void:
	if _state == DragState.LIFTING and _body != null and is_instance_valid(_body):
		# 缓动跟随：指数衰减阻尼，帧率无关的"重量感"
		var k := 1.0 - exp(-config.follow_speed * _delta)
		_body.global_position = _body.global_position.lerp(_hand_target, k)
		if predictor != null and not _stop_prediction_requested and _now_ms() - _last_hand_ms > config.hand_stop_ms and _body.global_position.distance_to(_hand_target) < 0.02:
			_stop_prediction_requested = true
			_hand_velocity = Vector3.ZERO
			predictor.request_prediction(_release_pose(), Vector3.ZERO, Vector3.ZERO, _now_ms())
	elif _state == DragState.DROPPING and _body != null and is_instance_valid(_body):
		_drop_age += _delta
		if _drop_age > 8.0 or _body.global_position.y < _start_pose.origin.y - 18:
			cancel_drag("落点超出地面，已放回原处")
			return
		if _is_settled():
			_settle_count += 1
		else:
			_settle_count = 0
		if _settle_count >= config.settle_frames:
			_finish_drop()


func _is_settled() -> bool:
	if _body.sleeping:
		return true
	return _body.linear_velocity.length() < config.settle_speed \
		and _body.angular_velocity.length() < config.settle_speed * 2.5


func _finish_drop() -> void:
	var candidate := _assembly_pose(_body.global_transform)
	if not _placement_valid(candidate):
		_body.freeze = true
		_body.global_transform = _start_pose
		_body.linear_velocity = Vector3.ZERO
		_body.angular_velocity = Vector3.ZERO
		_state = DragState.IDLE
		drop_rejected.emit(_entity_id, "落点不合法，已返回拖前位置")
		return
	_body.freeze = true
	_body.global_transform = candidate
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	var rest := candidate.origin
	# contact 保留旧逻辑格契约；它不是装配锚点或位置提交接口。
	var cell := Vector3i(int(floor(rest.x)), int(floor(rest.y)), int(floor(rest.z)))
	if not _reported:
		_reported = true
		_land_reports += 1
		if landed_reporter.is_valid():
			landed_reporter.call(_entity_id, cell)
	# 判定实体纪律：上报后物理不再动它
	_body.freeze = true
	_state = DragState.IDLE
	settled.emit(_entity_id, rest)


# ---------- 虚影视觉 ----------

func _on_prediction_ready(_id: int, result: Dictionary) -> void:
	if _state != DragState.LIFTING or _ghost == null or not is_instance_valid(_ghost):
		return
	_ghost_pose = _assembly_pose(result["transform"])
	_ghost.global_transform = _ghost_pose
	_ghost_valid = _placement_valid(_ghost_pose)
	_ghost_phase = "ready"
	_apply_ghost_material()


func _collect_placement_boxes(node: Node, xf: Transform3D) -> void:
	if node.has_meta("placement_ignore"): return
	if node is MeshInstance3D and node.mesh != null:
		_placement_boxes.append(xf * node.get_aabb())
	for c in node.get_children():
		if c is Node3D:
			_collect_placement_boxes(c, xf * c.transform)


## 保持拖前装配朝向，消除物理倾倒；以外延最小角为锚点，不量化中心。
func _assembly_pose(physical: Transform3D) -> Transform3D:
	var pose := Transform3D(_start_pose.basis, physical.origin)
	var extent: AABB = pose * _bounds
	pose.origin += extent.position.snapped(Vector3.ONE * DROP_QUANTUM) - extent.position
	return pose


## 六面都能落格才接受；尺寸/朝向不兼容时拒绝，不改变部件尺寸。
func _placement_valid(pose: Transform3D) -> bool:
	if _placement_boxes.is_empty() or not _check_validity(pose):
		return false
	for box in _placement_boxes:
		var extent: AABB = pose * box
		for corner in [extent.position, extent.end]:
			if corner.distance_to(corner.snapped(Vector3.ONE * DROP_QUANTUM)) > GRID_EPS:
				return false
	# 收缩极小数值容差允许贴面，不容许量化后穿进地板/别的刚体。
	var shape := BoxShape3D.new()
	shape.size = _bounds.size - Vector3.ONE * GRID_EPS * 2.0
	if shape.size.x <= 0 or shape.size.y <= 0 or shape.size.z <= 0:
		return false
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = pose * Transform3D(Basis.IDENTITY, _bounds.get_center())
	query.collision_mask = _body.collision_mask
	var excluded: Array[RID] = []
	var stack: Array[Node] = [_body]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		if node is CollisionObject3D:
			excluded.append(node.get_rid())
		stack.append_array(node.get_children())
	query.exclude = excluded
	return _body.get_world_3d().direct_space_state.intersect_shape(query, 1).is_empty()


func _check_validity(xf: Transform3D) -> bool:
	if not validator.is_valid():
		return true
	var verdict: Variant = validator.call(xf)
	return bool(verdict)


func _spawn_ghost_visual() -> void:
	_hide_ghost()
	_ghost_phase = "computing"
	if _body == null or _body.get_parent() == null:
		return
	_ghost = MeshInstance3D.new()
	_ghost.name = "DragGhost"
	# Combine all nested visible meshes in body-local space; preserve each part's transform.
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	_append_ghost_meshes(_body, Transform3D.IDENTITY, surface)
	_ghost.mesh = surface.commit()
	if _ghost.mesh == null: _ghost.mesh = _box_mesh_fallback()
	_ghost.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_apply_ghost_material()
	_body.get_parent().add_child(_ghost)
	_ghost.global_transform = _body.global_transform


func _append_ghost_meshes(node: Node, xf: Transform3D, surface: SurfaceTool) -> void:
	if node.has_meta("placement_ignore"): return
	if node is MeshInstance3D and node.mesh != null:
		for i in node.mesh.get_surface_count(): surface.append_from(node.mesh, i, xf)
	for child in node.get_children():
		if child is Node3D: _append_ghost_meshes(child, xf * child.transform, surface)


func _box_mesh_fallback() -> Mesh:
	var m := BoxMesh.new()
	m.size = Vector3(0.5, 0.5, 0.5)
	return m


func _apply_ghost_material() -> void:
	if _ghost == null or not is_instance_valid(_ghost):
		return
	var mat := StandardMaterial3D.new()
	# 计算中=淡态（不上合法性色）；出结果后落点虚影，颜色表达合法性（绿/红）。
	var base := Color(0.94, 0.94, 0.96)
	if _ghost_phase != "computing":
		base = Color(0.31, 0.89, 0.45) if _ghost_valid else Color(0.91, 0.27, 0.20)
	base.a = 0.12 if _ghost_phase == "computing" else 0.38
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = base
	mat.emission_enabled = true
	mat.emission = Color(0.4, 0.9, 1.0) if _ghost_valid else Color(1.0, 0.3, 0.2)
	mat.emission_energy_multiplier = 0.6
	_ghost.material_override = mat


func _hide_ghost() -> void:
	_ghost_phase = "hidden"
	if _ghost != null and is_instance_valid(_ghost):
		_ghost.queue_free()
	_ghost = null


func _release_pose() -> Transform3D:
	# "松手瞬间"的近似：物件当前位置（缓动滞后于手），不带旋转
	return Transform3D(_body.global_basis, _body.global_position)


func _now_ms() -> float:
	return float(Time.get_ticks_msec())


## 接上预测器并订阅结果（宿主/测试调这个，不要直接赋 predictor 字段——要连信号）。
func attach_predictor(p: GP) -> void:
	if predictor != null and is_instance_valid(predictor):
		predictor.prediction_ready.disconnect(_on_prediction_ready)
	predictor = p
	p.prediction_ready.connect(_on_prediction_ready)


func cancel_drag(reason := "已取消搬运") -> void:
	if _state == DragState.IDLE or not is_instance_valid(_body): return
	_body.freeze = true
	_body.global_transform = _start_pose
	_body.linear_velocity = Vector3.ZERO
	_body.angular_velocity = Vector3.ZERO
	_hide_ghost()
	_state = DragState.IDLE
	drop_rejected.emit(_entity_id, reason)
