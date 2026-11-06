extends SceneTree

# Independent 26-specimen contract; regrouping allowed, coverage must not shrink.
const SPECIMEN := "res://tests/bright_loop/bright_specimens.gd"
var passed := 0
var failed := 0

func _initialize() -> void:
	if not FileAccess.file_exists(SPECIMEN):
		check(false, "26-machine specimen builder exists")
		finish()
		return
	var builder = load(SPECIMEN)
	if builder == null:
		check(false, "specimen builder parses")
		finish()
		return
	check(is_equal_approx(builder.Q, 0.25), "q is 0.25 m")
	check(builder.MODULES.size() == 14, "14 modules from atlas")
	check(builder.PRIMITIVES.size() == 8, "8 code primitives from atlas")
	check(builder.FACILITIES.size() == 4, "4 studio facilities from atlas")
	check(builder.MACHINES.size() == 26, "26 independent specimens")
	var atlas_boxes := [5, 7, 5, 11, 8, 7, 6, 7, 7, 5, 3, 4, 7, 4, 4, 4, 5, 5, 4, 3, 4, 3, 5, 2, 1, 6]
	var original_sizes := [Vector3(2, 0.5, 2), Vector3(2.5, 1.5, 1.5), Vector3(2, 1.5, 2), Vector3(2.5, 1, 2)]
	for machine_index in 26:
		var machine: Dictionary = builder.MACHINES[machine_index]
		check(machine.boxes.size() == atlas_boxes[machine_index], "machine %d box count" % machine_index)
		check(machine.has("zh") and machine.has("en") and machine.has("summary"), "machine %d identity fields" % machine_index)
		var node: Node3D = builder.build_machine(machine_index)
		check(node.get_child_count() == machine.boxes.size(), "machine %d generated count" % machine_index)
		var total := AABB()
		for i in node.get_child_count():
			var part := node.get_child(i) as MeshInstance3D
			var row: Array = machine.boxes[i]
			var expected_min := Vector3(row[0], row[2], row[1]) * 0.25
			var expected_size := Vector3(row[3], row[5], row[4]) * 0.25
			var box: AABB = part.transform * part.mesh.get_aabb()
			check(box.position.is_equal_approx(expected_min) and box.size.is_equal_approx(expected_size), "machine %d part %d NW-bottom mapping and bounds" % [machine_index, i])
			total = box if i == 0 else total.merge(box)
			var on_grid := true
			for axis in 3:
				on_grid = on_grid and is_equal_approx(box.position[axis] / 0.25, round(box.position[axis] / 0.25)) and is_equal_approx(box.end[axis] / 0.25, round(box.end[axis] / 0.25))
			check(on_grid, "part six extents on q grid")
			var arrays: Array = part.mesh.surface_get_arrays(0)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
			check(indices.size() == 132, "44 triangles: genuine chamfer topology")
			var inset_ok := true
			for vertex in vertices:
				for axis in 3:
					var value: float = vertex[axis]
					inset_ok = inset_ok and (is_equal_approx(value, 0.0) or is_equal_approx(value, 0.05) or is_equal_approx(value, expected_size[axis] - 0.05) or is_equal_approx(value, expected_size[axis]))
			check(inset_ok, "0.05 m inward cut, not nonuniformly scaled bevel")
			var winding_ok := true
			for j in range(0, indices.size(), 3):
				var a: int = indices[j]
				var b: int = indices[j + 1]
				var c: int = indices[j + 2]
				var cross := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
				winding_ok = winding_ok and cross.dot(normals[a]) < -0.000001 and absf(cross.normalized().dot(normals[a])) > 0.999
			check(winding_ok, "all outward normals and Godot clockwise faces")
			var mat := part.material_override as StandardMaterial3D
			check(mat != null and not mat.emission_enabled, "lit matte material, no emissive substitute")
			var identity: Color = machine.color
			if row[6] == "SHELL":
				check(mat.albedo_color.is_equal_approx(identity), "shell carries identity albedo")
			if row[6] == "ACTION":
				check(mat.albedo_color.is_equal_approx(Color("ef743b")), "accent ACTION remapped to tool orange")
			if row[6] == "SIGNAL":
				check(mat.albedo_color.is_equal_approx(Color("24b9cf")), "accent SIGNAL remapped to bright cyan")
			if row[6] == "CORE":
				check(mat.albedo_color.is_equal_approx(Color("f2c43d")), "accent CORE remapped to bright amber")
			if row[6] == "SUCCESS":
				check(mat.albedo_color.is_equal_approx(Color("68ab5d")), "accent SUCCESS remapped to green")
			if row[6] == "ERROR":
				check(mat.albedo_color.is_equal_approx(Color("db6268")), "accent ERROR kept")
			if row[6] == "INK":
				check(mat.albedo_color.is_equal_approx(Color("263b40")), "ink kept")
			if row[6] == "PAPER":
				check(mat.albedo_color.get_luminance() > 0.85, "read surface is light")
			if row[6] == "STRUCTURE":
				check(mat.albedo_color.v < identity.v, "structure darkened versus identity")
		check(total.position.is_equal_approx(Vector3.ZERO), "machine %d total envelope origin" % machine_index)
		# The approved four are located by id: atlas order does not put them first.
		var original_slot: int = builder.ORIGINAL_IDS.find(machine.id)
		if original_slot >= 0:
			check(total.size.is_equal_approx(original_sizes[original_slot]), "original %s envelope unchanged" % machine.id)
		check(not builder.scene_has_label3d(node), "machine %d tree has no Label3D" % machine_index)
		node.free()
	# Ground labels: one flat tile per machine, four text lines, U=0.5 footprint.
	for machine_index in 26:
		var machine: Dictionary = builder.MACHINES[machine_index]
		check(machine.has("footprint") and machine.has("label_lines"), "machine %d label metadata" % machine_index)
		if not (machine.has("footprint") and machine.has("label_lines")):
			continue
		var label: Node3D = builder.build_label(machine_index)
		check(label.get_child_count() == 1, "label %d is a single flat tile" % machine_index)
		if label.get_child_count() == 1:
			var quad := label.get_child(0) as MeshInstance3D
			check(quad != null and quad.mesh is QuadMesh, "label %d ground quad mesh" % machine_index)
			var quad_size: Vector2 = quad.mesh.size
			check(is_equal_approx(quad_size.x / 0.5, round(quad_size.x / 0.5)) and is_equal_approx(quad_size.y / 0.5, round(quad_size.y / 0.5)), "label %d footprint on U=0.5 grid" % machine_index)
			check(quad.material_override is StandardMaterial3D, "label %d textured material" % machine_index)
		var lines: PackedStringArray = machine.label_lines
		check(lines.size() == 4, "label %d has four lines" % machine_index)
		check(lines[0] == machine.zh + " " + machine.en, "label %d name line" % machine_index)
		check(lines[1] == machine.summary, "label %d purpose line from atlas summary" % machine_index)
		check(lines[3] == "空闲 · 状态示意", "label %d idle status is schematic only" % machine_index)
		var text: String = "\n".join(lines)
		for forbidden in ["运行中", "成功", "错误："]:
			check(not text.contains(forbidden), "label %d does not fake a live event" % machine_index)
		check(not builder.scene_has_label3d(label), "label %d tree has no Label3D" % machine_index)
		label.free()
	# Flow arrows: in/out pairs on the ground, schematic only.
	for machine_index in 26:
		var arrows: Node3D = builder.build_arrows(machine_index)
		check(arrows.get_child_count() == 2, "machine %d has in+out arrow tiles" % machine_index)
		for arrow in arrows.get_children():
			check(arrow is MeshInstance3D and arrow.material_override is StandardMaterial3D, "machine %d arrow is textured ground tile" % machine_index)
			var label: String = arrow.get_meta("text", "")
			check(label == "IN" or label == "OUT", "machine %d arrow labeled in/out, not live wiring" % machine_index)
		arrows.free()
	finish()

func check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		push_error("FAIL: " + label)

func finish() -> void:
	print("BRIGHT SPECIMENS TOTAL: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
