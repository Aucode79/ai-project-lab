extends Node

## 数三：落点前推预测成本（拖拽虚影，交互侧早量的数）。
##
## 一次预测 = 把一个刚体克隆到独立 physics space 里前推 2 秒（同引擎、同固定 dt）。
## 本脚本量四件事：
##   1. 基线：50 刚体世界本身的 physics step 耗时
##   2. "每帧预测"策略：每 tick 发起一条新预测，稳态 120 条在飞（2 s × 60 Hz），
##      量它给 physics step 增加的毫秒数
##   3. "100 ms 降频预测"策略：每 6 tick 一条，稳态 20 条在飞
##   4. 克隆/重置一次的微成本，与单次 2 秒前推的墙钟延迟
## 若独立 space 不被主循环步进（探针检测），自动回退"主空间 + 专用碰撞层隔离"
## 并在报告里记录实际使用的模式。


const BW := preload("res://bench/bench_world.gd")
const Util := preload("res://bench/bench_report.gd")

const TICK_RATE := 60.0
const HORIZON_TICKS := 120          # 前推 2 s @ 60 Hz
const GHOST_POOL := 128
const WARMUP_TICKS := 120
const BASELINE_TICKS := 240
const PHASE_TICKS := 360            # 前 120 tick 爬坡到稳态，丢弃；后 240 tick 采数
const SKIP_TICKS := 140             # 丢弃的爬坡段（略高于 HORIZON）
const COOLDOWN_TICKS := 60
const SPAWN_EVERY_SLOW := 6         # 60 Hz 下每 6 tick = 100 ms
const SPAWN_POS := Vector3(0.0, 26.0, 0.0)
const SPAWN_VEL := Vector3(2.5, -1.0, 0.5)
const SPAWN_ANG := Vector3(3.0, 2.0, 1.0)
const FLOOR_TOP_Y := 20.0
const GHOST_LAYER := 1 << 24        # 主空间回退时：虚影只与虚影地板互撞
const GHOST_MASK := 1 << 25

var world: BW
var outfile := ""

var _space_mode := "dedicated"      # dedicated | main-space
var _space := RID()
var _main_space := RID()
var _floor := RID()
var _gravity_area := RID()
var _gravity_shape := RID()
var _ghost_shape := RID()
var _floor_shape := RID()
var _ghosts: Array[RID] = []
var _ghost_age: Array[int] = []
var _ghost_free: Array[int] = []
var _spawn_every := 0


func _ready() -> void:
	_run()


func _run() -> void:
	var ready_now: bool = await world.wait_ready(900)
	var col_ready: bool = await world.wait_collisions(900)
	if not ready_now or not col_ready:
		print("BENCH PREDICT: FAIL（地形=%s 碰撞=%s）" % [str(ready_now), str(col_ready)])
		get_tree().quit(1)
		return
	world.arm_physics()
	_main_space = world.get_world_3d().space

	_setup_space()
	if _space_mode == "dedicated" and not await _probe_space_steps():
		_teardown_space()
		_space_mode = "main-space"
		_setup_space()
		print("PREDICT: 独立 space 未被主循环步进，回退主空间 + 碰撞层隔离（layer=%d mask=%d）" % [GHOST_LAYER, GHOST_MASK])
		if not await _probe_space_steps():
			print("BENCH PREDICT: FAIL（回退模式仍不动）")
			get_tree().quit(1)
			return

	await _ticks(WARMUP_TICKS)
	if not world.physics_sane():
		print("BENCH PREDICT: FAIL（方块沉入甲板，物理世界不健康，拒绝测量）")
		get_tree().quit(1)
		return

	# 基线与策略交错测（A/B/A/B/A）：世界刚体的清醒程度会随时间漂移，
	# 只测一次基线会把"世界变安静了"误算成"虚影不花钱"（第一版实测出负增量）
	_spawn_every = 0
	var base1 := await _measure(BASELINE_TICKS, 0)

	_spawn_every = 1
	var fast := await _measure(PHASE_TICKS, SKIP_TICKS)

	_retire_all()
	await _ticks(COOLDOWN_TICKS)
	_spawn_every = 0
	var base2 := await _measure(BASELINE_TICKS, 0)

	_spawn_every = SPAWN_EVERY_SLOW
	var slow := await _measure(PHASE_TICKS, SKIP_TICKS)

	_retire_all()
	await _ticks(COOLDOWN_TICKS)
	_spawn_every = 0
	var base3 := await _measure(BASELINE_TICKS, 0)

	# 单次 2 秒前推：墙钟延迟与落点合理性
	_retire_all()
	await _ticks(10)
	var t0 := Time.get_ticks_usec()
	var probe_idx := _spawn_one()
	var start_y := _read_y(_ghosts[probe_idx])
	await _ticks(HORIZON_TICKS)
	var land_y := _read_y(_ghosts[probe_idx])
	var latency_s := float(Time.get_ticks_usec() - t0) / 1000000.0
	_retire_all()

	var reset_us := _measure_reset_cost()
	_teardown_space()

	var base_mean_around_fast: float = (base1["mean"] + base2["mean"]) * 0.5
	var base_mean_around_slow: float = (base2["mean"] + base3["mean"]) * 0.5
	var extra_fast: float = fast["mean"] - base_mean_around_fast
	var extra_slow: float = slow["mean"] - base_mean_around_slow
	var baseline_spread: float = maxf(base1["mean"], maxf(base2["mean"], base3["mean"])) \
		- minf(base1["mean"], minf(base2["mean"], base3["mean"]))
	var report := {
		"date": Time.get_datetime_string_from_system(true),
		"space_mode": _space_mode,
		"horizon_s": HORIZON_TICKS / TICK_RATE,
		"baseline1_step_ms": base1,
		"baseline2_step_ms": base2,
		"baseline3_step_ms": base3,
		"baseline_spread_ms": baseline_spread,
		"extra_below_resolution": absf(extra_fast) <= baseline_spread,
		"strategy_every_frame": fast,
		"strategy_100ms": slow,
		"extra_step_ms_every_frame": extra_fast,
		"extra_step_ms_100ms": extra_slow,
		"per_prediction_cpu_ms": extra_fast,
		"spawn_reset_us": reset_us,
		"rollout_wall_latency_s": latency_s,
		"rollout_start_y": start_y,
		"rollout_landing_y": land_y,
		"landing_sane": absf(land_y - (FLOOR_TOP_Y + 0.25)) < 0.5,
	}
	Util.write_json(outfile, report)
	print("BENCH PREDICT 完成：基线 %.4f/%.4f/%.4f ms/tick（漂移 %.4f）；每帧预测 %+.4f ms/tick（%d 在飞）；100ms 降频 %+.4f ms/tick（%d 在飞）；单次克隆 %.1f µs；2s 前推墙钟 %.2f s" % [
		base1["mean"], base2["mean"], base3["mean"], baseline_spread,
		extra_fast, fast["in_flight_end"], extra_slow, slow["in_flight_end"],
		reset_us, latency_s])
	get_tree().quit(0)


# ---------- 虚影空间 ----------

func _setup_space() -> void:
	_ghosts.clear()
	_ghost_age.clear()
	_ghost_free.clear()

	if _space_mode == "dedicated":
		_space = PhysicsServer3D.space_create()
		PhysicsServer3D.space_set_active(_space, true)
		# server 级 space 没有"空间重力"参数，重力要靠一个罩住全场 的 area 提供
		_gravity_area = PhysicsServer3D.area_create()
		PhysicsServer3D.area_set_space(_gravity_area, _space)
		PhysicsServer3D.area_set_param(_gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY, 9.8)
		PhysicsServer3D.area_set_param(_gravity_area, PhysicsServer3D.AREA_PARAM_GRAVITY_OVERRIDE_MODE, 1)
		_gravity_shape = PhysicsServer3D.box_shape_create()
		PhysicsServer3D.shape_set_data(_gravity_shape, Vector3(200.0, 200.0, 200.0))
		PhysicsServer3D.area_add_shape(_gravity_area, _gravity_shape,
			Transform3D(Basis.IDENTITY, Vector3(0.0, FLOOR_TOP_Y, 0.0)))

	# 虚影地板：20×20 的盒子，顶面在 FLOOR_TOP_Y
	_floor_shape = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(_floor_shape, Vector3(10.0, 0.5, 10.0))
	_floor = PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(_floor, PhysicsServer3D.BODY_MODE_STATIC)
	if _space_mode == "dedicated":
		PhysicsServer3D.body_set_collision_layer(_floor, 1)
		PhysicsServer3D.body_set_collision_mask(_floor, 1)
		PhysicsServer3D.body_set_space(_floor, _space)
	else:
		PhysicsServer3D.body_set_collision_layer(_floor, GHOST_MASK)
		PhysicsServer3D.body_set_collision_mask(_floor, GHOST_LAYER)
		PhysicsServer3D.body_set_space(_floor, _main_space)
	PhysicsServer3D.body_add_shape(_floor, _floor_shape,
		Transform3D(Basis.IDENTITY, Vector3(0.0, FLOOR_TOP_Y - 0.5, 0.0)))

	# 虚影刚体的共享形状（0.5³ 全尺寸方块；box_shape_create 的 data 是半边长，须 ×0.5）
	_ghost_shape = PhysicsServer3D.box_shape_create()
	PhysicsServer3D.shape_set_data(_ghost_shape, Vector3(0.25, 0.25, 0.25))


func _teardown_space() -> void:
	_retire_all()
	for rid in _ghosts:
		PhysicsServer3D.free_rid(rid)
	_ghosts.clear()
	_ghost_age.clear()
	_ghost_free.clear()
	if _floor.is_valid():
		PhysicsServer3D.free_rid(_floor)
		_floor = RID()
	if _gravity_area.is_valid():
		PhysicsServer3D.free_rid(_gravity_area)
		_gravity_area = RID()
	if _gravity_shape.is_valid():
		PhysicsServer3D.free_rid(_gravity_shape)
		_gravity_shape = RID()
	if _floor_shape.is_valid():
		PhysicsServer3D.free_rid(_floor_shape)
		_floor_shape = RID()
	if _ghost_shape.is_valid():
		PhysicsServer3D.free_rid(_ghost_shape)
		_ghost_shape = RID()
	if _space.is_valid():
		PhysicsServer3D.space_set_active(_space, false)
		PhysicsServer3D.free_rid(_space)
		_space = RID()


func _probe_space_steps() -> bool:
	var idx := _spawn_one()
	var y0 := _read_y(_ghosts[idx])
	await _ticks(10)
	var y1 := _read_y(_ghosts[idx])
	_retire_all()
	return y1 < y0 - 0.001


func _spawn_one() -> int:
	var idx := -1
	if _ghost_free.size() > 0:
		idx = _ghost_free.pop_back()
	elif _ghosts.size() < GHOST_POOL:
		var rid := PhysicsServer3D.body_create()
		PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_RIGID)
		if _space_mode == "dedicated":
			PhysicsServer3D.body_set_collision_layer(rid, 1)
			PhysicsServer3D.body_set_collision_mask(rid, 1)
		else:
			PhysicsServer3D.body_set_collision_layer(rid, GHOST_LAYER)
			PhysicsServer3D.body_set_collision_mask(rid, GHOST_MASK)
		PhysicsServer3D.body_add_shape(rid, _ghost_shape, Transform3D())
		PhysicsServer3D.body_set_param(rid, PhysicsServer3D.BODY_PARAM_MASS, 1.0)
		_ghosts.append(rid)
		_ghost_age.append(-1)
		idx = _ghosts.size() - 1
	else:
		# 池满：偷最老的一条（理论稳态不会走到这里）
		var best := -1
		var best_age := -2
		for i in _ghost_age.size():
			if _ghost_age[i] > best_age:
				best_age = _ghost_age[i]
				best = i
		_retire(best)
		idx = best
	var target := _space if _space_mode == "dedicated" else _main_space
	PhysicsServer3D.body_set_space(_ghosts[idx], target)
	PhysicsServer3D.body_set_state(_ghosts[idx], PhysicsServer3D.BODY_STATE_TRANSFORM,
		Transform3D(Basis.IDENTITY, SPAWN_POS))
	PhysicsServer3D.body_set_state(_ghosts[idx], PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, SPAWN_VEL)
	PhysicsServer3D.body_set_state(_ghosts[idx], PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, SPAWN_ANG)
	_ghost_age[idx] = 0
	return idx


func _retire(i: int) -> void:
	if _ghost_age[i] < 0:
		return
	PhysicsServer3D.body_set_space(_ghosts[i], RID())
	_ghost_age[i] = -1
	_ghost_free.append(i)


func _retire_all() -> void:
	for i in _ghost_age.size():
		_retire(i)


func _advance_age() -> void:
	for i in _ghost_age.size():
		if _ghost_age[i] >= 0:
			_ghost_age[i] += 1
			if _ghost_age[i] >= HORIZON_TICKS:
				_retire(i)


func _count_in_flight() -> int:
	var n := 0
	for a in _ghost_age:
		if a >= 0:
			n += 1
	return n


func _read_y(rid: RID) -> float:
	var xf: Transform3D = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM)
	return xf.origin.y


func _measure_reset_cost() -> float:
	# 单独一个刚体，量 1000 次"克隆重置"（设 transform + 两个速度）的微成本
	var rid := PhysicsServer3D.body_create()
	PhysicsServer3D.body_set_mode(rid, PhysicsServer3D.BODY_MODE_RIGID)
	PhysicsServer3D.body_add_shape(rid, _ghost_shape, Transform3D())
	PhysicsServer3D.body_set_param(rid, PhysicsServer3D.BODY_PARAM_MASS, 1.0)
	var xf := Transform3D(Basis.IDENTITY, SPAWN_POS)
	var n := 1000
	var t0 := Time.get_ticks_usec()
	for i in n:
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, SPAWN_VEL)
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, SPAWN_ANG)
	var us := float(Time.get_ticks_usec() - t0) / float(n)
	PhysicsServer3D.free_rid(rid)
	return us


# ---------- 相位测量 ----------

func _measure(ticks: int, skip: int) -> Dictionary:
	var samples: Array[float] = []
	var t0 := Time.get_ticks_usec()
	for i in ticks:
		if _spawn_every > 0 and i % _spawn_every == 0:
			_spawn_one()
		_advance_age()
		await get_tree().physics_frame
		if i >= skip:
			samples.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
	var wall_s := float(Time.get_ticks_usec() - t0) / 1000000.0
	return {
		"mean": Util.mean(samples),
		"p95": Util.percentile(samples, 0.95),
		"max": samples.max() if samples.size() > 0 else 0.0,
		"ticks": ticks,
		"skipped": skip,
		"samples": samples.size(),
		"wall_s": wall_s,
		"in_flight_end": _count_in_flight(),
	}


func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame
