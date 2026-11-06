extends RefCounted

## 沙盒里的「组件目录」：把新组件体系的四层展开接进真实沙盒。
##
## 沙盒的 28 件旧资产与新 26 件设计对象不是同一套 id，所以这里**不做猜测映射**：
## 目录是一个显式入口（沙盒里按 K），从第一个已映射对象开始，用生产阅读器渲染，
## 数字键逐层展开、Tab 换对象、B 返回、Esc 关闭。旧资产的点开行为不受影响。

const Reader := preload("res://scripts/interaction/unfolding_reader.gd")
const Map := preload("res://scripts/interaction/unfolding_map.gd")

var active := false
var reader := Reader.new()
var _view: WeakRef


func open(hub, owner: Node3D) -> bool:
	var ids: Array = Map.objects()
	if ids.is_empty():
		return false
	hub.open_view.close()
	_view = weakref(hub.open_view)
	hub.open_view.scrollable_source = true
	hub.open_view.choices_provider = reader.choices
	hub.open_view.choice_handler = _choose
	reader.reset(String(ids[0]))
	active = true
	hub.open_view.open(owner, "catalog:" + reader.object_id)
	return true


func text() -> String:
	return reader.text()


## 返回 true 表示状态已变，调用方负责重画。
func handle_key(keycode: int) -> bool:
	return active and reader.handle_key(keycode)


func deactivate() -> void:
	active = false
	if _view != null and _view.get_ref() != null:
		var view = _view.get_ref()
		view.scrollable_source = false
		view.choices_provider = Callable()
		view.choice_handler = Callable()
	_view = null

func _choose(index: int) -> void:
	if active and reader.select_choice(index) and _view != null and _view.get_ref() != null:
		_view.get_ref().refresh()
		_view.get_ref().reset_scroll()
