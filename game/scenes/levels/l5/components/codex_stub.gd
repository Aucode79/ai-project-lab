extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## codex 组件占位体（L5 专用）。
##
## 显式决定（本关口径）：L5 是五关终点，十四件齐备才能导出 Python；
## 但 L1–L4 的十件组件**以简化占位形式**装上——小方块 + 名牌即可，
## 本关不复刻前四关的全部行为（完整版在前四关各自的场景里）。
## 本节点就是那个"极简占位体"：世界侧它是真实实体（进注册表、进导出图），
## 视觉侧只有一方块 + 编号/名牌 Label3D。

const AssetNodeScript := preload("res://scripts/asset_lib/asset_node.gd")   # STANDARD_CUBE_SIZE：标准方块唯一尺寸来源

const CUBE_COLOR := Style.SHELL
const TEXT_COLOR := Style.INK

## 前四关的组色（编号对 mini-codex §一：1-2 L1 / 3,5,7 L4 / 4,6 L3 / 8,13,14 L2）
const LEVEL_TINTS := {
	1: Color(0.929, 0.471, 0.345),   # L1 暖色
	2: Color(0.929, 0.471, 0.345),
	3: Color(0.639, 0.804, 0.549),   # L4 绿
	4: Color(0.498, 0.851, 0.659),   # L3 薄荷绿
	5: Color(0.639, 0.804, 0.549),
	6: Color(0.498, 0.851, 0.659),
	7: Color(0.639, 0.804, 0.549),
	8: Color(0.851, 0.780, 0.655),   # L2 浅沙
	13: Color(0.851, 0.780, 0.655),
	14: Color(0.851, 0.780, 0.655),
}

var _number := 0
var _label := ""
var _cube_mat: StandardMaterial3D
var _num_label: Label3D
var _name_label: Label3D


func _ready() -> void:
	_build()
	set_stub(0, "（占位）")


# ---------- 对外 API ----------

## 编号 + 名牌（如 1 / 任务牌）；编号决定组色。
func set_stub(number: int, label: String) -> void:
	_number = number
	_label = label
	_cube_mat.albedo_color = LEVEL_TINTS.get(number, CUBE_COLOR)
	_num_label.text = "#%d" % number if number > 0 else ""
	_name_label.text = "%s·占位" % label if label != "" else "（占位）"


func get_stub_number() -> int:
	return _number


func get_stub_label() -> String:
	return _label


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 小方块（标准方块：STANDARD_CUBE_SIZE 0.5³，唯一尺寸来源；
	# 心 y 0.25 半嵌底垫——垫顶 0.125，嵌深 0.125 ≤ R3 上限）
	var cube := MeshInstance3D.new()
	cube.name = "Cube"
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3.ONE * AssetNodeScript.STANDARD_CUBE_SIZE
	cube.mesh = cube_mesh
	cube.position = Vector3(0.0, 0.25, 0.0)
	_cube_mat = StandardMaterial3D.new()
	_cube_mat.albedo_color = CUBE_COLOR
	_cube_mat.roughness = 0.6
	_cube_mat.metallic = 0.2
	cube_mesh.material = _cube_mat
	add_child(cube)

	# 底垫（半嵌地面：心 y 0，顶面出露 0.125）
	var pad := MeshInstance3D.new()
	pad.name = "Pad"
	var pad_mesh := BoxMesh.new()
	pad_mesh.size = Vector3(0.75, 0.25, 0.75)
	pad.mesh = pad_mesh
	pad.position = Vector3(0.0, 0.0, 0.0)
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.564, 0.533, 0.471)
	pad_mat.roughness = 0.68
	pad_mesh.material = pad_mat
	add_child(pad)

	# 编号（方块顶）
	_num_label = Label3D.new()
	_num_label.name = "NumLabel"
	_num_label.position = Vector3(0.0, 0.6, 0.0)
	_num_label.font_size = 30
	_num_label.pixel_size = 0.0028
	_num_label.modulate = TEXT_COLOR
	_num_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_num_label.double_sided = false
	add_child(_num_label)

	# 名牌（方块上方）
	_name_label = Label3D.new()
	_name_label.name = "StubLabel"
	_name_label.position = Vector3(0.0, 0.9, 0.0)
	_name_label.font_size = 32
	_name_label.pixel_size = 0.0028
	_name_label.modulate = TEXT_COLOR
	_name_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_name_label.double_sided = false
	add_child(_name_label)
