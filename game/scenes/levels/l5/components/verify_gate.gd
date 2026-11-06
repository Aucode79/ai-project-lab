extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 校验门组件（docs/10-契约/mini-codex.md §一 #10；L5 四件之一）。
## 世界形态：质检门——门框 + 可动门体（转角），通过走正门（门体让开正路），
## 拒绝走岔路（门体转角把货流拨向侧路）；拒绝原因显示在 Label3D 上。
## 对齐 concepts.yaml c10.3（conc_tool_slot_gate：字段对上闸门才开；
## failId c10.3:1 字段集不等 → 闸门关闭、调用记为失败）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：由步记录派生（codex.verify 步），
## 本节点只显示；门体转角是纯显示，不接物理。
## 派生口径（L5）：
##   待命：还没有针对本门的 codex.verify
##   正在：第一次 codex.verify 开始校验
##   出错：codex.verify 返回 ok=false（拒绝——失败进第四态）
##   完成：其后出现 ok=true（第二轮通过）

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

const FRAME_COLOR := Style.CHECK
const PASS_COLOR := Style.SUCCESS
const REJECT_COLOR := Style.ERROR
const TEXT_COLOR := Style.INK

## 门体转角：正门让开（沿正路 +X）与岔路拨转（指向岔路 +Z）两个可动位。
## 轴向对齐口径（2026-09-16）：只用 90° 的整数倍 —— 原 78° / −18° 是「斜向岔路」的产物；
## 现把岔路收成直角（地条同时转正），语义不变：通过 = 沿正路，拒绝 = 转向岔路。
const ARM_YAW_PASS := 90.0
const ARM_YAW_REJECT := 0.0

var _passed := false
var _reason := "（等一次校验）"
var _arm_pivot: Node3D
var _arm_mat: StandardMaterial3D
var _pass_strip_mat: StandardMaterial3D
var _reason_label: Label3D
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D


func _ready() -> void:
	_build()
	set_verdict(false, "（等一次校验）")
	set_state_visual(STATE_IDLE)


# ---------- 对外 API ----------

## 质检结果：通过走正门 / 拒绝走岔路（门体转角切换），拒绝原因上牌。
func set_verdict(passed: bool, reason := "") -> void:
	_passed = passed
	_reason = reason if reason != "" else ("通过：字段对上，走正门" if passed else "拒绝")
	_arm_pivot.rotation_degrees.y = ARM_YAW_PASS if passed else ARM_YAW_REJECT
	_arm_mat.albedo_color = PASS_COLOR if passed else REJECT_COLOR
	_arm_mat.emission = PASS_COLOR if passed else REJECT_COLOR
	_arm_mat.emission_energy_multiplier = 1.2 if passed else 0.9
	_pass_strip_mat.emission_energy_multiplier = 1.1 if passed else 0.0
	if passed:
		set_state_visual(STATE_DONE)
	elif _reason != "（等一次校验）":
		set_state_visual(STATE_ERROR)
	_refresh_reason()


func get_verdict() -> bool:
	return _passed


func get_last_reason() -> String:
	return _reason


func get_arm_yaw() -> float:
	return _arm_pivot.rotation_degrees.y


## 四态显示（灯色 + 灯字）。state 也可由步记录派生后调用。
func set_state_visual(state: String) -> void:
	var color: Color = STATE_COLORS.get(state, STATE_COLORS[STATE_IDLE])
	var caption: String = STATE_CAPTIONS.get(state, STATE_CAPTIONS[STATE_IDLE])
	_lamp_mat.albedo_color = color
	_lamp_mat.emission = color
	_state_label.text = caption


func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


# ---------- 状态派生（纯函数，输入步记录） ----------

## 全轨迹：traj[k] = 看完前 k+1 步后校验门应处的状态。
## codex.verify 步（l5_flow 记录）ok=false 即拒绝。
static func state_trajectory(steps: Array, gate_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			if tool == "codex.verify" and str(args.get("entityId", "")) == gate_eid:
				state = STATE_DONE if bool(output.get("ok", false)) else STATE_ERROR
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, gate_eid: String) -> String:
	var traj := state_trajectory(steps, gate_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _refresh_reason() -> void:
	_reason_label.text = _reason


func _build() -> void:
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = FRAME_COLOR
	frame_mat.roughness = 0.6
	frame_mat.metallic = 0.2

	# 正路地条（通过方向，绿色发光；坐在基座顶上：y 面 0..0.25 落格，2026-09-17 外延落格口径）
	var pass_strip := MeshInstance3D.new()
	pass_strip.name = "PassStrip"
	var strip_mesh := BoxMesh.new()
	strip_mesh.size = Vector3(0.5, 0.25, 2.5)
	pass_strip.mesh = strip_mesh
	pass_strip.position = Vector3(0.0, 0.125, 0.0)
	_pass_strip_mat = StandardMaterial3D.new()
	_pass_strip_mat.albedo_color = PASS_COLOR
	_pass_strip_mat.emission_enabled = true
	_pass_strip_mat.emission = PASS_COLOR
	_pass_strip_mat.emission_energy_multiplier = 0.0
	strip_mesh.material = _pass_strip_mat
	add_child(pass_strip)

	# 岔路地条（拒绝方向，暗红；坐在基座顶上同上，z 心 +0.125 使 z 面 0.5..1.75 落格）
	var side_strip := MeshInstance3D.new()
	side_strip.name = "SideStrip"
	var side_mesh := BoxMesh.new()
	side_mesh.size = Vector3(1.25, 0.25, 0.5)
	side_strip.mesh = side_mesh
	side_strip.position = Vector3(0.75, 0.125, 1.125)
	side_strip.rotation.y = PI * 0.5     # 岔路沿 +Z：长边转正，不再斜着（2026-09-16）
	var side_mat := StandardMaterial3D.new()
	side_mat.albedo_color = REJECT_COLOR
	side_mat.emission_enabled = true
	side_mat.emission = REJECT_COLOR
	side_mat.emission_energy_multiplier = 0.4
	side_mesh.material = side_mat
	add_child(side_strip)

	# 门框两柱 + 顶梁（柱心 ±0.875 / z −0.375：六面落 0.25 格；梁加宽到 2.0 恰压住两柱外沿，
	# 门扇开间 1.5 不变 —— 2026-09-17 外延落格口径）
	for px in [-0.875, 0.875]:
		var post := MeshInstance3D.new()
		post.name = "GatePost"
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.25, 1.5, 0.25)
		post.mesh = post_mesh
		post.position = Vector3(px, 0.75, -0.375)
		post_mesh.material = frame_mat
		add_child(post)
	var beam := MeshInstance3D.new()
	beam.name = "GateBeam"
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(2.0, 0.25, 0.25)
	beam.mesh = beam_mesh
	beam.position = Vector3(0.0, 1.625, -0.375)
	beam_mesh.material = frame_mat
	add_child(beam)

	# 可动门体（挂在左侧柱顶的转轴上，转角切换正门/岔路；轴心挪到格点使臂六面落格）
	_arm_pivot = Node3D.new()
	_arm_pivot.name = "GatePivot"
	_arm_pivot.position = Vector3(-0.875, 1.125, -0.375)
	add_child(_arm_pivot)
	var arm := MeshInstance3D.new()
	arm.name = "GateArm"
	var arm_mesh := BoxMesh.new()
	arm_mesh.size = Vector3(1.5, 0.25, 0.25)
	arm.mesh = arm_mesh
	arm.position = Vector3(0.875, 0.0, 0.0)
	_arm_mat = StandardMaterial3D.new()
	_arm_mat.albedo_color = REJECT_COLOR
	_arm_mat.emission_enabled = true
	_arm_mat.emission = REJECT_COLOR
	_arm_mat.emission_energy_multiplier = 0.9
	arm_mesh.material = _arm_mat
	_arm_pivot.add_child(arm)

	# 拒绝原因牌（Label3D）
	_reason_label = Label3D.new()
	_reason_label.name = "ReasonLabel"
	_reason_label.position = Vector3(0.0, 2.25, -0.5)
	_reason_label.font_size = 30
	_reason_label.pixel_size = 0.0028
	_reason_label.modulate = TEXT_COLOR
	_reason_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_reason_label.double_sided = false
	add_child(_reason_label)

	# 四态灯（门顶；R4 圆改方，落横梁顶上隙 0）
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.125, 1.875, -0.375)   # 心 x 挪到奇半格，灯的六面才落 0.25 格
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(0.0, 1.3, -0.25)
	_state_label.font_size = 32
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)
