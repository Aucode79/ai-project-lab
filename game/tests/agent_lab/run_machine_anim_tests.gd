extends SceneTree

## machine_anim 回归：弧长插值、0.25 整格、包推进、游标结构、事件限速回放
## （递归深度 / 包数量 / 出队节奏）、工作态材质切换与叠板深度点灯。
## 全部数学断言 + 至多一帧建场景，不依赖 Tween（headless 静默不跑）。

const Anim := preload("res://scripts/lessons/machine_anim.gd")
const View := preload("res://scripts/lessons/machine_view.gd")
const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
const TextTile := preload("res://scripts/asset_lib/text_tile.gd")
const Catalog := preload("res://scripts/asset_lib/component_catalog.gd")

var failed := 0

func _init() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed += 1
		print("FAIL: " + message)

func _plain_mesh(parent: Node3D, size: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = Surface.mesh(size)
	mesh.material_override = Style.matte(color)
	parent.add_child(mesh)
	return mesh

func _run() -> void:
	# ① 弧长插值：端点、等长中点、不等长分位、退化输入。
	var path := [Vector3.ZERO, Vector3(0, 1, 0), Vector3(0, 1, 2)]
	_check(Anim.packet_position(path, 0.0) == path[0], "packet_position at 0 is the first point")
	_check(Anim.packet_position(path, 1.0) == path[2], "packet_position at 1 is the last point")
	var even := [Vector3.ZERO, Vector3(2, 0, 0), Vector3(2, 0, 2)]
	_check(Anim.packet_position(even, 0.5).distance_to(even[1]) < 0.001,
		"mid progress lands on the shared vertex of two equal segments")
	var uneven := [Vector3.ZERO, Vector3(2, 0, 0), Vector3(2, 0, 2)]
	_check(Anim.packet_position(uneven, 0.25).distance_to(Vector3(1, 0, 0)) < 0.001,
		"quarter progress rides the longer first segment")
	_check(Anim.packet_position(uneven, 0.75).distance_to(Vector3(2, 0, 1)) < 0.001,
		"three-quarter progress rides the second segment")
	_check(Anim.packet_position([], 0.5) == Vector3.ZERO, "empty path yields origin")
	_check(Anim.packet_position([Vector3(1, 2, 3)], 0.7) == Vector3(1, 2, 3), "single-point path yields that point")

	# ② 弧长整格化：输出全部落在 0.25 网格，且按最近格取整。
	for value in [0.0, 0.1, 0.13, 0.3, 0.49, 1.1, 7.6]:
		var q := Anim.packet_quantum(value)
		_check(absf(q / 0.25 - roundf(q / 0.25)) < 0.0001, "quantum output on the 0.25 grid: " + str(q))
	_check(Anim.packet_quantum(0.0) == 0.0, "quantum keeps zero")
	_check(absf(Anim.packet_quantum(0.3) - 0.25) < 0.001, "quantum rounds to the nearest cell")
	_check(absf(Anim.packet_quantum(7.6) - 7.5) < 0.001, "quantum rounds down past the half cell")

	# ③ 包推进：有限步到达、终点吻合、正交走线上位置落 0.25 网格。
	var holder := Node3D.new()
	root.add_child(holder)
	var wire := View.wire_path(Vector3(0, 0.5, 0), Vector3(3, 0.5, 0))
	var packet := Anim.spawn_packet(holder, wire, View.EXEC_COLOR)
	_check(packet.node.position == wire[0], "packet spawns at the path start")
	_check(absf(packet.length - 4.0) < 0.001, "wire arc length is rise+run+drop")
	var steps := 0
	var on_grid := true
	while steps < 400:
		if Anim.advance_packet(packet, 0.016): break
		var position: Vector3 = packet.node.position
		for axis in 3:
			if absf(position[axis] / 0.25 - roundf(position[axis] / 0.25)) > 0.001: on_grid = false
		steps += 1
	_check(steps < 400, "advance_packet arrives within finite steps")
	_check(packet.node.position.distance_to(wire[3]) < 0.001, "packet ends exactly at the wire end")
	_check(absf(packet.traveled - packet.length) < 0.001, "traveled reaches the full arc length")
	_check(on_grid, "packet positions stay on the 0.25 grid on an orthogonal wire")
	var done := Anim.advance_packet(packet, 0.016)
	_check(done, "advance_packet keeps reporting done at the end")

	# ④ 运行游标：0.5 身体 + 双脚 + 前端工具头 + 头顶标记 = 5 个 MeshInstance3D。
	var cursor := Anim.build_cursor(holder, View.EXEC_COLOR)
	var parts := {}
	var mesh_count := 0
	for child in cursor.get_children():
		if child is MeshInstance3D:
			mesh_count += 1
			parts[str(child.name)] = child
	_check(mesh_count == 5, "cursor has 5 mesh parts, got " + str(mesh_count))
	for part in ["Body", "FootL", "FootR", "ToolHead", "Badge"]:
		_check(parts.has(part), "cursor part present: " + part)
	_check(parts["Body"].mesh.get_aabb().size.distance_to(Vector3(0.5, 0.5, 0.5)) < 0.01,
		"cursor body is the 0.5 m standard cube")
	_check(parts["ToolHead"].position.x > parts["Body"].position.x, "tool head sits in front of the body")
	_check(parts["Badge"].position.y > parts["Body"].position.y, "identity marker sits on top")
	_check(parts["FootL"].position.y < parts["Body"].position.y and parts["FootR"].position.y < parts["Body"].position.y,
		"both feet sit below the body")
	# 行进走位：水平贴线，浮动不超过 0.05。
	Anim.step_cursor(cursor, wire, 0.0)
	_check(cursor.position.distance_to(wire[0]) < 0.001, "cursor steps to the path start without bob")
	Anim.step_cursor(cursor, wire, 0.3)
	var ideal: Vector3 = Anim.packet_position(wire, 0.3)
	_check(absf(cursor.position.x - ideal.x) < 0.001 and absf(cursor.position.z - ideal.z) < 0.001,
		"cursor tracks the path horizontally")
	_check(cursor.position.y - ideal.y >= -0.001 and cursor.position.y - ideal.y <= Anim.BOB + 0.001,
		"travel bob stays within 0.05")

	# ⑤ 事件限速回放：出队节奏、递归深度、包数量与走向。
	var node_a := Node3D.new(); node_a.position = Vector3(1.25, 0, -1.75); holder.add_child(node_a)
	var node_b := Node3D.new(); node_b.position = Vector3(4.25, 0, 0); holder.add_child(node_b)
	var node_t := Node3D.new(); node_t.position = Vector3(2, 0, 1); holder.add_child(node_t)
	var w_gen := View.wire_path(Vector3(-1.25, 0.5, -6), node_a.position + Vector3(0, 1, 0))
	var w_ab := View.wire_path(node_a.position + Vector3(0, 1, 0), node_b.position + Vector3(0, 1, 0))
	var w_bv := View.wire_path(node_b.position + Vector3(0.875, 1, 0), Vector3(7.5, 1, 6.75))
	var hooks := {
		"wires": {"gen.next->a.exec": w_gen, "a.next->b.exec": w_ab, "b.value->c.value": w_bv},
		"nodes": {"a": node_a, "b": node_b, "t0": node_t},
		"tools": {"fs.read": "t0"},
		"tool_target": Vector3(-7.5, 0.75, 3),
		"packet_root": holder,
	}
	var events: Array = [
		{"kind": "node", "callId": "1", "moduleId": "main", "nodeId": "a"},
		{"kind": "node", "callId": "1", "moduleId": "main", "nodeId": "b"},
		{"kind": "value", "callId": "1", "moduleId": "main", "nodeId": "b"},
		{"kind": "tool.start", "tool": "fs.read", "args": {}},
		{"kind": "enter", "callId": "1", "parentCallId": null, "moduleId": "m1"},
		{"kind": "enter", "callId": "2", "parentCallId": "1", "moduleId": "m2"},
		{"kind": "leave", "callId": "2"},
	]
	var state := Anim.new_state()
	Anim.queue_events(state, events)
	var activated := Anim.update(state, 0.1, hooks)
	_check(activated.is_empty(), "no event leaves the queue before a full 0.15 s interval")
	activated = Anim.update(state, 0.05, hooks)
	_check(activated == ["a"], "first tick fires the first event only")
	activated = Anim.update(state, 0.6, hooks)
	_check(activated == ["b", "b", "t0"], "0.6 s releases the next four events in order")
	_check(int(state.depth) == 1, "one call still open after the first enter")
	activated = Anim.update(state, 0.15, hooks)
	_check(activated.is_empty(), "enter activates no node")
	_check(int(state.depth) == 2 and int(state.max_depth) == 2, "nested enter drives depth to 2")
	activated = Anim.update(state, 0.15, hooks)
	_check(state.queue.is_empty(), "all seven events drained")
	_check(int(state.depth) == 1, "leave closes the inner call back to depth 1")
	_check(state.packets.size() == 4, "node/node/value/tool.start spawned four packets")
	_check(state.packets[0].path == w_gen and state.packets[1].path == w_ab and state.packets[2].path == w_bv,
		"packets ride the exec-in, exec-in and value-out wires")
	_check(state.packets[3].node.material_override.albedo_color.is_equal_approx(Anim.TOOL_PULSE_COLOR),
		"tool.start spawns the golden pulse packet")
	_check(float(state.packets[0].traveled) > 0.0, "packets advanced while events replayed")
	await process_frame
	_check(is_instance_valid(state.packets[0].node), "unfinished packets stay alive")

	# ⑥ 工作态：开灯有 emission，关灯还原哑光基色。
	var work := Node3D.new()
	root.add_child(work)
	var mesh_a := _plain_mesh(work, Vector3(0.5, 0.5, 0.5), View.BODY_COLOR)
	var mesh_b := _plain_mesh(work, Vector3(0.25, 0.25, 0.25), View.EXEC_COLOR)
	Anim.set_working(work, true)
	_check(mesh_a.material_override.emission_enabled and mesh_b.material_override.emission_enabled,
		"working state lights every mesh with emission")
	_check(mesh_a.get_meta("base_color") == View.BODY_COLOR, "base color stored in meta before lighting")
	Anim.set_working(work, false)
	_check(not mesh_a.material_override.emission_enabled and not mesh_b.material_override.emission_enabled,
		"restored matte materials carry no emission")
	_check(mesh_a.material_override.albedo_color.is_equal_approx(View.BODY_COLOR)
		and mesh_b.material_override.albedo_color.is_equal_approx(View.EXEC_COLOR),
		"original colors restored after switching off")

	# ⑦ call 叠板深度点灯 + 深度徽标（贴地字砖：文本写在砖面 meta，headless 不烘）。
	var call_node := Node3D.new()
	root.add_child(call_node)
	var plates: Array = []
	for i in 3:
		plates.append(_plain_mesh(call_node, Vector3(1.5 - 0.25 * i, 0.25, 1.0 - 0.25 * i), Color("7499a2")))
	var badge := TextTile.ground_label(call_node, "DepthBadge", "", Vector3(0, 0.01, 1.25), Vector2(0.5, 0.5))
	Anim.depth_plates(call_node, 2)
	_check(plates[0].material_override.emission_enabled and plates[1].material_override.emission_enabled,
		"depth 2 lights the first two plates")
	_check(not plates[2].material_override.emission_enabled, "plates beyond depth stay matte")
	_check(PackedStringArray(badge.get_meta("text")) == PackedStringArray(["2"]),
		"depth badge shows the current depth")
	Anim.depth_plates(call_node, 0)
	_check(not plates[0].material_override.emission_enabled, "depth 0 resets the plates")
	_check(PackedStringArray(badge.get_meta("text")) == PackedStringArray(["0"]),
		"depth badge resets to zero")

	# ⑧ 追加：深度徽标是贴地字砖——非 Label3D、文本经字砖 meta 可读回、整树无 Label3D。
	var badge_node := Node3D.new()
	root.add_child(badge_node)
	for i in 3:
		_plain_mesh(badge_node, Vector3(1.5 - 0.25 * i, 0.25, 1.0 - 0.25 * i), Color("7499a2"))
	var tile_badge := TextTile.ground_label(badge_node, "DepthBadge", "", Vector3(0, 0.01, 1.25), Vector2(0.5, 0.5))
	Anim.depth_plates(badge_node, 3)
	_check(tile_badge.get_class() == "MeshInstance3D", "depth badge is a ground text tile, not a Label3D")
	_check(PackedStringArray(tile_badge.get_meta("text")) == PackedStringArray(["3"]),
		"depth tile text reads back from the tile meta")
	_check(tile_badge.visible, "depth write makes the tile badge visible")
	_check(not Catalog.scene_has_label3d(badge_node), "depth replay adds no Label3D")

	# ⑨ 工作态点灯不得洗掉字砖烘焙纹理：带 meta "text" 的字砖不参与点灯/还原
	# （模拟烘焙产物：albedo_color=WHITE + 任一 albedo_texture）。
	var lit_holder := Node3D.new()
	root.add_child(lit_holder)
	var plain := _plain_mesh(lit_holder, Vector3(0.5, 0.5, 0.5), View.BODY_COLOR)
	var station := TextTile.ground_label(lit_holder, "NameTile", "站", Vector3(0, 0.01, 1.25), Vector2(1.5, 0.5))
	var baked := StandardMaterial3D.new()
	baked.albedo_color = Color.WHITE
	baked.albedo_texture = ImageTexture.create_from_image(Image.create_empty(8, 8, false, Image.FORMAT_RGBA8))
	station.material_override = baked
	Anim.set_working(lit_holder, true)
	_check(plain.material_override.emission_enabled, "working state still lights plain meshes beside text tiles")
	_check(station.material_override == baked and station.material_override.albedo_texture != null,
		"working state keeps the baked text tile material and texture")
	Anim.set_working(lit_holder, false)
	_check(station.material_override == baked and station.material_override.albedo_texture != null,
		"switching working off keeps the baked text tile material and texture")
	lit_holder.free()

	holder.free()
	work.free()
	call_node.free()
	badge_node.free()
	# lit_holder 已在第 ⑨ 节末尾就地释放，这里不再重复 free。
	# 退出前等两帧：第一帧清 deferred 释放队列（queue_free 的包节点等），
	# 第二帧确保清空后再进 quit 的引擎收尾，避开偶发的退出期竞态（打印 PASS 后 rc=1）。
	await process_frame
	await process_frame
	print("MACHINE ANIM: ", "PASS" if failed == 0 else "FAIL", " failures=", failed)
	quit(0 if failed == 0 else 1)
