extends CanvasLayer

## On-demand navigation shared by the studio, sandbox and five lessons.
const Style := preload("res://scripts/asset_lib/asset_style.gd")
const DESTINATIONS := [
	["沙盒 · 可执行程序机器", "res://scenes/lessons/agent_lab.tscn"],
	["组件工坊 · 阅读与摆放", "res://scenes/studio/component_studio.tscn"],
	["第一课 · 真实 Agent 运输", "res://scenes/lessons/agent_transport.tscn"],
	["组件资产工区 · 拼装与导出", "res://scenes/sandbox/sandbox.tscn"],
	["L1  任务与角色", "res://scenes/levels/l1/l1.tscn"],
	["L2  读取与修改", "res://scenes/levels/l2/l2.tscn"],
	["L3  上下文与记忆", "res://scenes/levels/l3/l3.tscn"],
	["L4  计划与工具", "res://scenes/levels/l4/l4.tscn"],
	["L5  执行与校验", "res://scenes/levels/l5/l5.tscn"],
]
var panel: Control

func _ready() -> void:
	layer = 20

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F1 or (event.keycode == KEY_ESCAPE and panel != null):
			if panel != null: close()
			else: show_menu()
			get_viewport().set_input_as_handled()
	elif panel != null and (event is InputEventMouseMotion or event is InputEventMouseButton):
		# The panel's Controls handle pointer input; it must not move the world camera.
		return

func close() -> void:
	get_parent().set_meta("scene_menu_open", false)
	if panel != null: panel.queue_free()
	panel = null

func show_menu() -> void:
	get_parent().set_meta("scene_menu_open", true)
	panel = Control.new()
	panel.theme = Style.ui_theme()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(panel)
	var background := ColorRect.new()
	background.color = Style.BACKGROUND
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(background)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.add_child(center)
	var stack := VBoxContainer.new()
	stack.custom_minimum_size.x = 520
	stack.add_theme_constant_override("separation", 10)
	center.add_child(stack)
	var title := Label.new()
	title.text = "AI PROJECT LAB  /  方块实验室"
	title.add_theme_color_override("font_color", Style.INK)
	title.add_theme_font_size_override("font_size", 28)
	stack.add_child(title)
	if get_parent().has_method("open_python_picker") and not bool(get_parent().get("sample_mode")):
		var import_button := Button.new()
		import_button.text = "导入 Python 程序…"
		import_button.custom_minimum_size.y = 48
		import_button.add_theme_font_size_override("font_size", 20)
		import_button.pressed.connect(func():
			close()
			get_parent().call("open_python_picker"))
		stack.add_child(import_button)
	for destination in DESTINATIONS:
		var button := Button.new()
		button.text = destination[0]
		button.custom_minimum_size.y = 48
		button.add_theme_font_size_override("font_size", 20)
		button.pressed.connect(func():
			get_tree().set_meta("start_lesson_demo", "/levels/" in destination[1])
			get_tree().change_scene_to_file(destination[1]))
		stack.add_child(button)
	var back := Button.new()
	back.text = "返回当前场景  ·  Esc / F1"
	back.custom_minimum_size.y = 42
	back.pressed.connect(close)
	stack.add_child(back)
	var note := Label.new()
	note.text = "切换前可在工坊按 Ctrl+S 保存布局；沙盒用场内存档块。"
	note.add_theme_color_override("font_color", Style.INK)
	stack.add_child(note)
