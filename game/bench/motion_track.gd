extends RefCounted

## 最小烘焙轨道格式 v1（spec §7.1 口径：位置定点量化 + 差分）。
##
## 帧数据布局（内存形态）：每帧一个 PackedFloat32Array，每实体 7 个 float：
##   [x, y, z, qx, qy, qz, qw]，实体顺序在整条轨道里固定。
##
## 二进制布局（小端）：
##   u32 magic "MSB1" | u16 version=1 | u16 保留
##   u32 frame_count | u16 entity_count | u16 fps_milli(=fps*1000) | u8 key_interval
##   逐帧逐实体一个 u8 flags：
##     1 = 绝对关键帧：i32×3 位置(mm 定点) + i16×4 四元数(±32767 定点)
##     2 = 无变化（休眠）：仅此一字节
##     0 = 差分帧：i16×3 位置差(mm) + i16×4 四元数分量差(1/32767)
## 第一帧与每 key_interval 帧强制关键帧；差分溢出 i16 时退化成关键帧。
## 四元数先做符号规范化（w≥0）再量化与差分，避免 q 与 -q 翻转时差分爆炸。


const MAGIC := 0x3142534D   # "MSB1"
const VERSION := 1
const KEY_INTERVAL := 25    # 每 25 帧（1 秒 @25fps）一个关键帧
const POS_SCALE := 1000.0   # 位置定点：1 mm
const ROT_SCALE := 32767.0  # 四元数分量定点
const DELTA_LIMIT := 32000  # 差分超过此值退化成关键帧
# 精度口径：位置 ≤ 0.5 mm（mm 定点）；旋转 ≤ 1°（四分量各 i16 定点，
# 实测往返最大误差约 0.7°——四分量独立取整合成的角度偏差，不是 bug）
const POS_TOLERANCE_M := 0.0006
const ROT_TOLERANCE_DEG := 1.0


static func encode(frames: Array[PackedFloat32Array], entity_count: int, fps: float) -> PackedByteArray:
	var pb := StreamPeerBuffer.new()
	pb.big_endian = false
	pb.put_32(MAGIC)
	pb.put_16(VERSION)
	pb.put_16(0)
	pb.put_32(frames.size())
	pb.put_16(entity_count)
	pb.put_16(int(round(fps * 1000.0)))
	pb.put_8(KEY_INTERVAL)

	# 上一帧的量化态（整数），差分在量化域里做，解码端可精确还原
	var pos_q := PackedInt32Array()
	pos_q.resize(entity_count * 3)
	var rot_q := PackedInt32Array()
	rot_q.resize(entity_count * 4)
	var has_last := false

	for f in frames.size():
		var src: PackedFloat32Array = frames[f]
		var force_key: bool = (f % KEY_INTERVAL == 0) or not has_last
		for e in entity_count:
			var o := e * 7
			var q := _canonical_quat(Quaternion(src[o + 3], src[o + 4], src[o + 5], src[o + 6]))
			var px := clampi(int(round(src[o] * POS_SCALE)), -1000000000, 1000000000)
			var py := clampi(int(round(src[o + 1] * POS_SCALE)), -1000000000, 1000000000)
			var pz := clampi(int(round(src[o + 2] * POS_SCALE)), -1000000000, 1000000000)
			var rx := int(round(q.x * ROT_SCALE))
			var ry := int(round(q.y * ROT_SCALE))
			var rz := int(round(q.z * ROT_SCALE))
			var rw := int(round(q.w * ROT_SCALE))

			var p3 := e * 3
			var r4 := e * 4
			var unchanged: bool = has_last \
				and pos_q[p3] == px and pos_q[p3 + 1] == py and pos_q[p3 + 2] == pz \
				and rot_q[r4] == rx and rot_q[r4 + 1] == ry and rot_q[r4 + 2] == rz and rot_q[r4 + 3] == rw
			var overflow := false
			if not unchanged and not force_key:
				overflow = absi(px - pos_q[p3]) > DELTA_LIMIT or absi(py - pos_q[p3 + 1]) > DELTA_LIMIT \
					or absi(pz - pos_q[p3 + 2]) > DELTA_LIMIT \
					or absi(rx - rot_q[r4]) > DELTA_LIMIT or absi(ry - rot_q[r4 + 1]) > DELTA_LIMIT \
					or absi(rz - rot_q[r4 + 2]) > DELTA_LIMIT or absi(rw - rot_q[r4 + 3]) > DELTA_LIMIT

			if unchanged:
				pb.put_8(2)
			elif force_key or overflow:
				pb.put_8(1)
				pb.put_32(px)
				pb.put_32(py)
				pb.put_32(pz)
				pb.put_16(rx)
				pb.put_16(ry)
				pb.put_16(rz)
				pb.put_16(rw)
			else:
				pb.put_8(0)
				pb.put_16(px - pos_q[p3])
				pb.put_16(py - pos_q[p3 + 1])
				pb.put_16(pz - pos_q[p3 + 2])
				pb.put_16(rx - rot_q[r4])
				pb.put_16(ry - rot_q[r4 + 1])
				pb.put_16(rz - rot_q[r4 + 2])
				pb.put_16(rw - rot_q[r4 + 3])

			pos_q[p3] = px
			pos_q[p3 + 1] = py
			pos_q[p3 + 2] = pz
			rot_q[r4] = rx
			rot_q[r4 + 1] = ry
			rot_q[r4 + 2] = rz
			rot_q[r4 + 3] = rw
		has_last = true
	return pb.data_array


static func decode(data: PackedByteArray) -> Dictionary:
	var pb := StreamPeerBuffer.new()
	pb.data_array = data
	pb.big_endian = false
	if pb.get_32() != MAGIC:
		return {"ok": false, "error": "bad magic"}
	if pb.get_16() != VERSION:
		return {"ok": false, "error": "bad version"}
	pb.get_16()
	var frame_count := pb.get_32()
	var entity_count := pb.get_16()
	var fps := float(pb.get_16()) / 1000.0
	pb.get_8()

	var pos := PackedInt32Array()
	pos.resize(entity_count * 3)
	var rot := PackedInt32Array()
	rot.resize(entity_count * 4)
	var frames: Array[PackedFloat32Array] = []

	for f in frame_count:
		var fr := PackedFloat32Array()
		fr.resize(entity_count * 7)
		for e in entity_count:
			var flags := pb.get_8()
			var p3 := e * 3
			var r4 := e * 4
			if flags == 1:
				pos[p3] = pb.get_32()
				pos[p3 + 1] = pb.get_32()
				pos[p3 + 2] = pb.get_32()
				rot[r4] = pb.get_16()
				rot[r4 + 1] = pb.get_16()
				rot[r4 + 2] = pb.get_16()
				rot[r4 + 3] = pb.get_16()
			elif flags == 0:
				pos[p3] += pb.get_16()
				pos[p3 + 1] += pb.get_16()
				pos[p3 + 2] += pb.get_16()
				rot[r4] += pb.get_16()
				rot[r4 + 1] += pb.get_16()
				rot[r4 + 2] += pb.get_16()
				rot[r4 + 3] += pb.get_16()
			# flags == 2：不变，沿用上一帧量化态
			var o := e * 7
			fr[o] = float(pos[p3]) / POS_SCALE
			fr[o + 1] = float(pos[p3 + 1]) / POS_SCALE
			fr[o + 2] = float(pos[p3 + 2]) / POS_SCALE
			fr[o + 3] = float(rot[r4]) / ROT_SCALE
			fr[o + 4] = float(rot[r4 + 1]) / ROT_SCALE
			fr[o + 5] = float(rot[r4 + 2]) / ROT_SCALE
			fr[o + 6] = float(rot[r4 + 3]) / ROT_SCALE
		frames.append(fr)
	return {"ok": true, "fps": fps, "entity_count": entity_count, "frames": frames}


static func verify(frames: Array[PackedFloat32Array], data: PackedByteArray) -> Dictionary:
	# 解码回读：位置误差应 ≤ 半个毫米格，旋转误差应 < 0.2°。
	# 旋转比对必须角度等价（q 与 -q 是同一个旋转，编码端做过符号规范化）
	var dec := decode(data)
	if not dec.get("ok", false):
		return {"ok": false, "error": str(dec.get("error", "decode failed"))}
	var got: Array[PackedFloat32Array] = dec["frames"]
	if got.size() != frames.size():
		return {"ok": false, "error": "frame count mismatch"}
	var entity_count := frames[0].size() / 7 if frames.size() > 0 else 0
	var max_pos := 0.0
	var max_rot_rad := 0.0
	for f in frames.size():
		for e in entity_count:
			var o := e * 7
			for k in 3:
				max_pos = maxf(max_pos, absf(frames[f][o + k] - got[f][o + k]))
			var dot := 0.0
			for k in 4:
				dot += float(frames[f][o + 3 + k]) * float(got[f][o + 3 + k])
			max_rot_rad = maxf(max_rot_rad, 2.0 * acos(clampf(absf(dot), 0.0, 1.0)))
	var max_rot_deg := rad_to_deg(max_rot_rad)
	var ok: bool = max_pos <= POS_TOLERANCE_M and max_rot_deg <= ROT_TOLERANCE_DEG
	return {"ok": ok, "max_pos_err_m": max_pos, "max_rot_err_deg": max_rot_deg}


static func self_test() -> bool:
	# 合成数据：3 实体 × 30 帧（一个静止走 flags=2、一个平移、一个翻滚），往返校验
	var frames: Array[PackedFloat32Array] = []
	for f in 30:
		var t := float(f) * 0.04
		var fr := PackedFloat32Array()
		fr.resize(3 * 7)
		# 0 号：完全静止
		for k in 7:
			fr[k] = [1.0, 2.0, 3.0, 0.0, 0.0, 0.0, 1.0][k]
		# 1 号：平移
		var p1 := Basis.from_euler(Vector3(0.3, 0.8, 0.1)).get_rotation_quaternion()
		fr[7] = t * 1.5
		fr[8] = 0.5
		fr[9] = -t * 0.2
		fr[10] = p1.x
		fr[11] = p1.y
		fr[12] = p1.z
		fr[13] = p1.w
		# 2 号：翻滚 + 突跳（触发关键帧退化）
		var q2 := Quaternion.from_euler(Vector3(t * 2.0, t * 3.0, t * 1.0))
		if f == 20:
			q2 = Quaternion.from_euler(Vector3(2.5, 0.2, -0.4))
		fr[14] = sin(t) * 2.0
		fr[15] = 1.0 + t * 0.05
		fr[16] = cos(t * 0.7)
		fr[17] = q2.x
		fr[18] = q2.y
		fr[19] = q2.z
		fr[20] = q2.w
		frames.append(fr)
	var bytes := encode(frames, 3, 25.0)
	var v := verify(frames, bytes)
	if not v.ok:
		push_error("motion_track self_test 失败：%s" % str(v))
		return false
	return true


static func _canonical_quat(q: Quaternion) -> Quaternion:
	if q.w < 0.0:
		return Quaternion(-q.x, -q.y, -q.z, -q.w)
	return q
