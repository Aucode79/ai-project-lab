extends SceneTree

## 微课 3D 流水线 · 可执行整机导出（Blender 概念镜头用）。
## 读当前真实程序 game/agent-lab/program.json，用 machine_view 同源几何导出：
##   - res://shots/video3d/agent-lab/machine.glb（原点 = 包围盒底部中心，与 26 组件同约定）
##   - res://shots/video3d/agent-lab/machine_map.json（节点标签/位置/类别，供镜头与文字重建）
## 跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://scripts/video_pipeline/export_agent_lab_gltf.gd
## 退出码 0 = 成功；1 = 失败（原因经 stderr）。结尾 ObjectDB 泄漏告警是噪音。

const MachineView := preload("res://scripts/lessons/machine_view.gd")

const OUT_DIR := "res://shots/video3d/agent-lab"

func _initialize() -> void:
	var made := DirAccess.make_dir_recursive_absolute(OUT_DIR)
	if made != OK and made != ERR_ALREADY_EXISTS:
		push_error("无法创建输出目录 %s（%s）" % [OUT_DIR, error_string(made)])
		quit(1)
		return
	var text := FileAccess.get_file_as_string("res://agent-lab/program.json")
	if text.is_empty():
		push_error("缺少 game/agent-lab/program.json；请先启动一次 Agent Lab 生成程序")
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or not (parsed as Dictionary).get("modules", {}).has(str((parsed as Dictionary).get("entry", ""))):
		push_error("program.json 结构不完整（缺 entry 或模块）")
		quit(1)
		return
	var program: Dictionary = parsed
	var assembly := Node3D.new()
	assembly.name = "AgentLabMachine"
	var view := MachineView.build(assembly, program, program.entry, true, false)
	var min_p: Vector3 = view.positions.values()[0]
	var max_p: Vector3 = min_p
	for n in program.modules[program.entry].nodes:
		var p: Vector3 = view.positions[n.id]
		var ext := MachineView.extents(n)
		min_p = min_p.min(p - ext / 2)
		max_p = max_p.max(p + ext / 2)
	var shift := (min_p + max_p) / 2
	for child in assembly.get_children():
		child.position -= shift
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(assembly, state) != OK:
		push_error("整机无法加入 glTF 文档")
		quit(1)
		return
	var path := OUT_DIR + "/machine.glb"
	if doc.write_to_filesystem(state, path) != OK:
		push_error("写盘失败：%s" % path)
		quit(1)
		return
	var mapping := {"nodes": {}, "shift": [shift.x, shift.y, shift.z]}
	for n in program.modules[program.entry].nodes:
		var p: Vector3 = view.positions[n.id] - shift
		mapping.nodes[n.id] = {"label": str(n.get("label", n.id)), "op": str(n.op),
			"kind": MachineView.kind(n), "pos": [p.x, p.y, p.z]}
	var file := FileAccess.open(OUT_DIR + "/machine_map.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(mapping, "  ", false))
	file.close()
	print("MACHINE EXPORT: ", path, " nodes=", view.nodes.size(), " wires=", view.wires.size())
	quit(0)
