extends "res://scripts/scene/level_scene_base.gd"

## L4 关卡场景（照抄 l1_scene.gd 施工模式）。
## 主题（spec §9.1.1）："它怎么想、怎么决定"——装 思考机 + 计划板 + 工具带，
## 配 E40 占位视频。
##
## 场景内容全部代码搭建（tscn 只挂根节点 + 脚本，同 gen_l4_scenes.gd 模式）：
##   体素地面（复用 spike 的 terrain_generator）+ 明亮光影（抄 bench_world.gd 定稿配方）
##   + 工位：codex 本体 = 可移动方块小车（沿用 L1 造型）
##   + 思考机/计划板/工具带三个安装位（装上动作由 l4_flow 的 stage_install 驱动）
##   + 工具墙（工具带挂的那面墙）+ 播放器方块（E40 占位内容）
##
## 相机：第三人称慢速轨道。物理：本关无刚体演算（展示性移动），
## 体素碰撞体照常生成，留给后续关卡接物理时再用。
##
## 入口：
##   窗口围观：godot --path game scenes/levels/l4/l4.tscn
##   窗口演示：… scenes/levels/l4/l4.tscn -- --demo（跑一遍完整流程的可视版，不落盘）
##   截图：    … scenes/levels/l4/l4.tscn -- --shot（出 game/tests/levels/l4/l4_preview.png 后退出）
##   流程判定：headless 走 tests/levels/l4/run_l4_tests.gd（l4_flow.gd 驱动）

const ThinkerScene := preload("res://scenes/levels/l4/components/thinker.tscn")
const PlanBoardScene := preload("res://scenes/levels/l4/components/plan_board.tscn")
const ToolBeltScene := preload("res://scenes/levels/l4/components/tool_belt.tscn")
const E40ScreenScene := preload("res://scenes/levels/l4/components/e40_screen.tscn")
const L4FlowScript := preload("res://scripts/levels/l4/l4_flow.gd")

const OUT_SHOT := "res://tests/levels/l4/l4_preview.png"

# ---- 工位布局（全部落原点附近 13×13 甲板上）----
const THINKER_MOUNT_POS := Vector3(-3.0, DECK_TOP_Y, -0.5)
const THINKER_MOUNT_YAW := 0.0
const PLAN_MOUNT_POS := Vector3(2.5, DECK_TOP_Y, -2.0)
const PLAN_MOUNT_YAW := 0.0
const BELT_MOUNT_POS := Vector3(0.0, DECK_TOP_Y, -4.5)     # 挂在工具墙上（ToolWall 同点位复用）
const SCREEN_POS := Vector3(5.0, DECK_TOP_Y, -0.5)
const SCREEN_YAW := 0.0
const CODEX_START := Vector3(1.5, DECK_TOP_Y, 3.5)
const THINKER_FRONT := Vector3(-1.5, DECK_TOP_Y, 0.9)      # 小车停在思考机前

# ---- 相机轨道 ----
const ORBIT_RADIUS := 15.5
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
	return "L4"


func _shot_path() -> String:
	return OUT_SHOT


func _demo_pause() -> float:
	return 1.2   # 原 _run_mode_demo 的 1.2
## 可视演示：用独立内核（own_* 注入，不碰共享 autoload）跑五阶段，不 end_run 不落盘。
func _drive_visual_demo(pause_s: float) -> void:
	var flow := L4FlowScript.new()
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


# ---------- 对外（给 l4_flow / 测试用） ----------

func install_thinker():
	var mount := get_node("Workstation/ThinkerMount") as Node3D
	var existing := mount.get_node_or_null("Thinker")
	if existing != null:
		return existing
	var node := ThinkerScene.instantiate()
	mount.add_child(node)
	return node


func install_plan_board():
	var mount := get_node("Workstation/PlanBoardMount") as Node3D
	var existing := mount.get_node_or_null("PlanBoard")
	if existing != null:
		return existing
	var node := PlanBoardScene.instantiate()
	mount.add_child(node)
	return node


func install_tool_belt():
	var mount := get_node("Workstation/ToolBeltMount") as Node3D
	var existing := mount.get_node_or_null("ToolBelt")
	if existing != null:
		return existing
	var node := ToolBeltScene.instantiate()
	mount.add_child(node)
	return node


func get_thinker():
	return get_node_or_null("Workstation/ThinkerMount/Thinker")


func get_plan_board():
	return get_node_or_null("Workstation/PlanBoardMount/PlanBoard")


func get_tool_belt():
	return get_node_or_null("Workstation/ToolBeltMount/ToolBelt")


func get_player_screen():
	return get_node_or_null("Workstation/PlayerScreen")


func thinker_front_pos() -> Vector3:
	return THINKER_FRONT


## 小车走到目标位（带一点 Q 弹小跳）。逐帧插值，纯显示，不接物理。
# ---------- 工位 ----------

func _add_workstation() -> void:
	var ws := Node3D.new()
	ws.name = "Workstation"
	add_child(ws)

	ws.add_child(_build_cart())
	ws.add_child(_build_tool_wall())

	var thinker_mount := Node3D.new()
	thinker_mount.name = "ThinkerMount"
	thinker_mount.position = THINKER_MOUNT_POS
	thinker_mount.rotation.y = THINKER_MOUNT_YAW
	ws.add_child(thinker_mount)

	var plan_mount := Node3D.new()
	plan_mount.name = "PlanBoardMount"
	plan_mount.position = PLAN_MOUNT_POS
	plan_mount.rotation.y = PLAN_MOUNT_YAW
	ws.add_child(plan_mount)

	var belt_mount := Node3D.new()
	belt_mount.name = "ToolBeltMount"
	belt_mount.position = BELT_MOUNT_POS
	ws.add_child(belt_mount)

	var screen := E40ScreenScene.instantiate()
	screen.name = "PlayerScreen"
	screen.position = SCREEN_POS
	screen.rotation.y = SCREEN_YAW
	ws.add_child(screen)


## 工具墙：工具带挂的那面矮墙（墙板造型在 tool_belt.gd 里，这里给安放的基座）。
func _build_tool_wall() -> Node3D:
	var wall := Node3D.new()
	wall.name = "ToolWall"
	wall.position = BELT_MOUNT_POS

	var base := MeshInstance3D.new()
	base.name = "WallBase"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(3.5, 0.5, 0.5)
	base.mesh = base_mesh
	base.position = Vector3(0.0, 0.25, 0.25)
	base_mesh.material = _mat(PALETTE[3], 0.65, 0.15)
	wall.add_child(base)
	return wall


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
	body.position = Vector3(0.0, 0.75, 0.0)
	body_mesh.material = _mat(PALETTE[5], 0.5, 0.15)
	cart.add_child(body)

	# 舱盖（小一号叠上去，双层近似 Q 弹的圆角感）
	var cap := MeshInstance3D.new()
	cap.name = "Cap"
	var cap_mesh := BoxMesh.new()
	cap_mesh.size = Vector3(0.5, 0.5, 0.5)
	cap.mesh = cap_mesh
	cap.position = Vector3(0.0, 1.25, 0.0)
	cap_mesh.material = _mat(PALETTE[4], 0.5, 0.1)
	cart.add_child(cap)

	# 四轮（方轮 0.5³，与车身同贴块状化 v2 口径；共享 mesh）
	var wheel_mesh := BoxMesh.new()
	wheel_mesh.size = Vector3(0.5, 0.5, 0.5)
	wheel_mesh.material = _mat(PALETTE[1], 0.8, 0.1)
	for wx in [-0.25, 0.25]:
		for wz in [-0.5, 0.5]:
			var wheel := MeshInstance3D.new()
			wheel.name = "Wheel"
			wheel.mesh = wheel_mesh
			wheel.position = Vector3(wx, 0.25, wz)
			cart.add_child(wheel)

	# 头灯（青色发光 0.25³ 方灯，半嵌在车头面，朝向思考机那面）
	var lamp := MeshInstance3D.new()
	lamp.name = "HeadLamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.0, 0.75, -0.25)
	var lamp_mat := StandardMaterial3D.new()
	lamp_mat.albedo_color = PALETTE[6]
	lamp_mat.emission_enabled = true
	lamp_mat.emission = PALETTE[6]
	lamp_mat.emission_energy_multiplier = 1.6
	lamp_mesh.material = lamp_mat
	cart.add_child(lamp)

	_face_cart(cart, THINKER_MOUNT_POS)
	return cart


## 小车朝向思考机（纯 yaw 计算，不依赖 look_at——后者要求节点已在树里）。
func _face_cart(cart: Node3D, _target: Vector3) -> void:
	var dir := THINKER_MOUNT_POS - cart.position
	if Vector2(dir.x, dir.z).length() > 0.05:
		# Node3D 前向是 -Z：yaw = atan2(-dx, -dz) 让 -Z 指向思考机
		cart.rotation.y = snappedf(atan2(-dir.x, -dir.z), PI * 0.5)

