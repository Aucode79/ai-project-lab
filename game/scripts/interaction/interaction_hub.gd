class_name InteractionHub
extends Node
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")
const GR := preload("res://scripts/interaction/gesture_router.gd")
const GP := preload("res://scripts/interaction/ghost_predictor.gd")
const DC := preload("res://scripts/interaction/drag_controller.gd")
const OC := preload("res://scripts/interaction/open_controller.gd")
const OrbitCam := preload("res://scripts/interaction/orbit_camera.gd")
const RC := preload("res://scripts/interaction/run_controller.gd")

## 学员交互系统的总装（docs/10-契约/交互方案.md §二/§四）。
##
## 把 gesture_router / drag_controller + ghost_predictor / open_controller /
## orbit_camera / run_controller 接到真实输入流上：
##   左键经 router 按时长分手势（长按=搬，点按=开）
##   右键/滚轮/鼠标移动直接进相机；Tab 切预设位；空格跑/停；`,`/`.` 单步
## 各控制器本身不依赖本类——测试可以（也应该）单独实例化直测。
##
## 射线拾取必须在物理步内做（direct_space_state 纪律），所以手势回调先排队，
## _physics_process 里统一拾取再分发。

var config: IC

var router: GR
var predictor: GP
var drag: DC
var open_view: OC
var camera: OrbitCam
var run: RC

## 拾取目标的世界根（静态几何克隆与射线都从这里出发）。
var world_root: Node3D = null
## 物件名 → 状态层实体 id 的映射（未注入时用节点名）。
var entity_of: Callable = Callable()

var _pending: Array[Dictionary] = []
var _pick_mask := 3


func _init(cfg: IC = null) -> void:
	config = cfg if cfg != null else IC.new()
	router = GR.new(config)
	predictor = GP.new(config)
	drag = DC.new(config)
	drag.attach_predictor(predictor)
	open_view = OC.new(config)
	run = RC.new(config)


func _ready() -> void:
	add_child(predictor)
	add_child(drag)
	add_child(open_view)
	add_child(run)
	router.tap_opened.connect(_queue_tap)
	router.drag_start.connect(_queue_drag_start)
	router.drag_move.connect(_on_drag_move)
	router.drag_drop.connect(_on_drag_drop)


## 世界与相机就位后调用（相机须已在 world_root 场景里）。tools 传 WorldToolsCore
## 或等价入口；运行/单步/代码视图的语义都由它注入。
func setup(world: Node3D, cam: OrbitCam, tools = null) -> void:
	world_root = world
	camera = cam
	# Hub 统一转发输入；相机自身再收一次会使旋转、平移和缩放翻倍。
	camera.set_process_unhandled_input(false)
	if tools != null:
		run.run_start = func() -> void: tools.call_tool("world.run", {"duration": 1.0})
		run.step_forward_fn = func() -> Dictionary: return tools.call_tool("world.step", {})
		open_view.code_provider = func(_t: Node3D) -> String:
			var r: Dictionary = tools.export_python()
			return str(r.get("code", "")) if bool(r.get("ok", false)) else ""


func _unhandled_input(event: InputEvent) -> void:
	if world_root != null and world_root.get_meta("scene_menu_open", false): return
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and drag.state() != DC.DragState.IDLE:
		drag.cancel_drag()
		camera.look_enabled = true
		get_viewport().set_input_as_handled()
		return
	if open_view.is_open():
		return   # 全屏视图打开时世界输入全部吃掉
	if event.is_action_pressed("camera_preset_next"):
		camera.cycle_preset()
		return
	if event.is_action_pressed("run_toggle"):
		run.toggle_run()
		return
	if event.is_action_pressed("step_forward"):
		run.step_forward()
		return
	if event.is_action_pressed("step_back"):
		run.step_back()
		return
	if event.is_action("camera_zoom"):
		camera.feed(event)
		return
	camera.feed(event)
	if event is InputEventMouseButton or event is InputEventMouseMotion:
		router.feed(event, float(Time.get_ticks_msec()))


func _physics_process(_delta: float) -> void:
	router.poll(float(Time.get_ticks_msec()))
	_drain_pending()


# ---------- 手势分发（拾取延到物理步内） ----------

func _queue_tap(screen_pos: Vector2) -> void:
	_pending.append({"kind": "tap", "pos": screen_pos})


func _queue_drag_start(screen_pos: Vector2) -> void:
	_pending.append({"kind": "drag_start", "pos": screen_pos})


func _drain_pending() -> void:
	while not _pending.is_empty():
		var job: Dictionary = _pending.pop_front()
		var screen_pos: Vector2 = job["pos"]
		match str(job["kind"]):
			"tap":
				var picked := _pick_body(screen_pos)
				if picked != null:
					open_view.open(picked, _entity_id_of(picked))
			"drag_start":
				var picked := _pick_body(screen_pos)
				if picked != null and not picked.get_meta("drag_locked", false):
					camera.look_enabled = false
					# 缩视界：只克隆落点附近的静态几何进预测 space。
					predictor.clear_statics()
					predictor.capture_statics_from(world_root, picked.global_position, 24.0, picked)
					drag.begin_drag(picked, _entity_id_of(picked), picked.global_position)
			"drag_move":
				drag.update_hand(_hand_world(screen_pos), float(Time.get_ticks_msec()))
			"drag_drop":
				camera.look_enabled = true
				drag.release()


func _on_drag_move(screen_pos: Vector2) -> void:
	if drag.state() == DC.DragState.LIFTING:
		drag.update_hand(_hand_world(screen_pos), float(Time.get_ticks_msec()))
	else:
		_pending.append({"kind": "drag_move", "pos": screen_pos})


func _on_drag_drop(screen_pos: Vector2) -> void:
	if drag.state() == DC.DragState.LIFTING:
		camera.look_enabled = true
		drag.release()
	else:
		_pending.append({"kind": "drag_drop", "pos": screen_pos})


func _entity_id_of(node: Node3D) -> String:
	if entity_of.is_valid():
		var eid: Variant = entity_of.call(node)
		if eid is String and (eid as String) != "":
			return eid
	return str(node.name)


## 屏幕坐标 → 世界坐标（抓起/跟手都发生在鼠标射线上，距相机当前距离处）。
func _hand_world(screen_pos: Vector2) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var origin: Vector3 = camera.project_ray_origin(screen_pos)
	var normal: Vector3 = camera.project_ray_normal(screen_pos)
	if drag != null and drag._body != null and drag.state() != DC.DragState.IDLE:
		var plane := Plane(Vector3.UP, drag._start_pose.origin.y)
		var point: Variant = plane.intersects_ray(origin, normal)
		if point is Vector3: return point
	return origin + normal * camera.current_distance()


## 射线拾取可拖/可开的刚体。只许在 _physics_process 里被调（direct_space_state 纪律）。
func _pick_body(screen_pos: Vector2) -> RigidBody3D:
	if camera == null or world_root == null:
		return null
	var world3d: World3D = world_root.get_world_3d()
	if world3d == null:
		return null
	var origin: Vector3 = camera.project_ray_origin(screen_pos)
	var normal: Vector3 = camera.project_ray_normal(screen_pos)
	var params := PhysicsRayQueryParameters3D.create(origin + normal * 0.5,
		origin + normal * 200.0, _pick_mask)
	params.collide_with_areas = false
	var hit: Dictionary = world3d.direct_space_state.intersect_ray(params)
	var collider: Variant = hit.get("collider")
	if collider is Node and collider.has_meta("pick_target"):
		var target: Variant = collider.get_meta("pick_target")
		if is_instance_valid(target) and target is RigidBody3D: return target
	if collider is RigidBody3D:
		return collider
	return null
