extends RefCounted

## Opaque round cable geometry shared by machine wires and the live drag preview.
const RADIUS := 0.085
const JOINT_RADIUS := 0.09


static func build_wire(parent: Node3D, path: Array, color: Color,
		source_surface: Vector3, target_surface: Vector3, with_terminals := true) -> void:
	var jacket := _jacket(color)
	if with_terminals:
		_add_segment(parent, source_surface, path[0], RADIUS, jacket, "T_source")
	for i in path.size() - 1:
		var start: Vector3 = path[i]
		var finish: Vector3 = path[i + 1]
		if start.distance_to(finish) < 0.05: continue
		_add_segment(parent, start, finish, RADIUS, jacket, "S_" + str(i))
		var span := finish - start
		if absf(span.y) < 0.001 and (absf(span.x) > 0.001 or absf(span.z) > 0.001):
			_add_direction_marks(parent, start, finish, color)
			if i == _last_horizontal(path):
				_add_arrow(parent, finish, span.normalized(), color)
	if with_terminals:
		_add_segment(parent, path[path.size() - 1], target_surface, RADIUS, jacket, "T_target")
	for point in path:
		_add_joint(parent, point, jacket, "J_route")
	if with_terminals:
		_add_joint(parent, source_surface, jacket, "J_source")
		_add_joint(parent, target_surface, jacket, "J_target")


static func _last_horizontal(path: Array) -> int:
	var last := -1
	for i in path.size() - 1:
		var span: Vector3 = path[i + 1] - path[i]
		if absf(span.y) < 0.001 and (absf(span.x) > 0.001 or absf(span.z) > 0.001):
			last = i
	return last


static func _jacket(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.roughness = 0.34
	material.metallic = 0.16
	return material


static func _marker_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color.lightened(0.32)
	material.transparency = BaseMaterial3D.TRANSPARENCY_DISABLED
	material.roughness = 0.3
	material.metallic = 0.12
	return material


static func _add_segment(parent: Node3D, start: Vector3, finish: Vector3, radius: float,
		material: Material, node_name: String) -> void:
	var length := start.distance_to(finish)
	if length < 0.01: return
	var segment := MeshInstance3D.new()
	segment.name = node_name
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = length + radius * 0.6
	mesh.radial_segments = 16
	segment.mesh = mesh
	segment.material_override = material
	segment.position = (start + finish) * 0.5
	segment.quaternion = Quaternion(Vector3.UP, (finish - start).normalized())
	parent.add_child(segment)


static func _add_joint(parent: Node3D, point: Vector3, material: Material, node_name: String) -> void:
	var joint := MeshInstance3D.new()
	joint.name = node_name
	var mesh := SphereMesh.new()
	mesh.radius = JOINT_RADIUS
	mesh.height = JOINT_RADIUS * 2.0
	mesh.radial_segments = 16
	mesh.rings = 8
	joint.mesh = mesh
	joint.material_override = material
	joint.position = point
	parent.add_child(joint)


static func _add_direction_marks(parent: Node3D, start: Vector3, finish: Vector3, color: Color) -> void:
	var delta := finish - start
	var axis := 0 if absf(delta.x) > 0.001 else 2
	var direction := Vector3.RIGHT if axis == 0 else Vector3.BACK
	if delta[axis] < 0.0: direction = -direction
	var side := Vector3(direction.z, 0.0, -direction.x)
	var low: float = minf(start[axis], finish[axis])
	var high: float = maxf(start[axis], finish[axis])
	var material := _marker_material(color)
	for mark in range(ceili(low), floori(high) + 1):
		var center := start
		center[axis] = float(mark)
		var chevron := Node3D.new()
		chevron.name = "C_mark"
		chevron.position = center
		parent.add_child(chevron)
		var tip := direction * 0.09 + Vector3.UP * (RADIUS + 0.018)
		var back := -direction * 0.075 + Vector3.UP * (RADIUS + 0.018)
		_add_segment(chevron, back + side * 0.075, tip, 0.022, material, "C_head_a")
		_add_segment(chevron, back - side * 0.075, tip, 0.022, material, "C_head_b")


static func _add_arrow(parent: Node3D, tip: Vector3, direction: Vector3, color: Color) -> void:
	var arrow := MeshInstance3D.new()
	arrow.name = "Arrow"
	var mesh := CylinderMesh.new()
	mesh.top_radius = 0.0
	mesh.bottom_radius = 0.1
	mesh.height = 0.24
	mesh.radial_segments = 12
	arrow.mesh = mesh
	arrow.material_override = _marker_material(color)
	arrow.position = tip - direction * 0.12
	arrow.quaternion = Quaternion(Vector3.UP, direction)
	parent.add_child(arrow)
