extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 机械臂工具头组件（docs/10-契约/mini-codex.md §一 #13；L2 三件之一）。
## 世界形态：一台铰接机械臂——底座 + 立柱 + 大臂 + 小臂 + 夹爪 + 爪里一块待放方块。
## **一切修改的物理载体**（mini-codex §2.3）：fs.write 只能经它执行；
## 落点留一格高度标记（标记本体在 file_cabinet 的柜顶，新增/修改颜色区分）。
##
## 四态硬规则（mini-codex §2.1）：状态灯（待命/正在/完成/出错）由步记录派生，
## 派生函数是纯函数（本文件底部），set_state_visual() 只改灯色灯字，不存状态。
## pulse() 是纯显示的夹取脉冲——机械臂放进/替换一格的"动作可见"。

# ---- 四态（步记录派生，§2.1）----
const STATE_IDLE := "idle"
const STATE_RUNNING := "running"
const STATE_DONE := "done"
const STATE_ERROR := "error"
const STATE_COLORS := {
	STATE_IDLE: Color(0.564, 0.533, 0.471),
	STATE_RUNNING: Color(0.929, 0.471, 0.345),
	STATE_DONE: Color(0.373, 0.816, 0.451),
	STATE_ERROR: Color(0.914, 0.325, 0.325),
}
const STATE_CAPTIONS := {
	STATE_IDLE: "待命",
	STATE_RUNNING: "正在",
	STATE_DONE: "完成",
	STATE_ERROR: "出错",
}

# 明亮定稿调色板里的相关色（docs/10-契约/美术方向.md）
const BODY_COLOR := Style.ACTION
const ACCENT_COLOR := Style.ACTION
const TEXT_COLOR := Style.INK

const PULSE_SPEED := 3.2   # 夹爪开合摆动角速度（rad/s）
const PULSE_TIME := 0.8    # 一次脉冲时长

var _lamp_mat: StandardMaterial3D
var _grip_left: Node3D
var _grip_right: Node3D
var _held_mat: StandardMaterial3D
var _pulse_t := -1.0
var _state_label: Label3D


func _ready() -> void:
	_build()
	set_state_visual(STATE_IDLE)


func _process(delta: float) -> void:
	# 夹取脉冲：夹爪小幅开合 + 爪中方块发光冲高（纯显示）；爪静息位 ±0.25（贴持块面）
	if _pulse_t >= 0.0:
		_pulse_t += delta
		var k := cos(_pulse_t * PULSE_SPEED) * 0.06
		_grip_left.position.x = -0.25 - absf(k)
		_grip_right.position.x = 0.25 + absf(k)
		_held_mat.emission_energy_multiplier = 0.9 + 1.4 * maxf(0.0, 1.0 - _pulse_t / PULSE_TIME)
		if _pulse_t >= PULSE_TIME:
			_pulse_t = -1.0
			_grip_left.position.x = -0.25
			_grip_right.position.x = 0.25
			_held_mat.emission_energy_multiplier = 0.9


# ---------- 对外 API ----------

## 只改显示（灯色 + 灯字）。state 来自步记录派生，见类头注释。
func set_state_visual(state: String) -> void:
	var color: Color = STATE_COLORS.get(state, STATE_COLORS[STATE_IDLE])
	var caption: String = STATE_CAPTIONS.get(state, STATE_CAPTIONS[STATE_IDLE])
	_lamp_mat.albedo_color = color
	_lamp_mat.emission = color
	_state_label.text = caption


func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


## 放入/替换一格的夹取脉冲（动作可见，写留物——柜顶落点标记常驻）。
func pulse() -> void:
	_pulse_t = 0.0


# ---------- 状态派生（纯函数，输入步记录） ----------

## 四态轨迹（L2 口径）：
##   待命：工具头还没切换到机械臂
##   正在：world.switch_tool_head 切到本实体（args.entityId 是本机械臂）
##   完成：其后出现经本机械臂的 fs.write（action.carrierEntityId 指向本实体）成功
##   出错：经本机械臂的写入失败（被挡回等）
static func state_trajectory(steps: Array, arm_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a.get("args", {}) is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.switch_tool_head" and str(args.get("entityId", "")) == arm_eid:
				if step_ok:
					state = STATE_RUNNING
				else:
					state = STATE_ERROR
			elif tool == "fs.write" and str(a.get("carrierEntityId", "")) == arm_eid:
				state = STATE_DONE if step_ok else STATE_ERROR
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, arm_eid: String) -> String:
	var traj := state_trajectory(steps, arm_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 底座 + 立柱（块状化 v2：R4 圆柱→方柱；高度链：底 0.0→顶 0.5→柱顶 1.5）
	# 外延落格（2026-09-17）：柱/链是 0.25 奇数尺寸，心落半格（x.125）六面才落 0.25 格。
	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.0, 0.5, 1.0)
	base.mesh = base_mesh
	base.position = Vector3(0.0, 0.25, 0.0)
	base_mesh.material = _mat(BODY_COLOR, 0.6, 0.3)
	add_child(base)

	var column := MeshInstance3D.new()
	column.name = "Column"
	var column_mesh := BoxMesh.new()
	column_mesh.size = Vector3(0.25, 1.25, 0.25)
	column.mesh = column_mesh
	# 心 (0.125, 0.875, 0.125)：柱身 y 0.25..1.5，下段埋进底座、上段高出肩关节 0.125 当轴套
	column.position = Vector3(0.125, 0.875, 0.125)
	column_mesh.material = _mat(BODY_COLOR, 0.55, 0.3)
	add_child(column)

	# 大臂（关节中心 y=1.375 半格偏移，连杆面才落 0.25 格；肩埋在柱顶轴套里，便于后续做动画）
	var shoulder := Node3D.new()
	shoulder.name = "Shoulder"
	shoulder.position = Vector3(0.125, 1.375, 0.0)
	# 轴向对齐口径（2026-09-16）：关节角只用 90° 的整数倍。肩 90° = 上臂从竖直转成
	# **水平前伸**，腕 0° = 小臂同向续伸 → 整条臂在 y=1.25 上指向 +Z（柜格方向），
	# 与原来 −32°/58° 那套"朝 +Z 前下"的意图一致，只是不再斜着。
	shoulder.rotation_degrees = Vector3(90.0, 0.0, 0.0)
	add_child(shoulder)

	var upper_arm := MeshInstance3D.new()
	upper_arm.name = "UpperArm"
	var upper_mesh := BoxMesh.new()
	upper_mesh.size = Vector3(0.25, 1.0, 0.25)
	upper_arm.mesh = upper_mesh
	upper_arm.position = Vector3(0.0, 0.5, 0.0)
	upper_mesh.material = _mat(ACCENT_COLOR, 0.5, 0.2)
	shoulder.add_child(upper_arm)

	# 小臂 + 夹爪（朝 +Z 前下方向柜格）；腕 y=1.125（大臂端头 1.0 再进 0.125，肘部保持搭接不断链）
	var wrist := Node3D.new()
	wrist.name = "Wrist"
	wrist.position = Vector3(0.0, 1.125, 0.0)
	wrist.rotation_degrees = Vector3(0.0, 0.0, 0.0)
	shoulder.add_child(wrist)

	var forearm := MeshInstance3D.new()
	forearm.name = "Forearm"
	var fore_mesh := BoxMesh.new()
	fore_mesh.size = Vector3(0.25, 0.75, 0.25)
	forearm.mesh = fore_mesh
	# 心 0.25（经肩 90° 映到 z=1.375）：杆身 z 1.0..1.75，根端搭在大臂端头、端头 1.75 与爪面相接
	forearm.position = Vector3(0.0, 0.25, 0.0)
	fore_mesh.material = _mat(BODY_COLOR, 0.5, 0.25)
	wrist.add_child(forearm)

	var gripper := Node3D.new()
	gripper.name = "Gripper"
	gripper.position = Vector3(0.0, 0.75, 0.0)
	wrist.add_child(gripper)

	# 两片 0.25³ 方爪：心 ±0.25 落格，内缘 ±0.125 恰贴持块面（间隙 0）
	_grip_left = Node3D.new()
	_grip_left.name = "GripLeft"
	_grip_left.position = Vector3(-0.25, 0.0, 0.0)
	var gl := MeshInstance3D.new()
	var gl_mesh := BoxMesh.new()
	gl_mesh.size = Vector3.ONE * 0.25
	gl.mesh = gl_mesh
	gl_mesh.material = _mat(ACCENT_COLOR, 0.4, 0.3)
	_grip_left.add_child(gl)
	gripper.add_child(_grip_left)

	_grip_right = Node3D.new()
	_grip_right.name = "GripRight"
	_grip_right.position = Vector3(0.25, 0.0, 0.0)
	var gr := MeshInstance3D.new()
	var gr_mesh := BoxMesh.new()
	gr_mesh.size = Vector3.ONE * 0.25
	gr.mesh = gr_mesh
	gr_mesh.material = _mat(ACCENT_COLOR, 0.4, 0.3)
	_grip_right.add_child(gr)
	gripper.add_child(_grip_right)

	# 爪中待放方块（从工作台抓来的，写留物的"物"；迷你示意 0.25³）
	var held := MeshInstance3D.new()
	held.name = "HeldBlock"
	var held_mesh := BoxMesh.new()
	held_mesh.size = Vector3.ONE * 0.25
	held.mesh = held_mesh
	held.position = Vector3(0.0, 0.0, 0.0)
	_held_mat = StandardMaterial3D.new()
	_held_mat.albedo_color = ACCENT_COLOR
	_held_mat.emission_enabled = true
	_held_mat.emission = ACCENT_COLOR
	_held_mat.emission_energy_multiplier = 0.9
	held_mesh.material = _held_mat
	gripper.add_child(held)

	# 状态灯（柱侧；R4 球→0.25³，贴柱身 x=0.25 面外缘、心落半格六面落格）
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.375, 1.125, 0.125)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	_lamp_mat.roughness = 0.3
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(0.0, 1.68, 0.0)
	_state_label.font_size = 40
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)

	var title := Label3D.new()
	title.name = "Title"
	title.text = "机械臂 · 写"
	# 底座改为 1.0×0.5×1.0 后原位 (0,0.42,0) 会被埋，挪到底座前脸外
	title.position = Vector3(0.0, 0.25, 0.51)
	title.font_size = 44
	title.pixel_size = 0.003
	title.modulate = TEXT_COLOR
	title.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	title.double_sided = false
	add_child(title)


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m
