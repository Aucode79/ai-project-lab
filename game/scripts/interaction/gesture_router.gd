class_name GestureRouter
extends RefCounted
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")

## 手势路由（docs/10-契约/交互方案.md §二）：**长按是搬，点按是开**。
##
## 纯逻辑、无时钟、无节点依赖：所有事件经 feed() 注入、所有时间经参数注入，
## headless 测试直接构造 InputEvent 喂进来（见 tests/interaction/run_interaction_tests.gd T1）。
##
## 只路由鼠标左键（drag_long_press / open_tap 共用同一物理键，映射只注册基础键，
## 由这里按时长区分手势）；右键平移与滚轮缩放归 orbit_camera，不经过本路由。
##
## 状态机：
##   IDLE --按下--> PRESSING --松开(≤阈值)--> 发 tap_opened（点按=打开）
##                      |--按住(>阈值)--> 发 drag_start --> DRAGGING
##      DRAGGING --移动--> 发 drag_move（跟手）
##               --松开--> 发 drag_drop（真落下）

signal tap_opened(screen_pos: Vector2)
signal drag_start(screen_pos: Vector2)
signal drag_move(screen_pos: Vector2)
signal drag_drop(screen_pos: Vector2)

enum State { IDLE, PRESSING, DRAGGING }

var config: IC

var _state: State = State.IDLE
var _press_pos := Vector2.ZERO
var _press_ms := 0.0
var _now_ms := 0.0


func _init(cfg: IC = null) -> void:
	config = cfg if cfg != null else IC.new()


## 喂入原始输入事件。now_ms 由调用方注入（真实场景传 Time.get_ticks_msec()，
## 测试传假时钟）。支持 InputEventMouseButton（左键）与 InputEventMouseMotion。
func feed(event: InputEvent, now_ms: float) -> void:
	_now_ms = now_ms
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index != MOUSE_BUTTON_LEFT:
			return
		if mb.pressed:
			_press(mb.position, now_ms)
		else:
			_release(mb.position, now_ms)
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _state == State.DRAGGING:
			drag_move.emit(mm.position)
		elif _state == State.PRESSING:
			poll(now_ms)


## 每帧轮询：按住不动也要在超过阈值那一刻转成长按（不能只靠移动事件触发）。
## 宿主在 _physics_process 里调；测试手动注入假时钟。
func poll(now_ms: float) -> void:
	_now_ms = now_ms
	if _state == State.PRESSING and _held_ms(now_ms) > config.long_press_threshold_ms:
		_state = State.DRAGGING
		drag_start.emit(_press_pos)


func state() -> State:
	return _state


func held_ms() -> float:
	return _held_ms(_now_ms) if _state != State.IDLE else 0.0


func _press(pos: Vector2, now_ms: float) -> void:
	if _state != State.IDLE:
		return
	_state = State.PRESSING
	_press_pos = pos
	_press_ms = now_ms
	_now_ms = now_ms


func _release(pos: Vector2, now_ms: float) -> void:
	# 松开可能比下一次 physics poll 更早到达，先补做长按判定。
	poll(now_ms)
	if _state == State.PRESSING:
		# ≤阈值松开 = 点按（打开）。
		if _held_ms(now_ms) <= config.long_press_threshold_ms:
			tap_opened.emit(pos)
	elif _state == State.DRAGGING:
		drag_drop.emit(pos)
	_state = State.IDLE
	_now_ms = now_ms


func _held_ms(now_ms: float) -> float:
	return maxf(0.0, now_ms - _press_ms)
