class_name OpenController
extends CanvasLayer
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")

## 点按打开（docs/10-契约/交互方案.md §二）：点按任一物件 → **占满全屏**看它的代码/面板。
## 它是"界面上不放东西"的唯一例外：只在打开时出现，**不常驻**，
## ESC / 再点一下立即关闭回到世界。
##
## 本阶段最小实现：全屏 SubViewport 容器显示该物件的占位内容
## （code_provider 注入真实内容源，例如 WorldToolsCore.export_python 的产物；
## 未注入时显示实体名占位）。

signal view_opened(entity_id: String)
signal view_closed()

var config: IC

## (Node3D target) -> String：该物件的代码/面板文本。不注入就用占位。
var code_provider: Callable = Callable()
## (keycode: int) -> bool：阅读器内部分层导航的按键消费方。返回 true 表示已处理。
var key_provider: Callable = Callable()
## (target: Node3D) -> void：**打开**时调用一次，用来重置阅读状态。
## 只在 open() 里调用，refresh() 不碰它——否则分层状态会被重新渲染覆盖掉。
var open_hook: Callable = Callable()
## Opt-in source reader: internal clicks/scroll remain inside the view; Esc closes.
## Legacy sandbox panels retain their existing click-to-close behavior.
var scrollable_source := false
var choices_provider: Callable
var choice_handler: Callable
var _choices: VBoxContainer
const Style := preload("res://scripts/asset_lib/asset_style.gd")

var _overlay: Control = null
var _container: SubViewportContainer = null
var _viewport: SubViewport = null
var _label: Label = null
var _open_target: Node3D = null
var _open_entity_id := ""
var _resize_connected := false


## 阅读器布局：按视口实际尺寸显式给定，不依赖锚点或父尺寸回读。
func _reader_viewport_size() -> Vector2:
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	if viewport_size.x < 1.0 or viewport_size.y < 1.0:
		# headless 无视口尺寸：退回项目窗口配置，布局仍确定可测。
		viewport_size = Vector2(
			float(ProjectSettings.get_setting("display/window/size/viewport_width", 1152)),
			float(ProjectSettings.get_setting("display/window/size/viewport_height", 648)))
	return viewport_size


func _reader_inset(viewport_size: Vector2) -> float:
	return minf(32.0, minf(viewport_size.x, viewport_size.y) * 0.08)


func _layout_source_reader() -> void:
	if _overlay == null or not is_instance_valid(_overlay):
		return
	var viewport_size := _reader_viewport_size()
	var inset := _reader_inset(viewport_size)
	# _overlay 走 FULL_RECT 锚点自适应，不再显式赋 size（会被布局覆盖）。
	var background := _overlay.get_node_or_null("SourceBackground") as ColorRect
	if background != null:
		background.size = viewport_size
	var scroll := _overlay.get_node_or_null("SourceScroll") as ScrollContainer
	if scroll != null:
		scroll.position = Vector2(inset, inset + 58)
		scroll.size = viewport_size - Vector2.ONE * inset * 2.0 - Vector2(0, 58)


func _init(cfg: IC = null) -> void:
	config = cfg if cfg != null else IC.new()


func is_open() -> bool:
	return _overlay != null and is_instance_valid(_overlay)


func open_target() -> Node3D:
	return _open_target


## 打开：全屏 SubViewport 容器 + 占位内容。重复 open 直接换内容（仍只一块屏）。
func open(target: Node3D, entity_id: String = "") -> void:
	if target == null:
		return
	_open_target = target
	_open_entity_id = entity_id if entity_id != "" else target.name
	if not is_open():
		_build_overlay()
	if open_hook.is_valid():
		open_hook.call(target)
	_label.text = _content_text()
	_refresh_choices()
	view_opened.emit(_open_entity_id)


## 关闭：整块视图拆掉，立刻回到世界（无残留）。
func close() -> void:
	if _resize_connected:
		get_viewport().size_changed.disconnect(_layout_source_reader)
		_resize_connected = false
	if is_open():
		_overlay.queue_free()
	_overlay = null
	_container = null
	_viewport = null
	_label = null
	_open_target = null
	_choices = null
	view_closed.emit()


## 重新拉取内容（分层导航切换后调用）。
func refresh() -> void:
	if is_open():
		_label.text = _content_text()
		_refresh_choices()
		if _viewport != null: _viewport.render_target_update_mode = SubViewport.UPDATE_ONCE


## 回到内容顶部（换层时用，避免停在上一次的滚动位置）。
func reset_scroll() -> void:
	if not is_open() or _overlay == null:
		return
	var scroll := _overlay.get_node_or_null("SourceScroll") as ScrollContainer
	if scroll != null:
		scroll.scroll_vertical = 0
		scroll.scroll_horizontal = 0


## ESC / 打开状态下再点一下 = 关闭。真实输入走 _input，测试直接 feed。
func feed(event: InputEvent) -> bool:
	if not is_open():
		return false
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo:
			if k.keycode == KEY_ESCAPE:
				close()
				return true
			if key_provider.is_valid() and bool(key_provider.call(k.keycode)):
				return true
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and scrollable_source and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			var scroll := _overlay.get_node_or_null("SourceScroll") as ScrollContainer
			if scroll != null:
				scroll.scroll_vertical += -90 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 90
			return true
		if mb.pressed and not scrollable_source:
			close()
			return true
	return false


func _input(event: InputEvent) -> void:
	if feed(event): get_viewport().set_input_as_handled()


func _content_text() -> String:
	if code_provider.is_valid():
		var text: Variant = code_provider.call(_open_target)
		if text is String and (text as String) != "":
			return text
	return "%s\n\n%s\n\n%s" % [
		_open_entity_id,
		"(代码/面板占位视图)",
		"点按打开 → 全屏查看；ESC 或再点一下关闭，立刻回到世界。",
	]


func _build_overlay() -> void:
	_overlay = Control.new()
	_overlay.name = "OpenViewOverlay"
	_overlay.theme = Style.ui_theme()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_overlay)

	if scrollable_source:
		var viewport_size := _reader_viewport_size()
		var inset := _reader_inset(viewport_size)
		var background := ColorRect.new()
		background.name = "SourceBackground"
		background.color = Style.BACKGROUND
		background.size = viewport_size
		_overlay.add_child(background)
		var scroll := ScrollContainer.new()
		scroll.name = "SourceScroll"
		scroll.position = Vector2(inset, inset + 58)
		scroll.size = viewport_size - Vector2.ONE * inset * 2.0 - Vector2(0, 58)
		_overlay.add_child(scroll)
		var stack := VBoxContainer.new()
		stack.add_theme_constant_override("separation", 20)
		scroll.add_child(stack)
		_choices = VBoxContainer.new()
		stack.add_child(_choices)
		_label = Label.new()
		_label.name = "Content"
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.add_theme_font_size_override("font_size", 20)
		_label.add_theme_color_override("font_color", Color("263b40"))
		stack.add_child(_label)
		_build_reader_toolbar(inset)
		if not _resize_connected:
			get_viewport().size_changed.connect(_layout_source_reader)
			_resize_connected = true
		return

	# 全屏 SubViewport 容器：内容画在独立 viewport 里，为后续"面板进一步交互"留位
	_container = SubViewportContainer.new()
	_container.name = "OpenViewPort"
	_container.set_anchors_preset(Control.PRESET_FULL_RECT)
	_container.stretch = true
	_overlay.add_child(_container)

	_viewport = SubViewport.new()
	_viewport.name = "OpenView"
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_container.add_child(_viewport)

	var background := ColorRect.new()
	background.color = Style.BACKGROUND
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport.add_child(background)
	_label = Label.new()
	_label.add_theme_color_override("font_color", Style.INK)
	_label.add_theme_font_override("font", Style.ui_theme().default_font)
	_label.name = "Content"
	_label.position = Vector2(80, 80)
	_label.add_theme_font_size_override("font_size", 24)
	_viewport.add_child(_label)


func _build_reader_toolbar(inset: float) -> void:
	var row := HBoxContainer.new()
	row.position = Vector2(inset, inset)
	row.add_theme_constant_override("separation", 12)
	_overlay.add_child(row)
	for pair in [["← 返回上层", KEY_B], ["下一组件 →", KEY_TAB], ["关闭  Esc", KEY_ESCAPE]]:
		var button := Button.new()
		button.text = pair[0]
		button.custom_minimum_size = Vector2(148, 42)
		button.add_theme_font_size_override("font_size", 18)
		var key: int = pair[1]
		button.pressed.connect(func():
			if key == KEY_ESCAPE: close()
			elif key_provider.is_valid(): key_provider.call(key))
		row.add_child(button)

func _refresh_choices() -> void:
	if _choices == null: return
	for child in _choices.get_children():
		_choices.remove_child(child)
		child.queue_free()
	if not choices_provider.is_valid(): return
	var entries: Array = choices_provider.call()
	for index in entries.size():
		var button := Button.new()
		button.text = "%02d   %s   →" % [index + 1, entries[index].get("title", "")]
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.custom_minimum_size.y = 44
		button.add_theme_font_size_override("font_size", 18)
		button.pressed.connect(func():
			if choice_handler.is_valid(): choice_handler.call(index))
		_choices.add_child(button)
