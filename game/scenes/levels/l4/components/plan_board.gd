extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 计划板组件（docs/10-契约/mini-codex.md §一 #3；L4 三件之一）。
## 世界形态：排程板——步骤列表（Label3D 行），**当前步骤有指针**
## （发光箭头 + 亮条，随执行推进）。
## 它是家族一代码结构方块的预设装配，不是新方块类型（mini-codex §一）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：由步记录派生，不另做状态机。派生口径（L4）：
##   待命：还没有针对本实体的 set_param(plan_text)
##   正在：计划已上板（set_param plan_text 成功），指针尚未走完
##   完成：其后的 world.run（actor=codex）步里，本实体 step_out >= 步数-1
##         （步数从同一步世界摘要里的 plan_text 参数解析——判定只用记录本身）
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

const PANEL_COLOR := Style.PAPER
const FRAME_COLOR := Style.CORE
const POST_COLOR := Style.STRUCTURE
const TEXT_COLOR := Style.INK
const POINTER_COLOR := Style.SIGNAL

const TOOL_CAPTIONS := {"read": "读", "write": "写", "run": "跑", "search": "搜"}

# 行距/行顶是 Label3D 行的排版量（Label 豁免不计格）；指针 y 随这条行轨走，
# 位置被 run_l4_tests 的指针推进断言钉死，不参与块状化 v2 落格。
const ROW_GAP := 0.34
const ROW_TOP_Y := 1.86
const MAX_ROWS := 6

var _steps: Array = []
var _current := -1
var _rows_root: Node3D
var _pointer: Node3D
var _lamp_mat: StandardMaterial3D
var _state_label: Label3D


func _ready() -> void:
	_build()
	set_plan([])
	set_state_visual(STATE_IDLE)


# ---------- 对外 API ----------

## 计划上板：重建步骤行（Label3D，"1. 步名 · 工具"），指针归位隐藏。
func set_plan(steps: Array) -> void:
	_steps = steps.duplicate(true)
	for c in _rows_root.get_children():
		c.queue_free()
	var n := mini(_steps.size(), MAX_ROWS)
	for i in n:
		_rows_root.add_child(_make_row(i, _steps[i]))
	set_current_step(-1)


func get_plan() -> Array:
	return _steps.duplicate(true)


## 指针推进：指向第 index 步（发光箭头 + 亮条）；-1 = 收起。
func set_current_step(index: int) -> void:
	_current = index
	if index < 0 or index >= mini(_steps.size(), MAX_ROWS):
		_pointer.visible = false
		return
	_pointer.visible = true
	_pointer.position = Vector3(0.0, ROW_TOP_Y - index * ROW_GAP, 0.0)


func get_current_step() -> int:
	return _current


## 只改显示（灯色 + 灯字）。state 来自步记录派生，见类头注释。
func set_state_visual(state: String) -> void:
	var color: Color = STATE_COLORS.get(state, STATE_COLORS[STATE_IDLE])
	var caption: String = STATE_CAPTIONS.get(state, STATE_CAPTIONS[STATE_IDLE])
	_lamp_mat.albedo_color = color
	_lamp_mat.emission = color
	_state_label.text = caption


func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


# ---------- 状态派生（纯函数，输入步记录） ----------

## 全轨迹：traj[k] = 看完前 k+1 步后计划板应处的状态。
## 完成条件里的"步数"从该步世界摘要的 plan_text 参数解析——全部信息都在记录里。
static func state_trajectory(steps: Array, board_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	var planned := false
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var actor := str(s.get("actor", ""))
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and str(args.get("entityId", "")) == board_eid:
				if str(args.get("key", "")) == "plan_text":
					if step_ok:
						planned = true
						state = STATE_RUNNING
					else:
						state = STATE_ERROR
			elif tool == "world.run" and actor == "codex" and planned:
				var world: Dictionary = s.get("world", {}) if s.get("world", {}) is Dictionary else {}
				var entities: Dictionary = world.get("entities", {}) if world.get("entities", {}) is Dictionary else {}
				if entities.has(board_eid):
					var entity: Dictionary = entities[board_eid]
					var plan_arr: Variant = JSON.parse_string(str((entity.get("params", {}) as Dictionary).get("plan_text", "[]")))
					var ports: Dictionary = entity.get("ports", {}) if entity.get("ports", {}) is Dictionary else {}
					var port: Dictionary = ports.get("step_out", {}) if ports.get("step_out", {}) is Dictionary else {}
					if plan_arr is Array and not (plan_arr as Array).is_empty():
						if float(port.get("value", -1.0)) >= float((plan_arr as Array).size() - 1):
							state = STATE_DONE
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, board_eid: String) -> String:
	var traj := state_trajectory(steps, board_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 两根立柱（0.25²×2.5，落地间隙 0，顶与框顶齐平；z 前移半格的 1/4 落格外延格）
	for side in [-1, 1]:
		var post := MeshInstance3D.new()
		post.name = "PostL" if side < 0 else "PostR"
		var post_mesh := BoxMesh.new()
		post_mesh.size = Vector3(0.25, 2.5, 0.25)
		post.mesh = post_mesh
		post.position = Vector3(side * 1.25, 1.25, 0.25)
		post_mesh.material = _mat(POST_COLOR, 0.6, 0.2)
		add_child(post)

	# 排程板面板 + 暖色边框（框落地加深到 0.5，面板贴框前脸，四周露 0.25 边；
	# 全部尺寸/位置按"部件盒六面落 0.25 m 世界格"口径取值，run_ground_tests T7）
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(2.75, 2.5, 0.5)
	frame.mesh = frame_mesh
	frame.position = Vector3(0.0, 1.25, -0.125)
	frame_mesh.material = _mat(FRAME_COLOR, 0.5, 0.1)
	add_child(frame)

	var panel := MeshInstance3D.new()
	panel.name = "Panel"
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(2.25, 2.25, 0.25)
	panel.mesh = panel_mesh
	panel.position = Vector3(0.0, 1.375, 0.25)
	panel_mesh.material = _mat(PANEL_COLOR, 0.55, 0.0)
	add_child(panel)

	# 标题行
	var header := Label3D.new()
	header.name = "Header"
	header.text = "计划板 · PLAN"
	header.position = Vector3(0.0, 2.36, 0.26)
	header.font_size = 40
	header.pixel_size = 0.0028
	header.modulate = TEXT_COLOR
	header.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	header.double_sided = false
	add_child(header)

	# 步骤行容器
	_rows_root = Node3D.new()
	_rows_root.name = "StepsRoot"
	add_child(_rows_root)

	# 指针：发光箭头（左缘）+ 当前步骤亮条（横向）
	_pointer = Node3D.new()
	_pointer.name = "Pointer"
	add_child(_pointer)

	var bar := MeshInstance3D.new()
	bar.name = "Bar"
	var bar_mesh := BoxMesh.new()
	bar_mesh.size = Vector3(2.25, 0.25, 0.25)
	bar.mesh = bar_mesh
	bar.position = Vector3(0.0, 0.125, 0.5)
	var bar_mat := StandardMaterial3D.new()
	bar_mat.albedo_color = Color(0.855, 0.965, 0.925)
	bar_mat.emission_enabled = true
	bar_mat.emission = POINTER_COLOR
	bar_mat.emission_energy_multiplier = 0.35
	bar_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	bar_mat.albedo_color.a = 0.55
	bar_mesh.material = bar_mat
	_pointer.add_child(bar)

	var arrow := MeshInstance3D.new()
	arrow.name = "Arrow"
	# 指示块用方块（不再用 PrismMesh 三角）：资产一律由方块组成（2026-09-16）。
	# 静置位 x=-1.5：箭头探出板左缘 0.25，指进行内（整组与 Bar 同挪，落格外延格）
	var arrow_mesh := BoxMesh.new()
	arrow_mesh.size = Vector3(0.25, 0.25, 0.25)
	arrow.mesh = arrow_mesh
	arrow.rotation_degrees = Vector3(0.0, 0.0, -90.0)
	arrow.position = Vector3(-1.5, 0.125, 0.5)
	var arrow_mat := StandardMaterial3D.new()
	arrow_mat.albedo_color = POINTER_COLOR
	arrow_mat.emission_enabled = true
	arrow_mat.emission = POINTER_COLOR
	arrow_mat.emission_energy_multiplier = 1.6
	arrow_mesh.material = arrow_mat
	_pointer.add_child(arrow)
	_pointer.visible = false

	# 状态灯（0.25² 方灯杆立在框顶，0.25³ 方灯坐在杆顶）
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 0.5, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(0.0, 2.75, 0.25)
	mast_mesh.material = _mat(POST_COLOR, 0.6, 0.2)
	add_child(mast)

	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.0, 3.125, 0.25)
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
	_state_label.position = Vector3(0.0, 2.66, 0.26)
	_state_label.font_size = 38
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)


func _make_row(i: int, step: Dictionary) -> Label3D:
	var row := Label3D.new()
	row.name = "StepRow%d" % i
	var sname := str(step.get("name", ""))
	var stool := str(step.get("tool", ""))
	row.text = "%d. %s · %s" % [i + 1, sname, str(TOOL_CAPTIONS.get(stool, stool))]
	row.position = Vector3(0.02, ROW_TOP_Y - i * ROW_GAP, 0.26)
	row.font_size = 34
	row.pixel_size = 0.0028
	row.modulate = TEXT_COLOR
	row.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	row.double_sided = false
	return row


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m
