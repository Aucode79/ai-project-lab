extends "res://scripts/scene/level_scene_base.gd"

## L2 关卡场景（spec §9.1.1 第 2 关："它怎么读、怎么写"）。
## 装上 文件柜 + 扫描器 + 机械臂 三件组件，配 E51 占位视频。
##
## 场景内容全部代码搭建（tscn 只挂根节点 + 脚本，同 bench/gen_scene.gd 模式）：
##   体素地面（复用 spike 的 terrain_generator）+ 明亮光影（抄 bench_world.gd 定稿配方）
##   + 工位：codex 本体 = 可移动方块小车（车顶挂工具头指示，切换可见）
##   + 文件柜/扫描器/机械臂三个安装位 + 工作台（机械臂抓方块的地方）
##   + 播放器方块（player_block.tscn，占位内容）
##
## 相机：第三人称慢速轨道（美术方向相机路线裁决，抄 L1）。
## 物理：本关没有刚体演算（小车/组件都是展示性移动，不接物理），与 L1 同：
##   体素碰撞体照常生成（generate_collisions），物理就绪门纪律抄 bench
##   （wait_ready 等流式地形就绪才开演示）。
##
## 入口：
##   窗口围观：godot --path game scenes/levels/l2/l2.tscn
##   窗口演示：… scenes/levels/l2/l2.tscn -- --demo（跑一遍完整流程的可视版，不落盘）
##   截图：    … scenes/levels/l2/l2.tscn -- --shot（出 game/tests/levels/l2/l2_preview.png 后退出）
##   流程判定：headless 走 tests/levels/l2/run_l2_tests.gd（l2_flow.gd 驱动）

const CabinetScene := preload("res://scenes/levels/l2/components/file_cabinet.tscn")
const ScannerScene := preload("res://scenes/levels/l2/components/scanner.tscn")
const ArmScene := preload("res://scenes/levels/l2/components/arm.tscn")
const PlayerBlockScene := preload("res://scenes/blocks/player_block.tscn")
const L2FlowScript := preload("res://scripts/levels/l2/l2_flow.gd")
const OUT_SHOT := "res://tests/levels/l2/l2_preview.png"

# ---- 工位布局（全部落原点附近 13×13 甲板上）----
const CABINET_MOUNT_POS := Vector3(-2.5, DECK_TOP_Y, -1.0)
const CABINET_MOUNT_YAW := 0.0
const SCANNER_MOUNT_POS := Vector3(0.0, DECK_TOP_Y, -3.0)
const SCANNER_MOUNT_YAW := 0.0
const ARM_MOUNT_POS := Vector3(1.5, DECK_TOP_Y, -2.5)
const ARM_MOUNT_YAW := 0.0
const WORKBENCH_POS := Vector3(1.5, DECK_TOP_Y, -4.5)
const WORKBENCH_YAW := 0.0
const SCREEN_POS := Vector3(4.5, DECK_TOP_Y, -1.5)
const SCREEN_YAW := 0.0
const CODEX_START := Vector3(2.5, DECK_TOP_Y, 3.5)
const SCANNER_FRONT := Vector3(0.0, DECK_TOP_Y, -1.5)    # 小车停在扫描器前
const ARM_FRONT := Vector3(1.5, DECK_TOP_Y, -1.5)        # 小车停在机械臂前

# ---- 相机轨道 ----
const ORBIT_RADIUS := 16.0
const ORBIT_HEIGHT := DECK_TOP_Y + 6.5
const ORBIT_SPEED := 0.12             # rad/s，慢速环绕
const ORBIT_LOOK_AT := Vector3(0.0, DECK_TOP_Y + 1.5, -0.5)

# ---------- 基座覆写点 ----------

func _init() -> void:
	orbit_radius = ORBIT_RADIUS
	orbit_height = ORBIT_HEIGHT
	orbit_speed = ORBIT_SPEED
	orbit_look_at = ORBIT_LOOK_AT


func _level_label() -> String:
	return "L2"


func _shot_path() -> String:
	return OUT_SHOT


func _shot_pause() -> float:
	return 0.15   # L2 截图节奏比其余关快（原 _run_mode_shot 的 0.15）
## 可视演示：用独立内核（own_* 注入，不碰共享 autoload）跑五阶段，不 end_run 不落盘。
## slow_step_seconds 用 mini-codex §2.3 的默认 0.6 秒/步（shot 模式可调快）。
func _drive_visual_demo(slow_step := 0.6) -> void:
	var flow := L2FlowScript.new()
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	var tools := WorldToolsCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	flow.tools = tools
	flow.view = self
	flow.slow_step_seconds = slow_step
	add_child(flow)
	flow.setup_world()
	flow.begin()
	await flow.stage_video()
	await flow.stage_install()
	await flow.stage_run()
	await flow.stage_tune()
	flow.stage_score()


# ---------- 对外（给 l2_flow / 测试用） ----------

func install_file_cabinet():
	var mount := get_node("Workstation/CabinetMount") as Node3D
	var existing := mount.get_node_or_null("FileCabinet")
	if existing != null:
		return existing
	var node := CabinetScene.instantiate()
	mount.add_child(node)
	return node


func install_scanner():
	var mount := get_node("Workstation/ScannerMount") as Node3D
	var existing := mount.get_node_or_null("ScannerHead")
	if existing != null:
		return existing
	var node := ScannerScene.instantiate()
	mount.add_child(node)
	return node


func install_arm():
	var mount := get_node("Workstation/ArmMount") as Node3D
	var existing := mount.get_node_or_null("MechanicalArm")
	if existing != null:
		return existing
	var node := ArmScene.instantiate()
	mount.add_child(node)
	return node


func get_file_cabinet():
	return get_node_or_null("Workstation/CabinetMount/FileCabinet")


func get_scanner():
	return get_node_or_null("Workstation/ScannerMount/ScannerHead")


func get_arm():
	return get_node_or_null("Workstation/ArmMount/MechanicalArm")


func get_player_screen():
	return get_node_or_null("Workstation/PlayerScreen")


## 占位幕布换 L2 标题（player_block 的标题是 L1 常量，实例上覆写文本即可）。
func set_screen_title(title: String) -> void:
	var screen: Node = get_player_screen()
	if screen == null:
		return
	var label := screen.get_node_or_null("ScreenLabel") as Label3D
	if label != null:
		label.text = title


func scanner_front_pos() -> Vector3:
	return SCANNER_FRONT


func arm_front_pos() -> Vector3:
	return ARM_FRONT


## 工具头切换可见（mini-codex §2.3）：小车顶的指示头换成当前那只。
func set_tool_head(head_name: String) -> void:
	var cart := get_node_or_null("Workstation/CodexCart")
	if cart == null:
		return
	var mini_scanner := cart.get_node_or_null("HeadMount/MiniScannerHead")
	var mini_arm := cart.get_node_or_null("HeadMount/MiniArmHead")
	if mini_scanner != null:
		mini_scanner.visible = head_name == "scanner"
	if mini_arm != null:
		mini_arm.visible = head_name == "arm"


## 小车走到目标位（带一点 Q 弹小跳）。逐帧插值，纯显示，不接物理。
# ---------- 工位 ----------

func _add_workstation() -> void:
	var ws := Node3D.new()
	ws.name = "Workstation"
	add_child(ws)

	ws.add_child(_build_cart())
	ws.add_child(_build_workbench())

	var cabinet_mount := Node3D.new()
	cabinet_mount.name = "CabinetMount"
	cabinet_mount.position = CABINET_MOUNT_POS
	cabinet_mount.rotation.y = CABINET_MOUNT_YAW
	ws.add_child(cabinet_mount)

	var scanner_mount := Node3D.new()
	scanner_mount.name = "ScannerMount"
	scanner_mount.position = SCANNER_MOUNT_POS
	scanner_mount.rotation.y = SCANNER_MOUNT_YAW
	ws.add_child(scanner_mount)

	var arm_mount := Node3D.new()
	arm_mount.name = "ArmMount"
	arm_mount.position = ARM_MOUNT_POS
	arm_mount.rotation.y = ARM_MOUNT_YAW
	ws.add_child(arm_mount)

	var screen := PlayerBlockScene.instantiate()
	screen.name = "PlayerScreen"
	screen.position = SCREEN_POS
	screen.rotation.y = SCREEN_YAW
	ws.add_child(screen)


## codex 本体：一个可移动的方块小车（L2 不做精细造型；纯显示移动，不接物理）。
## 车顶 HeadMount 挂两只迷你工具头（扫描盘 / 夹爪），set_tool_head 切换可见。
func _build_cart() -> Node3D:
	var cart := Node3D.new()
	cart.name = "CodexCart"
	cart.position = CODEX_START

	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.0, 0.5, 0.5)
	body.mesh = body_mesh
	# 高度链（与 L1 统一值）：底=轮顶 0.5、顶=1.0
	body.position = Vector3(0.0, 0.75, 0.0)
	body_mesh.material = _mat(PALETTE[5], 0.5, 0.15)
	cart.add_child(body)

	# 舱盖（小一号叠上去，双层近似 Q 弹的圆角感）
	var cap := MeshInstance3D.new()
	cap.name = "Cap"
	var cap_mesh := BoxMesh.new()
	cap_mesh.size = Vector3(0.5, 0.5, 0.5)
	cap.mesh = cap_mesh
	cap.position = Vector3(0.0, 1.25, 0.0)   # 底=车顶 1.0、顶=1.5
	cap_mesh.material = _mat(PALETTE[4], 0.5, 0.1)
	cart.add_child(cap)

	# 四轮（共享 mesh；R4 圆件方化：圆柱轮 → 0.5³ 方轮=一颗标准方块，与 L1 统一。
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

	# 头灯（青色发光方灯，朝前；R4 球→0.25³，半嵌前脸 z=-0.25）
	var lamp := MeshInstance3D.new()
	lamp.name = "HeadLamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.0, 0.75, -0.25)
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = PALETTE[6]
	lamp_mat.emission_enabled = true
	lamp_mat.emission = PALETTE[6]
	lamp_mat.emission_energy_multiplier = 1.6
	lamp_mesh.material = lamp_mat
	cart.add_child(lamp)

	# 工具头安装座 + 两只迷你头（切换可见）。随车顶链抬到 1.25（舱盖心），
	# z=-0.25 落在前脸格线上：两只 0.25³ 迷你头半嵌舱盖前脸、露出 0.125 示意。
	var head_mount := Node3D.new()
	head_mount.name = "HeadMount"
	head_mount.position = Vector3(0.0, 1.25, -0.25)
	cart.add_child(head_mount)

	var mini_scanner := Node3D.new()
	mini_scanner.name = "MiniScannerHead"
	var dish := MeshInstance3D.new()
	var dish_mesh := BoxMesh.new()
	dish_mesh.size = Vector3.ONE * 0.25   # R4 圆盘→方盘（迷你指示 0.25³）
	dish.mesh = dish_mesh
	var dish_mat := StandardMaterial3D.new()
	dish_mat.albedo_color = PALETTE[6]
	dish_mat.emission_enabled = true
	dish_mat.emission = PALETTE[6]
	dish_mat.emission_energy_multiplier = 1.2
	dish_mesh.material = dish_mat
	mini_scanner.add_child(dish)
	mini_scanner.visible = false
	head_mount.add_child(mini_scanner)

	var mini_arm := Node3D.new()
	mini_arm.name = "MiniArmHead"
	var claw := MeshInstance3D.new()
	var claw_mesh := BoxMesh.new()
	claw_mesh.size = Vector3.ONE * 0.25   # 迷你夹爪指示 0.25³
	claw.mesh = claw_mesh
	var claw_mat := StandardMaterial3D.new()
	claw_mat.albedo_color = PALETTE[5]
	claw_mat.emission_enabled = true
	claw_mat.emission = PALETTE[5]
	claw_mat.emission_energy_multiplier = 0.9
	claw_mesh.material = claw_mat
	mini_arm.add_child(claw)
	mini_arm.visible = false
	head_mount.add_child(mini_arm)

	_face_cart(cart, CABINET_MOUNT_POS)
	return cart


## 工作台：机械臂从这里抓方块（mini-codex §2.3"从工作台抓一块方块"）。
func _build_workbench() -> Node3D:
	var bench := Node3D.new()
	bench.name = "Workbench"
	bench.position = WORKBENCH_POS
	bench.rotation.y = WORKBENCH_YAW

	var top := MeshInstance3D.new()
	top.name = "Top"
	var top_mesh := BoxMesh.new()
	top_mesh.size = Vector3(1.5, 0.5, 1.0)
	top.mesh = top_mesh
	# y 0.75 = 腿高 0.5（顶 0.5）+ 板半厚 0.25 → 台面顶 = 1.0
	top.position = Vector3(0.0, 0.75, 0.0)
	top_mesh.material = _mat(PALETTE[3], 0.6, 0.2)
	bench.add_child(top)

	for leg_x in [-0.5, 0.5]:
		for leg_z in [-0.25, 0.25]:
			var leg := MeshInstance3D.new()
			leg.name = "Leg"
			var leg_mesh := BoxMesh.new()
			leg_mesh.size = Vector3(0.1, 0.5, 0.1)
			leg.mesh = leg_mesh
			leg.position = Vector3(leg_x, 0.25, leg_z)
			leg_mesh.material = _mat(PALETTE[3], 0.7, 0.2)
			bench.add_child(leg)

	# 两块待抓的方块（一暖橙一饱和青：对应新增/修改两种落点标记色）
	# 标准方块：STANDARD_CUBE_SIZE（0.5 m 正立方体，唯一尺寸来源）。
	# 落位：腿高 0.5（顶 0.5）+ 台面板厚 0.5（中心 0.75，顶 1.0），
	# 方块半边 0.25 → 中心 y = 1.25，底面贴台面不悬空；
	# 台面宽 1.5，两块并排 x = ±0.5（外缘 ±0.75 与台边平齐；
	# 块间净距 0.5，不重叠不悬出）。
	var block_colors := [PALETTE[5], PALETTE[7]]
	for i in 2:
		var block := MeshInstance3D.new()
		block.name = "SpareBlock%d" % i
		var block_mesh := BoxMesh.new()
		block_mesh.size = Vector3.ONE * AssetNodeScript.STANDARD_CUBE_SIZE
		block.mesh = block_mesh
		block.position = Vector3(-0.5 + 1.0 * i, 1.25, 0.0)
		block_mesh.material = _mat(block_colors[i], 0.4, 0.1)
		bench.add_child(block)

	return bench


## 小车朝向目标（纯 yaw 计算，不依赖 look_at——后者要求节点已在树里）。
func _face_cart(cart: Node3D, target: Vector3) -> void:
	var dir := target - cart.position
	if Vector2(dir.x, dir.z).length() > 0.05:
		# Node3D 前向是 -Z：yaw = atan2(-dx, -dz) 让 -Z 指向目标
		cart.rotation.y = snappedf(atan2(-dir.x, -dir.z), PI * 0.5)

