class_name GhostPredictor
extends Node
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")

## 虚影=物理落点预测（docs/10-契约/交互方案.md §二虚影口径 + docs/20-验收/测量结果.md §数三）。
##
## 三条铁律（测量结果直接否决了 naïve 同步前推）：
##   1. **同一套物理**：克隆走 PhysicsServer3D（项目当前引擎 = Jolt，见 project.godot），
##      与真世界同 dt、同参数；禁止另写启发式落点——虚影会撒谎。
##   2. **异步**：一次预测 = 把刚体克隆进**独立 physics space**（game/bench/bench_predict.gd
##      已验证该 space 被主循环自动步进、且 CPU 成本在监测分辨率以下），主线程只做
##      克隆重置（实测 0.2 µs 量级），前推在真实帧流里推进，**绝不同步跑满视界**
##      （2s 前推 = 2s 墙钟，主线程同步做会卡死交互）。
##   3. **降频**：重算只在"手移动超过阈值或世界变化"且距上次 ≥ recompute_interval_ms
##      时发生（100ms 降频 CPU 免费，测量结果：无条件采纳）。
##
## 用法（drag_controller 是现成调用方；测试直接注入静态几何）：
##   var p := GhostPredictor.new(); add_child(p); p.setup(cfg)
##   p.add_static_box(Vector3(20, 1, 20), Transform3D(Basis.IDENTITY, Vector3(0, -0.5, 0)))
##   p.bind_source(rigid_body)
##   var id := p.request_prediction(xf, lin, ang, now_ms)
##   await p.prediction_ready  # 前推 1.5s（视界）后出结果

signal prediction_ready(id: int, result: Dictionary)

var config: IC

var _space := RID()
var _gravity_area := RID()
var _gravity_shape := RID()
var _statics: Array[RID] = []
var _ghost_shape := RID()
var _ghost := RID()
var _ghost_age := -1
var _active_id := -1
var _next_id := 1
var _has_source := false
var _source_shape_transform := Transform3D.IDENTITY
var _source_lock_rotation := false
var _source_mass := 1.0
var _source_friction := 1.0
var _source_bounce := 0.0
var _last_recompute_ms := -1.0e9
var _last_hand_pos := Vector3.INF
var _world_dirty := false
## 异步证据：request_prediction 同步段的墙钟耗时（测试断言 < 16ms）。
var last_request_cost_us := 0.0


func _init(cfg: IC = null) -> void:
	config = cfg if cfg != null else IC.new()


func _exit_tree() -> void:
	teardown()


## 建独立 space + 全场重力 area。重力取 project 的默认重力（与真世界同一个数）。
func setup(cfg: IC = null) -> void:
	if cfg != null:
		config = cfg
	if _space.is_valid():
		return
	_space = PhysicsServer3D.space_create()
	PhysicsServer3D.space_set_active(_space, true)
	var gravity: float = ProjectSettings.get_setting_with_override(
		"physics/3d/default_gravity") if ProjectSettings.has_setting("physics/3d/default_gravity") \
		else 9.8
	_gravity_area = PhysicsServer3D.area_create()
	PhysicsServer3D.area_set_space(_gravity_area, _space)
	PhysicsServer3D.area_set_param(_gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY, gravity)
	PhysicsServer3D.area_set_param(_gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY_OVERRIDE_MODE, 1)
	_gravity_shape = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(_gravity_shape, Vector3(600.0, 600.0, 600.0))
	PhysicsServer3D.area_add_shape(_gravity_area, _gravity_shape, Transform3D())


func teardown() -> void:
	_retire_ghost()
	if _ghost.is_valid():
		PhysicsServer3D.free_rid(_ghost)
		_ghost = RID()
	if _ghost_shape.is_valid():
		PhysicsServer3D.free_rid(_ghost_shape)
		_ghost_shape = RID()
	for rid in _statics:
		PhysicsServer3D.free_rid(rid)
	_statics.clear()
	if _gravity_area.is_valid():
		PhysicsServer3D.free_rid(_gravity_area)
		_gravity_area = RID()
	if _gravity_shape.is_valid():
		PhysicsServer3D.free_rid(_gravity_shape)
		_gravity_shape = RID()
	if _space.is_valid():
		PhysicsServer3D.space_set_active(_space, false)
		PhysicsServer3D.free_rid(_space)
		_space = RID()
	_has_source = false


# ---------- 世界静态几何（克隆对象：预测要撞的东西） ----------

## 注入一块静态盒（size=完整尺寸；测试用它搭"地面 + 方块"最小场景，
## 真实场景走 capture_statics_from）。注意 server 的 box data 是半边长。
func add_static_box(size: Vector3, global_xf: Transform3D) -> void:
	if not _space.is_valid():
		setup()
	var shape := PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(shape, size * 0.5)
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, 1)
	PhysicsServer3D.body_set_collision_mask(body, 1)
	PhysicsServer3D.body_add_shape(body, shape, Transform3D())
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, global_xf)
	PhysicsServer3D.body_set_space(body, _space)
	_statics.append(body)
	_statics.append(shape)


func clear_statics() -> void:
	for rid in _statics:
		PhysicsServer3D.free_rid(rid)
	_statics.clear()
	_world_dirty = true


## 从真实世界克隆静态盒/球（只取 Box/Sphere 形状，demo 的方块世界够用）。
## 返回克隆件数。只克隆 around 附近 radius 半径内的，缩视界三策略之一。
func capture_statics_from(node: Node3D, around: Vector3, radius: float, exclude: Node3D = null) -> int:
	if not _space.is_valid(): setup()
	if node == exclude or node.has_meta("pick_target"): return 0
	var count := 0
	var fixed: bool = node is StaticBody3D or node is AnimatableBody3D or (node is RigidBody3D and node.freeze)
	if fixed:
		for shape_node in _collision_shapes(node):
			if shape_node.disabled or shape_node.shape == null: continue
			# Include large floors even when their origin lies outside the local capture radius.
			var reach := radius
			if shape_node.shape is BoxShape3D: reach += shape_node.shape.size.length() * 0.5
			if shape_node.global_position.distance_to(around) <= reach and _clone_shape_of(shape_node):
				count += 1
	for child in node.get_children():
		if child is Node3D:
			count += capture_statics_from(child, around, radius, exclude)
	return count


func _collision_shapes(body: Node3D) -> Array:
	var out: Array = []
	for c in body.get_children():
		if c is CollisionShape3D:
			out.append(c)
	return out


func _clone_shape_of(cs: CollisionShape3D) -> bool:
	var shape: Shape3D = cs.shape
	var srid := RID()
	if shape is BoxShape3D:
		srid = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(srid, (shape as BoxShape3D).size * 0.5)
	elif shape is SphereShape3D:
		srid = PhysicsServer3D.sphere_shape_create()
		PhysicsServer3D.shape_set_data(srid, (shape as SphereShape3D).radius)
	else:
		return false
	var body := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(body, PhysicsServer3D.BODY_MODE_STATIC)
	PhysicsServer3D.body_set_collision_layer(body, 1)
	PhysicsServer3D.body_set_collision_mask(body, 1)
	PhysicsServer3D.body_add_shape(body, srid, Transform3D())
	PhysicsServer3D.body_set_state(body, PhysicsServer3D.BODY_STATE_TRANSFORM, cs.global_transform)
	PhysicsServer3D.body_set_space(body, _space)
	_statics.append(body)
	_statics.append(srid)
	return true


# ---------- 被拖物件（克隆参数来源） ----------

## 从真实刚体记下质量/摩擦/弹性与形状（同一套物理的证据：参数逐项复制）。
func bind_source(body: RigidBody3D) -> void:
	_retire_ghost()
	if _ghost.is_valid():
		PhysicsServer3D.free_rid(_ghost)
		_ghost = RID()
	_source_shape_transform = Transform3D.IDENTITY
	_source_lock_rotation = body.lock_rotation
	_source_mass = body.mass
	_source_friction = 1.0
	_source_bounce = 0.0
	var mat: PhysicsMaterial = body.physics_material_override
	if mat != null:
		_source_friction = mat.friction
		_source_bounce = mat.bounce
	if _ghost_shape.is_valid():
		PhysicsServer3D.free_rid(_ghost_shape)
	_ghost_shape = RID()
	for c in body.get_children():
		if c is CollisionShape3D and (c as CollisionShape3D).shape is BoxShape3D:
			_source_shape_transform = c.transform
			_ghost_shape = PhysicsServer3D.box_shape_create()
			PhysicsServer3D.shape_set_data(_ghost_shape,
				((c as CollisionShape3D).shape as BoxShape3D).size * 0.5)
			break
	if not _ghost_shape.is_valid():
		# 兜底 0.5³（demo 标准方块）
		_ghost_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(_ghost_shape, Vector3(0.5, 0.5, 0.5))
	_has_source = true


# ---------- 重算门（降频三策略：移动阈值 / 世界变化 / 间隔） ----------

## 世界变了（别的东西动了/加了）→ 下次 gate 检查强制放行一次。
func notify_world_changed() -> void:
	_world_dirty = true


## 手移动事件：是否该重算一次预测。纯逻辑、时间注入，测试直测（T3）。
func should_recompute(hand_pos: Vector3, now_ms: float) -> bool:
	var moved := _last_hand_pos == Vector3.INF \
		or hand_pos.distance_to(_last_hand_pos) >= config.hand_move_threshold_m
	if not (moved or _world_dirty):
		return false
	if now_ms - _last_recompute_ms < config.recompute_interval_ms:
		return false
	_last_recompute_ms = now_ms
	_last_hand_pos = hand_pos
	_world_dirty = false
	return true


# ---------- 预测（异步） ----------

## 发起一次前推：同步段只做克隆重置（µs 级），前推由主循环步进独立 space 完成，
## 视界（默认 1.5s = 90 tick）后经 prediction_ready 信号回传。返回预测 id。
## 若已在飞，旧的立即作废（结果已过时）。绝不放大物理步长。
func request_prediction(lift_xf: Transform3D, linear_vel: Vector3, angular_vel: Vector3,
		now_ms: float) -> int:
	var t0 := Time.get_ticks_usec()
	if not _space.is_valid():
		setup()
	if not _has_source:
		push_error("GhostPredictor：先 bind_source() 再 request_prediction()")
		return -1
	_retire_ghost()
	if not _ghost.is_valid():
		_ghost = PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(_ghost, PhysicsServer3D.BODY_MODE_RIGID)
		PhysicsServer3D.body_set_collision_layer(_ghost, 1)
		PhysicsServer3D.body_set_collision_mask(_ghost, 1)
		PhysicsServer3D.body_add_shape(_ghost, _ghost_shape, _source_shape_transform)
		for axis in [PhysicsServer3D.BODY_AXIS_ANGULAR_X, PhysicsServer3D.BODY_AXIS_ANGULAR_Y, PhysicsServer3D.BODY_AXIS_ANGULAR_Z]:
			PhysicsServer3D.body_set_axis_lock(_ghost, axis, _source_lock_rotation)
		PhysicsServer3D.body_set_param(_ghost, PhysicsServer3D.BODY_PARAM_MASS, _source_mass)
		PhysicsServer3D.body_set_param(_ghost, PhysicsServer3D.BODY_PARAM_FRICTION, _source_friction)
		PhysicsServer3D.body_set_param(_ghost, PhysicsServer3D.BODY_PARAM_BOUNCE, _source_bounce)
	PhysicsServer3D.body_set_space(_ghost, _space)
	PhysicsServer3D.body_set_state(_ghost, PhysicsServer3D.BODY_STATE_TRANSFORM, lift_xf)
	PhysicsServer3D.body_set_state(_ghost, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, linear_vel)
	PhysicsServer3D.body_set_state(_ghost, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, angular_vel)
	_ghost_age = 0
	_active_id = _next_id
	_next_id += 1
	# 同步记录：这次重算占掉降频窗口（拖拽开始的首次预测也算一次重算）
	_last_recompute_ms = now_ms
	last_request_cost_us = float(Time.get_ticks_usec() - t0)
	return _active_id


func prediction_in_flight() -> bool:
	return _ghost_age >= 0


func horizon_ticks() -> int:
	return maxi(1, int(round(config.prediction_horizon_s * Engine.physics_ticks_per_second)))


func _physics_process(_delta: float) -> void:
	if _ghost_age < 0:
		return
	_ghost_age += 1
	if _ghost_age < horizon_ticks():
		return
	var xf: Transform3D = PhysicsServer3D.body_get_state(_ghost, PhysicsServer3D.BODY_STATE_TRANSFORM)
	var lin: Vector3 = PhysicsServer3D.body_get_state(_ghost, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	var ang: Vector3 = PhysicsServer3D.body_get_state(_ghost, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
	var sleeping: bool = PhysicsServer3D.body_get_state(_ghost, PhysicsServer3D.BODY_STATE_SLEEPING)
	var result := {
		"id": _active_id,
		"transform": xf,
		"position": xf.origin,
		"basis": xf.basis,
		"linear_velocity": lin,
		"angular_velocity": ang,
		# 视界内已睡眠或近乎静止 = 可信落点；仍在动则虚影照样画但标记未停稳
		"resting": sleeping or (lin.length() < 0.1 and ang.length() < 0.3),
		"horizon_s": config.prediction_horizon_s,
		"ticks": _ghost_age,
	}
	var id := _active_id
	_retire_ghost()
	prediction_ready.emit(id, result)


func _retire_ghost() -> void:
	if _ghost.is_valid() and _ghost_age >= 0:
		PhysicsServer3D.body_set_space(_ghost, RID())
	_ghost_age = -1
	_active_id = -1
