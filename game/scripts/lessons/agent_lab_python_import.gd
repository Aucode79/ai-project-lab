extends Node

## One gesture imports a Python file into the executable 3D program graph.
const Style := preload("res://scripts/asset_lib/asset_style.gd")
var lab: Variant
var picker: FileDialog
var error_dialog: AcceptDialog
var run_dialog: ConfirmationDialog
var run_field: LineEdit
var run_button: Button
var constant_dialog: ConfirmationDialog
var constant_field: LineEdit
var importing := false
var run_after_input := true


func _ready() -> void:
	lab = get_parent()
	picker = FileDialog.new()
	picker.access = FileDialog.ACCESS_FILESYSTEM
	picker.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	picker.filters = PackedStringArray(["*.py ; Python source"])
	picker.use_native_dialog = true
	picker.file_selected.connect(_import_file)
	add_child(picker)
	error_dialog = AcceptDialog.new()
	error_dialog.title = "Python 导入失败"
	add_child(error_dialog)
	run_dialog = ConfirmationDialog.new()
	run_dialog.title = "编辑入口输入"
	run_dialog.dialog_text = "输入值会显示在 3D 输入口上；运行时直接使用这个值。"
	run_dialog.ok_button_text = "更新输入"
	run_dialog.min_size = Vector2i(520, 160)
	run_field = LineEdit.new()
	run_field.position = Vector2(20, 70)
	run_field.size = Vector2(480, 34)
	run_field.placeholder_text = "例如：{\"count\": 0} 或 [1, 2, 3]"
	run_dialog.add_child(run_field)
	run_dialog.confirmed.connect(_run_input_confirmed)
	add_child(run_dialog)
	constant_dialog = ConfirmationDialog.new()
	constant_dialog.title = "编辑程序常量"
	constant_dialog.dialog_text = "输入 JSON 标量；字符串要带双引号。"
	constant_dialog.ok_button_text = "保存"
	constant_dialog.min_size = Vector2i(520, 160)
	constant_field = LineEdit.new()
	constant_field.position = Vector2(20, 70)
	constant_field.size = Vector2(480, 34)
	constant_field.placeholder_text = "例如：3、\"hello\"、true 或 null"
	constant_dialog.add_child(constant_field)
	constant_dialog.confirmed.connect(_constant_edit_confirmed)
	add_child(constant_dialog)
	get_window().files_dropped.connect(_files_dropped)
	if not lab.sample_mode:
		var actions := CanvasLayer.new()
		actions.name = "ProgramActions"
		actions.layer = 10
		add_child(actions)
		run_button = Button.new()
		run_button.name = "RunProgramButton"
		run_button.text = "运行程序  ·  空格"
		run_button.tooltip_text = "Python 程序使用 3D 输入口上显示的值；选中 task 输入口按 F2 修改。"
		run_button.position = Vector2(24, 24)
		run_button.custom_minimum_size = Vector2(210, 48)
		run_button.theme = Style.ui_theme()
		run_button.pressed.connect(_run_button_pressed)
		actions.add_child(run_button)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.ctrl_pressed and event.keycode == KEY_O:
		if not lab.get_meta("scene_menu_open", false):
			open_picker()
		get_viewport().set_input_as_handled()

func open_picker() -> void:
	if lab.sample_mode:
		_show_error("教学样例是只读的。请进入可执行程序场景后导入。")
		return
	picker.popup_centered_ratio(0.7)


func open_run_input(run_after := false) -> void:
	run_after_input = run_after
	run_field.text = JSON.stringify(lab.get_meta("run_input", lab.program.get("exampleTask", null)))
	run_dialog.popup_centered()
	run_field.grab_focus()
	run_field.select_all()


func _run_button_pressed() -> void:
	if lab.program.is_empty():
		_show_error("程序尚未加载。")
		return
	if lab.run_status != "running":
		lab.call("_submit")


func open_constant_editor() -> void:
	if lab.selected_node_ids.size() != 1:
		_show_error("先选中一个常量节点，再按 F2 编辑。")
		return
	for node in lab.program.get("modules", {}).get(lab.view_mid, {}).get("nodes", []):
		if str(node.get("id", "")) != lab.selected_node_ids[0]: continue
		if str(node.get("op", "")) == "input":
			var entry: Dictionary = lab.program.get("modules", {}).get(str(lab.program.get("entry", "")), {})
			if str(entry.get("language", "")) == "python":
				open_run_input(false)
				return
		if str(node.get("op", "")) != "const":
			_show_error("F2 只编辑常量节点或 Python 入口输入。")
			return
		var params: Dictionary = node.get("params", {})
		var value: Variant = params.get("value", null)
		constant_field.text = str(int(value)) if str(params.get("literalType", "")) == "int" \
			else JSON.stringify(value)
		constant_dialog.popup_centered()
		constant_field.grab_focus()
		constant_field.select_all()
		return
	_show_error("当前选中的节点已不存在。")


func _run_input_confirmed() -> void:
	var parsed := JSON.new()
	if parsed.parse(run_field.text) != OK:
		_show_error("运行输入必须是有效 JSON：" + parsed.get_error_message())
		return
	if lab.sample_mode or lab.run_status == "running": return
	lab.set_meta("run_input", parsed.data)
	if lab.has_method("build_machine"):
		lab.call("build_machine", lab.view_mid)
	if not run_after_input: return
	var body := "{\"task\":" + run_field.text + "}"
	var result: Dictionary = await lab.api("/run", null, body)
	if not result.get("ok", false):
		var message := str(result.get("error", "程序启动失败"))
		var errors: Array = result.get("errors", [])
		if not errors.is_empty(): message = str(errors[0].get("message", message))
		_show_error(message)


func _constant_edit_confirmed() -> void:
	var parsed := JSON.new()
	if parsed.parse(constant_field.text) != OK:
		_show_error("常量必须是有效的 JSON 标量：" + parsed.get_error_message())
		return
	var value: Variant = parsed.data
	var raw := constant_field.text.strip_edges()
	if typeof(value) == TYPE_FLOAT and not raw.contains(".") and not raw.to_lower().contains("e"):
		var integer := int(raw)
		if str(integer) != raw and raw != "-0":
			_show_error("整数超出 64 位范围。")
			return
		value = integer
	if typeof(value) not in [TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_BOOL, TYPE_NIL]:
		_show_error("常量只接受数字、字符串、布尔值或 null。")
		return
	if typeof(value) == TYPE_FLOAT and not is_finite(value):
		_show_error("数字必须是有限值。")
		return
	lab.call("_set_selected_constant", value)


func _files_dropped(files: PackedStringArray) -> void:
	if files.size() != 1:
		_show_error("一次只接受一个 Python 文件。")
		return
	_import_file(files[0])


func _import_file(path: String) -> void:
	if importing:
		return
	if lab.sample_mode:
		_show_error("教学样例是只读的。请进入可执行程序场景后导入。")
		return
	if path.get_extension().to_lower() != "py":
		_show_error("请选择 .py 文件。")
		return
	var stream := FileAccess.open(path, FileAccess.READ)
	if stream == null:
		_show_error("无法读取文件：" + path)
		return
	if stream.get_length() > 1024 * 1024:
		_show_error("Python 文件不能超过 1 MiB。")
		return
	var source_bytes := stream.get_buffer(stream.get_length())
	stream.close()
	var source := source_bytes.get_string_from_utf8()
	if source.to_utf8_buffer() != source_bytes:
		_show_error("Python 文件必须使用 UTF-8 编码。")
		return
	importing = true
	var result: Dictionary = await lab.api("/import", {
		"source": source, "filename": path.get_file(), "revision": lab.revision})
	if not result.get("ok", false):
		importing = false
		var message := str(result.get("error", "Python 导入失败"))
		if message == "Unknown endpoint":
			message = "当前 Agent Lab 后台服务是旧版本。请关闭旧 lab_service.py 后重新启动 Agent Lab。"
		var errors: Array = result.get("errors", [])
		if not errors.is_empty(): message = str(errors[0].get("message", message))
		_show_error(message)
		return
	lab.selected_node_ids.clear()
	lab.crumb.clear()
	await lab.load_program()
	importing = false


func _show_error(message: String) -> void:
	push_error(message)
	error_dialog.dialog_text = message
	error_dialog.popup_centered()
