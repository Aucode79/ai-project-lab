extends RefCounted

## One 0.05 m inward chamfer for catalog, teaching assets and scene assembly.
const Block := preload("res://scripts/sandbox/sandbox_block.gd")
static var _meshes := {}

static func mesh(size: Vector3, centered := true) -> ArrayMesh:
	var key := str(size) + str(centered)
	if _meshes.has(key): return _meshes[key]
	var arrays := Block.block_mesh().surface_get_arrays(0).duplicate(true)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		var vertex := vertices[i]
		for axis in 3:
			if vertex[axis] > 0.5: vertex[axis] = size[axis] - (1.0 - vertex[axis])
		vertices[i] = vertex - size * 0.5 if centered else vertex
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_meshes[key] = result
	return result

static func apply(node: Node) -> void:
	if node is MeshInstance3D and node.mesh is BoxMesh:
		var original: BoxMesh = node.mesh
		# Existing sub-0.1 m glyph leaders cannot contain two 0.05 m cuts.
		if original.size.x > 0.1 and original.size.y > 0.1 and original.size.z > 0.1:
			node.mesh = mesh(original.size)
			node.set_surface_override_material(0, original.material)
	for child in node.get_children(): apply(child)
