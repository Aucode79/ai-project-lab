extends "res://scripts/scene/level_scene_base.gd"

## L1 关卡场景（计划 §7 第 3 步：第 1 关端到端）。
## 主题（spec §9.1.1）："它是谁、接什么活"——装任务牌 + 角色铭牌，配 E49 占位视频。
##
## 世界配方（地形/环境/光照/粒子/材质/相机）与模式解析、体素就绪等待、小车移动都在基座
## scripts/scene/level_scene_base.gd；本文件只留 L1 的工位布局与组件安装。
##
## 场景内容全部代码搭建（tscn 只挂根节点 + 脚本，同 bench/gen_scene.gd 模式）：
##   + 工位：codex 本体 = 一个可移动的方块小车（L1 不做精细造型）
##   + 任务牌/铭牌安装位（装上动作由 l1_flow 的 stage_install 驱动）
##   + 播放器方块（player_block.tscn，占位内容）
##   + 求助屏（help_screen.tscn，docs/10-契约/交互方案.md §5.1）：摆在播放器幕布旁、
##     不遮西侧工位；问题组件=任务牌，感应对象=codex 小车，概念映射 L1→c10.1；
##     request_highlight 由本场景落地成"任务牌变红 N 秒"的材质回调
##   + 交互总装（InteractionHub，docs/10-契约/交互方案.md §二/§四）：轨道相机接管主相机、
##     长按搬散块/点按开全屏/空格跑停/落定经 PhysicsBridge 单向上报状态层
##
## 物理：小车/组件都是展示性移动不接物理，但散块（LooseBlock×2）是真刚体——
## 长按搬、松手物理接管、落定 landed_reporter 上报一次。体素碰撞体照常生成。
##
## 失败计数：本场景暴露 notify_attempt_failed() 场景级入口（转调求助屏 report_fail）。
##
## 入口：
##   窗口围观：godot --path game scenes/levels/l1/l1.tscn
##   窗口演示：… scenes/levels/l1/l1.tscn -- --demo（跑一遍完整流程的可视版，不落盘）
##   截图：    … scenes/levels/l1/l1.tscn -- --shot（出 game/tests/levels/l1/l1_preview.png 后退出）
##   流程判定：headless 走 tests/levels/l1/run_l1_tests.gd（l1_flow.gd 驱动）
##   接线判定：headless 走 tests/levels/l1/run_l1_wiring_tests.gd（求助屏 + 交互 hub）

const TaskBoardScene := preload("res://scenes/levels/l1/components/task_board.tscn")
const NameplateScene := preload("res://scenes/levels/l1/components/nameplate.tscn")
const PlayerBlockScene := preload("res://scenes/blocks/player_block.tscn")
const HelpScreenScene := preload("res://scenes/blocks/help_screen.tscn")
const OpsChartScene := preload("res://scenes/blocks/ops_chart.tscn")
const L1FlowScript := preload("res://scripts/levels/l1/l1_flow.gd")
# 交互/状态侧走 preload（同 interaction 包纪律：不依赖 .godot 全局类缓存）
const HubScript := preload("res://scripts/interaction/interaction_hub.gd")
const WorldStateScript := preload("res://scripts/core/world_state_core.gd")
const PhysicsBridgeScript := preload("res://scripts/core/physics_bridge.gd")

const OUT_SHOT := "res://tests/levels/l1/l1_preview.png"

# ---- 工位布局（全部落原点附近 13×13 甲板上；摆位取 0.25 m 格，整格优先）----
const BOARD_MOUNT_POS := Vector3(-2.0, DECK_TOP_Y, -0.5)
const BOARD_MOUNT_YAW := PI * 0.30
const PLATE_MOUNT_POS := Vector3(-3.5, DECK_TOP_Y, -2.0)   # 任务牌背面
const PLATE_MOUNT_YAW := PI * 0.30
const SCREEN_POS := Vector3(4.5, DECK_TOP_Y, -1.5)
const SCREEN_YAW := -PI * 0.42
const HELP_POS := Vector3(5.5, DECK_TOP_Y, 1.0)     # 求助屏：播放器幕布旁，不遮工位
const HELP_YAW := -PI * 0.57
const CHART_POS := Vector3(1.0, DECK_TOP_Y, 2.5)    # 图表方块：工位旁东南角，不遮散块
const CHART_YAW := -PI * 0.25
const CODEX_START := Vector3(2.5, DECK_TOP_Y, 3.5)
const BOARD_FRONT := Vector3(-0.5, DECK_TOP_Y, 0.5)        # 小车停在任务牌前
const LOOSE_BLOCK_SPOTS := [
	Vector3(3.5, DECK_TOP_Y + 0.25, 2.5),   # y = 甲板面 + 半块高 → 出生即贴地
	Vector3(4.5, DECK_TOP_Y + 0.25, 3.0),
]
const ASSET_LOOSE_BLOCK := "drag_block"
const HIGHLIGHT_RED := Color(0.914, 0.325, 0.325)

const ORBIT_LOOK_AT := Vector3(0.0, DECK_TOP_Y + 1.5, 0.0)  # OrbitCam 的注视主体位

var _help = null                    # scenes/blocks/help_screen.gd
var _hub = null                     # scripts/interaction/interaction_hub.gd
var _state = null                   # 场景级状态层（物理→逻辑单向上报的接收端）
var _bridge = null                  # scripts/core/physics_bridge.gd
## request_highlight 的变红时长（秒）；测试可调小。
var highlight_seconds := 3.0
## 空格 run_start 是否驱动场景演示流程（窗口围观语义）。
var space_runs_demo := true
var _demo_running := false
var _highlight_overrides := {}      # MeshInstance3D -> 变红前的 material_override


# ---------- 基座覆写点 ----------

func _level_label() -> String:
	return "L1"


func _shot_path() -> String:
	return OUT_SHOT


func _demo_pause() -> float:
	return 1.2


func _add_camera() -> void:
	# 轨道相机接管主相机：OrbitCam 即场景 "Camera" 节点，注视主体=甲板中心。
	# 进场机位收在甲板空域内（presets 注释见 world_builder.make_orbit_camera）。
	_orbit_cam = WorldBuilder.make_orbit_camera(self, ORBIT_LOOK_AT,
		"deck", {"yaw": deg_to_rad(45.0), "pitch": 0.9, "distance": 9.0})
	WorldBuilder.attach_viewer(self)


## 可视演示：用独立内核（own_* 注入，不碰共享 autoload）跑五阶段，不 end_run 不落盘。
func _drive_visual_demo(pause_s: float) -> void:
	var flow := L1FlowScript.new()
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	var tools := WorldToolsCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	flow.tools = tools
	flow.view = self
	add_child(flow)
	flow.setup_world()
	flow.begin()
	await flow.stage_video()
	await _sleep(pause_s)
	await flow.stage_install()
	await _sleep(pause_s)
	await flow.stage_run()
	await _sleep(pause_s)
	await flow.stage_tune()
	flow.stage_score()


# ---------- 对外（给 l1_flow / 测试用） ----------

func install_task_board():
	var mount := get_node("Workstation/TaskBoardMount") as Node3D
	var existing := mount.get_node_or_null("TaskBoard")
	if existing != null:
		return existing
	var node := TaskBoardScene.instantiate()
	mount.add_child(node)
	_attach_pick_proxy(node, Vector3(2.5, 1.5, 0.5), Vector3(0.0, 1.75, 0.0),
		"conc_task_board",
		"任务牌（conc_task_board）：显示当前任务与状态灯；状态由步记录派生，不另做状态机")
	_wire_help_context()
	return node


func install_nameplate():
	var mount := get_node("Workstation/NamePlateMount") as Node3D
	var existing := mount.get_node_or_null("Nameplate")
	if existing != null:
		return existing
	var node := NameplateScene.instantiate()
	mount.add_child(node)
	_attach_pick_proxy(node, Vector3(1.5, 1.5, 0.5), Vector3(0.0, 1.5, 0.0),
		"conc_nameplate",
		"角色铭牌（conc_nameplate）：mini codex 的身份牌——名字与角色，接线后任务牌认识它")
	return node


## 图表方块（conc_ops_chart，chart_ 展示方块）就位：工位旁的效率对比展柜。
## 幂等；懒加载——第一次喂图（refresh_ops_chart，flow 的 score 阶段）时落地。
func install_ops_chart():
	var ws := get_node("Workstation") as Node3D
	var existing := ws.get_node_or_null("OpsChart")
	if existing != null:
		return existing
	var node := OpsChartScene.instantiate()
	node.name = "OpsChart"
	node.position = CHART_POS
	node.rotation.y = CHART_YAW
	ws.add_child(node)
	return node


## flow 评分阶段的喂图回调：把两次 world.run 的实测 ops 交给图表（真实数据驱动，
## 非装饰）。图表是纯展示——喂图失败（ok=false）被丢弃，不影响过关判定
## （判定只看步记录，见 l1_flow._refresh_ops_chart 的同一条纪律）。
func refresh_ops_chart(bars: String) -> void:
	var chart = install_ops_chart()
	if chart != null and is_instance_valid(chart) and chart.has_method("set_param"):
		var _ok: bool = chart.set_param("bars", bars)


func get_ops_chart():
	return get_node_or_null("Workstation/OpsChart")


## 场景级失败入口：关卡尝试失败时调用（flow 侧 check_pass 失败的接入留给
## flow 任务——本方法是 flow 之外的场景级入口）。转调求助屏 report_fail，
## 返回本关累计失败次数。
func notify_attempt_failed() -> int:
	if _help == null:
		return 0
	return _help.report_fail()


func get_help_screen():
	return _help


func get_interaction_hub():
	return _hub


func get_task_board():
	return get_node_or_null("Workstation/TaskBoardMount/TaskBoard")


func get_nameplate():
	return get_node_or_null("Workstation/NamePlateMount/Nameplate")


func get_player_screen():
	return get_node_or_null("Workstation/PlayerScreen")


func board_front_pos() -> Vector3:
	return BOARD_FRONT


# ---------- 工位 ----------

func _add_workstation() -> void:
	var ws := Node3D.new()
	ws.name = "Workstation"
	add_child(ws)

	ws.add_child(_build_cart())

	var board_mount := Node3D.new()
	board_mount.name = "TaskBoardMount"
	board_mount.position = BOARD_MOUNT_POS
	board_mount.rotation.y = BOARD_MOUNT_YAW
	ws.add_child(board_mount)

	var plate_mount := Node3D.new()
	plate_mount.name = "NamePlateMount"
	plate_mount.position = PLATE_MOUNT_POS
	plate_mount.rotation.y = PLATE_MOUNT_YAW
	ws.add_child(plate_mount)

	var screen := PlayerBlockScene.instantiate()
	screen.name = "PlayerScreen"
	screen.position = SCREEN_POS
	screen.rotation.y = SCREEN_YAW
	ws.add_child(screen)


## codex 本体：一个可移动的方块小车（L1 不做精细造型；纯显示移动，不接物理）。
func _build_cart() -> Node3D:
	var cart := Node3D.new()
	cart.name = "CodexCart"
	cart.position = CODEX_START

	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.0, 0.5, 0.5)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.75, 0.0)   # 底=轮顶 0.5、顶=1.0（高度链不断）
	body_mesh.material = _mat(PALETTE[5], 0.5, 0.15)
	cart.add_child(body)

	# 舱盖（小一号叠上去，双层近似 Q 弹的圆角感）
	var cap := MeshInstance3D.new()
	cap.name = "Cap"
	var cap_mesh := BoxMesh.new()
	cap_mesh.size = Vector3(0.5, 0.5, 0.5)
	cap.mesh = cap_mesh
	cap.position = Vector3(0.0, 1.25, 0.0)   # 底=车顶 1.0
	cap_mesh.material = _mat(PALETTE[4], 0.5, 0.1)
	cart.add_child(cap)

	# 四轮（共享 mesh；R4 圆件方化：圆柱轮 → 0.5³ 方轮=一颗标准方块。
	# x=±0.25 两轮合盖车底全长 [-0.5,0.5]，z=±0.5 外挂车侧、与车身 z 面相接）
	var wheel_mesh := BoxMesh.new()
	wheel_mesh.size = Vector3.ONE * AssetNodeScript.STANDARD_CUBE_SIZE
	wheel_mesh.material = _mat(PALETTE[1], 0.8, 0.1)
	for wx in [-0.25, 0.25]:
		for wz in [-0.5, 0.5]:
			var wheel := MeshInstance3D.new()
			wheel.name = "Wheel"
			wheel.mesh = wheel_mesh
			wheel.position = Vector3(wx, 0.25, wz)
			cart.add_child(wheel)

	# 头灯（青色发光方灯，朝向任务牌那面；R4 球→0.25³，半嵌前脸）
	var lamp := MeshInstance3D.new()
	lamp.name = "HeadLamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.0, 0.75, -0.25)   # 嵌进前脸 0.125、凸出 0.125
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = PALETTE[6]
	lamp_mat.emission_enabled = true
	lamp_mat.emission = PALETTE[6]
	lamp_mat.emission_energy_multiplier = 1.6
	lamp_mesh.material = lamp_mat
	cart.add_child(lamp)

	_face_cart(cart, BOARD_MOUNT_POS)
	return cart


## 小车朝向任务牌（纯 yaw 计算，不依赖 look_at——后者要求节点已在树里）。
func _face_cart(cart: Node3D, _target: Vector3) -> void:
	var dir := BOARD_MOUNT_POS - cart.position
	if Vector2(dir.x, dir.z).length() > 0.05:
		# Node3D 前向是 -Z：yaw = atan2(-dx, -dz) 让 -Z 指向任务牌
		cart.rotation.y = atan2(-dir.x, -dir.z)


# ---------- 求助屏接线（docs/10-契约/交互方案.md §5.1） ----------

func _add_extras() -> void:
	var help := HelpScreenScene.instantiate()
	help.name = "HelpScreen"
	help.position = HELP_POS
	help.rotation.y = HELP_YAW
	help.level_id = "l1"
	help.concept_map = {"l1": "c10.1"}   # L2 诊断读 concepts.yaml 的 c10.1 fail 条目
	get_node("Workstation").add_child(help)   # 进树（_ready 建屏与服务）
	help.set_visitor(get_node("Workstation/CodexCart"))   # 感应对象=codex 小车
	help.request_highlight.connect(_on_request_highlight)
	_help = help
	_wire_help_context()   # 任务牌若已装则补锚点（正常时装动作在 flow 的 install 阶段）


## 任务牌装上后把求助屏的锚点指向它（问题组件名进 L1 文案、L3 气泡指任务牌）。
func _wire_help_context() -> void:
	if _help == null:
		return
	var board = get_task_board()
	if board != null:
		_help.set_problem_component(board)
		_help.set_task_board(board)


## 求助屏 request_highlight 的落地（屏不直接涂别家组件的材质——指令回调归场景）：
## 给目标的所有 MeshInstance3D 盖一层红色 material_override，highlight_seconds 后还原。
func _on_request_highlight(target: Node3D) -> void:
	_clear_highlight()
	if target == null or not is_instance_valid(target):
		return
	var red := StandardMaterial3D.new()
	red.albedo_color = HIGHLIGHT_RED
	red.emission_enabled = true
	red.emission = HIGHLIGHT_RED
	red.emission_energy_multiplier = 1.2
	for c in target.get_children():
		if c is MeshInstance3D:
			_highlight_overrides[c] = (c as MeshInstance3D).material_override
			(c as MeshInstance3D).material_override = red
	if highlight_seconds > 0.0:
		# connect 而非 await：场景被释放时连接自动断开，不会在尸体上还原
		get_tree().create_timer(highlight_seconds).timeout.connect(_clear_highlight)


func _clear_highlight() -> void:
	for mi in _highlight_overrides:
		if is_instance_valid(mi):
			(mi as MeshInstance3D).material_override = _highlight_overrides[mi]
	_highlight_overrides.clear()


# ---------- 交互 hub 接线（docs/10-契约/交互方案.md §二/§四） ----------

## setup 必须在任何输入到来之前完成（hub._unhandled_input 未 setup 会崩），
## 所以全部在 _ready 的同步段里做完。
func _add_interaction() -> void:
	# 场景级状态层：物理→逻辑单向上报的接收端（与 flow 的内核互不污染）。
	# 散块在这里登记成实体（touched 口），落定上报才有处可去。
	_state = WorldStateScript.new()
	_state.register_asset(ASSET_LOOSE_BLOCK, WorldStateScript.KIND_PARAMETRIC, {},
		[{"id": "touched", "kind": "BOOL", "dir": "in"}])
	_bridge = PhysicsBridgeScript.new(_state)
	_spawn_loose_blocks()

	_hub = HubScript.new()
	_hub.name = "InteractionHub"
	add_child(_hub)                      # 先进树（_ready 连手势信号、挂控制器子节点）
	_hub.setup(self, _orbit_cam, null)   # 再 setup；tools=null——run/打开的语义下面自己注入
	_hub.entity_of = Callable(self, "_entity_id_of")
	_hub.drag.landed_reporter = _bridge.report_contact   # 物理→逻辑单向上报（一次）
	_hub.open_view.code_provider = Callable(self, "_describe_target")
	_hub.run.run_start = Callable(self, "_on_run_started")
	_hub.run.run_stop = Callable(self, "_on_run_stopped")


## 散块：长按可搬的练习方块（真刚体——松手物理接管、落定上报一次后冻结）。
## 出生先冻结：体素甲板的碰撞体是异步流式的，就绪前解冻会穿过世界掉下去；
## 就绪后再解冻落上甲板（_settle_loose_blocks）。
func _spawn_loose_blocks() -> void:
	var ws := get_node("Workstation") as Node3D
	# 标准方块（STANDARD_CUBE_SIZE，0.5 m 正立方体，唯一尺寸来源；
	# 出生点 y = 甲板面 + 半块 0.25 → 出生即贴地，解冻即落上甲板、无悬空坠落）
	var block_mesh := BoxMesh.new()
	block_mesh.size = Vector3.ONE * AssetNodeScript.STANDARD_CUBE_SIZE
	block_mesh.material = _mat(PALETTE[5], 0.5, 0.15)
	for i in LOOSE_BLOCK_SPOTS.size():
		var spot: Vector3 = LOOSE_BLOCK_SPOTS[i]
		var body := RigidBody3D.new()
		body.name = "LooseBlock%d" % (i + 1)
		body.mass = 1.0
		body.freeze = true
		var pm := PhysicsMaterial.new()
		pm.friction = 0.9
		pm.bounce = 0.05
		body.physics_material_override = pm
		var cs := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3.ONE * AssetNodeScript.STANDARD_CUBE_SIZE
		cs.shape = shape
		body.add_child(cs)
		var mi := MeshInstance3D.new()
		mi.name = "Block"
		mi.mesh = block_mesh
		body.add_child(mi)
		body.position = spot
		var placed: Dictionary = _state.place(ASSET_LOOSE_BLOCK,
			[int(round(spot.x)), int(round(spot.y)), int(round(spot.z))])
		var eid := str(placed.get("entityId", ""))
		body.set_meta("entity_id", eid)
		body.set_meta("desc", "散块（%s）：长按搬起、松手落下——物理接管，落定只上报一次" % eid)
		ws.add_child(body)
	_settle_loose_blocks()


## 甲板碰撞体就绪后解冻散块（落到甲板面上；就绪前冻结在出生点，不下坠穿地）。
func _settle_loose_blocks() -> void:
	await wait_ready(900)
	for i in LOOSE_BLOCK_SPOTS.size():
		var body := get_node_or_null("Workstation/LooseBlock%d" % (i + 1)) as RigidBody3D
		if body != null and is_instance_valid(body):
			# Terrain can finish streaming after the learner has already grabbed a block.
			# That block's freeze is now owned by the drag controller, until release/cancel.
			if _hub != null and _hub.drag._body == body and _hub.drag.state() == _hub.drag.DragState.LIFTING:
				continue
			body.freeze = false


## 任务牌/铭牌本体是展示性 Node3D（无刚体），而交互系统的射线拾取只认
## RigidBody3D——挂一块冻结的透明拾取刚体（形状贴面板，无视觉、无行为）。
func _attach_pick_proxy(host: Node3D, box_size: Vector3, box_offset: Vector3,
		entity_id: String, desc: String) -> void:
	if host.get_node_or_null("PickProxy") != null:
		return
	var body := RigidBody3D.new()
	body.name = "PickProxy"
	body.freeze = true
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = box_size
	cs.shape = shape
	cs.position = box_offset
	body.add_child(cs)
	body.set_meta("entity_id", entity_id)
	body.set_meta("desc", desc)
	host.add_child(body)


## 点按打开的 code_provider：给任务牌/铭牌/散块一段简短描述文本。
func _describe_target(target: Node3D) -> String:
	if target != null and target.has_meta("desc"):
		return str(target.get_meta("desc"))
	return "%s：L1 工位的物件（点按查看）" % str(target.name)


## 空格 run_toggle 的语义注入：l1_flow 没有公开的跑/停翻转接口（stage_run 是
## 一次性阶段驱动），所以 run_start 接到场景层演示流程（_drive_visual_demo，
## 独立内核、不落盘）；run_stop 只翻状态（演示不可中断，窗口语义如需可后续加）。
func _on_run_started() -> void:
	run_drive_count += 1
	run_drive_toggled.emit(true)
	if space_runs_demo and not _demo_running:
		_demo_running = true
		_run_demo_once()


func _on_run_stopped() -> void:
	run_drive_count += 1
	run_drive_toggled.emit(false)


func _run_demo_once() -> void:
	await _drive_visual_demo(0.4)
	_demo_running = false
