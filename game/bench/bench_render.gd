extends Node

## 数一：单帧渲染耗时（1920×1080、25 fps、最终光影配置）。
##
## 两种跑法共用本脚本，由 bench_world 按 mode 派发：
##   render      ：Movie Maker（--write-movie PNG 序列 + --fixed-fps 25）→ 含写盘的单帧耗时
##   render-pure ：不开 Movie Maker、关垂直同步全速跑 → 纯渲染（含提交与呈现）的单帧耗时
## 两者都跳过 WARMUP_FRAMES 帧预热——体素流式加载与网格化会污染前段数据。
## headless 是 dummy 渲染器测不了真耗时，本 bench 只在有窗口的跑法下使用。


const BW := preload("res://bench/bench_world.gd")
const Util := preload("res://bench/bench_report.gd")

const WARMUP_FRAMES := 100        # 4 s @25fps：等体素流式加载与 AO 稳定
const SAMPLE_FRAMES := 250        # 10 s @25fps 的采样帧
const FRAMES_PER_EPISODE := 10400 # 一集约 4–8 分钟轨道，按 25 fps 取 416 s
const EPISODES := 63


var world: BW
var outfile := ""

var _walls: Array[float] = []
var _proc: Array[float] = []
var _phys: Array[float] = []
var _frame := 0
var _last_us := 0
var _movie := false
var _done := false


func _ready() -> void:
	_movie = Engine.get_write_movie_path() != ""
	_arm_when_ready()
	if DisplayServer.get_name() != "headless":
		# 关垂直同步：让墙钟帧耗时反映真实成本，而不是被显示器刷新率封顶
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_last_us = Time.get_ticks_usec()
	var adapter := "unknown"
	if OS.has_method("get_video_adapter_name"):
		adapter = str(OS.call("get_video_adapter_name"))
	print("RENDER BENCH: movie=%s viewport=%s adapter=%s" % [
		str(_movie), str(get_viewport().get_visible_rect().size), adapter])
	set_meta("adapter", adapter)


func _arm_when_ready() -> void:
	# 体素碰撞体就绪前方块全部冻结；就绪后放行，统计帧从放行后起算
	if not await world.wait_ready(900):
		print("RENDER BENCH: FAIL（体素地形未就绪）")
		get_tree().quit(1)
		return
	if not await world.wait_collisions(900):
		print("RENDER BENCH: FAIL（体素碰撞体未就绪）")
		get_tree().quit(1)
		return
	world.arm_physics()


func _process(_delta: float) -> void:
	if _done or not world.armed:
		_last_us = Time.get_ticks_usec()
		return
	var now := Time.get_ticks_usec()
	var wall_ms := float(now - _last_us) / 1000.0
	_last_us = now
	_frame += 1
	if _frame >= 3 and _frame > WARMUP_FRAMES:
		_walls.append(wall_ms)
		_proc.append(Performance.get_monitor(Performance.TIME_PROCESS))
		_phys.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
		if _walls.size() >= SAMPLE_FRAMES:
			_finish()


func _finish() -> void:
	_done = true
	var mean_ms := Util.mean(_walls)
	var total_frames := FRAMES_PER_EPISODE * EPISODES
	var vp := get_viewport().get_visible_rect().size
	var report := {
		"date": Time.get_datetime_string_from_system(true),
		"movie_png_write": _movie,
		"fixed_fps": 25 if _movie else 0,
		"resolution": [int(vp.x), int(vp.y)],
		"vsync": ("disabled" if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_DISABLED else "enabled" if DisplayServer.window_get_vsync_mode() == DisplayServer.VSYNC_ENABLED else "adaptive"),
		"adapter": str(get_meta("adapter", "unknown")),
		"warmup_frames": WARMUP_FRAMES,
		"sample_frames": _walls.size(),
		"frame_wall_ms_mean": mean_ms,
		"frame_wall_ms_p95": Util.percentile(_walls, 0.95),
		"frame_wall_ms_max": _walls.max(),
		"frame_wall_ms_min": _walls.min(),
		"engine_time_process_ms_mean": Util.mean(_proc),
		"engine_physics_process_ms_mean": Util.mean(_phys),
		"per_episode_render_min": mean_ms * float(FRAMES_PER_EPISODE) / 60000.0,
		"total_frames_63ep": total_frames,
		"total_render_hours_63ep": mean_ms * float(total_frames) / 3600000.0,
	}
	Util.write_json(outfile, report)
	print("RENDER BENCH 完成：mean=%.2fms p95=%.2fms max=%.2fms（%d 帧，%s）" % [
		mean_ms, report["frame_wall_ms_p95"], report["frame_wall_ms_max"],
		_walls.size(), "含 PNG 写盘" if _movie else "纯渲染"])
	get_tree().quit(0)
