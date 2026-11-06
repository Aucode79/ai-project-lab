extends Node3D

## 锚点气泡（docs/10-契约/交互方案.md §五：第 2 级提示"用气泡指到具体方块上"，
## 抄 Code.org 的锚点气泡——泛泛的提示文本对儿童几乎无效）。
##
## 3D 物（无 Control）：一个小标签（Label3D）+ 连线（细长方块）指向场景中的
## 目标 Node3D；气泡悬在目标上方，位置带弹簧感（略欠临界阻尼，有一点回弹）
## 地跟随目标。提示第 1/2/3 级都靠它把话"钉"到具体方块上。
##
## 弹簧按固定步长推进（FIXED_DT，与真实帧率解耦）：headless 无渲染时钟
## 也可按帧数精确断言跟随行为。
##
## API：set_target(node, text) / clear_target() / set_text() / get_target()
## 不用 class_name（同 fail_counter.gd 的注释）。

const FOLLOW_HEIGHT := 1.1        # 气泡悬在目标上方多高
const STIFFNESS := 60.0           # 弹簧刚度
const DAMPING := 8.0              # 阻尼（ζ≈0.52，欠阻尼：有一点弹簧感）
const FIXED_DT := 1.0 / 60.0      # 每帧固定推进一步弹簧

const PANEL_COLOR := Color(0.549, 0.451, 0.392)   # 深层暖褐 #8C7364（粉彩沙盘调色板 #1）
const ACCENT_COLOR := Color(0.929, 0.471, 0.345)  # 机器珊瑚橙 #ED7858（粉彩沙盘调色板 #5）
const TEXT_COLOR := Color(0.973, 0.976, 0.984)

var _target: Node3D = null
var _vel := Vector3.ZERO
var _panel: MeshInstance3D
var _label: Label3D
var _line: MeshInstance3D


func _ready() -> void:
	top_level = true          # 气泡活在世界空间里，不随挂载的屏转
	_build()
	visible = false


# ---------- 对外 API ----------

## 指向一个目标并显示（首次显示先贴到目标上方，之后换目标靠弹簧飞过去）。
func set_target(target: Node3D, text := "") -> void:
	var was_hidden := not visible
	_target = target
	if text != "":
		set_text(text)
	if _target == null:
		clear_target()
		return
	visible = true
	if was_hidden:
		global_position = _goal()
		_vel = Vector3.ZERO
	_update_line()


func clear_target() -> void:
	_target = null
	visible = false
	_vel = Vector3.ZERO


func set_text(text: String) -> void:
	_label.text = _wrap_cjk(text, 10)


func get_target() -> Node3D:
	return _target


# ---------- 跟随 ----------

func _process(_delta: float) -> void:
	if not visible or _target == null or not is_instance_valid(_target):
		return
	_spring(FIXED_DT)
	_update_line()


func _spring(dt: float) -> void:
	var goal := _goal()
	_vel += (goal - global_position) * STIFFNESS * dt
	_vel *= maxf(0.0, 1.0 - DAMPING * dt)
	global_position += _vel * dt


func _goal() -> Vector3:
	return _target.global_position + Vector3(0.0, FOLLOW_HEIGHT, 0.0)


func _update_line() -> void:
	if not is_inside_tree() or _target == null or not is_instance_valid(_target):
		_line.visible = false
		return
	var to_target := _target.global_position - global_position
	var len := to_target.length()
	if len < 0.001:
		_line.visible = false
		return
	_line.visible = true
	_line.global_position = global_position + to_target * 0.5
	# 连线正对目标；目标恰在正上/正下方时 UP 平行于方向，换一个 up 防 look_at 报错
	var dir := to_target / len
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.99 else Vector3.FORWARD
	_line.look_at(_target.global_position, up)
	_line.scale = Vector3(1.0, 1.0, len)


# ---------- 搭建 ----------

func _build() -> void:
	_panel = MeshInstance3D.new()
	_panel.name = "Panel"
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(1.15, 0.55, 0.06)
	_panel.mesh = panel_mesh
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = PANEL_COLOR
	panel_mat.emission_enabled = true
	panel_mat.emission = ACCENT_COLOR
	panel_mat.emission_energy_multiplier = 0.35
	panel_mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	panel_mesh.material = panel_mat
	add_child(_panel)

	_label = Label3D.new()
	_label.name = "BubbleText"
	_label.font_size = 40
	_label.pixel_size = 0.004
	_label.modulate = TEXT_COLOR
	_label.outline_size = 10
	_label.outline_modulate = Color(0.125, 0.12, 0.10)   # 暖深灰（同明度，冷蓝灰转暖）
	_label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	add_child(_label)

	_line = MeshInstance3D.new()
	_line.name = "Tether"
	var line_mesh := BoxMesh.new()
	line_mesh.size = Vector3(0.035, 0.035, 1.0)
	_line.mesh = line_mesh
	var line_mat := StandardMaterial3D.new()
	line_mat.albedo_color = ACCENT_COLOR
	line_mat.emission_enabled = true
	line_mat.emission = ACCENT_COLOR
	line_mat.emission_energy_multiplier = 1.4
	line_mesh.material = line_mat
	add_child(_line)
	_line.visible = false


## CJK 按列数折行（Label3D 无自动换行；同 task_board.gd 的做法）。
func _wrap_cjk(text: String, cols: int) -> String:
	var lines: Array[String] = []
	var line := ""
	var count := 0
	for ch in text:
		line += ch
		count += 1
		if ch == "\n":
			lines.append(line.substr(0, line.length() - 1))
			line = ""
			count = 0
		elif count >= cols:
			lines.append(line)
			line = ""
			count = 0
	if line != "":
		lines.append(line)
	return "\n".join(lines)
