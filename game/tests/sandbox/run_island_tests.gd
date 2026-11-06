extends SceneTree

## 沙盒箱庭浮空岛测试（headless，退出码制）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/sandbox/run_island_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 为什么单开一套：scripts/sandbox/sandbox_island.gd 是一份新的确定性形状算法，
## 它的不变量全是"看不见但一破就出事"的那类——顶面不平则工位浮空、形状函数与
## 落点查询不一致则草丛悬在空气里、地层带被岛底吃掉则崖面只剩土色。这些都不是
## 逻辑测试（run_sandbox_tests.gd）能发现的，各留一套。
##
## 覆盖（验收标准，8 条）：
##  T1  确定性：两份独立生成器实例产出逐体素完全相同的块（无随机数）
##  T2  顶面平整：工位区每列顶面实心、其上为空气（工位摆位与物理的前提）
##  T3  形状函数一致：is_land()（草/树/石落点判定）与体素顶面的实心/空气逐点吻合
##  T4  有限且无悬浮块：远处纯空气；岛内每列自顶面往下连续；岛底明显收束
##  T5  崖壁四段地层都在：同一列能依次读到草皮/壤土/陶土/岩层与岛底深岩
##  T6  四角灯笼柱：柱身两格砖 + 顶一颗核心 + 其上空气，且柱子落在岛上
##  T7  材质库对账：方块模型数 == 调色板长度、发光只在核心一档
##  T8  场景装配：进场机位真的落在请求的预设上（曾经卡在默认姿态的回归锁）、
##      **没有草叶几何**（草不是几何）、地形网格库与调色板一致
##  T9  甲板实心有碰撞（代理盒）
##  T10 草是顶层方块的表面：草皮方块只出现在 wy==TOP_WY，材质走草皮档（pattern_kind 3）

const IslandScript := preload("res://scripts/sandbox/sandbox_island.gd")
const DioramaScript := preload("res://scripts/sandbox/sandbox_diorama.gd")
const SandboxScene := preload("res://scenes/sandbox/sandbox.tscn")

const TOP_WY := IslandScript.TOP_WY          # 顶面体素（上表面 = DECK_TOP_Y = 23）
const PAD_X := 8                              # 工位区取样范围（生成台实测占 |x|≤6.9）
const PAD_ZMIN := -9
const PAD_ZMAX := 7

var _passed := 0
var _failed := 0
var _cache: Dictionary = {}                  # origin → VoxelBuffer（逐点查询就地缓存）


func _initialize() -> void:
	_t01_deterministic()
	_t02_flat_top()
	_t03_shape_query_agrees_with_voxels()
	_t04_finite_and_tapered()
	_t05_strata_bands_present()
	_t06_lamp_pillars()
	_t07_library_matches_palette()
	await _t08_scene_assembly()
	await _t09_deck_is_solid()
	_t10_grass_is_top_layer_surface()
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


# ---------- 取样工具 ----------

func _block(gen, origin: Vector3i) -> VoxelBuffer:
	if _cache.has(origin):
		return _cache[origin]
	var b := VoxelBuffer.new()
	b.create(16, 16, 16)
	gen.generate_block(b, origin, 0)
	_cache[origin] = b
	return b


## 世界坐标的体素类型（按 16 对齐到所在块；块生成结果缓存）。
func _voxel(gen, wx: int, wy: int, wz: int) -> int:
	var origin := Vector3i(floori(wx / 16.0) * 16, floori(wy / 16.0) * 16, floori(wz / 16.0) * 16)
	var b := _block(gen, origin)
	return b.get_voxel(wx - origin.x, wy - origin.y, wz - origin.z)


func _is_lamp_column(wx: int, wz: int) -> bool:
	for spot in IslandScript.LAMP_SPOTS:
		if spot.x == wx and spot.y == wz:
			return true
	return false


# ---------- T1 确定性 ----------

func _t01_deterministic() -> void:
	_cache.clear()
	var a = IslandScript.new()
	var b = IslandScript.new()
	var ok := true
	# 取两块：一块含顶部与灯笼（origin.y=16），一块含岛底（origin.y=0）
	for origin in [Vector3i(-16, 16, -16), Vector3i(0, 0, 0)]:
		var ba := _block(a, origin)
		var bb := VoxelBuffer.new()
		bb.create(16, 16, 16)
		b.generate_block(bb, origin, 0)
		for y in 16:
			for z in 16:
				for x in 16:
					if ba.get_voxel(x, y, z) != bb.get_voxel(x, y, z):
						ok = false
						break
				if not ok:
					break
			if not ok:
				break
	_check(ok, "T1 确定性：两份独立生成器实例逐体素一致（同一坐标必得同一结果，形状无随机数）")


# ---------- T2 顶面平整 ----------

func _t02_flat_top() -> void:
	_cache.clear()
	var gen = IslandScript.new()
	var bad_top: Array = []
	var bad_above: Array = []
	for wz in range(PAD_ZMIN, PAD_ZMAX + 1):
		for wx in range(-PAD_X, PAD_X + 1):
			if _is_lamp_column(wx, wz):
				continue
			if _voxel(gen, wx, TOP_WY, wz) == IslandScript.T_AIR:
				bad_top.append(Vector2i(wx, wz))
			if _voxel(gen, wx, TOP_WY + 1, wz) != IslandScript.T_AIR:
				bad_above.append(Vector2i(wx, wz))
	var detail := "顶面缺口 %d 列、顶面上方有方块 %d 列" % [bad_top.size(), bad_above.size()]
	_check(bad_top.is_empty() and bad_above.is_empty(),
		"T2 顶面平整：工位区 x∈[-%d,%d] z∈[%d,%d] 每列 wy=%d 实心且其上为空气（%s）"
		% [PAD_X, PAD_X, PAD_ZMIN, PAD_ZMAX, TOP_WY, detail])


# ---------- T3 形状函数与体素一致 ----------

func _t03_shape_query_agrees_with_voxels() -> void:
	_cache.clear()
	var gen = IslandScript.new()
	var probe = IslandScript.new()      # 落点查询用的那一份（与地形实例分开，同生产用法）
	var mismatches: Array = []
	# 沿四条对角线 + 四条轴线扫到海岸线外：这是 is_land 的判定边界最容易被写歪的地方
	var dirs := [Vector2(1, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, -1), Vector2(-1, 1), Vector2(-1, -1)]
	for d in dirs:
		for r in range(4, 22):
			var x := int(round(d.x * r))
			var z := int(round(d.y * r))
			var land: bool = probe.is_land(float(x), float(z))
			var solid: bool = _voxel(gen, x, TOP_WY, z) != IslandScript.T_AIR
			if land != solid:
				mismatches.append("%s land=%s solid=%s" % [Vector2i(x, z), str(land), str(solid)])
	var detail := "吻合" if mismatches.is_empty() else str(mismatches.slice(0, 4))
	_check(mismatches.is_empty(),
		"T3 形状函数一致：is_land() 与顶面体素逐点吻合（草/树/石落点不会悬空）（%s）" % detail)


# ---------- T4 有限 + 收束 ----------

func _t04_finite_and_tapered() -> void:
	_cache.clear()
	var gen = IslandScript.new()

	# (a) 远处纯空气
	var far_ok := true
	for xz in [Vector2i(32, 0), Vector2i(0, 32), Vector2i(-32, -32), Vector2i(40, 40)]:
		for wy in [TOP_WY, TOP_WY - 6, IslandScript.KEEL_BOTTOM_WY + 2]:
			if _voxel(gen, xz.x, wy, xz.y) != IslandScript.T_AIR:
				far_ok = false

	# (b) 岛内每列自顶面往下连续（没有夹层空洞 → 不会出现悬浮的块）
	var continuous := true
	var columns := 0
	for wz in range(-14, 15, 2):
		for wx in range(-14, 15, 2):
			if not gen.is_land(float(wx), float(wz)):
				continue
			columns += 1
			var seen_air := false
			for d in range(0, IslandScript.DEPTH + 1):
				var solid := _voxel(gen, wx, TOP_WY - d, wz) != IslandScript.T_AIR
				if not solid:
					seen_air = true
				elif seen_air:
					continuous = false
					break

	# (c) 岛底明显收束：底部一层的实心列数远少于顶面
	var top_cols := 0
	var keel_cols := 0
	for wz in range(-18, 19):
		for wx in range(-18, 19):
			if _voxel(gen, wx, TOP_WY, wz) != IslandScript.T_AIR:
				top_cols += 1
			if _voxel(gen, wx, IslandScript.KEEL_BOTTOM_WY + 1, wz) != IslandScript.T_AIR:
				keel_cols += 1
	var tapered := keel_cols > 0 and float(keel_cols) < float(top_cols) * 0.15
	_check(far_ok and continuous and columns > 50 and tapered,
		"T4 有限且无悬浮块：远处纯空气、岛内 %d 列自顶面往下连续、岛底收束 %d/%d 列（<15%%）"
		% [columns, keel_cols, top_cols])


# ---------- T5 崖壁地层 ----------

## 地层"够深才够得着"：收束剖面让贴海岸线的柱子只有顶上几格，岩层与岛底深岩
## 只出现在更靠中心的柱子上。所以沿半径扫一排柱子（岛缘 → 中心），而不是只看
## 岛缘那一圈 —— 取样盲区会让"地层被岛底吃掉"这类错漏检。
func _t05_strata_bands_present() -> void:
	_cache.clear()
	var gen = IslandScript.new()
	var families := {}
	var columns := 0
	for d in [Vector2(1, 0), Vector2(0, 1), Vector2(1, 1), Vector2(-1, 0), Vector2(0, -1), Vector2(-1, -1)]:
		var dir: Vector2 = d.normalized()
		var dl := IslandScript.l4(dir.x, dir.y)
		for frac in [0.98, 0.85, 0.70, 0.55, 0.42, 0.30, 0.18, 0.08]:
			var t: float = IslandScript.COAST_L4 * float(frac) / dl
			var wx := int(round(dir.x * t))
			var wz := int(round(dir.y * t))
			if not gen.is_land(float(wx), float(wz)):
				continue
			columns += 1
			for dep in range(1, IslandScript.DEPTH + 1):
				var v := _voxel(gen, wx, TOP_WY - dep, wz)
				if v == IslandScript.T_AIR:
					break
				families[_family_of(v)] = true
	var missing: Array = []
	for n in ["soil", "earth", "stone", "keel"]:
		if not families.has(n):
			missing.append(n)
	_check(missing.is_empty() and columns >= 20,
		"T5 崖壁四段地层都在：沿半径扫 %d 条柱子，壤土/陶土/岩层/岛底深岩全部读到（缺 %s）"
		% [columns, "无" if missing.is_empty() else str(missing)])


func _family_of(v: int) -> String:
	var g := IslandScript
	if v >= g.T_KEEL_A and v <= g.T_KEEL_B:
		return "keel"
	if v >= g.T_SOIL_A and v <= g.T_SOIL_B:
		return "soil"
	if v >= g.T_EARTH_A and v <= g.T_EARTH_B:
		return "earth"
	if v >= g.T_STONE_A and v <= g.T_STONE_C:
		return "stone"
	if v >= g.T_TURF_A and v <= g.T_TURF_C:
		return "turf"
	if v >= g.T_DRY_A and v <= g.T_DRY_B:
		return "dry"
	return "other"


# ---------- T6 灯笼柱 ----------

func _t06_lamp_pillars() -> void:
	_cache.clear()
	var gen = IslandScript.new()
	var ok := true
	var detail := ""
	for spot in IslandScript.LAMP_SPOTS:
		var on_land: bool = gen.is_land(float(spot.x), float(spot.y))
		var brick_a := _voxel(gen, spot.x, TOP_WY + 1, spot.y)
		var brick_b := _voxel(gen, spot.x, TOP_WY + 2, spot.y)
		var core := _voxel(gen, spot.x, TOP_WY + 3, spot.y)
		var above := _voxel(gen, spot.x, TOP_WY + 4, spot.y)
		var brick_ok := (brick_a == IslandScript.T_BRICK_A or brick_a == IslandScript.T_BRICK_B) \
			and (brick_b == IslandScript.T_BRICK_A or brick_b == IslandScript.T_BRICK_B)
		if not (on_land and brick_ok and core == IslandScript.T_CORE and above == IslandScript.T_AIR):
			ok = false
			detail += " [%s land=%s 砖=%d/%d 核=%d 上=%d]" % [spot, str(on_land), brick_a, brick_b, core, above]
	_check(ok, "T6 四角灯笼柱：柱身两格砖 + 顶一颗核心 + 其上空气，且柱子落在岛上%s" % detail)


# ---------- T7 材质库对账 ----------

func _t07_library_matches_palette() -> void:
	var lib := DioramaScript.build_library()
	var count_ok := lib.get_models().size() == IslandScript.PALETTE.size()
	var emissive_ok := true
	for k in IslandScript.EMISSIVE:
		if k <= 0 or k >= IslandScript.PALETTE.size():
			emissive_ok = false
	# 只有核心一档发光（"发光不是越多越好"）
	if IslandScript.EMISSIVE.size() != 1 or not IslandScript.EMISSIVE.has(IslandScript.T_CORE):
		emissive_ok = false
	_check(count_ok and emissive_ok,
		"T7 材质库对账：方块模型数 %d == 调色板长度 %d、发光只在核心一档（%s）"
		% [lib.get_models().size(), IslandScript.PALETTE.size(),
			"EMISSIVE 仅 T_CORE" if emissive_ok else "EMISSIVE 越界或多档"])


# ---------- T8 场景装配 ----------

func _t08_scene_assembly() -> void:
	var scene: Node3D = SandboxScene.instantiate()
	root.add_child(scene)
	for i in 5:
		await create_timer(0.02).timeout

	# (a) 进场机位真的落在请求的预设上（回归锁：曾经卡在 OrbitCamera 的默认姿态）
	var cam := scene.get_node_or_null("Camera")
	var want: Dictionary = DioramaScript.PRESET_BENCH
	var pose_ok := false
	var pose_detail := "相机缺失"
	if cam != null and cam.has_method("current_pose"):
		var pose: Dictionary = cam.current_pose()
		pose_ok = absf(float(pose["pitch"]) - float(want["pitch"])) < 0.01 \
			and absf(float(pose["distance"]) - float(want["distance"])) < 0.01 \
			and absf(float(pose["yaw"]) - float(want["yaw"])) < 0.01 \
			and absf(cam.fov - DioramaScript.CAMERA_FOV) < 0.01 \
			and cam.projection == Camera3D.PROJECTION_PERSPECTIVE
		pose_detail = "pitch=%.3f distance=%.1f fov=%.1f" % [pose["pitch"], pose["distance"], cam.fov]

	# (b) 草不是几何：场景里不该再有草叶 MultiMesh（用户口径 2026-09-16：
	#     不要把草做成长那么高的东西；草改由顶层方块的表面表达，见 T10）
	var grass_node := scene.get_node_or_null("Grass")
	var grass_ok := grass_node == null
	var grass_detail := "场景里没有草叶几何" if grass_ok else "仍有 Grass 节点（草又变回几何了）"

	# (c) 地形网格库与调色板一致（装配真的换成了箱庭配方，不是关卡那份）
	var terrain := scene.get_node_or_null("Terrain")
	var lib_n := -1
	if terrain != null and terrain.mesher != null and terrain.mesher.library != null:
		lib_n = terrain.mesher.library.get_models().size()
	var lib_ok := lib_n == IslandScript.PALETTE.size()

	_check(pose_ok and grass_ok and lib_ok,
		"T8 场景装配：进场机位在 bench 预设（%s）、%s、地形网格库 %d == 调色板 %d"
		% [pose_detail, grass_detail, lib_n, IslandScript.PALETTE.size()])

	scene.free()
	await physics_frame


# ---------- T9 甲板碰撞 ----------

## 倒角方块走 VoxelBlockyModelMesh（自定义网格），实测它**一个碰撞体都不出**：
## 同一套 VoxelTerrain 配置下换成 VoxelBlockyModelCube 就有，换成 mesh 模型则
## collision_aabbs 与 set_mesh_collision_enabled 都救不回来。所以甲板碰撞由
## sandbox_diorama.add_deck_collision() 的代理盒子提供。
## 这条一旦配错，甲板就没碰撞（射线直接穿过去），而**其余测试全绿**（工位件是冻结
## 刚体，不会掉下去）—— 所以必须用射线把它单独钉住。
func _t09_deck_is_solid() -> void:
	var scene: Node3D = SandboxScene.instantiate()
	root.add_child(scene)
	# 取两个避开工位与四角灯柱的甲板点（工位区 |x|≤6.9、z∈[-8.6,6.6]）
	var probes := [Vector2(0.0, -11.0), Vector2(7.5, 7.5)]
	var want := IslandScript.top_y()
	var results: Array = []
	for p in probes:
		var hit_y := -100.0
		for i in 300:
			await physics_frame
			var q := PhysicsRayQueryParameters3D.create(
				Vector3(p.x, want + 6.0, p.y), Vector3(p.x, want - 4.0, p.y))
			q.collide_with_areas = false
			var hit: Dictionary = scene.get_world_3d().direct_space_state.intersect_ray(q)
			if hit.has("position"):
				hit_y = float(hit["position"].y)
				break
		results.append("%s→y=%.2f" % [p, hit_y])
	var ok := true
	for i in probes.size():
		if absf(float(results[i].get_slice("y=", 1)) - want) > 0.4:
			ok = false
	_check(ok and results.size() == 2,
		"T9 甲板实心有碰撞：两处射线命中甲板面 y≈%.1f（%s）—— add_deck_collision 代理生效（VoxelBlockyModelMesh 自己不出碰撞）"
		% [want, ", ".join(PackedStringArray(results))])
	scene.free()
	await physics_frame


# ---------- T10 草 = 顶层方块的表面 ----------

## 用户口径（2026-09-16）：不要把草做成长那么高的东西，把方块最上面一层渲染成草的样子，
## 总体形状还是正方体。草因此不再是独立几何，而是**顶层方块的一个表面档**。两条一起钉：
##   ① 草皮方块类型（T_TURF_* / T_DRY_*）只出现在最上面一格（wy == TOP_WY）
##   ② 它们的材质走"草皮"档（pattern_kind 3）；台面/砖镶边走砖砌（0）、崖壁地层走土质（1）
## 这两条一破，症状都是"草又变回几何/又跑到底下去了"，而其余测试全绿 —— 只能这么钉。
func _t10_grass_is_top_layer_surface() -> void:
	_cache.clear()
	var gen = IslandScript.new()
	var top_only := true
	var detail := ""
	for wz in range(-16, 17, 3):
		for wx in range(-16, 17, 3):
			if not gen.is_land(float(wx), float(wz)):
				continue
			for dep in range(0, IslandScript.DEPTH + 1):
				var v := _voxel(gen, wx, TOP_WY - dep, wz)
				if v == IslandScript.T_AIR:
					break
				var is_grass: bool = (v >= IslandScript.T_TURF_A and v <= IslandScript.T_TURF_C) 					or (v >= IslandScript.T_DRY_A and v <= IslandScript.T_DRY_B)
				if is_grass and dep != 0:
					top_only = false
					detail = "(%d,%d) 深度 %d 读到草皮方块 %d" % [wx, wz, dep, v]
					break

	var lib := DioramaScript.build_library()
	var kinds := {}
	for idx in [IslandScript.T_TURF_A, IslandScript.T_DRY_A, IslandScript.T_PAD_A,
			IslandScript.T_BRICK_A, IslandScript.T_SOIL_A]:
		var mat = lib.get_model(idx).get_material_override(0)
		kinds[idx] = int((mat as ShaderMaterial).get_shader_parameter("pattern_kind")) 			if mat is ShaderMaterial else -1
	var kinds_ok: bool = kinds[IslandScript.T_TURF_A] == 3 and kinds[IslandScript.T_DRY_A] == 3 		and kinds[IslandScript.T_PAD_A] == 0 and kinds[IslandScript.T_BRICK_A] == 0 		and kinds[IslandScript.T_SOIL_A] == 1

	_check(top_only and kinds_ok,
		"T10 草是顶层方块的表面：草皮方块只出现在 wy=%d（最上面一格）%s；"
		% [TOP_WY, "成立" if top_only else "不成立 " + detail]
		+ "材质档：草皮=%d/干草斑=%d（应 3）、台面=%d/砖=%d（应 0）、壤土=%d（应 1）"
		% [kinds[IslandScript.T_TURF_A], kinds[IslandScript.T_DRY_A],
			kinds[IslandScript.T_PAD_A], kinds[IslandScript.T_BRICK_A],
			kinds[IslandScript.T_SOIL_A]])
