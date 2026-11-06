extends SceneTree

## 方块合规锁（headless，退出码制）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/sandbox/run_block_conformance_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 用户口径（2026-09-16）：**所有资产都是方块组成，方向也一样。** 这两条在 headless 下
## 完全可判定 —— 但它判定的是**整个沙盒场景**（不只是生成台上的 28 件）：南侧工区的
## 播放器/求助屏、房间里的树石、按钮、灯笼都在画面里，都得守同一条口径。
## 所以这套件直接从场景根扫下来，任何一处非方块网格或任意角旋转都会 FAIL。
##
## 覆盖（2 条）：
##  T1 全是方块：场景里每个可见几何（MeshInstance3D）的网格都是 BoxMesh
##  T2 方向一致：每个节点相对世界的旋转都是 90° 的整数倍
##
## 为什么值得单开一套：这两条**被破坏时逻辑测试全绿** —— 一块斜着的装饰、一个圆柱树干、
## 一张"躺着"的幕布，都不影响任何流程断言，只在画面上难看（而且靠肉眼在不同机位下很难查全：
## 实测沙盒里曾同时有 7 类斜的东西：工区整屏 ±33°、锚点气泡 66°、树石随机偏航、
## 闸门斜向岔路 −28.6°、机械臂 −32°/26°、以及两张躺着的 PlaneMesh 幕布）。
##
## 注：`Label3D` 是文字叠层、不算几何，故不参与本判定（也不参与占格）。

const SandboxScene := preload("res://scenes/sandbox/sandbox.tscn")

var _passed := 0
var _failed := 0
var _non_box: Array = []
var _tilted: Array = []
var _geometry := 0


func _initialize() -> void:
	var scene: Node3D = SandboxScene.instantiate()
	root.add_child(scene)
	for i in 8:
		await create_timer(0.03).timeout
	await physics_frame

	_scan(scene, "", Transform3D.IDENTITY)

	_check(_non_box.is_empty() and _geometry > 0,
		"T1 全是方块：场景里 %d 个可见几何全部是 BoxMesh（非方块 %d 处%s）"
		% [_geometry, _non_box.size(),
			"" if _non_box.is_empty() else "：" + str(_non_box.slice(0, 3))])
	_check(_tilted.is_empty(),
		"T2 方向一致：全部节点的旋转都是 90° 的整数倍（任意角 %d 处%s）"
		% [_tilted.size(), "" if _tilted.is_empty() else "：" + str(_tilted.slice(0, 3))])

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


## 逐级合成局部变换（不用 get_global_transform：AnimatableBody3D 的子节点在 headless 下
## 它可能没接上父链，见 AGENTS.md 已知坑位 10）。
func _scan(node: Node, path: String, t: Transform3D) -> void:
	var here := t
	if node is Node3D:
		here = t * (node as Node3D).transform
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		_geometry += 1
		var where := path + "/" + str(node.name)
		var mesh := mi.mesh
		if not _is_block(mesh):
			_non_box.append("%s（%s）" % [where, mesh.get_class() if mesh != null else "null"])
		var e := here.basis.get_euler()
		for pair in [["x", e.x], ["y", e.y], ["z", e.z]]:
			var deg := rad_to_deg(float(pair[1]))
			var m := fposmod(deg, 90.0)
			if m > 0.5 and m < 89.5:
				_tilted.append("%s %s 轴 %.1f°" % [where, pair[0], deg])
				break
	for c in node.get_children():
		_scan(c, path + "/" + str(node.name), here)


## A bevel is accepted only with the exact 44-triangle topology, inward vertices and normals.
func _is_block(mesh: Mesh) -> bool:
	if mesh is BoxMesh: return true
	if not mesh is ArrayMesh or mesh.get_surface_count() != 1: return false
	var arrays := mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	if indices.size() != 132: return false
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var box := mesh.get_aabb()
	for vertex in vertices:
		for axis in 3:
			var value: float = vertex[axis] - box.position[axis]
			var width: float = box.size[axis]
			if not (is_equal_approx(value, 0) or is_equal_approx(value, 0.05) or is_equal_approx(value, width - 0.05) or is_equal_approx(value, width)):
				return false
	for i in range(0, indices.size(), 3):
		var a := indices[i]
		var cross := (vertices[indices[i+1]] - vertices[a]).cross(vertices[indices[i+2]] - vertices[a])
		if cross.dot(normals[a]) >= 0: return false
	return true
