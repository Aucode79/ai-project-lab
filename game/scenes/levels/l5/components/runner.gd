extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 执行器组件（docs/10-契约/mini-codex.md §一 #9；L5 四件之一）。
## 世界形态：带观测窗的机器——机身 + 正面凹进的深色观测窗，
## 窗里一串小方块滚动（输出在窗里流动，run.python / run.tests 的载体）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：待命/正在/完成/出错由步记录派生，
## **不另做状态机**——本节点只负责显示；小方块滚动是纯装饰动画
## （_process 插值，不接物理、不参与判定）。
## 派生口径（L5）：
##   待命：装上后还没有 codex 的 world.run
##   正在：其后出现 actor=codex 的 world.run（执行器在跑）
##   完成：其后出现针对校验门的 codex.verify 通过步（跑完且过了质检）
##   出错：针对本实体的写操作返回失败

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

const BODY_COLOR := Style.ACTION
const WINDOW_COLOR := Style.INK
const CUBE_COLOR := Style.SIGNAL
const TEXT_COLOR := Style.INK

const CUBE_COUNT := 7
const CUBE_SPACING := 0.25   # 流方块间距（R2：0.25 网格）
const WINDOW_WIDTH := 1.5
const FLOW_SPEED := 0.55   # 格/秒

var _flowing := false
var _flow_t := 0.0
var _cubes: Array[MeshInstance3D] = []
var _output_label: Label3D
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D


func _ready() -> void:
	_build()
	set_flowing(false)
	set_state_visual(STATE_IDLE)


func _process(delta: float) -> void:
	# 观测窗里的小方块滚动：输出流动的纯装饰动画
	# x 基准含 +0.125：与 _build 里的静置位一致（外延落 0.25 m 格，T7）
	if _flowing:
		_flow_t = fmod(_flow_t + delta * FLOW_SPEED, CUBE_SPACING)
	for i in _cubes.size():
		var x := -WINDOW_WIDTH * 0.5 + 0.125 + i * CUBE_SPACING + _flow_t
		if x > WINDOW_WIDTH * 0.5:
			x -= CUBE_SPACING * CUBE_COUNT
		_cubes[i].position.x = x
		_cubes[i].visible = _flowing and x >= -WINDOW_WIDTH * 0.5 - 0.01


# ---------- 对外 API ----------

## 输出在观测窗里流动（run 中开，跑完停）。
func set_flowing(flowing: bool) -> void:
	_flowing = flowing
	_output_label.text = "输出流动中" if flowing else "待执行"
	if not flowing:
		for cube in _cubes:
			cube.visible = false


func is_flowing() -> bool:
	return _flowing


## 四态显示（灯色 + 灯字）。state 来自步记录派生，见类头注释。
func set_state_visual(state: String) -> void:
	var color: Color = STATE_COLORS.get(state, STATE_COLORS[STATE_IDLE])
	var caption: String = STATE_CAPTIONS.get(state, STATE_CAPTIONS[STATE_IDLE])
	_lamp_mat.albedo_color = color
	_lamp_mat.emission = color
	_state_label.text = caption


func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


# ---------- 状态派生（纯函数，输入步记录） ----------

static func state_trajectory(steps: Array, runner_eid: String, gate_eid := "") -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.run" and str(s.get("actor", "")) == "codex":
				state = STATE_RUNNING
			elif tool == "codex.verify" and gate_eid != "" \
					and str(args.get("entityId", "")) == gate_eid and step_ok:
				state = STATE_DONE
			elif tool == "world.set_param" and str(args.get("entityId", "")) == runner_eid and not step_ok:
				state = STATE_ERROR
		traj.append(state)
	return traj


static func derive_state_from_steps(steps: Array, runner_eid: String, gate_eid := "") -> String:
	var traj := state_trajectory(steps, runner_eid, gate_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = BODY_COLOR
	body_mat.roughness = 0.5
	body_mat.metallic = 0.15

	# 机身（R1：2.0×1.0×1.0 全 0.25 倍数；心 y 0.75 落底座上，z 让半格的 1/4 落格外延格）
	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(2.0, 1.0, 1.0)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.75, 0.125)
	body_mesh.material = body_mat
	add_child(body)

	# 底座（半嵌地面：心 y 0.125，机身底 0.25 压座顶，隙 0）
	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.5, 0.25, 0.75)
	base.mesh = base_mesh
	base.position = Vector3(0.0, 0.125, 0.0)
	base_mesh.material = body_mat
	add_child(base)

	# 观测窗（正面凹进的深色面板；厚 0.25 半嵌机身正面）
	var window_panel := MeshInstance3D.new()
	window_panel.name = "Window"
	var window_mesh := BoxMesh.new()
	window_mesh.size = Vector3(WINDOW_WIDTH, 0.5, 0.25)
	window_panel.mesh = window_mesh
	window_panel.position = Vector3(0.0, 0.75, -0.5)
	var window_mat := StandardMaterial3D.new()
	window_mat.albedo_color = WINDOW_COLOR
	window_mat.roughness = 0.25
	window_mat.metallic = 0.1
	window_mat.emission_enabled = true
	window_mat.emission = WINDOW_COLOR
	window_mat.emission_energy_multiplier = 0.35
	window_mesh.material = window_mat
	add_child(window_panel)

	# 窗里滚动的小方块（输出流；0.25³，半嵌窗面）。
	# 静置位 (+0.125, +0.125, −0.125)：与 _process 的 x 公式同源，外延落 0.25 m 格（T7）
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3(0.25, 0.25, 0.25)
	var cube_mat := StandardMaterial3D.new()
	cube_mat.albedo_color = CUBE_COLOR
	cube_mat.emission_enabled = true
	cube_mat.emission = CUBE_COLOR
	cube_mat.emission_energy_multiplier = 1.3
	cube_mesh.material = cube_mat
	for i in CUBE_COUNT:
		var cube := MeshInstance3D.new()
		cube.name = "FlowCube"
		cube.mesh = cube_mesh
		cube.position = Vector3(-WINDOW_WIDTH * 0.5 + 0.125 + i * CUBE_SPACING, 0.875, -0.75)
		cube.visible = false
		add_child(cube)
		_cubes.append(cube)

	# 输出状态字（观测窗下沿）
	_output_label = Label3D.new()
	_output_label.name = "OutputLabel"
	_output_label.position = Vector3(0.0, 0.375, -0.625)
	_output_label.font_size = 28
	_output_label.pixel_size = 0.0028
	_output_label.modulate = TEXT_COLOR
	_output_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_output_label.double_sided = false
	add_child(_output_label)

	# 四态灯（机顶；R4 圆改方，落机身顶上隙 0；x 让半格的 1/4 落格外延格）
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.125, 1.375, 0.0)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(0.0, 1.75, 0.0)
	_state_label.font_size = 32
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)
