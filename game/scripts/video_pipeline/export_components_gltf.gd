extends SceneTree

## 微课 3D 流水线 · 组件几何导出（glTF 二进制 .glb，供 Blender 摆位/打光）。
##
## 跑法（headless -s，退出码制）：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://scripts/video_pipeline/export_components_gltf.gd
##   退出码 0 = 全部导出成功；1 = 有组件失败（原因经 stderr 说明）。
##
## 注意（AGENTS.md 已知坑位）：headless 的退出码经管道会丢，验收请直接取 $?；
## 结尾的 ObjectDB 泄漏告警是噪音，看退出码即可。
##
## 几何真源：component_catalog.build_machine() —— 与 studio.capture 的现搭路径同一处
## （真实 45°×0.05 m 倒角几何，不是包围盒）。catalog 里组件的原点是「西北底角」，
## 导出前整体平移 -footprint/2，使 .glb 的原点落在**底部中心**（Blender 摆位约定）；
## 单位沿用 Godot 默认（1 单位 = 1 米），不缩放。

const Catalog := preload("res://scripts/asset_lib/component_catalog.gd")

const OUT_DIR := "res://shots/video3d/components"

var _exported := 0
var _failed := 0
var _total_bytes := 0


func _initialize() -> void:
	var made := DirAccess.make_dir_recursive_absolute(OUT_DIR)
	if made != OK and made != ERR_ALREADY_EXISTS:
		push_error("无法创建输出目录 %s（%s）" % [OUT_DIR, error_string(made)])
		quit(1)
		return
	for i in Catalog.MACHINES.size():
		if not _export_one(i):
			_failed += 1
	print("EXPORT TOTAL: %d 成功 / %d 失败，共 %.2f MB → %s" % [
		_exported, _failed, float(_total_bytes) / 1048576.0, OUT_DIR])
	quit(1 if _failed > 0 else 0)


func _export_one(index: int) -> bool:
	var id: String = Catalog.MACHINES[index].id
	var assembly := Node3D.new()
	assembly.name = id

	var geometry := Catalog.build_machine(index)
	var span := Catalog.footprint(index)
	geometry.position = Vector3(-span.x * 0.5, 0.0, -span.y * 0.5)
	assembly.add_child(geometry)
	var triangles := _triangle_count(geometry)

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(assembly, state)
	if err != OK:
		push_error("组件 %s 无法加入 glTF 文档：%s" % [id, error_string(err)])
		assembly.free()
		return false
	var path := "%s/%s.glb" % [OUT_DIR, id]
	# 4.7 起写盘入口是 write_to_filesystem(state, path)；.glb 后缀决定二进制封装。
	err = doc.write_to_filesystem(state, path)
	if err != OK:
		push_error("组件 %s 写盘失败 %s：%s" % [id, path, error_string(err)])
		assembly.free()
		return false

	var bytes := _file_size(path)
	if bytes <= 0:
		push_error("组件 %s 写出空文件：%s" % [id, path])
		assembly.free()
		return false
	_exported += 1
	_total_bytes += bytes
	print("EXPORT: %-24s %8d B  %4d 三角形  %s" % [
		id, bytes, triangles, Vector2(span.x, span.y)])
	assembly.free()
	return true


## build_machine() 的根节点下逐个 MeshInstance3D 就是 catalog 的每个 box。
func _triangle_count(geometry: Node3D) -> int:
	var total := 0
	for child in geometry.get_children():
		if child is MeshInstance3D:
			var mesh := (child as MeshInstance3D).mesh
			if mesh != null:
				total += mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3
	return total


func _file_size(path: String) -> int:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return 0
	var length := int(f.get_length())
	f.close()
	return length
