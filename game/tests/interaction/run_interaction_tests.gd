extends SceneTree
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")
const Router := preload("res://scripts/interaction/gesture_router.gd")
const GPred := preload("res://scripts/interaction/ghost_predictor.gd")
const DragC := preload("res://scripts/interaction/drag_controller.gd")
const OpenC := preload("res://scripts/interaction/open_controller.gd")
const OrbitCam := preload("res://scripts/interaction/orbit_camera.gd")
const RunC := preload("res://scripts/interaction/run_controller.gd")
const HubC := preload("res://scripts/interaction/interaction_hub.gd")
const WSC := preload("res://scripts/core/world_state_core.gd")
const Bridge := preload("res://scripts/core/physics_bridge.gd")

## 学员交互系统测试（headless，纯逻辑层直测，不依赖真鼠标）。
## 跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/interaction/run_interaction_tests.gd
## 退出码 0 = 全部 PASS。
##
## 覆盖（验收标准，≥7 条）：
##   T1  手势路由：100ms 松开=点按、300ms=拖拽；阈值改 400ms 后 300ms 变点按
##   T2  虚影=同一套物理：独立 space 前推 1s 的落点 vs 真放下去停稳的位置差 < 0.3m
##   T3  降频门：连续 5 次 move 只在间隔 > 100ms 时放行重算；世界变化绕过移动阈值
##   T4  预设位：五个预设逐个 Tween 过渡到正确目标姿态；iso 切正交；Tab 轮换回绕
##   T5  合法性颜色：校验回调 false → 虚影红；true → 虚影绿（同一落点两套表达）
##   T6  落定上报：松手后 WorldState 收到一次 contact 事件、之后冻结、不重复上报
##   T7  run_toggle 状态翻转 + 慢放只动 Engine.time_scale（物理 tick 率不动）
##   T8  点按打开：全屏视图开/ESC 关/再点关；code_provider 注入生效
##   T9  project.godot [input] 段：8 个动作全部注册且键位正确
##   T10 异步证据：request_prediction / update_hand 主线程同步耗时 < 16ms

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_run_all()


func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


# ---------- 测试基础设施 ----------

func _run_all() -> void:
	await _t01_gesture_router()
	await _t02_ghost_matches_real_physics()
	await _t03_recompute_gate()
	await _t04_camera_presets()
	await _t05_validity_color()
	await _t06_landed_report_once()
	await _t07_run_toggle_and_time_scale()
	await _t08_open_view()
	_t09_input_map_registered()
	await _t10_async_evidence()
	await _t11_hub_wiring()
	await _t12_release_before_next_physics_frame()
	await physics_frame   # 让 queue_free 的场景落地，干净退出
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _wait_physics_frames(n: int) -> void:
	for i in n:
		await physics_frame


## 场景骨架：地板顶面 y=0（20×20 盒），0.5³ 方块刚体可放任意处。
func _make_floor(parent: Node3D, name: String = "Floor") -> StaticBody3D:
	var floor_body := StaticBody3D.new()
	floor_body.name = name
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(20.0, 1.0, 20.0)
	cs.shape = shape
	floor_body.add_child(cs)
	floor_body.position = Vector3(0.0, -0.5, 0.0)
	parent.add_child(floor_body)
	return floor_body


func _make_box(parent: Node3D, pos: Vector3, name: String = "DragBox") -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = name
	body.mass = 1.0
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.bounce = 0.05
	body.physics_material_override = mat
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.5, 0.5, 0.5)
	cs.shape = shape
	body.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.5, 0.5, 0.5)
	mi.mesh = mesh
	body.add_child(mi)
	body.position = pos
	parent.add_child(body)
	return body


func _mouse_event(button: int, pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	return e


func _key_event(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	return e


# ---------- T1 手势路由 ----------

func _t01_gesture_router() -> void:
	var cfg := IC.new()
	cfg.long_press_threshold_ms = 250.0
	var router := Router.new(cfg)
	var events: Array[String] = []
	router.tap_opened.connect(func(_p): events.append("tap"))
	router.drag_start.connect(func(_p): events.append("drag_start"))
	router.drag_move.connect(func(_p): events.append("drag_move"))
	router.drag_drop.connect(func(_p): events.append("drag_drop"))

	# 100ms 松开 = 点按
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(100, 100)), 0.0)
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, false, Vector2(100, 100)), 100.0)
	var tap_ok := events == ["tap"]

	# 300ms 按住 = 拖拽（poll 触发长按开始），移动跟手，松开=落下
	events.clear()
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(120, 100)), 1000.0)
	router.poll(1310.0)   # 按住 310ms > 250ms
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(200, 150)
	router.feed(mm, 1400.0)
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, false, Vector2(200, 150)), 1500.0)
	var drag_ok := events == ["drag_start", "drag_move", "drag_drop"]

	# 阈值改成 400ms：300ms 松开变回点按
	cfg.long_press_threshold_ms = 400.0
	events.clear()
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(80, 80)), 0.0)
	router.poll(300.0)   # 300ms ≤ 400ms：还不算长按
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, false, Vector2(80, 80)), 300.0)
	var threshold_ok := events == ["tap"]
	# 松开先于下一次 physics poll 时，仍应完成长按和放下。
	cfg.long_press_threshold_ms = 250.0
	events.clear()
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(80, 80)), 1000.0)
	router.feed(_mouse_event(MOUSE_BUTTON_LEFT, false, Vector2(80, 80)), 1300.0)
	var quick_release_ok := events == ["drag_start", "drag_drop"]

	_check(tap_ok and drag_ok and threshold_ok and quick_release_ok,
		"T1 手势路由：点按/长按/阈值调整，以及长按后同帧松手")


# ---------- T2 虚影预测与真实落点一致（同一套物理的证据） ----------

func _t02_ghost_matches_real_physics() -> void:
	var cfg := IC.new()
	cfg.prediction_horizon_s = 1.0
	var scene := Node3D.new()
	root.add_child(scene)
	_make_floor(scene)
	var box := _make_box(scene, Vector3(0.0, 2.2, 0.0))
	var init_lin := Vector3(0.8, -0.3, 0.4)
	var init_ang := Vector3.ZERO
	# _initialize 协程里 add_child 的节点要到第一帧才真正进树：
	# 冻结等一帧，确保两侧（真身与克隆）从完全同一初始状态出发
	box.freeze = true
	box.linear_velocity = init_lin
	box.angular_velocity = init_ang

	var predictor := GPred.new(cfg)
	scene.add_child(predictor)
	predictor.add_static_box(Vector3(20.0, 1.0, 20.0),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -0.5, 0.0)))
	predictor.bind_source(box)
	await physics_frame
	var init_xf := box.global_transform
	# Jolt 纪律：先解冻再赋速度——冻结态下设置速度会被丢弃
	box.freeze = false
	box.linear_velocity = init_lin
	box.angular_velocity = init_ang

	var t0 := Time.get_ticks_usec()
	var id := predictor.request_prediction(init_xf, init_lin, init_ang, 0.0)
	var request_us := float(Time.get_ticks_usec() - t0)
	var args: Array = await predictor.prediction_ready
	var result: Dictionary = args[1]

	# 真放下去：同一初始条件，主空间里跑到停稳（sleeping）
	var frames := 0
	while not box.sleeping and frames < 600:
		await physics_frame
		frames += 1
	var dist: float = (result["position"] as Vector3).distance_to(box.global_position)
	_check(id > 0 and dist < 0.3 and request_us < 16000.0,
		"T2 同一套物理：独立 space 前推 1s 落点 vs 真实停稳位置差 %.3fm（<0.3m），resting=%s，同步请求 %.0fµs" % [
			dist, str(result["resting"]), request_us])
	scene.queue_free()


# ---------- T3 降频门 ----------

func _t03_recompute_gate() -> void:
	var cfg := IC.new()
	cfg.recompute_interval_ms = 100.0
	cfg.hand_move_threshold_m = 0.10
	var predictor := GPred.new(cfg)
	# 连续 5 次 move：只有第一次（无历史）与间隔 >100ms 的那次放行
	var decisions: Array[bool] = []
	decisions.append(predictor.should_recompute(Vector3(0, 0, 0), 1000.0))
	decisions.append(predictor.should_recompute(Vector3(1, 0, 0), 1010.0))
	decisions.append(predictor.should_recompute(Vector3(2, 0, 0), 1020.0))
	decisions.append(predictor.should_recompute(Vector3(3, 0, 0), 1030.0))
	decisions.append(predictor.should_recompute(Vector3(4, 0, 0), 1040.0))
	var burst_ok := decisions == [true, false, false, false, false]

	var after_interval := predictor.should_recompute(Vector3(5, 0, 0), 1200.0)  # 距上次放行 200ms
	# 世界变化：即使手没动（同一位置）也要在下个间隔放行一次
	predictor.notify_world_changed()
	var world_dirty_ok := predictor.should_recompute(Vector3(5, 0, 0), 1320.0)
	_check(burst_ok and after_interval and world_dirty_ok,
		"T3 降频门：5 连 move 只有首发放行、间隔 200ms 放行、世界变化在同位置放行（100ms 间隔纪律）")
	predictor.free()


# ---------- T4 相机预设位 ----------

func _t04_camera_presets() -> void:
	var cfg := IC.new()
	cfg.preset_transition_s = 0.2
	var scene := Node3D.new()
	root.add_child(scene)
	var target := Node3D.new()
	target.name = "Subject"
	scene.add_child(target)
	var cam := OrbitCam.new(cfg)
	scene.add_child(cam)
	await physics_frame   # 让 _ready 应用初始姿态

	var all_ok := true
	var names: Array[String] = cam.preset_names()
	for preset_name in names:
		cam.switch_preset(preset_name)
		var waited := 0
		while cam.transitioning() and waited < 300:
			await physics_frame
			waited += 1
		var pose: Dictionary = cam.current_pose()
		var want: Dictionary = cam.presets[preset_name]
		var yaw_err: float = absf(wrapf(float(pose["yaw"]) - float(want["yaw"]), -PI, PI))
		var ok := not cam.transitioning() and yaw_err < 0.01 \
			and absf(float(pose["pitch"]) - float(want["pitch"])) < 0.01 \
			and absf(float(pose["distance"]) - float(want["distance"])) < 0.01 \
			and bool(pose["ortho"]) == bool(want.get("ortho", false))
		if not ok:
			all_ok = false
			print("  预设位不符：%s -> %s（want %s）" % [preset_name, str(pose), str(want)])
	# iso 是正交等距
	cam.switch_preset("iso")
	var waited2 := 0
	while cam.transitioning() and waited2 < 300:
		await physics_frame
		waited2 += 1
	var iso_ok := cam.projection == Camera3D.PROJECTION_ORTHOGONAL and absf(cam.size - 10.0) < 0.01
	# Tab 轮换：vista 之后回绕到 iso
	cam.switch_preset("vista")
	var waited3 := 0
	while cam.transitioning() and waited3 < 300:
		await physics_frame
		waited3 += 1
	var cycled: String = cam.cycle_preset()
	var waited4 := 0
	while cam.transitioning() and waited4 < 300:
		await physics_frame
		waited4 += 1
	var wrap_ok := cycled == "iso" and cam.projection == Camera3D.PROJECTION_ORTHOGONAL
	_check(all_ok and iso_ok and wrap_ok,
		"T4 预设位：五个预设 Tween 到正确姿态、iso 切正交(size=10)、Tab 从 vista 回绕 iso")
	scene.queue_free()


# ---------- T5 合法性颜色 ----------

func _t05_validity_color() -> void:
	var cfg := IC.new()
	cfg.prediction_horizon_s = 0.5
	var scene := Node3D.new()
	root.add_child(scene)
	_make_floor(scene)
	var box := _make_box(scene, Vector3(0.0, 2.0, 0.0))
	var predictor := GPred.new(cfg)
	scene.add_child(predictor)
	predictor.add_static_box(Vector3(20.0, 1.0, 20.0),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -0.5, 0.0)))
	var drag := DragC.new(cfg)
	drag.attach_predictor(predictor)
	scene.add_child(drag)
	await physics_frame   # 节点进树后再开始拖拽

	# 注意：GDScript lambda 按值捕获——要换判定结果必须换整个回调，不能改被捕获变量
	drag.validator = func(_xf: Transform3D) -> bool: return false
	drag.begin_drag(box, "block#1", Vector3(0.0, 2.0, 0.0))
	var ghost_state := drag.ghost_visual_state()
	var computing_ok := str(ghost_state["phase"]) == "computing"
	await predictor.prediction_ready
	await physics_frame
	var st_red: Dictionary = drag.ghost_visual_state()
	var ghost: MeshInstance3D = scene.get_node_or_null("DragGhost") as MeshInstance3D
	var red_mat: StandardMaterial3D = ghost.material_override if ghost != null else null
	var red_ok := str(st_red["phase"]) == "ready" and bool(st_red["valid"]) == false \
		and red_mat != null and red_mat.albedo_color.r > 0.5 and red_mat.albedo_color.g < 0.5

	# 换成合法：等降频间隔过去（>100ms 实时钟）再挪手触发重算，新预测到达后变绿
	drag.validator = func(_xf: Transform3D) -> bool: return true
	await _wait_physics_frames(12)   # ~200ms，跨过 100ms 重算间隔
	drag.update_hand(Vector3(3.0, 2.0, 0.0), float(Time.get_ticks_msec()))
	await predictor.prediction_ready
	await physics_frame
	var st_green: Dictionary = drag.ghost_visual_state()
	var green_mat: StandardMaterial3D = ghost.material_override if ghost != null else null
	var green_ok := str(st_green["phase"]) == "ready" and bool(st_green["valid"]) == true \
		and green_mat != null and green_mat.albedo_color.g > 0.5 and green_mat.albedo_color.r < 0.5

	_check(computing_ok and red_ok and green_ok,
		"T5 合法性颜色：预测期=计算中淡态、校验 false→虚影红、true→虚影绿")
	drag.release()
	scene.queue_free()


# ---------- T6 落定上报一次 ----------

func _t06_landed_report_once() -> void:
	var cfg := IC.new()
	cfg.prediction_horizon_s = 0.5
	var scene := Node3D.new()
	root.add_child(scene)
	_make_floor(scene)
	var box := _make_box(scene, Vector3(1.2, 1.0, 0.8))

	# 状态层：独立内核实例（不碰 autoload），物理→逻辑单向上报
	var st := WSC.new()
	st.register_asset("drag_block", WSC.KIND_PARAMETRIC, {}, [
		{"id": "touched", "kind": "BOOL", "dir": "in"},
	])
	st.place("drag_block", [1, 0, 1])
	var bridge := Bridge.new(st)

	var predictor := GPred.new(cfg)
	scene.add_child(predictor)
	var drag := DragC.new(cfg)
	drag.attach_predictor(predictor)
	drag.landed_reporter = bridge.report_contact
	scene.add_child(drag)
	await physics_frame   # 节点进树后再开始拖拽

	drag.begin_drag(box, "drag_block#1", Vector3(1.2, 1.0, 0.8))
	drag.update_hand(Vector3(1.2, 1.0, 0.8), 100.0)   # 同一位置：不带惯性，垂直落
	drag.release()

	var frames := 0
	while drag.state() != DragC.DragState.IDLE and frames < 600:
		await physics_frame
		frames += 1
	var settled_ok := drag.state() == DragC.DragState.IDLE and box.freeze
	var touched: Dictionary = st.read_ref("drag_block#1:touched")
	var reported_once := drag.land_report_count() == 1 and bool(touched.get("ok")) \
		and bool(touched.get("value"))
	# 再跑一段：不重复上报、冻结件不再动
	var pos_after_settle := box.global_position
	await _wait_physics_frames(60)
	var still_frozen := drag.land_report_count() == 1 \
		and box.global_position.distance_to(pos_after_settle) < 0.001
	_check(settled_ok and reported_once and still_frozen,
		"T6 落定上报：松手→物理接管→停稳上报一次（touched=true）→冻结→60 帧后不重复不移动")
	scene.queue_free()


# ---------- T7 run_toggle 与时间控制纪律 ----------

func _t07_run_toggle_and_time_scale() -> void:
	var cfg := IC.new()
	var run := RunC.new(cfg)
	root.add_child(run)
	var counts := {"start": 0, "stop": 0}
	run.run_start = func() -> void: counts["start"] += 1
	run.run_stop = func() -> void: counts["stop"] += 1

	var s1 := run.toggle_run()
	var s2 := run.toggle_run()
	var flip_ok := s1 == true and s2 == false and int(counts["start"]) == 1 and int(counts["stop"]) == 1

	var no_back: Dictionary = run.step_back()
	run.step_forward_fn = func() -> Dictionary: return {"ok": true, "result": {"ticked": true}}
	var fwd: Dictionary = run.step_forward()
	var step_ok := not bool(no_back["ok"]) and str(no_back["code"]) == "unsupported" \
		and bool(fwd["ok"]) and bool(fwd["result"]["ticked"])

	var ticks_before := Engine.physics_ticks_per_second
	run.set_speed(0.25)
	var slow_ok := is_equal_approx(Engine.time_scale, 0.25) \
		and Engine.physics_ticks_per_second == ticks_before
	var cycled: float = run.cycle_speed()   # 0.25 -> 2.0（档位表 1/0.5/0.25/2/4 的下一档）
	var fast_ok := is_equal_approx(cycled, 2.0) and Engine.physics_ticks_per_second == ticks_before
	run.reset_speed()
	var reset_ok := is_equal_approx(Engine.time_scale, 1.0)
	_check(flip_ok and step_ok and slow_ok and fast_ok and reset_ok,
		"T7 run_toggle 翻转（start/stop 各一次）、step 注入/未注入、慢放只动 time_scale（物理 tick 率 %d 不变）" % ticks_before)
	run.queue_free()


# ---------- T8 点按打开全屏视图 ----------

func _t08_open_view() -> void:
	var open := OpenC.new()
	root.add_child(open)
	var target := Node3D.new()
	target.name = "GateBlock"
	root.add_child(target)
	var seen: Array[String] = []
	open.view_opened.connect(func(eid): seen.append(eid))
	open.code_provider = func(_t: Node3D) -> String: return "CODE-42"

	open.open(target, "gate#1")
	var lbl := open.get_node_or_null("OpenViewOverlay/OpenViewPort/OpenView/Content") as Label
	var open_ok := open.is_open() and seen == ["gate#1"] \
		and lbl != null and lbl.text.contains("CODE-42")
	var esc_handled := open.feed(_key_event(KEY_ESCAPE))
	var esc_ok := esc_handled and not open.is_open()

	open.open(target, "gate#1")
	var click_handled := open.feed(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(10, 10)))
	var click_ok := click_handled and not open.is_open()
	_check(open_ok and esc_ok and click_ok,
		"T8 点按打开：全屏视图出现（SubViewport 容器 + 注入内容）、ESC 关、再点关、不常驻")
	open.queue_free()
	target.queue_free()


# ---------- T9 输入映射（project.godot [input] 段） ----------

func _t09_input_map_registered() -> void:
	var wanted: Dictionary = {
		"drag_long_press": "mouse:1",
		"open_tap": "mouse:1",
		"camera_pan": "mouse:2",
		"camera_zoom": "mouse:4|5",
		"run_toggle": "key:32",
		"step_back": "key:44",
		"step_forward": "key:46",
		"camera_preset_next": "key:4194306",
	}
	var ok := true
	for action in wanted:
		if not InputMap.has_action(action):
			ok = false
			print("  缺输入动作：%s" % action)
			continue
		var spec: String = wanted[action]
		var events: Array = InputMap.action_get_events(action)
		if spec.begins_with("mouse:"):
			var buttons: Array[int] = []
			for e in events:
				if e is InputEventMouseButton:
					buttons.append((e as InputEventMouseButton).button_index)
			for code_str in spec.substr("mouse:".length()).split("|"):
				if int(code_str) not in buttons:
					ok = false
		else:
			var code := int(spec.substr("key:".length()))
			var found := false
			for e in events:
				if e is InputEventKey and (e as InputEventKey).physical_keycode == code:
					found = true
			if not found:
				ok = false
	_check(ok, "T9 [input] 映射：8 动作全注册（左键=搬/开同键、右键平移、滚轮缩放、空格/逗号/句号/Tab）")


# ---------- T10 异步证据：主线程无同步前推 ----------

func _t10_async_evidence() -> void:
	var cfg := IC.new()
	var scene := Node3D.new()
	root.add_child(scene)
	var box := _make_box(scene, Vector3(0.0, 2.0, 0.0))
	var predictor := GPred.new(cfg)
	scene.add_child(predictor)
	predictor.add_static_box(Vector3(20.0, 1.0, 20.0),
		Transform3D(Basis.IDENTITY, Vector3(0.0, -0.5, 0.0)))
	predictor.bind_source(box)

	# 连发 3 次预测请求：同步段（克隆重置，前推本身在独立 space 随帧推进）
	var worst_us := 0.0
	for i in 3:
		predictor.request_prediction(Transform3D(Basis.IDENTITY, Vector3(0, 3.0, 0)),
			Vector3(1.0, 0.0, 0.0), Vector3.ZERO, float(i) * 150.0)
		worst_us = maxf(worst_us, predictor.last_request_cost_us)
	_check(worst_us < 16000.0,
		"T10 异步证据：request_prediction 主线程同步耗时最差 %.0fµs（< 16ms），前推在独立 space 随帧推进" % worst_us)
	scene.queue_free()


# ---------- T11 总装冒烟：hub 接线后输入流走通 ----------

func _t11_hub_wiring() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var cam := OrbitCam.new()
	scene.add_child(cam)
	var hub := HubC.new()
	root.add_child(hub)
	hub.setup(scene, cam)
	await physics_frame   # 节点进树后再喂输入
	var wired := hub.drag.predictor == hub.predictor and hub.router != null \
		and hub.open_view != null and hub.run != null \
		and not cam.is_processing_unhandled_input()

	# 鼠标移动 → 相机旋转（世界无主体时也不崩）
	var before: float = cam.current_pose()["yaw"]
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(640, 360)
	mm.relative = Vector2(40.0, 0.0)
	hub._unhandled_input(mm)
	var yaw_moved := absf(float(cam.current_pose()["yaw"]) - float(before)) > 0.001

	# 空格子上的点按（100ms 松开）→ 拾取落空 → 什么都不打开，管线不崩
	hub._unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT, true, Vector2(640, 360)))
	hub._unhandled_input(_mouse_event(MOUSE_BUTTON_LEFT, false, Vector2(640, 360)))
	await _wait_physics_frames(3)
	var tap_safe := not hub.open_view.is_open()

	# Tab 预设位轮换经 hub 生效：初始 iso → Tab → front（透视）
	hub._unhandled_input(_key_event(KEY_TAB))
	var waited := 0
	while cam.transitioning() and waited < 300:
		await physics_frame
		waited += 1
	var pose: Dictionary = cam.current_pose()
	var want_front: Dictionary = cam.presets["front"]
	var preset_ok := not cam.transitioning() \
		and absf(wrapf(float(pose["yaw"]) - float(want_front["yaw"]), -PI, PI)) < 0.01 \
		and bool(pose["ortho"]) == false
	_check(wired and yaw_moved and tap_safe and preset_ok,
		"T11 总装：hub 接线完整、鼠标移动转视角、空拾取安全、Tab 从 iso 轮到 front")
	hub.queue_free()
	scene.queue_free()


func _t12_release_before_next_physics_frame() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var box := _make_box(scene, Vector3.ZERO, "QuickReleaseBox")
	box.freeze = true
	var cam := OrbitCam.new()
	scene.add_child(cam)
	var hub := HubC.new()
	scene.add_child(hub)
	hub.setup(scene, cam)
	await physics_frame
	var center := root.get_viewport().get_visible_rect().get_center()
	hub.router.drag_start.emit(center)
	hub.router.drag_drop.emit(center)
	await _wait_physics_frames(2)
	_check(hub.drag.state() != DragC.DragState.LIFTING,
		"T12 长按触发后同一物理帧松手：不会留下卡住的拖动状态")
	scene.queue_free()
