extends SceneTree

## L1 求助屏 + 交互 hub 接线测试（headless）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/levels/l1/run_l1_wiring_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准，≥7 条）：
##  T1  场景实例化即自带接线：HelpScreen + InteractionHub 两子节点就位、
##      hub 已 setup（轨道相机接管主相机、控制器连好）
##  T2  求助屏三级链路：3 次 notify_attempt_failed 解锁 → 3 次 ask 屏文案升级
##      1→2→3、L1 文案含问题组件名（TaskBoard）、L3 发 request_demo
##  T3  request_highlight 落地：任务牌面板变红（albedo+emission override），
##      短时后还原（material_override 撤掉）
##  T4  长按抓起散块：hub 拾取到刚体目标（drag 进 LIFTING、方块被冻结）、
##      虚影预测请求在飞；松手进 DROPPING（完整落点断言归交互套件，不重复）
##  T5  点按任务牌：全屏打开（entity=conc_task_board、code_provider 简述文本
##      出现）→ ESC 关闭
##  T6  空格 run_toggle：状态翻转 true→false，场景回调被调（run_drive_toggled
##      信号两次、run_drive_count=2）
##  T7  感应：小车走到屏前 in_range=true，走远后 false
##  T8  物理→逻辑单向上报：entity_of 映射正确、landed_reporter 接的是
##      WorldState.apply_physics_event（首次 ok、同一 cell 重复上报被去重拒绝）
##
## 产物：runs/help/l1.json（求助屏 ask 的轻量日志，game/runs/ 已 gitignore）。
## L1 原流程回归另跑 tests/levels/l1/run_l1_tests.gd（期望 7/0）。

const L1Scene := preload("res://scenes/levels/l1/l1.tscn")
const DragC := preload("res://scripts/interaction/drag_controller.gd")

var _passed := 0
var _failed := 0
var _scene: Node3D = null
var _help = null
var _hub = null


func _initialize() -> void:
	_run_all.call_deferred()


func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


func _mouse(button: int, pressed: bool, pos: Vector2) -> InputEventMouseButton:
	var e := InputEventMouseButton.new()
	e.button_index = button
	e.pressed = pressed
	e.position = pos
	e.global_position = pos
	return e


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	return e


func _run_all() -> void:
	_scene = L1Scene.instantiate()
	root.add_child(_scene)
	for i in 5:
		await create_timer(0.02).timeout
	_help = _scene.get_node_or_null("Workstation/HelpScreen")
	_hub = _scene.get_node_or_null("InteractionHub")

	_t01_wiring_nodes()
	await _t02_hint_chain()
	await _t03_highlight()
	await _t04_drag_loose_block()
	await _t05_tap_open_esc()
	_t06_space_toggle()
	await _t07_sense()
	_t08_landed_report()

	_scene.free()
	await physics_frame   # 让释放落地，干净退出
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ---------- T1 节点与 setup ----------

func _t01_wiring_nodes() -> void:
	var cam := _scene.get_node_or_null("Camera") as Camera3D
	var ok := _help != null and _hub != null
	ok = ok and cam != null and cam.current
	ok = ok and cam.get_script() == preload("res://scripts/interaction/orbit_camera.gd")
	ok = ok and _hub.camera == cam and _hub.world_root == _scene   # setup 已完成
	ok = ok and _hub.drag.predictor == _hub.predictor and _hub.router != null
	ok = ok and _hub.open_view != null and _hub.run != null
	_check(ok, "T1 场景自带接线：HelpScreen + InteractionHub 就位、轨道相机接管主相机、hub setup 完成（未 setup 时输入会崩的坑位已防）")


# ---------- T2 求助屏三级链路 ----------

func _t02_hint_chain() -> void:
	_scene.highlight_seconds = 0.5   # T3 要看"变红后还原"，不等默认 3 秒
	_scene.install_task_board()
	var board: Node3D = _scene.get_task_board()
	var demos: Array = []
	_help.request_demo.connect(func(l: String): demos.append(l))

	# 感应对象=小车：把它挪到屏前（走到屏前才开始对话）
	var cart := _scene.get_node("Workstation/CodexCart") as Node3D
	cart.global_position = _help.global_position + Vector3(1.0, 0.0, 0.6)
	await create_timer(0.05).timeout   # 让屏的 _process 刷新感应

	# 3 次失败（场景级入口）解锁，3 次问逐级升
	for i in 3:
		_scene.notify_attempt_failed()
	var h1: Dictionary = _help.ask("哪里不对")
	var h2: Dictionary = _help.ask("为什么")
	var h3: Dictionary = _help.ask("做给我看")
	var ok := board != null \
		and str(h1.get("kind", "")) == "hint" and int(h1.get("level", 0)) == 1 \
		and int(h2.get("level", 0)) == 2 and int(h3.get("level", 0)) == 3
	ok = ok and str(h1.get("text", "")).contains("TaskBoard")   # 问题组件名进 L1 文案
	ok = ok and str(h2.get("text", "")).contains("c10.1")       # L2 诊断带概念 id
	ok = ok and demos == ["l1"]                                 # L3 发代做请求
	ok = ok and _help.get_last_text() == str(h3.get("text", ""))
	_check(ok, "T2 求助屏三级链路：3 次 notify_attempt_failed 解锁、3 次 ask 升级 1→2→3、L1 文案含问题组件名 TaskBoard、L3 发 request_demo")


# ---------- T3 request_highlight 变红 ----------

func _t03_highlight() -> void:
	var board: Node3D = _scene.get_task_board()
	var panel := board.get_node("Panel") as MeshInstance3D
	var mat := panel.material_override as StandardMaterial3D
	var red_now := mat != null and mat.albedo_color.r > 0.8 and mat.albedo_color.g < 0.5 \
		and mat.emission_enabled
	await create_timer(0.9).timeout   # highlight_seconds=0.5，已过还原点
	var restored: bool = panel.material_override == null
	_check(red_now and restored,
		"T3 request_highlight：任务牌面板变红（红色 albedo+emission override 已盖上）、0.5s 后还原（override 撤掉）")


# ---------- T4 长按抓起散块 ----------

func _t04_drag_loose_block() -> void:
	var block := _scene.get_node("Workstation/LooseBlock1") as RigidBody3D
	var eid := str(_hub.entity_of.call(block))
	var cam := _scene.get_node("Camera") as Camera3D
	var sp: Vector2 = cam.unproject_position(block.global_position)

	_hub._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true, sp))
	for i in 30:   # 0.5s > 250ms 长按阈值（真实时钟，router.poll 转长按）
		await physics_frame
	var lifting: bool = _hub.drag.state() == DragC.DragState.LIFTING
	var picked: bool = lifting and block.freeze   # begin_drag 冻结的是拾到的目标本身
	var predicting: bool = _hub.predictor.prediction_in_flight() \
		or str(_hub.drag.ghost_visual_state()["phase"]) != "hidden"
	_hub._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false, sp))
	var dropping: bool = _hub.drag.state() == DragC.DragState.DROPPING
	_check(eid == "drag_block#1" and picked and predicting and dropping,
		"T4 长按抓起散块：hub 拾取到刚体目标（LIFTING+冻结）、虚影预测请求在飞、松手进 DROPPING；entity_of=drag_block#1")


# ---------- T5 点按任务牌 → 全屏打开 → ESC ----------

func _t05_tap_open_esc() -> void:
	var board: Node3D = _scene.get_task_board()
	var cam := _scene.get_node("Camera") as Camera3D
	var sp: Vector2 = cam.unproject_position(board.to_global(Vector3(0.0, 1.85, 0.0)))
	var opened: Array = []
	_hub.open_view.view_opened.connect(func(eid: String): opened.append(eid))

	_hub._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, true, sp))
	_hub._unhandled_input(_mouse(MOUSE_BUTTON_LEFT, false, sp))   # 立刻松开=点按
	for i in 3:
		await physics_frame   # 拾取延到物理步内做，等排空
	var label := _hub.open_view.get_node_or_null(
		"OpenViewOverlay/OpenViewPort/OpenView/Content") as Label
	var opened_ok: bool = _hub.open_view.is_open() and opened == ["conc_task_board"] \
		and label != null and label.text.contains("任务牌")
	var esc_ok: bool = _hub.open_view.feed(_key(KEY_ESCAPE)) and not _hub.open_view.is_open()
	_check(opened_ok and esc_ok,
		"T5 点按任务牌：全屏打开（entity=conc_task_board、code_provider 简述文本出现）→ ESC 关闭")


# ---------- T6 空格 run_toggle ----------

func _t06_space_toggle() -> void:
	_scene.space_runs_demo = false   # 测试只验证翻转与回调，不真跑演示
	var flips: Array = []
	_scene.run_drive_toggled.connect(func(r: bool): flips.append(r))
	var space := _key(32)   # physical 32 = run_toggle 映射
	_hub._unhandled_input(space)
	var first: bool = _hub.run.running and flips == [true]
	_hub._unhandled_input(space.duplicate())
	var second: bool = not _hub.run.running and flips == [true, false]
	_check(first and second and _scene.run_drive_count == 2,
		"T6 空格 run_toggle：翻转 true→false、场景回调被调（run_drive_toggled 两次、run_drive_count=2）")


# ---------- T7 感应 ----------

func _t07_sense() -> void:
	var near: bool = _help.is_visitor_in_range()   # T2 已把小车挪到屏前
	var cart := _scene.get_node("Workstation/CodexCart") as Node3D
	cart.global_position += Vector3(6.0, 0.0, 6.0)   # 走远（出 2.4m 感应圈）
	await create_timer(0.05).timeout
	var far: bool = not _help.is_visitor_in_range()
	_check(near and far, "T7 感应：小车走到屏前 in_range=true，走远后 false（走到屏前才开始对话）")


# ---------- T8 物理→逻辑单向上报 ----------

func _t08_landed_report() -> void:
	var block := _scene.get_node("Workstation/LooseBlock2") as RigidBody3D
	var eid := str(_hub.entity_of.call(block))
	var r1: Dictionary = _hub.drag.landed_reporter.call(eid, Vector3i(4, 23, 3))
	var r2: Dictionary = _hub.drag.landed_reporter.call(eid, Vector3i(4, 23, 3))
	var ok: bool = eid == "drag_block#2" and _hub.drag.landed_reporter.is_valid() \
		and bool(r1.get("ok", false)) \
		and not bool(r2.get("ok", true)) and str(r2.get("code", "")) == "duplicate_event"
	_check(ok, "T8 物理→逻辑单向上报：entity_of 映射 drag_block#2、landed_reporter 接 WorldState.apply_physics_event（首次 ok、同一 cell 重复上报被去重拒绝）")
