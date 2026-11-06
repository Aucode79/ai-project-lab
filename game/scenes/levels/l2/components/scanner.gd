extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 扫描器工具头组件（docs/10-契约/mini-codex.md §一 #14；L2 三件之一）。
## 世界形态：一台立式扫描装置——立柱 + 悬臂 + 发射盘 + 一片薄荷绿扫描光幕。
## **一切读取的物理载体**（mini-codex §2.3）：fs.read 只能经它执行；
## 扫过柜格留下淡痕（淡痕本体在 file_cabinet 的格面上，本节点负责发光示意）。
##
## 四态硬规则（mini-codex §2.1）：状态灯（待命/正在/完成/出错）由步记录派生，
## 派生函数是纯函数（本文件底部），set_state_visual() 只改灯色灯字，不存状态。
## pulse() 是纯显示的发光脉冲——扫描器扫过一格的"动作可见"。

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
const BODY_COLOR := Style.SIGNAL
const ACCENT_COLOR := Style.SIGNAL
const BEAM_COLOR := Style.SIGNAL
const TEXT_COLOR := Style.INK

const PULSE_ENERGY := 2.04
const PULSE_DECAY := 4.0   # 每秒衰减系数

var _lamp_mat: StandardMaterial3D
var _dish_mat: StandardMaterial3D
var _beam_mat: StandardMaterial3D
var _pulse_t := -1.0
var _state_label: Label3D


func _ready() -> void:
	_build()
	set_state_visual(STATE_IDLE)


func _process(delta: float) -> void:
	# 扫描脉冲：发光能量冲高后指数衰减回基线（纯显示）
	if _pulse_t >= 0.0:
		_pulse_t += delta
		var k := exp(-_pulse_t * PULSE_DECAY)
		_dish_mat.emission_energy_multiplier = 0.8 + (PULSE_ENERGY - 0.8) * k
		_beam_mat.albedo_color.a = 0.22 + 0.5 * k
		_beam_mat.emission_energy_multiplier = 0.8 + (PULSE_ENERGY - 0.8) * k
		if k < 0.02:
			_pulse_t = -1.0


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


## 扫过一格的发光脉冲（动作可见，读不留物——柜格上的淡痕才留几秒）。
func pulse() -> void:
	_pulse_t = 0.0


# ---------- 状态派生（纯函数，输入步记录） ----------

## 四态轨迹（L2 口径）：
##   待命：工具头还没切换到扫描器
##   正在：world.switch_tool_head 切到本实体（args.entityId 是本扫描器）
##   完成：其后出现经本扫描器的 fs.read（action.carrierEntityId 指向本实体）成功
##   出错：经本扫描器的读取失败且不是"上锁拒绝"（上锁被拒是许可系统在正常工作）
static func state_trajectory(steps: Array, scanner_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a.get("args", {}) is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.switch_tool_head" and str(args.get("entityId", "")) == scanner_eid:
				if step_ok:
					state = STATE_RUNNING
				else:
					state = STATE_ERROR
			elif tool == "fs.read" and str(a.get("carrierEntityId", "")) == scanner_eid:
				if step_ok:
					state = STATE_DONE
				elif str(output.get("error", {}).get("code", "")) != "locked":
					state = STATE_ERROR
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, scanner_eid: String) -> String:
	var traj := state_trajectory(steps, scanner_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 底座 + 立柱（块状化 v2：R4 圆柱底座→方座；高度链：底 0.0→顶 0.5→柱顶 2.0）
	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.0, 0.5, 1.0)
	base.mesh = base_mesh
	base.position = Vector3(0.0, 0.25, 0.0)
	base_mesh.material = _mat(BODY_COLOR, 0.6, 0.25)
	add_child(base)

	var post := MeshInstance3D.new()
	post.name = "Post"
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.25, 1.5, 0.25)
	post.mesh = post_mesh
	post.position = Vector3(0.125, 1.25, 0.125)   # 底=底座顶 0.5、顶=2.0；柱身 0..0.25 落格
	post_mesh.material = _mat(BODY_COLOR, 0.6, 0.25)
	add_child(post)

	# 悬臂（朝 +Z 伸出，扫向文件柜；根端埋进立柱 0.125 不断链）
	var boom := MeshInstance3D.new()
	boom.name = "Boom"
	var boom_mesh := BoxMesh.new()
	boom_mesh.size = Vector3(0.25, 0.25, 1.0)
	boom.mesh = boom_mesh
	boom.position = Vector3(0.125, 1.875, 0.5)
	boom_mesh.material = _mat(BODY_COLOR, 0.55, 0.25)
	add_child(boom)

	# 发射盘（朝下的方盘，扫描光从这出；R4 圆盘→0.5×0.25 方盘，
	# 心 (0,1.625,0.75)：顶面贴悬臂底 1.75、悬臂 z 0.5..1.0 段正下方）
	var dish := MeshInstance3D.new()
	dish.name = "Dish"
	var dish_mesh := BoxMesh.new()
	dish_mesh.size = Vector3(0.5, 0.25, 0.5)
	dish.mesh = dish_mesh
	dish.position = Vector3(0.0, 1.625, 0.75)
	_dish_mat = StandardMaterial3D.new()
	_dish_mat.albedo_color = BEAM_COLOR
	_dish_mat.emission_enabled = true
	_dish_mat.emission = BEAM_COLOR
	_dish_mat.emission_energy_multiplier = 0.8
	_dish_mat.roughness = 0.3
	dish_mesh.material = _dish_mat
	add_child(dish)

	# 扫描光幕（半透明光块，脉冲时亮起；盘下留 0.25 不交叠；z 0.75..1.0 与盘前半对齐）
	# 改前是 PlaneMesh —— 默认 orientation = FACE_Y 是**水平**的一片，与注释写的"竖直"不符；
	# 换成 0.25 厚的方块，朝向由盒子自己定，也满足"资产一律由方块组成"（2026-09-16 口径）。
	var beam := MeshInstance3D.new()
	beam.name = "Beam"
	var beam_mesh := BoxMesh.new()
	beam_mesh.size = Vector3(0.75, 1.0, 0.25)
	beam.mesh = beam_mesh
	beam.position = Vector3(0.125, 0.75, 0.875)
	_beam_mat = StandardMaterial3D.new()
	_beam_mat.albedo_color = Color(BEAM_COLOR, 0.22)
	_beam_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_beam_mat.emission_enabled = true
	_beam_mat.emission = BEAM_COLOR
	_beam_mat.emission_energy_multiplier = 0.8
	_beam_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_beam_mat.no_depth_test = false
	beam_mesh.material = _beam_mat
	add_child(beam)

	# 状态灯（柱顶；R4 球→0.25³，坐柱顶面格线 y=2.0；x/z 与柱身 0..0.25 平齐落格）
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.125, 2.125, 0.125)
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
	_state_label.position = Vector3(0.0, 1.55, 0.0)
	_state_label.font_size = 40
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)

	var title := Label3D.new()
	title.name = "Title"
	title.text = "扫描器 · 读"
	# 底座改为 1.0×0.5×1.0 后原位 (0,0.5,0) 会被埋，挪到底座前脸外
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
