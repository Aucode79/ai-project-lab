extends Control

var active := false
var start := Vector2.ZERO
var finish := Vector2.ZERO

func set_drag_rect(a: Vector2, b: Vector2) -> void:
	active = true
	start = a
	finish = b
	queue_redraw()

func clear_drag_rect() -> void:
	active = false
	queue_redraw()

func _draw() -> void:
	if not active: return
	var rect := Rect2(start, finish - start).abs()
	draw_rect(rect, Color(0.25, 0.8, 0.85, 0.12), true)
	draw_rect(rect, Color(0.25, 0.8, 0.85, 0.9), false, 2.0)
