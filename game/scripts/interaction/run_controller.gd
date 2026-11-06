class_name RunController
extends Node
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")

## 运行与时间控制（docs/10-契约/交互方案.md §四）：
##   空格  = 单一运行键：跑 / 停
##   `,` `.`= 单步前 / 后（world.step 语义：引擎真单步）
##   慢放 0.5×/0.25×、加速 2×/4× = **只靠取帧**（Engine.time_scale 控制帧流），
##   **绝不放大物理步长**（Engine.physics_ticks_per_second 一根手指都不碰——
##   放大步长会让东西穿透、堆叠炸开，美术方向引用的 Besiege 官方论坛实测现象）。
##
## 世界侧动作经 Callable 注入（真实场景接 WorldToolsCore 的 world.run / world.step；
## step_back 需要历史回退能力，demo 状态层暂无，注入为空时结构化拒绝而不是装能）。

signal run_state_changed(running: bool)
signal speed_changed(mult: float)

var config: IC

var run_start: Callable = Callable()
var run_stop: Callable = Callable()
## 单步前（world.step 真单步）
var step_forward_fn: Callable = Callable()
## 单步后（需要历史回退，注入为空 = 结构化不支持）
var step_back_fn: Callable = Callable()

var running := false
var speed_index := 0

var _tick_rate_at_ready := -1


func _init(cfg: IC = null) -> void:
	config = cfg if cfg != null else IC.new()


## 空格：跑/停翻转。返回翻转后的状态。
func toggle_run() -> bool:
	running = not running
	if running:
		if run_start.is_valid():
			run_start.call()
	else:
		if run_stop.is_valid():
			run_stop.call()
	run_state_changed.emit(running)
	return running


## `.`：单步前——引擎真单步（world.step 语义），不是把动画放慢。
func step_forward() -> Dictionary:
	return _call_step(step_forward_fn, "world.step")


## `,`：单步后——需要注入历史回退；未注入时结构化拒绝。
func step_back() -> Dictionary:
	return _call_step(step_back_fn, "history.step_back")


func _call_step(fn: Callable, label: String) -> Dictionary:
	if not fn.is_valid():
		return {"ok": false, "code": "unsupported",
			"message": "未注入 %s 提供方（demo 状态层无历史回退）" % label}
	var ret: Variant = fn.call()
	if ret is Dictionary:
		return ret
	return {"ok": true, "result": ret}


# ---------- 慢放 / 加速（取帧，不动物理步长） ----------

## 循环档位：1× → 0.5× → 0.25× → 2× → 4× → 1×。返回当前倍速。
func cycle_speed() -> float:
	speed_index = (speed_index + 1) % config.speed_steps.size()
	return set_speed(config.speed_steps[speed_index])


## 直接设倍速（0.25 / 0.5 / 1 / 2 / 4）。只动 Engine.time_scale。
func set_speed(mult: float) -> float:
	mult = clampf(mult, 0.1, 4.0)
	Engine.time_scale = mult
	# 档位表里能对上的就同步索引，cycle_speed 才连续
	var idx := config.speed_steps.find(mult)
	if idx >= 0:
		speed_index = idx
	# 纪律自检：物理 tick 率必须保持入场时的值（谁都不许靠放大步长做慢放）
	assert(Engine.physics_ticks_per_second == _tick_rate_at_ready,
		"physics_ticks_per_second 被人动了——慢放只许取帧，不许放大步长")
	speed_changed.emit(mult)
	return Engine.time_scale


func current_speed() -> float:
	return Engine.time_scale


func reset_speed() -> void:
	speed_index = 0
	Engine.time_scale = 1.0


func _ready() -> void:
	_tick_rate_at_ready = Engine.physics_ticks_per_second
