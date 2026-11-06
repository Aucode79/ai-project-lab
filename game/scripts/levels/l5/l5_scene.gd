extends "res://scripts/scene/level_scene_base.gd"

## L5 关卡场景（五关终点关；施工模式照抄 l1_scene.gd）。
## 主题（spec §9.1.1）："它怎么跑完、怎么不错"——装回廊 + 执行器 + 校验门 +
## 旁路四件，配 E60 占位视频；同时摆出 L1–L4 十件的占位区（小方块 + 名牌，
## 显式决定：本关不复刻前四关行为，完整版在前四关场景里）。
##
## 场景内容全部代码搭建（tscn 只挂根节点 + 脚本，同 gen_l1_scenes.gd 模式）：
##   体素地面（复用 spike 的 terrain_generator）+ 明亮光影（抄 bench_world.gd 定稿配方）
##   + 工位：codex 本体方块小车 + 四安装位 + 十件占位摆放区（StubZone）
##   + 播放器方块（player_block.tscn，占位内容；标题运行时覆盖为 L5 · E60）
##
## 相机：第三人称慢速轨道（美术方向相机路线裁决）。
## 物理：本关没有刚体演算（小车/组件都是展示性移动，不接物理）；
## 体素碰撞体照常生成，留给后续关卡接物理时再用。
##
## 入口：
##   窗口围观：godot --path game scenes/levels/l5/l5.tscn
##   窗口演示：… scenes/levels/l5/l5.tscn -- --demo（跑一遍完整流程的可视版，不落盘）
##   截图：    … scenes/levels/l5/l5.tscn -- --shot（出 game/tests/levels/l5/l5_preview.png 后退出）
##   流程判定：headless 走 tests/levels/l5/run_l5_tests.gd（l5_flow.gd 驱动）

const LoopGalleryScene := preload("res://scenes/levels/l5/components/loop_gallery.tscn")
const RunnerScene := preload("res://scenes/levels/l5/components/runner.tscn")
const VerifyGateScene := preload("res://scenes/levels/l5/components/verify_gate.tscn")
const BypassScene := preload("res://scenes/levels/l5/components/bypass.tscn")
const CodexStubScene := preload("res://scenes/levels/l5/components/codex_stub.tscn")
const PlayerBlockScene := preload("res://scenes/blocks/player_block.tscn")
const L5FlowScript := preload("res://scripts/levels/l5/l5_flow.gd")

const OUT_SHOT := "res://tests/levels/l5/l5_preview.png"
const SCREEN_TITLE := "L5 · E60 占位视频"

# ---- 工位布局（全部落原点附近 13×13 甲板上）----
const GALLERY_MOUNT_POS := Vector3(-2.0, DECK_TOP_Y, 1.0)
const GALLERY_MOUNT_YAW := 0.0
const RUNNER_MOUNT_POS := Vector3(-4.5, DECK_TOP_Y, -1.5)   # z 收 1.0：给回廊出口引道让位（底座同在甲板面 0..0.25 带）
const RUNNER_MOUNT_YAW := 0.0
const GATE_MOUNT_POS := Vector3(-2.0, DECK_TOP_Y, -2.5)
const GATE_MOUNT_YAW := 0.0
const BYPASS_MOUNT_POS := Vector3(0.5, DECK_TOP_Y, -2.5)
const BYPASS_MOUNT_YAW := 0.0
const SCREEN_POS := Vector3(4.5, DECK_TOP_Y, -1.5)
const SCREEN_YAW := 0.0
const STUB_ZONE_POS := Vector3(1.0, DECK_TOP_Y, 2.0)
const CODEX_START := Vector3(2.5, DECK_TOP_Y, 4.25)   # z 收 0.25：方轮外沿 z±0.75 不出广场半径
const GALLERY_FRONT := Vector3(-0.5, DECK_TOP_Y, 2.5)   # 小车停在回廊入口前

## 占位区两行五列的相对格位（install_stub 按序取用）。
const STUB_SLOTS := [
	Vector3(0.0, 0.0, -0.5), Vector3(1.0, 0.0, -0.5), Vector3(2.0, 0.0, -0.5),
	Vector3(3.0, 0.0, -0.5), Vector3(4.0, 0.0, -0.5),
	Vector3(0.0, 0.0, 0.5), Vector3(1.0, 0.0, 0.5), Vector3(2.0, 0.0, 0.5),
	Vector3(3.0, 0.0, 0.5), Vector3(4.0, 0.0, 0.5),
]

# ---- 相机轨道 ----
const ORBIT_RADIUS := 16.0
const ORBIT_HEIGHT := DECK_TOP_Y + 7.0
const ORBIT_SPEED := 0.10             # rad/s，慢速环绕
const ORBIT_LOOK_AT := Vector3(0.0, DECK_TOP_Y + 1.5, 0.0)

# ---------- 基座覆写点 ----------

func _init() -> void:
	orbit_radius = ORBIT_RADIUS
	orbit_height = ORBIT_HEIGHT
	orbit_speed = ORBIT_SPEED
	orbit_look_at = ORBIT_LOOK_AT


func _level_label() -> String:
	return "L5"


func _shot_path() -> String:
	return OUT_SHOT


func _demo_pause() -> float:
	return 1.2   # 原 _run_mode_demo 的 1.2
var _stub_slots_used := 0


## 可视演示：用独立内核（own_* 注入，不碰共享 autoload）跑五阶段，不 end_run 不落盘。
func _drive_visual_demo(pause_s: float) -> void:
	var flow := L5FlowScript.new()
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


# ---------- 对外（给 l5_flow / 测试用） ----------

func install_loop_gallery():
	return _install_at("LoopGalleryMount", "LoopGallery", LoopGalleryScene)

func install_runner():
	return _install_at("RunnerMount", "Runner", RunnerScene)

func install_verify_gate():
	return _install_at("VerifyGateMount", "VerifyGate", VerifyGateScene)

func install_bypass():
	return _install_at("BypassMount", "Bypass", BypassScene)


## 十件占位按 STUB_SLOTS 顺序摆放（小方块 + 名牌；显式决定见 codex_stub.gd 头注释）。
func install_stub(number: int, label: String):
	var zone := get_node_or_null("Workstation/StubZone") as Node3D
	if zone == null:
		return null
	var node_name := "Stub%d" % number
	var existing := zone.get_node_or_null(node_name)
	if existing != null:
		return existing
	var node := CodexStubScene.instantiate()
	node.name = node_name
	node.position = STUB_SLOTS[mini(_stub_slots_used, STUB_SLOTS.size() - 1)]
	_stub_slots_used += 1
	zone.add_child(node)
	node.set_stub(number, label)
	return node


func get_loop_gallery():
	return get_node_or_null("Workstation/LoopGalleryMount/LoopGallery")

func get_runner():
	return get_node_or_null("Workstation/RunnerMount/Runner")

func get_verify_gate():
	return get_node_or_null("Workstation/VerifyGateMount/VerifyGate")

func get_bypass():
	return get_node_or_null("Workstation/BypassMount/Bypass")

func get_player_screen():
	return get_node_or_null("Workstation/PlayerScreen")

func gallery_front_pos() -> Vector3:
	return GALLERY_FRONT


func _install_at(mount_name: String, child_name: String, scene: PackedScene):
	var mount := get_node("Workstation/" + mount_name) as Node3D
	var existing := mount.get_node_or_null(child_name)
	if existing != null:
		return existing
	var node := scene.instantiate()
	node.name = child_name
	mount.add_child(node)
	return node


## 小车走到目标位（带一点 Q 弹小跳）。逐帧插值，纯显示，不接物理。
# ---------- 工位 ----------

func _add_workstation() -> void:
	var ws := Node3D.new()
	ws.name = "Workstation"
	add_child(ws)

	ws.add_child(_build_cart())

	# 四安装位（本关四件实体）
	for entry in [
		["LoopGalleryMount", GALLERY_MOUNT_POS, GALLERY_MOUNT_YAW],
		["RunnerMount", RUNNER_MOUNT_POS, RUNNER_MOUNT_YAW],
		["VerifyGateMount", GATE_MOUNT_POS, GATE_MOUNT_YAW],
		["BypassMount", BYPASS_MOUNT_POS, BYPASS_MOUNT_YAW],
	]:
		var mount := Node3D.new()
		mount.name = entry[0]
		mount.position = entry[1]
		mount.rotation.y = entry[2]
		ws.add_child(mount)

	# 十件占位摆放区（L1–L4 的简化占位体；install_stub 逐个落位）
	var zone := Node3D.new()
	zone.name = "StubZone"
	zone.position = STUB_ZONE_POS
	zone.rotation.y = 0.0
	ws.add_child(zone)

	# 播放器方块（占位内容；标题运行时覆盖为本关的 E60 文案）
	var screen := PlayerBlockScene.instantiate()
	screen.name = "PlayerScreen"
	screen.position = SCREEN_POS
	screen.rotation.y = SCREEN_YAW
	ws.add_child(screen)
	var title_label := screen.get_node_or_null("ScreenLabel") as Label3D
	if title_label != null:
		title_label.text = SCREEN_TITLE


## codex 本体：一个可移动的方块小车（与 L1 同款造型；纯显示移动，不接物理）。
func _build_cart() -> Node3D:
	var cart := Node3D.new()
	cart.name = "CodexCart"
	cart.position = CODEX_START

	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.0, 0.5, 0.5)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.75, 0.0)   # 骑在方轮上（轮顶 0.5，隙 0）
	body_mesh.material = _mat(PALETTE[5], 0.5, 0.15)
	cart.add_child(body)

	# 舱盖（小一号叠上去，双层近似 Q 弹的圆角感）
	var cap := MeshInstance3D.new()
	cap.name = "Cap"
	var cap_mesh := BoxMesh.new()
	cap_mesh.size = Vector3(0.5, 0.5, 0.5)
	cap.mesh = cap_mesh
	cap.position = Vector3(0.0, 1.25, 0.0)   # 落在车身上（顶 1.0，隙 0）
	cap_mesh.material = _mat(PALETTE[4], 0.5, 0.1)
	cart.add_child(cap)

	# 四只方轮（共享 mesh；R4 圆改方，0.5 标准块，轮心 y 0.25 落甲板）
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

	# 头灯（青色发光小方块，半嵌车头正面，朝向回廊那面）
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

	_face_cart(cart, GALLERY_MOUNT_POS)
	return cart


## 小车朝向回廊（纯 yaw 计算，不依赖 look_at——后者要求节点已在树里）。
func _face_cart(cart: Node3D, _target: Vector3) -> void:
	var dir := GALLERY_MOUNT_POS - cart.position
	if Vector2(dir.x, dir.z).length() > 0.05:
		# Node3D 前向是 -Z：yaw = atan2(-dx, -dz) 让 -Z 指向回廊
		cart.rotation.y = snappedf(atan2(-dir.x, -dir.z), PI * 0.5)

