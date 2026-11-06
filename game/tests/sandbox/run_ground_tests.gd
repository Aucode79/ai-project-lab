extends SceneTree

## 沙盒地面与摆位的正确性锁（headless，退出码制）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/sandbox/run_ground_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 为什么单开一套：这几条都是"错了也不会让逻辑测试变红"的那类 ——
##   * 甲板碰撞代理的轮廓（地形自身 generate_collisions=false，代理盒是纯视觉外的东西）
##   * 生成台是否真的摆满了全量资产（摆不下时 _pack_slots 会 push_error 然后静默截断）
##   * 摆位的三条口径：**同向 / 落格 / 互不穿模**（用户 2026-09-16 明确的目标）
## 它们只在"拖拽落定停在空气上""某件资产根本没出现""两件机器长在一起"时才露脸。
##
## 覆盖（7 条）：
##  T1 甲板碰撞代理的轮廓与海岸线吻合（16 方向 × 0.1 m 多点射线，不止打中心）
##  T2 生成台全量在场：运行枚举 == 载偶数 == 状态层实体数（防静默截断）
##  T3 摆位同向：全部件 yaw == 0（不再把深件转 90°）
##  T4 摆位落格：位置在 0.25 m 格上、占格在 0.5 m 格上、整数 cell 唯一
##  T5 互不穿模：任意两件的**可见包围盒**（含基座）在水平面上不相交
##  T6 全部件落在夯土台面内，且生成台收口不越进南侧工区
##  T7 部件外延落格：每个部件盒世界 AABB 的六面都在 0.25 m 格点上（"占满整格"，
##      2026-09-17 拍板的口径；中心允许 0.125 m 奇半格偏移，只要外延在格上）。
##      **当前预期红**（28 件全有离格外延，待 A3+A6 修复）：逐条违规清单见同目录
##      extent_violations_baseline.txt（修复前后对照证据），修复完成后本条转绿。
##      诊断一行一条走 stderr、带 [extent] 前缀，不污染本套件的机读汇总行。

const AssetsScript := preload("res://scripts/sandbox/sandbox_assets.gd")
const IslandScript := preload("res://scripts/sandbox/sandbox_island.gd")
const SandboxScene := preload("res://scenes/sandbox/sandbox.tscn")

const DECK_Y := 23.0          # 岛顶面（= WorldBuilder.DECK_TOP_Y）
# 判定带（米，按 L4 半径）：离海岸线 ±0.5 以内属代理栅格的台阶模糊带，两种结果都算对。
# 带外必须严格一致 —— 实测 0.5 m 格距的轮廓误差 ≤ 0.20 m（见 sandbox_diorama.DECK_CELL_M）。
const COAST_BAND := 0.5
const LATTICE := 0.25         # 摆位格（世界度量体系：摆位 n×0.25）
const CELL := 0.5             # 占格格距 = 一个标准方块
const OVERLAP_EPS := 0.001    # 1 mm 以内的"贴着"不算穿模（浮点误差，不是穿模）
const UTILITY_Z := 4.0        # 南侧工区分界：生成台的可见体不得越过
const EXTENT_EPS := 0.0001    # T7 外延落格容差：距最近 0.25 m 格点超过 1e-4 m 才算离格

var _passed := 0
var _failed := 0


func _initialize() -> void:
	var scene: Node3D = SandboxScene.instantiate()
	root.add_child(scene)
	for i in 8:
		await create_timer(0.03).timeout
	await physics_frame

	await _t01_deck_outline_matches_coast(scene)
	_t02_all_assets_on_bench(scene)
	_t03_uniform_orientation(scene)
	_t04_grid_and_unique_cells(scene)
	_t05_no_interpenetration(scene)
	_t06_inside_pad_and_clear_of_utility(scene)
	_t07_part_extents_on_grid(scene)

	scene.free()
	await physics_frame
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


## 只探甲板那一层：射线从 y=23.2 打到 22.5。起点落在工位件/按钮/屏的碰撞盒内部
## （它们都从 y=23 往上长），而 intersect_ray 默认 hit_from_inside=false 会跳过
## "起点在内部"的形状 —— 于是这条射线只可能命中甲板代理盒（22.5..23.0），
## 也就把"工位件会不会挡住探测"这个问题绕开了。
func _deck_hit(scene: Node3D, x: float, z: float) -> float:
	var q := PhysicsRayQueryParameters3D.create(
		Vector3(x, DECK_Y + 0.2, z), Vector3(x, DECK_Y - 0.5, z))
	q.collide_with_areas = false
	var hit: Dictionary = scene.get_world_3d().direct_space_state.intersect_ray(q)
	if not hit.has("position"):
		return -100.0
	return float(hit["position"].y)


func _t01_deck_outline_matches_coast(scene: Node3D) -> void:
	var island = IslandScript.new()
	var holes: Array = []        # 岛内该有甲板却没有
	var spills: Array = []       # 岛外不该有甲板却有
	var sampled := 0
	for i in 16:
		var ang := TAU * float(i) / 16.0
		var dir := Vector2(cos(ang), sin(ang))
		var r := 5.0
		while r <= IslandScript.COAST_MAX + 2.0:
			var x := dir.x * r
			var z := dir.y * r
			var l4 := IslandScript.l4(x, z)
			var coast: float = island.coast_limit(x, z)
			# 台阶模糊带内不判对错
			if absf(l4 - coast) >= COAST_BAND:
				sampled += 1
				var land := l4 <= coast
				var hit := _deck_hit(scene, x, z) > -50.0
				if land and not hit:
					holes.append("r=%.2f l4=%.2f coast=%.2f" % [r, l4, coast])
				elif hit and not land:
					spills.append("r=%.2f l4=%.2f coast=%.2f" % [r, l4, coast])
			r += 0.1
	var detail := ""
	if not holes.is_empty():
		detail += " 岛内缺口 %d 例（%s）" % [holes.size(), holes[0]]
	if not spills.is_empty():
		detail += " 岛外多出 %d 例（%s）" % [spills.size(), spills[0]]
	_check(sampled > 200 and holes.is_empty() and spills.is_empty(),
		"T1 甲板轮廓吻合：16 方向 × 0.1 m 扫 %d 个取样点，离海岸线 %0.1f m 带外"
		% [sampled, COAST_BAND]
		+ "「岛内必有甲板 / 岛外必无甲板」全部成立%s" % detail)


func _t02_all_assets_on_bench(scene: Node3D) -> void:
	var ids := AssetsScript.asset_ids()
	var items: Array = scene.get_bench_items()
	var entities: Dictionary = scene.state.logical_snapshot()["entities"]
	_check(ids.size() > 0 and items.size() == ids.size() and entities.size() == ids.size(),
		"T2 生成台全量在场：运行枚举 %d 件 == 生成台载体 %d 件 == 状态层实体 %d 件"
		% [ids.size(), items.size(), entities.size()])


# ---------- 摆位三条口径（用户 2026-09-16 的目标）----------

func _t03_uniform_orientation(scene: Node3D) -> void:
	var bad: Array = []
	for item in scene.get_bench_items():
		var y := absf(wrapf((item as Node3D).rotation.y, -PI, PI))
		if y > 0.001:
			bad.append("%s yaw=%.1f°" % [
				item.get_meta("asset_id"), rad_to_deg((item as Node3D).rotation.y)])
	_check(bad.is_empty(),
		"T3 摆位同向：全部 %d 件的 yaw == 0（同向是坐标唯一确定的前提；原来把深件转了 90°）%s"
		% [scene.get_bench_items().size(), "" if bad.is_empty() else "（%s）" % bad[0]])


func _t04_grid_and_unique_cells(scene: Node3D) -> void:
	var off_lattice: Array = []
	var cells := {}
	var dup: Array = []
	for item in scene.get_bench_items():
		var aid := str(item.get_meta("asset_id"))
		var gp: Vector3 = (item as Node3D).global_position
		for pair in [["x", gp.x], ["z", gp.z]]:
			var v := float(pair[1])
			if absf(round(v / LATTICE) * LATTICE - v) > 0.001:
				off_lattice.append("%s %s=%.3f" % [aid, pair[0], v])
		# 基座 = 占格：尺寸必须是 0.5 m 的整数倍
		var plinth := item.get_node_or_null("Plinth") as MeshInstance3D
		if plinth != null and plinth.mesh != null:
			for pair in [["占格宽", plinth.mesh.get_aabb().size.x],
					["占格深", plinth.mesh.get_aabb().size.z]]:
				var v2 := float(pair[1])
				if absf(round(v2 / CELL) * CELL - v2) > 0.001:
					off_lattice.append("%s %s=%.3f" % [aid, pair[0], v2])
		var key := Vector2i(int(round(gp.x)), int(round(gp.z)))
		if cells.has(key):
			dup.append("%s 与 %s 同在 %s" % [cells[key], aid, str(key)])
		cells[key] = aid
	_check(off_lattice.is_empty() and dup.is_empty(),
		"T4 摆位落格：%d 件位置均在 0.25 m 格、占格均为 0.5 m 整数倍；整数 cell %d 个不重合%s%s"
		% [scene.get_bench_items().size(), cells.size(),
			"" if off_lattice.is_empty() else "（离格：%s）" % off_lattice[0],
			"" if dup.is_empty() else "（重合：%s）" % dup[0]])


## 世界坐标下的可见包围盒（只算 MeshInstance3D；铭牌是 Label3D 文字叠层，不算几何）。
##
## **必须逐级合成局部变换，不能用 `get_global_transform()`**：`AnimatableBody3D` 的子节点
## （如传送带的带面 `Plate`）在 headless 下 `get_global_transform()` 会返回没接上父链的值
## （实测带面落到世界原点附近），于是包围盒凭空宽 2 m、误报一堆"穿模"。
## 物理服务器那套变换与渲染用的节点变换不是一回事。
func _world_aabb(node: Node3D) -> AABB:
	return _aabb_chain(node, node.global_transform)


func _aabb_chain(node: Node, base: Transform3D) -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array = [[node, base]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var t: Transform3D = pair[1]
		if n is MeshInstance3D:
			var mi := n as MeshInstance3D
			var wb: AABB = t * mi.get_aabb()
			if first:
				acc = wb
				first = false
			else:
				acc = acc.merge(wb)
		for c in n.get_children():
			if c is Node3D:
				stack.append([c, t * (c as Node3D).transform])
	return acc


func _t05_no_interpenetration(scene: Node3D) -> void:
	# 全场都算：生成台 28 件 + 南侧工区（播放器/求助屏/三块按钮）——
	# "不穿模"如果不把工区算进来，就等于没检查生成台有没有长进工区。
	var boxes: Array = []
	for item in scene.get_bench_items():
		boxes.append({"aid": str(item.get_meta("asset_id")), "box": _world_aabb(item as Node3D)})
	var util := scene.get_node_or_null("Utility")
	if util != null:
		for c in util.get_children():
			if c is Node3D and (c as Node3D).is_visible_in_tree():
				boxes.append({"aid": "Utility/" + str(c.name), "box": _world_aabb(c as Node3D)})
	var hits: Array = []
	var worst := 0.0
	var worst_pair := "无"
	for i in boxes.size():
		for j in range(i + 1, boxes.size()):
			var a: AABB = boxes[i]["box"]
			var b: AABB = boxes[j]["box"]
			var ox := minf(a.position.x + a.size.x, b.position.x + b.size.x) \
				- maxf(a.position.x, b.position.x)
			var oz := minf(a.position.z + a.size.z, b.position.z + b.size.z) \
				- maxf(a.position.z, b.position.z)
			if ox > OVERLAP_EPS and oz > OVERLAP_EPS:
				if ox * oz > worst:
					worst = ox * oz
					worst_pair = "%s × %s（%.2f×%.2f m）" % [
						boxes[i]["aid"], boxes[j]["aid"], ox, oz]
				hits.append("%s × %s" % [boxes[i]["aid"], boxes[j]["aid"]])
	_check(hits.is_empty(),
		"T5 互不穿模：%d 个可见体（生成台 28 + 工区）两两在水平面上不相交（重叠对数 %d，最大 %s）%s"
		% [boxes.size(), hits.size(), worst_pair,
			"" if hits.is_empty() else "（%s）" % hits[0]])


func _t06_inside_pad_and_clear_of_utility(scene: Node3D) -> void:
	var off_pad: Array = []
	var max_z := -1000.0
	var farthest := ""
	for item in scene.get_bench_items():
		var box := _world_aabb(item as Node3D)
		for corner in [
			Vector2(box.position.x, box.position.z),
			Vector2(box.position.x + box.size.x, box.position.z),
			Vector2(box.position.x, box.position.z + box.size.z),
			Vector2(box.position.x + box.size.x, box.position.z + box.size.z),
		]:
			if IslandScript.l4(corner.x, corner.y) > IslandScript.PAD_L4:
				off_pad.append("%s 角 %s" % [item.get_meta("asset_id"), str(corner)])
		if box.position.z + box.size.z > max_z:
			max_z = box.position.z + box.size.z
			farthest = str(item.get_meta("asset_id"))
	_check(off_pad.is_empty() and max_z <= UTILITY_Z,
		"T6 全部件在夯土台面内（越界 %d 例%s）；生成台可见体最南到 z=%.2f ≤ %.1f（%s），不叠进工区"
		% [off_pad.size(), "" if off_pad.is_empty() else "（%s）" % off_pad[0],
			max_z, UTILITY_Z, farthest])


# ---------- T7 部件外延落格（"占满整格"，2026-09-17 拍板的更严口径）----------

## 离格判定：v 距最近的 0.25 m 格点超过 EXTENT_EPS 才算违规
##（fposmod 手法同 run_block_conformance_tests.gd；负坐标也落在 [0, LATTICE)）。
func _off_grid(v: float) -> bool:
	var m := fposmod(v, LATTICE)
	return minf(m, LATTICE - m) > EXTENT_EPS


## 离格面的建议吸附值（最近的 0.25 m 格点）。
func _snap(v: float) -> float:
	return roundf(v / LATTICE) * LATTICE


## 28 件资产逐件扫子树里所有 BoxMesh 网格（Plinth、端口方标、发光芯全算），
## 断言每个部件盒世界 AABB 的六面都在 0.25 m 格点上 —— 即部件盒占满完整的 0.25 m 格。
## 违规时一行一条走 stderr（可 grep "^\[extent\]"）：
##   [extent] 资产id | 节点路径 | 违规轴 | 实际外延 (min,max) | 建议吸附值 (min,max)
func _t07_part_extents_on_grid(scene: Node3D) -> void:
	var items: Array = scene.get_bench_items()
	var viol: Array = []      # 违规行（stderr 清单，落盘 extent_violations_baseline.txt 用）
	var meshes := 0           # 扫到的部件网格总数
	var bad_meshes := 0       # 至少一条轴离格的网格数
	var clean := 0            # 六面全在格上的件数
	for item in items:
		var aid := str(item.get_meta("asset_id"))
		var item_bad := 0
		# 载体自身是 RigidBody3D（无网格），从子节点扫起；基座用载体的全局变换，
		# 子树内逐级合成局部变换（严禁 get_global_transform，见 _aabb_chain 的注释）。
		var base: Transform3D = (item as Node3D).global_transform
		for c in (item as Node3D).get_children():
			if c is Node3D:
				var r := _extent_scan(c, aid, base * (c as Node3D).transform, "", viol)
				meshes += int(r["meshes"])
				item_bad += int(r["bad"])
		if item_bad == 0:
			clean += 1
		bad_meshes += item_bad
	for line in viol:
		printerr(line)
	_check(bad_meshes == 0,
		"T7 部件外延落格：部件盒 AABB 六面均在 0.25 m 格上 —— %d 件中 %d 件干净 / %d 件违规，%d 个部件网格里 %d 个离格（逐条清单走 stderr [extent] 行%s）"
		% [items.size(), clean, items.size() - clean, meshes, bad_meshes,
			"" if viol.is_empty() else "，样例 " + viol[0]])


## 递归扫 node 子树，返回 {meshes: BoxMesh 网格数, bad: 有违规轴的网格数}，违规行追加进 viol。
## path 为相对载体的节点路径（首层不带 "/" 前缀）。变换沿 t 逐级合成局部变换。
func _extent_scan(node: Node3D, aid: String, t: Transform3D, path: String,
		viol: Array) -> Dictionary:
	var here_path := path + str(node.name)
	var meshes := 0
	var bad := 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := node as MeshInstance3D
		meshes += 1
		var box: AABB = t * mi.get_aabb()
		var any_bad := false
		for axis in [["x", box.position.x, box.end.x],
				["y", box.position.y, box.end.y],
				["z", box.position.z, box.end.z]]:
			if _off_grid(axis[1]) or _off_grid(axis[2]):
				any_bad = true
				viol.append("[extent] %s | %s | %s | (%.4f, %.4f) | (%.4f, %.4f)" % [
					aid, here_path, axis[0], axis[1], axis[2],
					_snap(axis[1]), _snap(axis[2])])
		if any_bad:
			bad += 1
	for c in node.get_children():
		if c is Node3D:
			var r := _extent_scan(c, aid, t * (c as Node3D).transform, here_path + "/", viol)
			meshes += int(r["meshes"])
			bad += int(r["bad"])
	return {"meshes": meshes, "bad": bad}
