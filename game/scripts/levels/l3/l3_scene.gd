extends "res://scripts/scene/level_scene_base.gd"

## L3 关卡场景（第 3 关端到端，同 l1_scene.gd 施工模式）。
## 主题（spec §9.1.1）："它记得住什么"——装上下文容器 + 记忆柜，配 E50 占位视频。
##
## 场景内容全部代码搭建（tscn 只挂根节点 + 脚本，同 bench/gen_scene.gd 模式）：
##   体素地面（复用 spike 的 terrain_generator）+ 明亮光影（抄 l1_scene.gd 定稿配方）
##   + 工位：codex 本体 = 一个可移动的方块小车（沿用 L1 造型）
##   + 上下文容器/记忆柜两个安装位（装上动作由 l3_flow 的 stage_install 驱动）
##   + 播放器方块（player_block.tscn，占位内容；标题换成本关的 "L3 · E50 占位视频"
##     ——实例级配置，不改共享组件文件）
##   + report.txt 石板（任务输入）与 out 格（任务 2 的交付格）
##
## 相机：第三人称慢速轨道（美术方向相机路线裁决）。
## 物理：本关没有刚体演算（小车/组件都是展示性移动，不接物理），体素碰撞体
## 照常生成，留给后续关卡接物理时再用。
##
## 入口：
##   窗口围观：godot --path game scenes/levels/l3/l3.tscn
##   窗口演示：… scenes/levels/l3/l3.tscn -- --demo（跑一遍完整流程的可视版，不落盘）
##   截图：    … scenes/levels/l3/l3.tscn -- --shot（出 game/tests/levels/l3/l3_preview.png 后退出）
##   流程判定：headless 走 tests/levels/l3/run_l3_tests.gd（l3_flow.gd 驱动）

const ContainerScene := preload("res://scenes/levels/l3/components/context_container.tscn")
const CabinetScene := preload("res://scenes/levels/l3/components/memory_cabinet.tscn")
const PlayerBlockScene := preload("res://scenes/blocks/player_block.tscn")
const L3FlowScript := preload("res://scripts/levels/l3/l3_flow.gd")
const EPISODE_TITLE := "L3 · E50 占位视频"
const OUT_SHOT := "res://tests/levels/l3/l3_preview.png"

# ---- 工位布局（全部落原点附近 13×13 甲板上）----
const CONTAINER_MOUNT_POS := Vector3(-2.0, DECK_TOP_Y, -0.5)
const CONTAINER_MOUNT_YAW := 0.0
const CABINET_MOUNT_POS := Vector3(-4.5, DECK_TOP_Y, -2.0)
const CABINET_MOUNT_YAW := 0.0
const SCREEN_POS := Vector3(4.5, DECK_TOP_Y, -1.5)
const SCREEN_YAW := 0.0
const REPORT_POS := Vector3(2.5, DECK_TOP_Y, -1.5)
const REPORT_YAW := 0.0
const OUT_POS := Vector3(0.5, DECK_TOP_Y, -2.5)
const OUT_YAW := 0.0
const CODEX_START := Vector3(2.5, DECK_TOP_Y, 3.5)
const CONTAINER_FRONT := Vector3(-0.5, DECK_TOP_Y, 0.5)   # 小车停在容器前
const CABINET_FRONT := Vector3(-3.0, DECK_TOP_Y, 0.5)     # 小车停在记忆柜前

# ---- 相机轨道 ----
const ORBIT_RADIUS := 15.0
const ORBIT_HEIGHT := DECK_TOP_Y + 6.5
const ORBIT_SPEED := 0.12             # rad/s，慢速环绕
const ORBIT_LOOK_AT := Vector3(-0.5, DECK_TOP_Y + 1.5, 0.0)

# ---------- 基座覆写点 ----------

func _init() -> void:
	orbit_radius = ORBIT_RADIUS
	orbit_height = ORBIT_HEIGHT
	orbit_speed = ORBIT_SPEED
	orbit_look_at = ORBIT_LOOK_AT


func _level_label() -> String:
	return "L3"


func _shot_path() -> String:
	return OUT_SHOT


func _demo_pause() -> float:
	return 1.0   # 原 _run_mode_demo 的 1.0


func _shot_pause() -> float:
	return 0.2   # 原 _run_mode_shot 的 0.2
var _out_label: Label3D
var _out_cube_mat: StandardMaterial3D


## 可视演示：用独立内核（own_* 注入，不碰共享 autoload）跑五阶段，不 end_run 不落盘。
func _drive_visual_demo(pause_s: float) -> void:
	var flow := L3FlowScript.new()
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


# ---------- 对外（给 l3_flow / 测试用） ----------

func install_context_container():
	var mount := get_node("Workstation/ContextContainerMount") as Node3D
	var existing := mount.get_node_or_null("ContextContainer")
	if existing != null:
		return existing
	var node := ContainerScene.instantiate()
	mount.add_child(node)
	return node


func install_memory_cabinet():
	var mount := get_node("Workstation/MemoryCabinetMount") as Node3D
	var existing := mount.get_node_or_null("MemoryCabinet")
	if existing != null:
		return existing
	var node := CabinetScene.instantiate()
	mount.add_child(node)
	return node


func get_context_container():
	return get_node_or_null("Workstation/ContextContainerMount/ContextContainer")


func get_memory_cabinet():
	return get_node_or_null("Workstation/MemoryCabinetMount/MemoryCabinet")


func get_player_screen():
	return get_node_or_null("Workstation/PlayerScreen")


func container_front_pos() -> Vector3:
	return CONTAINER_FRONT


func cabinet_front_pos() -> Vector3:
	return CABINET_FRONT


## out 格显示写入值（任务 2 的交付格：数值亮起）。
func set_out_value(value: int) -> void:
	if _out_label != null:
		_out_label.text = "out 格：%d" % value
	if _out_cube_mat != null:
		_out_cube_mat.emission_energy_multiplier = 1.4


## 小车走到目标位（带一点 Q 弹小跳）。逐帧插值，纯显示，不接物理。
# ---------- 工位 ----------

func _add_workstation() -> void:
	var ws := Node3D.new()
	ws.name = "Workstation"
	add_child(ws)

	ws.add_child(_build_cart())

	var container_mount := Node3D.new()
	container_mount.name = "ContextContainerMount"
	container_mount.position = CONTAINER_MOUNT_POS
	container_mount.rotation.y = CONTAINER_MOUNT_YAW
	ws.add_child(container_mount)

	var cabinet_mount := Node3D.new()
	cabinet_mount.name = "MemoryCabinetMount"
	cabinet_mount.position = CABINET_MOUNT_POS
	cabinet_mount.rotation.y = CABINET_MOUNT_YAW
	ws.add_child(cabinet_mount)

	var screen := PlayerBlockScene.instantiate()
	screen.name = "PlayerScreen"
	screen.position = SCREEN_POS
	screen.rotation.y = SCREEN_YAW
	ws.add_child(screen)
	# player_block 的占位标题是 L1·E49 常量；本关换成 E50（实例级配置，不改共享组件）
	var screen_label := screen.get_node_or_null("ScreenLabel") as Label3D
	if screen_label != null:
		screen_label.text = EPISODE_TITLE

	ws.add_child(_build_report_slab())
	ws.add_child(_build_out_cell())


## report.txt 石板（家族二"文本"方块的世界形态：任务输入摆在工位旁）。
func _build_report_slab() -> Node3D:
	var slab := Node3D.new()
	slab.name = "ReportSlab"
	slab.position = REPORT_POS
	slab.rotation.y = REPORT_YAW

	var pedestal := MeshInstance3D.new()
	pedestal.name = "Pedestal"
	var ped_mesh := BoxMesh.new()
	ped_mesh.size = Vector3(1.0, 0.5, 0.5)
	ped_mesh.material = _mat(PALETTE[3], 0.6, 0.25)
	pedestal.mesh = ped_mesh
	pedestal.position = Vector3(0.0, 0.25, 0.0)   # 高度链：底 0.0 + 半高 0.25，顶到 0.5
	slab.add_child(pedestal)

	var plate := MeshInstance3D.new()
	plate.name = "Plate"
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(1.0, 1.0, 0.25)   # v2：薄板升 0.25 厚（半块工艺件）
	plate_mesh.material = _mat(PALETTE[4], 0.55, 0.1)
	plate.mesh = plate_mesh
	plate.position = Vector3(0.0, 1.0, 0.0)   # 基座顶 0.5 + 板半高 0.5；厚 0.25 全嵌进基座 z 向（±0.125）
	slab.add_child(plate)

	var label := Label3D.new()
	label.name = "FileLabel"
	label.text = "report.txt"
	label.position = Vector3(0.0, 1.35, 0.14)   # Label3D 豁免；贴板前面 z=0.125 + 0.015 防 z-fight
	label.font_size = 44
	label.pixel_size = 0.0028
	label.modulate = Color(0.30, 0.26, 0.22)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.double_sided = false
	slab.add_child(label)

	var body := Label3D.new()
	body.name = "FileBody"
	body.text = "第 3 行：错误 缺少分号\n第 7 行：错误 越界访问\n第 9 行：错误 重复定义"
	body.position = Vector3(0.0, 0.98, 0.14)   # Label3D 豁免；贴板前面 z=0.125 + 0.015 防 z-fight
	body.font_size = 26
	body.pixel_size = 0.0022
	body.modulate = Color(0.22, 0.27, 0.35)
	body.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	body.double_sided = false
	slab.add_child(body)
	return slab


## out 格（任务 2 的交付格：凹槽 + 数值方块，写入后亮起）。
func _build_out_cell() -> Node3D:
	var cell := Node3D.new()
	cell.name = "OutCell"
	cell.position = OUT_POS
	cell.rotation.y = OUT_YAW

	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.0, 0.5, 1.0)
	base_mesh.material = _mat(PALETTE[3], 0.6, 0.25)
	base.mesh = base_mesh
	base.position = Vector3(0.0, 0.25, 0.0)   # 高度链：底 0.0 + 半高 0.25，顶到 0.5
	cell.add_child(base)

	var back := MeshInstance3D.new()
	back.name = "Back"
	var back_mesh := BoxMesh.new()
	back_mesh.size = Vector3(1.0, 0.5, 0.5)
	back_mesh.material = _mat(PALETTE[2], 0.6, 0.2)
	back.mesh = back_mesh
	back.position = Vector3(0.0, 0.75, -0.25)   # Base 顶 0.5 + 板半高 0.25；z 贴 Base 后缘（-0.5+0.25）
	cell.add_child(back)

	var cube := MeshInstance3D.new()
	cube.name = "ValueCube"
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3.ONE * AssetNodeScript.STANDARD_CUBE_SIZE   # token 方块 = 标准方块（唯一尺寸来源）
	_out_cube_mat = StandardMaterial3D.new()
	_out_cube_mat.albedo_color = PALETTE[6]
	_out_cube_mat.emission_enabled = true
	_out_cube_mat.emission = PALETTE[6]
	_out_cube_mat.emission_energy_multiplier = 0.0   # 写入后亮起
	cube_mesh.material = _out_cube_mat
	cube.mesh = cube_mesh
	cube.position = Vector3(0.0, 0.75, 0.0)   # Base 顶 0.5 + 半块 0.25
	cell.add_child(cube)

	_out_label = Label3D.new()
	_out_label.name = "OutLabel"
	_out_label.text = "out 格：—"
	_out_label.position = Vector3(0.0, 1.02, 0.0)
	_out_label.font_size = 44
	_out_label.pixel_size = 0.0028
	_out_label.modulate = Color(0.30, 0.26, 0.22)
	_out_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_out_label.double_sided = false
	cell.add_child(_out_label)
	return cell


## codex 本体：一个可移动的方块小车（沿用 L1 造型；纯显示移动，不接物理）。
func _build_cart() -> Node3D:
	var cart := Node3D.new()
	cart.name = "CodexCart"
	cart.position = CODEX_START

	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.0, 0.5, 0.5)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.75, 0.0)   # 高度链：轮顶 0.5 + 半高 0.25（v2 与 L1 统一值）
	body_mesh.material = _mat(PALETTE[5], 0.5, 0.15)
	cart.add_child(body)

	# 舱盖（小一号叠上去，双层近似 Q 弹的圆角感）
	var cap := MeshInstance3D.new()
	cap.name = "Cap"
	var cap_mesh := BoxMesh.new()
	cap_mesh.size = Vector3(0.5, 0.5, 0.5)
	cap.mesh = cap_mesh
	cap.position = Vector3(0.0, 1.25, 0.0)   # Body 顶 1.0 + 半高 0.25
	cap_mesh.material = _mat(PALETTE[4], 0.5, 0.1)
	cart.add_child(cap)

	# 四轮（共享 mesh；v2 方轮化：0.5³ 标准方块，轮心落半块格，轮底触地）
	var wheel_mesh := BoxMesh.new()
	wheel_mesh.size = Vector3.ONE * 0.5
	wheel_mesh.material = _mat(PALETTE[1], 0.8, 0.1)
	for wx in [-0.25, 0.25]:
		for wz in [-0.5, 0.5]:
			var wheel := MeshInstance3D.new()
			wheel.name = "Wheel"
			wheel.mesh = wheel_mesh
			wheel.position = Vector3(wx, 0.25, wz)   # 轮心 y=0.25：0.25³ 链底，轮顶 0.5 托住 Body
			cart.add_child(wheel)

	# 头灯（v2 方灯：0.25³ 半嵌进车头，前脸凸出 0.125）
	var lamp := MeshInstance3D.new()
	lamp.name = "HeadLamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.0, 0.75, -0.25)   # 半嵌 Body（y 0.5..1.0），前脸 -0.25 凸出至 -0.375
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = PALETTE[6]
	lamp_mat.emission_enabled = true
	lamp_mat.emission = PALETTE[6]
	lamp_mat.emission_energy_multiplier = 1.6
	lamp_mesh.material = lamp_mat
	cart.add_child(lamp)

	_face_cart(cart, ORBIT_LOOK_AT)
	return cart


## 小车朝向工位中心（纯 yaw 计算，不依赖 look_at——后者要求节点已在树里）。
func _face_cart(cart: Node3D, _target: Vector3) -> void:
	var dir := ORBIT_LOOK_AT - cart.position
	if Vector2(dir.x, dir.z).length() > 0.05:
		# Node3D 前向是 -Z：yaw = atan2(-dx, -dz) 让 -Z 指向工位
		cart.rotation.y = snappedf(atan2(-dir.x, -dir.z), PI * 0.5)

