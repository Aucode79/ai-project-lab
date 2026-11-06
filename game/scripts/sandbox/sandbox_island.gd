extends VoxelGeneratorScript

## 沙盒浮空岛地形生成器 —— 「箱庭浮空岛」美术方向（Zoy 式微缩沙盘）。
##
## 为什么与 scripts/terrain_generator.gd 分开：那份要的是"能承载工位的无边界
## 平面甲板"（五关 + bench 共用），这份要的是"有限的一小块陆地悬在天空中"——
## 两个目的相反。各留一份生成器，改这里不会动到关卡与基准场景。
##
## 形状全部是坐标的纯函数（无随机数：同一坐标必得同一结果）：
##   顶面     全岛同高 wy = TOP_WY —— 工作台面必须绝对平（工位摆位与物理的前提）
##   平面轮廓 L4 范数的圆角方，不是圆：工位区是矩形，圆形会把左右两侧浪费掉
##   海岸线   L4 半径叠一层低频噪声 → 有机的岛缘，读不出几何感
##   台面分区 夯土台面（工位落在这）→ 砖砌镶边 → 草皮外缘（草皮顶块堆在这）
##   崖壁     TOP_WY 以下按深度分三段地层（壤土 / 陶土 / 岩层），带宽噪声抖动
##   岛底     半径随深度收束成一点 —— 浮空岛最要紧的就是"下面是空的"那条轮廓
##   灯笼     标准沙盒台面砖镶边四角各一根砖柱 + 暖黄核心；Agent Lab 场景关闭该装饰
##
## 调色板与方块类型序号是本文件的唯一真源：材质库由 SandboxDiorama 按
## PALETTE 建（与 world_builder 的 PALETTE 同一种"生成器出序号、装配方建库"分工）。

const CHANNEL := VoxelBuffer.CHANNEL_TYPE

# ---- 方块类型序号（必须与 PALETTE 的下标一致，也和材质库的 add_model 顺序一致）----
const T_AIR := 0
const T_PAD_A := 1        # 夯土台面（三档微差）
const T_PAD_B := 2
const T_PAD_C := 3
const T_TURF_A := 4       # 草皮（草根处的暗橄榄土；草画在它的顶面上）
const T_TURF_B := 5
const T_TURF_C := 6
const T_SOIL_A := 7       # 壤土（崖面上层）
const T_SOIL_B := 8
const T_EARTH_A := 9      # 陶土（崖面中层）
const T_EARTH_B := 10
const T_STONE_A := 11     # 岩层（崖面下层）
const T_STONE_B := 12
const T_STONE_C := 13
const T_KEEL_A := 14      # 岛底深岩
const T_KEEL_B := 15
const T_BRICK_A := 16     # 砖砌（镶边 / 灯笼柱）
const T_BRICK_B := 17
const T_CORE := 18        # 暖黄发光核心
const T_DRY_A := 19       # 台面草皮斑（干草色：沙与草皮之间的过渡）
const T_DRY_B := 20

## 调色板：下标即方块类型序号。[0] 是空气占位。
## 配方取向（对标 Zoy 前瞻片）：暖砂夯土台面 + 陶砖镶边 + 草皮暗橄榄 +
## 崖壁三段暖褐→陶土→灰岩的地层 + 暗岩岛底；唯一发光是暖黄核心。
## 亮度口径：不是凭感觉调的，是按 tools/measure_image.py 的实测值对齐参考片
## （《Zoy》前瞻片封面：亮度 145 / 标准差 45 / 饱和度 63）。第一版给了近白的
## 暖砂 + 灰调岩层，实测标准差只有 23、饱和度 35 —— 画面"什么都看得见偏偏
## 不像一个地方"就是这个原因。所以这里的每个色都往两极推：饱和的暖色 + 明确
## 的暗部，把标准差与饱和度拉上去。
const PALETTE := [
	Color(0.000, 0.000, 0.000),   # 0  空气
	Color(0.530, 0.376, 0.206),   # 1  台面 A #875F34 暖砂（饱和的橙棕）
	Color(0.487, 0.340, 0.180),   # 2  台面 B #7C562E
	Color(0.574, 0.420, 0.243),   # 3  台面 C #926B3E 亮（斑驳感靠这三档微差）
	Color(0.302, 0.239, 0.078),   # 4  草皮 A #4D3D14 深橄榄土
	Color(0.353, 0.286, 0.098),   # 5  草皮 B #5A4919
	Color(0.267, 0.208, 0.063),   # 6  草皮 C #44350F
	Color(0.318, 0.196, 0.110),   # 7  壤土 A #51321C
	Color(0.365, 0.231, 0.133),   # 8  壤土 B #5D3B22
	Color(0.522, 0.267, 0.157),   # 9  陶土 A #854428 饱和陶红
	Color(0.451, 0.220, 0.125),   # 10 陶土 B #73381F
	Color(0.400, 0.333, 0.282),   # 11 岩层 A #665548 暖灰岩
	Color(0.451, 0.376, 0.318),   # 12 岩层 B #735F51
	Color(0.345, 0.286, 0.243),   # 13 岩层 C #58493E
	Color(0.239, 0.196, 0.176),   # 14 岛底 A #3D322D
	Color(0.192, 0.157, 0.141),   # 15 岛底 B #312824
	Color(0.510, 0.239, 0.141),   # 16 砖砌 A #843D24 饱和陶砖
	Color(0.443, 0.204, 0.118),   # 17 砖砌 B #71341E
	Color(0.780, 0.443, 0.129),   # 18 核心 #C77121 琥珀（唯一发光）
	Color(0.463, 0.361, 0.192),   # 19 草斑 A #765C31 干草地皮
	Color(0.412, 0.318, 0.165),   # 20 草斑 B #69512A
]
const EMISSIVE := {T_CORE: 0.34}

# ---- 岛体尺寸（L4 范数半径；1 体素 = 1 m）----
const TOP_WY := 22                 # 顶面体素：上表面 y = 23 = WorldBuilder.DECK_TOP_Y
const KEEL_BOTTOM_WY := 6          # 岛底最低体素（岛体厚 16 m）
const DEPTH := TOP_WY - KEEL_BOTTOM_WY
const PAD_L4 := 14.0               # 夯土台面外边界（为 Agent Lab 程序工位扩大可用空间）
const RIM_W := 0.9                 # 砖砌镶边宽度
const TURF_L4 := PAD_L4 + RIM_W    # 草皮外缘内边界：草皮只画在它以外
const COAST_L4 := 18.4             # 海岸半径、岛宽约扩大 37%
const COAST_NOISE_AMP := 0.055     # 海岸线起伏幅度（±5.5%，必须远小于草皮环宽）
const COAST_MAX := COAST_L4 * (1.0 + COAST_NOISE_AMP)
# 崖壁三段地层厚度（体素；从 d=1 起算）。三段之和必须明显小于 DEPTH，
# 否则岛底深岩段会把岩层整段吃掉 —— 第一版 DEPTH=12、深岩从 d=9 起，
# 岩层一段都不剩，崖面只有土色没石头。
const SOIL_BAND := 4               # 壤土段
const EARTH_BAND := 5              # 陶土段
const STONE_BAND := 4              # 岩层段
# 台面外缘的草皮斑：噪声过阈值的台面格改用草皮色（草就画在这些格子的顶面上）。
# 只啃台面外缘（PATCH_INNER_L4 以内留干净）—— 中央整片留白，工位才读得清。
const PATCH_INNER_L4 := 7.8
const PATCH_THRESHOLD := 0.20

## 标准沙盒四角灯笼柱的落点（体素 x,z）：L4 半径约 14.3 —— 正落在砖砌镶边上。
const LAMP_SPOTS: Array[Vector2i] = [
	Vector2i(12, 12), Vector2i(12, -12), Vector2i(-12, 12), Vector2i(-12, -12),
]

var show_lamp_pillars := true

# 收束剖面：r(d) = coast * profile[d]，d = 顶面往下的深度。
# 前段几乎垂直（崖口），后段加速收成岛底尖 —— 用一张预计算表省掉逐体素 pow。
var _profile := PackedFloat32Array()

var _coast_noise := FastNoiseLite.new()
var _band_noise := FastNoiseLite.new()
var _patch_noise := FastNoiseLite.new()   # 台面外缘的草皮斑


func _init() -> void:
	_profile.resize(DEPTH + 1)
	for d in range(DEPTH + 1):
		var t := float(d) / float(DEPTH)
		# pow(t,1.8)：d 小时 k≈0（崖壁垂直），d→DEPTH 时 k→1（收成一点）
		var k := pow(t, 1.8)
		var r := 1.0 - 0.95 * k
		if d == 1:
			r *= 1.05          # 崖口一圈微外凸：草皮挂边的那道檐
		_profile[d] = r

	_coast_noise.seed = 20260916
	_coast_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_coast_noise.frequency = 0.07
	_coast_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_coast_noise.fractal_octaves = 2

	_band_noise.seed = 20260917
	_band_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_band_noise.frequency = 0.05

	_patch_noise.seed = 20260918
	_patch_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_patch_noise.frequency = 0.13
	_patch_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_patch_noise.fractal_octaves = 2


func _get_used_channels_mask() -> int:
	return 1 << CHANNEL


# ---------- 对外查询（甲板碰撞代理轮廓判定）----------

## 该点是否落在岛顶实心区内。甲板碰撞代理按它决定铺盒范围，避免悬空。
## 调用方必须用**本脚本的另一个实例**（体素生成跑在 worker 线程，共享实例去读
## 噪声不安全；形状是坐标的纯函数，两份实例的结果必然一致）。
func is_land(x: float, z: float) -> bool:
	return l4(x, z) <= coast_limit(x, z)


## 该列的海岸线半径（含噪声起伏）。
func coast_limit(x: float, z: float) -> float:
	return COAST_L4 * (1.0 + COAST_NOISE_AMP * _coast_noise.get_noise_2d(x, z))


## 岛顶面的世界高度（顶面上表面 y）。所有站在岛上的东西都从这里起算。
static func top_y() -> float:
	return float(TOP_WY + 1)


## 该点是不是草皮。**顶面用色与"草长在哪"共用同一份判定**：草不是独立几何，
## 就是顶层方块（d == 0）的草皮表面，所以"哪些格子是草"只有这一处口径 ——
## 不会出现"画成草地却没长草"或"草长在铺装上"。
func is_turf_top(rr: float, x: float, z: float) -> bool:
	if rr > TURF_L4:
		return true
	if rr <= PAD_L4:
		return _on_patch(rr, x, z)
	return false


# ---------- 生成 ----------

func _generate_block(buffer: VoxelBuffer, origin_in_voxels: Vector3i, lod: int) -> void:
	var size := buffer.get_size()
	# 岛只占约 38 m 见方，视野内绝大多数块是纯空气：先探相交，不相交直接填空气。
	# 注意用 fill(0) 而不是 clear() —— clear() 会把缓冲区尺寸复位成 (0,0,0)，
	# 地形收到尺寸不符的块会整块丢弃并刷 "Block is different from expected size"。
	if not _block_touches_island(origin_in_voxels, size):
		buffer.fill(0)
		return

	# 逐列预计算（每块 16x16 列 = 3 次噪声/列）：海岸线半径、地层带宽抖动、
	# 收束相位。逐体素循环里只剩乘加比较，不再采噪声。
	var ox := origin_in_voxels.x
	var oz := origin_in_voxels.z
	var coast := PackedFloat32Array()
	var wob := PackedInt32Array()
	var phase := PackedInt32Array()
	var top_type := PackedInt32Array()
	coast.resize(size.x * size.z)
	wob.resize(size.x * size.z)
	phase.resize(size.x * size.z)
	top_type.resize(size.x * size.z)
	for z in size.z:
		for x in size.x:
			var wx := ox + x
			var wz := oz + z
			var i := z * size.x + x
			var c := coast_limit(float(wx), float(wz))
			coast[i] = c
			wob[i] = int(round(2.0 * _band_noise.get_noise_2d(float(wx), float(wz))))
			# 高频相位：同一深度上各列的收束进度不一样 → 崖壁是碎台阶，不是
			# 一圈规整的楼梯（低频的 wob 只管地层界线，管不到轮廓）
			phase[i] = clampi(int(round(2.0 * _band_noise.get_noise_2d(
				float(wx) * 6.0, float(wz) * 6.0))), -2, 2)
			top_type[i] = _top_type_at(l4(float(wx), float(wz)), c, wx, wz)

	for z in size.z:
		for x in size.x:
			var wx := ox + x
			var wz := oz + z
			var i := z * size.x + x
			var rr := l4(float(wx), float(wz))
			var c: float = coast[i]
			var w: int = wob[i]
			var p: int = phase[i]
			var tt: int = top_type[i]
			for y in size.y:
				var wy := origin_in_voxels.y + y
				buffer.set_voxel(_voxel_type(wy, rr, c, w, p, tt, wx, wz), x, y, z, CHANNEL)


## 本块是否可能含有岛体。岛体的 AABB：x/z ∈ ±COAST_MAX，y ∈ [KEEL_BOTTOM_WY, TOP_WY+3]
## （+3 是灯笼柱顶）。
func _block_touches_island(origin: Vector3i, size: Vector3i) -> bool:
	if origin.x + size.x <= -COAST_MAX or float(origin.x) >= COAST_MAX:
		return false
	if origin.z + size.z <= -COAST_MAX or float(origin.z) >= COAST_MAX:
		return false
	if origin.y + size.y <= KEEL_BOTTOM_WY or origin.y > TOP_WY + 3:
		return false
	return true


func _voxel_type(wy: int, rr: float, coast: float, wob: int, phase: int, top_type: int,
		wx: int, wz: int) -> int:
	if wy > TOP_WY:
		return _prop_at(wx, wy, wz)
	var d := TOP_WY - wy
	if d >= _profile.size():
		return T_AIR
	# d==0 一定用 profile[0]==1：顶面海岸线必须与 coast_limit() 完全一致，
	# is_land 的轮廓判定就是按它算的（甲板碰撞代理差一格就会悬空）。
	var prof_d := 0 if d == 0 else clampi(d + phase, 0, DEPTH)
	if rr > coast * float(_profile[prof_d]):
		return T_AIR
	if d == 0:
		return top_type
	return _band_type(d, wob, wx, wy, wz)


## 顶面分区：夯土台面（外缘带草皮斑）→ 砖砌镶边 → 草皮外缘。
## rr 超出海岸线的列返回空气。
func _top_type_at(rr: float, coast: float, wx: int, wz: int) -> int:
	if rr > coast:
		return T_AIR
	# 草皮顶块（草皮环 / 台面草皮斑）：用色与"草长在哪"走同一个判定，两处不会漂
	if is_turf_top(rr, float(wx), float(wz)):
		if rr > TURF_L4:
			return _tone(wx, 0, wz, T_TURF_A, T_TURF_C)
		return _tone(wx, 0, wz, T_DRY_A, T_DRY_B)
	if rr > PAD_L4:
		return _tone(wx, 0, wz, T_BRICK_A, T_BRICK_B)
	return _tone(wx, 0, wz, T_PAD_A, T_PAD_C)


## 台面外缘的草皮斑判定（供 is_turf_top：草皮用色与"草画在哪"同源）。
func _on_patch(rr: float, x: float, z: float) -> bool:
	if rr <= PATCH_INNER_L4:
		return false
	return _patch_noise.get_noise_2d(x, z) > PATCH_THRESHOLD


## 崖壁地层：壤土 → 陶土 → 岩层 → 岛底深岩。只按深度分带，带界线按列噪声抖动，
## 因此地层线不是水平直线（一眼读作地质层，不是分层蛋糕）。
func _band_type(d: int, wob: int, wx: int, wy: int, wz: int) -> int:
	if d > SOIL_BAND + EARTH_BAND + STONE_BAND:
		return _tone(wx, wy, wz, T_KEEL_A, T_KEEL_B)
	if d <= SOIL_BAND + wob:
		return _tone(wx, wy, wz, T_SOIL_A, T_SOIL_B)
	if d <= SOIL_BAND + EARTH_BAND + wob:
		return _tone(wx, wy, wz, T_EARTH_A, T_EARTH_B)
	return _tone(wx, wy, wz, T_STONE_A, T_STONE_C)


## 灯笼柱：四角各一根两格砖柱（TOP_WY+1 / +2）顶一颗暖黄核心（TOP_WY+3）。
## 柱身要够高（3 m）才读得出"灯"——第一版只有一格柱，顶一颗悬空黄方块，
## 没有"柱"的存在感。
func _prop_at(wx: int, wy: int, wz: int) -> int:
	if not show_lamp_pillars:
		return T_AIR
	for spot in LAMP_SPOTS:
		if spot.x == wx and spot.y == wz:
			if wy == TOP_WY + 1 or wy == TOP_WY + 2:
				return _tone(wx, wy, wz, T_BRICK_A, T_BRICK_B)
			if wy == TOP_WY + 3:
				return T_CORE
	return T_AIR


## 同族方块里按坐标散一档色调（三档微差）—— Zoy 的砖石每块深浅不同，
## 这一层"斑驳"是它不像 MC 的关键之一。用整数哈希而非噪声：无状态、跨块一致、
## 逐体素便宜。
func _tone(wx: int, wy: int, wz: int, first: int, last: int) -> int:
	return first + _hash3(wx, wy, wz) % (last - first + 1)


# ---------- 纯函数工具 ----------

## L4 范数半径：圆角方而不是圆（工位区是矩形，圆形浪费两侧）。
## 公开给装配层用（甲板碰撞代理等的判定要走与地形完全同一个形状函数）。
static func l4(x: float, z: float) -> float:
	var a := absf(x)
	var b := absf(z)
	var s := a * a * a * a + b * b * b * b
	return sqrt(sqrt(s))


## 整数三维哈希（0 .. 0x7FFFFFFF）。乘数取常用的大素数；每步掩码，
## 避免负号进入后续异或（GDScript 的 >> 对负数是算术右移）。
func _hash3(x: int, y: int, z: int) -> int:
	const M := 0x7FFFFFFF
	var h := (x * 374761393 + y * 668265263 + z * 1274126177) & M
	h = ((h ^ (h >> 13)) * 1103515245) & M
	return (h ^ (h >> 16)) & M
