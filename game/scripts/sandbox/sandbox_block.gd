extends RefCounted

## 沙盒的"方块本体"设计 —— 倒角砖块（对标《Zoy》前瞻片的石砌）。
##
## 这一份管的是**一块方块长什么样**，与地形形状（sandbox_island.gd 管在哪生成）
## 和世界配方（sandbox_diorama.gd 管天光与相机）分开。
##
## 参考图里读出来的设计语汇（不是"正方体刷个色"）：
##   1. 倒角 —— 每个方块 12 条棱与 8 个角都切一刀，读作"磨过的石头"而不是"格子的边"；
##      相邻两块的倒角之间自然形成凹缝，砖与砖因此分得开
##   2. 砖缝 —— 表面按顺砖砌法（running bond）分格、逐行错半块，格间是下沉的缝
##   3. 斑驳 —— 同族色按坐标哈希散深浅，相邻两块明显不同色（这条最像石砌）
##   4. 花纹 —— 少量砖上压芽纹 / 菱形 / 锯齿镶边 / 鳞纹，稀疏且低对比
##
## 为什么倒角必须走**几何**而不是着色器：着色器只能改明暗，改不了轮廓。
## 岛缘那一圈方块的轮廓直接对着天空，方角与倒角在剪影上一眼就分得出来——
## 用户第一条反馈就是"它并不是一个正方体"。
##
## 代价（明确记下来）：倒角让方块不再贴到体素边界，网格器的"邻面剔除"就用不上
## （`culls_neighbors = false`），岛体内部的面也会被生成。实测可接受：整座岛
## 约 5000 个实心体素 × 44 三角形 ≈ 22 万三角形。
##
## 绕序（2026-09-17 修正）：44 个三角形**全部是 Godot 认定的正面**，不再有反面靠
## shader 的 `cull_disabled` 兜底。Godot 的正面是**顺时针**绕序：cross(v1−v0, v2−v0)
## 与外向顶点法线**反向**（点积 < 0）——引擎自带的 BoxMesh / PlaneMesh / SphereMesh
## 逐三角形都是这个符号（`surface_get_arrays` 一算便知）。**别按 OpenGL 的
## "逆时针 = 正面"去改**：把 44 个点积翻成正的表面上看"更整齐"，实际是整座岛的
## 地形全变反面、只剩环境光，暗成一片（2026-09-17 实测：台面亮面像素
## (244,171,0) → (32,55,5)，而同帧的资产与天空逐像素不变）。
## 修正前是混合状态（22 正面 / 22 反面）：反面那半是 −a 面与一半倒角面，多数背对
## 相机、又只有一两像素宽，所以一直没露馅。三组各自的绕序条件写在各自生成处。
##
## 用法：const Block := preload("res://scripts/sandbox/sandbox_block.gd")
## 纯静态工具，不实例化。

const ISLAND := preload("res://scripts/sandbox/sandbox_island.gd")
const BlockPatternShader := preload("res://scripts/sandbox/sandbox_block.gdshader")

const CHAMFER := 0.05           # 倒角**直角边**（米）。用户裁定 2026-09-17：统一直切倒角 ——
                                # 裸露表面一律 45° 直切、直角边 0.05 m（斜面宽 = 0.05×√2
                                # ≈ 0.0707 m），**向内切**，不动占格外包络与堆叠面。
                                # 相邻两块的倒角因此合成 0.10 m 凹缝；砖缝 0.030 / 花纹线
                                # 0.10 是 shader 画在表面上的（不涉几何），各管各的。
                                # 改这个值必须同步 sandbox_block.gdshader 里 uv 回归那两处
                                # 硬编码（0.05 / 0.10）—— 那边是刻意写死的回归对账。

static var _mesh: ArrayMesh = null


## 共享的倒角方块网格（[0,1]³ 局部坐标，与 VoxelBlockyModelCube 的立方体同一套
## 局部标架）。全部方块类型共用这一份网格，颜色靠顶点色/材质区分。
## 结果缓存：材质库每次重建都调它，没必要重复生成。
static func block_mesh() -> ArrayMesh:
	if _mesh != null:
		return _mesh
	var c := CHAMFER
	var lo := c
	var hi := 1.0 - c
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var idx := PackedInt32Array()

	# ---- 6 个内缩面 ----
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		for sign in 2:
			var n := Vector3.ZERO
			n[a] = -1.0 if sign == 0 else 1.0
			var base := verts.size()
			# 绕序：(u,v) 走 (lo,lo)→(lo,hi)→(hi,hi)→(hi,lo) 时 cross 恒指 −a（因为
			# û × v̂ = +a）。Godot 的正面要求 cross 与法线**反向**（见文件头"绕序"），
			# 所以 −a 面（法线 −a）要反着走、+a 面正着走。
			var ring: Array = [[lo, lo], [lo, hi], [hi, hi], [hi, lo]]
			if sign == 0:
				ring.reverse()
			for corner in ring:
				var p := Vector3.ZERO
				p[a] = 0.0 if sign == 0 else 1.0
				p[u] = corner[0]
				p[v] = corner[1]
				verts.append(p)
				norms.append(n)
			idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

	# ---- 12 条棱的斜面 ----
	# 棱方向 a，另两轴 b/c 各取一个符号；斜面四点是"b 面上的点 → c 面上的点"各两个
	for a in 3:
		var b := (a + 1) % 3
		var cc := (a + 2) % 3
		for sb in 2:
			for sc in 2:
				var full_b := 0.0 if sb == 0 else 1.0
				var full_c := 0.0 if sc == 0 else 1.0
				var ins_b := c if sb == 0 else 1.0 - c
				var ins_c := c if sc == 0 else 1.0 - c
				var n := Vector3.ZERO
				n[b] = -1.0 if sb == 0 else 1.0
				n[cc] = -1.0 if sc == 0 else 1.0
				n = n.normalized()
				var base := verts.size()
				var quad := []
				quad.append(_axis3(a, lo, b, full_b, cc, ins_c))
				quad.append(_axis3(a, lo, b, ins_b, cc, full_c))
				quad.append(_axis3(a, hi, b, ins_b, cc, full_c))
				quad.append(_axis3(a, hi, b, full_b, cc, ins_c))
				# 绕序：法线是 (b, cc) 两轴的合成方向；上面的点位顺序给出的 cross 只在
				# sb != sc（法线落两异号轴）时与法线反向（= Godot 正面），其余 6 条棱要反着走。
				if sb == sc:
					quad.reverse()
				for p in quad:
					verts.append(p)
					norms.append(n)
				idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])

	# ---- 8 个切角 ----
	for sa in 2:
		for sb in 2:
			for sc in 2:
				var n := Vector3.ZERO
				n[0] = -1.0 if sa == 0 else 1.0
				n[1] = -1.0 if sb == 0 else 1.0
				n[2] = -1.0 if sc == 0 else 1.0
				n = n.normalized()
				var fa := 0.0 if sa == 0 else 1.0
				var fb := 0.0 if sb == 0 else 1.0
				var fc := 0.0 if sc == 0 else 1.0
				var ia := c if sa == 0 else 1.0 - c
				var ib := c if sb == 0 else 1.0 - c
				var ic := c if sc == 0 else 1.0 - c
				var base := verts.size()
				var tri := [
					Vector3(fa, ib, ic),
					Vector3(ia, fb, ic),
					Vector3(ia, ib, fc),
				]
				# 绕序：镜像一个坐标轴就翻转一次三角形朝向，所以这个顺序只在
				# **偶数个 + 轴**（sa+sb+sc 为偶）的角与法线反向（= Godot 正面），
				# 奇数个 + 轴的角要反着走。
				if (sa + sb + sc) % 2 == 1:
					tri.reverse()
				for p in tri:
					verts.append(p)
					norms.append(n)
				idx.append_array([base, base + 1, base + 2])

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = idx
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh = m
	return m


## 按轴号拼一个 Vector3（避免到处写轴序展开）。
static func _axis3(a: int, av: float, b: int, bv: float, c: int, cv: float) -> Vector3:
	var p := Vector3.ZERO
	p[a] = av
	p[b] = bv
	p[c] = cv
	return p


# ---------- 表面花纹材质 ----------

## 每个方块类型一份材质（颜色照样走顶点色，这里只给"这一族方块怎么砌"）。
## 分四档：
##   砖砌石面 —— 台面铺装 / 砖镶边 / 岩层 / 岛底（石砌，带砖缝与雕饰）
##   土质地皮 —— 崖壁地层（壤土 / 陶土：不分砖，只要斑驳与颗粒）
##   **草皮顶块** —— 草皮环与台面草皮斑（顶层方块：顶面成团草色 + 侧面顶部草皮断面）
##   素面     —— 核心（发光，不加任何花纹）
##
## 草只在**颜色**上存在（用户口径 2026-09-16：草不做成高草几何，只把最上面一层
## 渲染成草的样子，总体形状还是正方体）。所以草皮这一档必然是"顶层方块"——
## `sandbox_island._top_type_at` 只在 d==0（最上面一格）给 T_TURF / T_DRY，
## 下面全是地层色。这条由 run_island_tests 的 T8 钉住。
static func material_for(index: int) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = BlockPatternShader
	mat.set_shader_parameter("pattern_kind", _pattern_kind(index))
	var slab: bool = index >= ISLAND.T_PAD_A and index <= ISLAND.T_PAD_C
	# 台面是"一方块一块石板"：砖格与方块重合，砖缝交给倒角几何去当 ——
	# 再画一套缝就多出一条与倒角错位的线，两级网格一叠就读成瓷砖地。
	# 墙面反而是"一个方块两皮砖"：竖直面够高，分皮才有砌体感。
	mat.set_shader_parameter("brick_size", Vector2(1.0, 1.0) if slab else Vector2(1.0, 0.5))
	mat.set_shader_parameter("seam_m", 0.0 if slab else 0.030)
	mat.set_shader_parameter("motif_density", 0.16 if slab else 0.11)
	mat.set_shader_parameter("emission_color", ISLAND.PALETTE[index])
	mat.set_shader_parameter("emission_energy", float(ISLAND.EMISSIVE.get(index, 0.0)))
	return mat


static func _pattern_kind(index: int) -> int:
	if ISLAND.EMISSIVE.has(index):
		return 2
	# 草皮顶块：草皮环 + 台面草皮斑（原来前者是"土 + 高草"、后者是"干土地皮 + 稀疏高草"）
	if index >= ISLAND.T_TURF_A and index <= ISLAND.T_TURF_C:
		return 3
	if index >= ISLAND.T_DRY_A and index <= ISLAND.T_DRY_B:
		return 3
	if index >= ISLAND.T_SOIL_A and index <= ISLAND.T_EARTH_B:
		return 1
	return 0
