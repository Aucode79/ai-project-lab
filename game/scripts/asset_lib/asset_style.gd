extends RefCounted

## Shared visual roles for teaching assets; terrain keeps its own palette.
const INK := Color("263b40")
const STRUCTURE := Color("536b73")
const SECONDARY := Color("8ca3a6")
const SHELL := Color("b9cbcb")
const PAPER := Color("f7f0d8")
const ACTION := Color("ef743b")
const SIGNAL := Color("24b9cf")
const CORE := Color("f2c43d")
const SUCCESS := Color("68ab5d")
const ERROR := Color("db6268")
const MUTED := Color("8f9998")

const PALETTE := [INK, STRUCTURE, SHELL, PAPER, ACTION, CORE, SIGNAL]

const MEMORY := Color("4279d4")
const LOOP := Color("9261c5")
const CHECK := Color("546066")
const BACKGROUND := Color("fdfcf9")
static var _materials := {}

## Shared immutable matte materials: meshes reuse them; state lamps keep their own material.
static func matte(color: Color) -> StandardMaterial3D:
	if _materials.has(color):
		return _materials[color]
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = 0.82
	_materials[color] = material
	return material


## matte 的发光工作态变体：同参数基色叠低能量自发光（emission≈基色），用于"正在工作"高亮。
static func lit(color: Color) -> StandardMaterial3D:
	var key := "lit/" + color.to_html()
	if _materials.has(key):
		return _materials[key]
	var material: StandardMaterial3D = matte(color).duplicate()
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.35
	_materials[key] = material
	return material


static func ui_theme() -> Theme:
	var theme := Theme.new()
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC"])
	theme.default_font = font
	theme.default_font_size = 18
	for state in ["normal", "hover", "pressed", "focus", "disabled"]:
		var box := StyleBoxFlat.new()
		box.bg_color = PAPER if state == "normal" else Color("f1dcc8")
		box.border_color = ACTION if state in ["hover", "focus"] else SHELL
		box.set_border_width_all(2 if state == "focus" else 1)
		box.set_corner_radius_all(5)
		box.content_margin_left = 16
		box.content_margin_right = 16
		box.content_margin_top = 8
		box.content_margin_bottom = 8
		theme.set_stylebox(state, "Button", box)
	for key in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		theme.set_color(key, "Button", INK)
	return theme
