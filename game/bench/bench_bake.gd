extends Node

## 数二：最小 studio.bake 原型——烘焙耗时 + 轨道体积。
##
## 流程（spec §7.1 烘焙轨道口径）：
##   1. 物理固定 dt（60 Hz）逐 tick 采 50 个受物理影响实体的平移+旋转，采 10 秒
##   2. 按 25 fps 插值降采样成捕获帧（10 s → 250 帧）
##   3. 定点量化 + 差分编码（motion_track.gd），解码回读校验
##   4. 落盘 motion/{runId}.bin，报告烘焙耗时分解与体积外推
## 记录开始时推一下方墙，让 10 秒里有真实的翻倒运动，不是全静止的假数据。


const BW := preload("res://bench/bench_world.gd")
const Util := preload("res://bench/bench_report.gd")
const MT := preload("res://bench/motion_track.gd")

const SETTLE_TICKS := 90           # 1.5 s：等落体与碰撞体就绪
const RECORD_TICKS := 600          # 10 s @ 60 Hz
const TARGET_FPS := 25.0           # spec §3.4 捕获帧率
const PUSH_IMPULSE := Vector3(0.0, 0.0, 18.0)


var world: BW
var outfile := ""


func _ready() -> void:
	_run()


func _run() -> void:
	var ready_now: bool = await world.wait_ready(900)
	var col_ready: bool = await world.wait_collisions(900)
	if not ready_now or not col_ready:
		print("BENCH BAKE: FAIL（地形=%s 碰撞=%s）" % [str(ready_now), str(col_ready)])
		get_tree().quit(1)
		return
	world.arm_physics()
	await _ticks(SETTLE_TICKS)
	if not world.physics_sane():
		print("BENCH BAKE: FAIL（方块沉入甲板，物理世界不健康，拒绝采样）")
		get_tree().quit(1)
		return

	var entity_count := world.cubes.size()
	var sim_rate := float(Engine.physics_ticks_per_second)

	# 推墙，制造运动
	world.cubes[world.wall_cube_index(1, 2, 0)].apply_central_impulse(PUSH_IMPULSE)

	# 1) 60 Hz 原始采样
	var capture_us := Time.get_ticks_usec()
	var raw: Array[PackedFloat32Array] = []
	for i in RECORD_TICKS:
		raw.append(_sample(world.cubes))
		await get_tree().physics_frame
	var capture_ms := float(Time.get_ticks_usec() - capture_us) / 1000.0

	# 2) 25 fps 插值降采样
	var interp_us := Time.get_ticks_usec()
	var frames := _downsample(raw, TARGET_FPS, sim_rate)
	var interp_ms := float(Time.get_ticks_usec() - interp_us) / 1000.0

	# 3) 编码 + 自检 + 回读校验
	var self_ok := MT.self_test()
	var encode_us := Time.get_ticks_usec()
	var bytes := MT.encode(frames, entity_count, TARGET_FPS)
	var encode_ms := float(Time.get_ticks_usec() - encode_us) / 1000.0
	var verify := MT.verify(frames, bytes)

	# 4) 落盘
	var run_id := Util.run_id()
	var write_us := Time.get_ticks_usec()
	DirAccess.make_dir_recursive_absolute("res://bench/out/motion")
	var bin_path := "res://bench/out/motion/%s.bin" % run_id
	var f := FileAccess.open(bin_path, FileAccess.WRITE)
	if f == null:
		print("BENCH BAKE: FAIL（无法写 %s）" % bin_path)
		get_tree().quit(1)
		return
	f.store_buffer(bytes)
	f.close()
	var write_ms := float(Time.get_ticks_usec() - write_us) / 1000.0

	var bytes_per_frame := float(bytes.size()) / float(frames.size())
	var bytes_per_frame_per_entity := bytes_per_frame / float(entity_count)
	var raw_bytes_per_frame := entity_count * 7 * 4
	var ep4_min := 6000.0 * bytes_per_frame          # 4 分钟/集
	var ep8_min := 12000.0 * bytes_per_frame         # 8 分钟/集
	var sim_wait_ms := RECORD_TICKS / sim_rate * 1000.0
	var capture_overhead_ms := maxf(0.0, capture_ms - sim_wait_ms)
	var report := {
		"date": Time.get_datetime_string_from_system(true),
		"run_id": run_id,
		"bin_path": ProjectSettings.globalize_path(bin_path),
		"entities": entity_count,
		"sim_rate_hz": sim_rate,
		"capture_ticks": RECORD_TICKS,
		"sim_wait_s": RECORD_TICKS / sim_rate,
		"frames_25fps": frames.size(),
		"self_test": self_ok,
		"roundtrip_verify_ok": verify.get("ok", false),
		"roundtrip_max_pos_err_m": verify.get("max_pos_err_m", -1.0),
		"roundtrip_max_rot_err_deg": verify.get("max_rot_err_deg", -1.0),
		"timing_ms": {
			"capture_overhead": capture_overhead_ms,
			"interpolate": interp_ms,
			"encode": encode_ms,
			"write": write_ms,
			"bake_overhead_total": capture_overhead_ms + interp_ms + encode_ms + write_ms,
		},
		"file_bytes": bytes.size(),
		"bytes_per_frame": bytes_per_frame,
		"bytes_per_frame_per_entity": bytes_per_frame_per_entity,
		"raw_float_bytes_per_frame": raw_bytes_per_frame,
		"compression_vs_raw": float(raw_bytes_per_frame) / bytes_per_frame,
		"extrapolated_episode_4min_mb": ep4_min / 1048576.0,
		"extrapolated_episode_8min_mb": ep8_min / 1048576.0,
	}
	Util.write_json(outfile, report)
	print("BENCH BAKE 完成：%d 实体 × %d 帧 = %d B（%.1f B/帧），单集 4/8 分钟外推 %.2f/%.2f MB，回读校验 %s" % [
		entity_count, frames.size(), bytes.size(), bytes_per_frame,
		report["extrapolated_episode_4min_mb"], report["extrapolated_episode_8min_mb"],
		"OK" if verify.get("ok", false) else "FAIL"])
	get_tree().quit(0 if (verify.get("ok", false) and self_ok) else 1)


func _ticks(n: int) -> void:
	for i in n:
		await get_tree().physics_frame


func _sample(bodies: Array[RigidBody3D]) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	out.resize(bodies.size() * 7)
	for i in bodies.size():
		var b := bodies[i]
		var p := b.global_position
		var q := b.global_basis.get_rotation_quaternion()
		var o := i * 7
		out[o] = p.x
		out[o + 1] = p.y
		out[o + 2] = p.z
		out[o + 3] = q.x
		out[o + 4] = q.y
		out[o + 5] = q.z
		out[o + 6] = q.w
	return out


func _downsample(raw: Array[PackedFloat32Array], fps: float, sim_rate: float) -> Array[PackedFloat32Array]:
	var out: Array[PackedFloat32Array] = []
	var n := int(floor(float(raw.size() - 1) * fps / sim_rate)) + 1
	for i in n:
		var tf := float(i) / fps * sim_rate
		var i0 := clampi(int(floor(tf)), 0, raw.size() - 1)
		var i1 := clampi(i0 + 1, 0, raw.size() - 1)
		var a := tf - float(i0)
		var fr := PackedFloat32Array()
		fr.resize(raw[i0].size())
		for o in raw[i0].size():
			if o % 7 < 3:
				fr[o] = lerpf(raw[i0][o], raw[i1][o], a)
			elif o % 7 == 3:
				var q0 := Quaternion(raw[i0][o], raw[i0][o + 1], raw[i0][o + 2], raw[i0][o + 3])
				var q1 := Quaternion(raw[i1][o], raw[i1][o + 1], raw[i1][o + 2], raw[i1][o + 3])
				var qs := q0.slerp(q1, a)
				fr[o] = qs.x
				fr[o + 1] = qs.y
				fr[o + 2] = qs.z
				fr[o + 3] = qs.w
		out.append(fr)
	return out
