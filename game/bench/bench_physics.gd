extends Node

## 数四：物理引擎现状（不改 project.godot，只测当前默认引擎）。
##
## 量四件事：
##   1. 当前 physics/3d/physics_engine 的取值（project.godot 没写则为引擎默认）
##      与实际在跑的 PhysicsServer 类名
##   2. 50 刚体场景（含传送带运转）的 physics step 毫秒：均值 / P95 / 最大
##   3. 推 / 堆稳定性（spec §7.1"勉强好用"口径，定性记录）：
##      - 穿透次数：甲板区域内方块掉到甲板面以下，或任何方块掉出世界
##      - 堆叠沉降：10 层塔在 3 s 稳定后到 10 s 的顶部下沉量与倾角
##   4. 推倒表现：t=4 s 给方墙底部一个冲量，记录被推离的方块数与最大位移
## Jolt 对照由主会话后测，这里只测默认并留好可复跑脚本。


const BW := preload("res://bench/bench_world.gd")
const Util := preload("res://bench/bench_report.gd")

const WARMUP_TICKS := 60
const TOTAL_TICKS := 600            # 10 s @ 60 Hz
const SETTLE_AT_TICK := 180         # 3 s：塔稳定后取沉降基准
const PUSH_AT_TICK := 240           # 4 s：推墙
const PUSH_IMPULSE := Vector3(0.0, 0.0, 18.0)
const PEN_REGION := 6.0             # 甲板判定区半宽 = plaza 半径；出 plaza 后掉向低地形是正常搬运，不算穿透
const DECK_MIN_Y := 21.0            # 甲板区域内低于此高度 = 穿透甲板
const DISPLACE_THRESHOLD := 0.5     # 推倒判定：位移超过 0.5 m 算被推走


var world: BW
var outfile := ""


func _ready() -> void:
	_run()


func _run() -> void:
	var has_setting := ProjectSettings.has_setting("physics/3d/physics_engine")
	var setting_value := str(ProjectSettings.get_setting_with_override("physics/3d/physics_engine"))
	var server: Object = Engine.get_singleton("PhysicsServer3D")
	var server_class := server.get_class()
	print("PHYSICS ENGINE: project 设置存在=%s 值=%s 实际 server=%s" % [
		str(has_setting), setting_value, server_class])

	var ready_now: bool = await world.wait_ready(900)
	var col_ready: bool = await world.wait_collisions(900)
	if not ready_now or not col_ready:
		print("BENCH PHYSICS: FAIL（地形=%s 碰撞=%s）" % [str(ready_now), str(col_ready)])
		get_tree().quit(1)
		return
	world.arm_physics()

	var steps: Array[float] = []
	var penetrated: Array[int] = []      # 穿透过甲板的方块索引（去重）
	var fell_world: Array[int] = []      # 掉出世界的方块索引
	var pre_push_pos: Array[Vector3] = []
	var settle_top_y := 0.0
	var settle_top_xz := Vector2.ZERO
	var t0 := Time.get_ticks_usec()

	for tick in TOTAL_TICKS:
		if tick == WARMUP_TICKS:
			pre_push_pos = _capture_wall_positions()
		if tick == SETTLE_AT_TICK:
			settle_top_y = world.cubes[world.TOWER_COUNT - 1].global_position.y
			settle_top_xz = _top_xz()
		if tick == PUSH_AT_TICK:
			world.cubes[world.wall_cube_index(1, 2, 0)].apply_central_impulse(PUSH_IMPULSE)
		await get_tree().physics_frame
		if tick >= WARMUP_TICKS:
			steps.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
			_scan_penetration(penetrated, fell_world)

	var wall_s := float(Time.get_ticks_usec() - t0) / 1000000.0
	var final_top_y := world.cubes[world.TOWER_COUNT - 1].global_position.y
	var final_top_xz := _top_xz()
	var settlement_mm := (settle_top_y - final_top_y) * 1000.0
	var lean_m := (final_top_xz - settle_top_xz).length()

	# 推倒统计：与推之前比位移
	var displaced := 0
	var max_disp := 0.0
	for i in range(pre_push_pos.size()):
		var idx := world.TOWER_COUNT + i
		var d: float = (world.cubes[idx].global_position - pre_push_pos[i]).length()
		if d > DISPLACE_THRESHOLD:
			displaced += 1
		max_disp = maxf(max_disp, d)

	# 传送带搬运：10 个带上方块的平均前进量
	var belt_dx := 0.0
	for b in world.BELT_CUBES:
		belt_dx += world.cubes[world.belt_cube_index(b)].global_position.x - (-4.0 + float(b) * 0.9)
	belt_dx /= float(world.BELT_CUBES)

	var report := {
		"date": Time.get_datetime_string_from_system(true),
		"engine_setting_in_project": has_setting,
		"engine_setting_value": setting_value,
		"physics_server_class": server_class,
		"body_count": world.cubes.size(),
		"ticks": TOTAL_TICKS,
		"step_ms_mean": Util.mean(steps),
		"step_ms_p95": Util.percentile(steps, 0.95),
		"step_ms_max": steps.max(),
		"wall_s": wall_s,
		"ticks_per_second_measured": float(TOTAL_TICKS) / wall_s,
		"penetration": {
			"deck_pierce_count": penetrated.size(),
			"deck_pierce_bodies": penetrated,
			"fell_out_of_world_count": fell_world.size(),
		},
		"tower": {
			"settle_top_y": settle_top_y,
			"final_top_y": final_top_y,
			"expected_top_y": world.DECK_TOP_Y + 0.25 + float(world.TOWER_COUNT - 1) * 0.5,
			"standing": absf(settle_top_y - (world.DECK_TOP_Y + 0.25 + float(world.TOWER_COUNT - 1) * 0.5)) < 0.1,
			"settlement_mm": settlement_mm,
			"lean_m": lean_m,
		},
		"push": {
			"impulse": [PUSH_IMPULSE.x, PUSH_IMPULSE.y, PUSH_IMPULSE.z],
			"displaced_count": displaced,
			"max_displacement_m": max_disp,
		},
		"belt": {
			"mean_carry_dx_m": belt_dx,
		},
	}
	Util.write_json(outfile, report)
	print("BENCH PHYSICS 完成：step %.3f/%.3f/%.3f ms（mean/p95/max）；穿透 %d+%d；塔沉降 %.1f mm 倾 %.3f m；推走 %d 块（最大 %.2f m）；带平均搬运 %.2f m" % [
		report["step_ms_mean"], report["step_ms_p95"], report["step_ms_max"],
		penetrated.size(), fell_world.size(), settlement_mm, lean_m,
		displaced, max_disp, belt_dx])
	get_tree().quit(0)


func _capture_wall_positions() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in world.WALL_W * world.WALL_D * world.WALL_H:
		out.append(world.cubes[world.TOWER_COUNT + i].global_position)
	return out


func _top_xz() -> Vector2:
	var base := world.cubes[0].global_position
	var top := world.cubes[world.TOWER_COUNT - 1].global_position
	return Vector2(top.x - base.x, top.z - base.z)


func _scan_penetration(penetrated: Array[int], fell_world: Array[int]) -> void:
	for i in world.cubes.size():
		var p := world.cubes[i].global_position
		if p.y < 0.0:
			if not fell_world.has(i):
				fell_world.append(i)
		elif absf(p.x) <= PEN_REGION and absf(p.z) <= PEN_REGION and p.y < DECK_MIN_Y:
			if not penetrated.has(i):
				penetrated.append(i)
