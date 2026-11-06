extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 角色铭牌组件（docs/10-契约/mini-codex.md §一 #2；L1 两件之一）。
## 世界形态：任务牌背面的一张铭牌——显示 codex 名字与角色描述。
## 与任务牌同为家族一预设装配，不是新方块类型。
##
## 状态规则同任务牌（mini-codex §2.1）：铭牌自身无状态机，
## 亮不亮由步记录派生（L1 里 identity_out=1 后常亮）。

const PANEL_COLOR := Style.PAPER
const FRAME_COLOR := Style.SIGNAL
const POST_COLOR := Style.STRUCTURE
const TEXT_COLOR := Style.INK

var _name_text := ""
var _role_text := ""
var _name_label: Label3D
var _role_label: Label3D
var _frame_mat: StandardMaterial3D


func _ready() -> void:
	_build()
	apply_identity("mini codex", "")


# ---------- 对外 API ----------

## 名字与角色描述（set_identity 撞 Node3D 原生方法名，故叫 apply_identity）。
func apply_identity(display_name: String, role_text: String) -> void:
	_name_text = display_name
	_role_text = role_text
	_name_label.text = display_name
	_role_label.text = _wrap_cjk(role_text, 14)


func get_name_text() -> String:
	return _name_text


func get_role_text() -> String:
	return _role_text


## identity_out=1 时铭牌亮起（薄荷绿描边发光）。参数 bool，纯显示。
func set_identity_lit(lit: bool) -> void:
	_frame_mat.emission_enabled = lit
	_frame_mat.emission_energy_multiplier = 1.2 if lit else 0.0


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 柱（比任务牌矮一截——它是"牌背面的一张铭牌"；心挪 (0.125,·,0.125) 使六面落 0.25 格，2026-09-17 口径）
	var post := MeshInstance3D.new()
	post.name = "Post"
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.25, 1.0, 0.25)   # 细杆→0.25 方柱（R1/R2），顶接面板底 1.0
	post.mesh = post_mesh
	post.position = Vector3(0.125, 0.5, 0.125)
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = POST_COLOR
	post_mat.roughness = 0.6
	post_mat.metallic = 0.2
	post_mesh.material = post_mat
	add_child(post)

	# 面板（z 面 0..0.25 落格）
	var panel := MeshInstance3D.new()
	panel.name = "Panel"
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(1.5, 1.0, 0.25)
	panel.mesh = panel_mesh
	panel.position = Vector3(0.0, 1.5, 0.125)   # 完整落在 PickProxy 盒 (1.5,1.5,0.5)@y1.5 内（x 贴满、y/z 居中）
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = PANEL_COLOR
	panel_mat.roughness = 0.5
	panel_mesh.material = panel_mat
	add_child(panel)

	# 边框（薄荷绿，identity_out=1 时发光；描边 0.25 才能让六面都落 0.25 格——露边由 0.125 加宽到 0.25）
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(2.0, 1.5, 0.25)
	frame.mesh = frame_mesh
	frame.position = Vector3(0.0, 1.5, -0.125)   # 贴面板背面（z 面相接），四周露 0.25 边
	_frame_mat = StandardMaterial3D.new()
	_frame_mat.albedo_color = FRAME_COLOR
	_frame_mat.roughness = 0.4
	frame_mesh.material = _frame_mat
	add_child(frame)

	# 名字
	_name_label = Label3D.new()
	_name_label.name = "NameText"
	_name_label.position = Vector3(0.0, 1.75, 0.265)   # 悬在面板前面（前面 z=0.25）
	_name_label.font_size = 64
	_name_label.pixel_size = 0.0028
	_name_label.modulate = TEXT_COLOR
	_name_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_name_label.double_sided = false
	add_child(_name_label)

	# 角色描述
	_role_label = Label3D.new()
	_role_label.name = "RoleText"
	_role_label.position = Vector3(0.0, 1.25, 0.265)   # 悬在面板前面（前面 z=0.25）
	_role_label.font_size = 34
	_role_label.pixel_size = 0.003
	_role_label.modulate = Color(0.35, 0.34, 0.28)
	_role_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_role_label.double_sided = false
	add_child(_role_label)


func _wrap_cjk(text: String, cols: int) -> String:
	if text == "":
		return ""
	var lines: Array[String] = []
	var line := ""
	var count := 0
	for ch in text:
		line += ch
		count += 1
		if count >= cols:
			lines.append(line)
			line = ""
			count = 0
	if line != "":
		lines.append(line)
	return "\n".join(lines)
