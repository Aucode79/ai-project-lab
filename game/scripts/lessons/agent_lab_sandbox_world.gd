extends RefCounted

## Joins the executable Agent Lab to the free sandbox island and its transport stage.
const Diorama := preload("res://scripts/sandbox/sandbox_diorama.gd")
const Island := preload("res://scripts/sandbox/sandbox_island.gd")

const DECK_TOP_Y := Diorama.TOP_Y
const PROGRAM_STAGE_CENTER := Vector3(0.0, DECK_TOP_Y, -4.0)
const TRANSPORT_STAGE_ORIGIN := Vector3(0.0, DECK_TOP_Y, 4.25)
const TRANSPORT_STAGE_CENTER := Vector3(0.0, DECK_TOP_Y + 1.0, 5.75)
const TRANSPORT_HALF_EXTENTS := Vector2(5.25, 3.25)
const TRANSPORT_MAX_HEIGHT := 3.0
const WORLD_TOOL_TARGET := Vector3(0.0, DECK_TOP_Y + 1.0, TRANSPORT_STAGE_CENTER.z)
const DOCUMENT_LOCAL_TARGET := Vector3(5.0, 0.75, -0.75)


## Keeps the real transport actors from agent_transport.gd and replaces its
## temporary floor, camera and lighting with the free sandbox world recipe.
static func integrate(parent: Node3D, transport_modules: Array) -> Camera3D:
	var transport_zone := Node3D.new()
	transport_zone.name = "TransportZone"
	parent.add_child(transport_zone)

	for child in parent.get_children().duplicate():
		if child == transport_zone:
			continue
		if child is WorldEnvironment:
			parent.remove_child(child)
			child.free()
			continue
		if not child is Node3D:
			continue
		if str(child.name).begins_with("StationTile"):
			child.visible = false
			continue
		if transport_modules.has(child):
			# TextTile.bake_all runs asynchronously from the inherited world builder.
			# Keep the original assemblies alive until its collected quads finish baking.
			child.visible = false
			continue
		if _is_transport_actor(child):
			child.reparent(transport_zone, false)
			if _is_road(child):
				_set_road_material(child)
		elif _contains_text_tile(child):
			# Other catalog assemblies can also contain text quads collected by bake_all.
			child.visible = false
		else:
			parent.remove_child(child)
			child.free()

	transport_zone.position = TRANSPORT_STAGE_ORIGIN

	var updater := VoxelEngineUpdater.new()
	updater.name = "VoxelEngineUpdater"
	parent.add_child(updater)
	Diorama.add_environment(parent)
	Diorama.add_sun(parent)
	Diorama.add_particles(parent)
	var island = Island.new()
	island.show_lamp_pillars = false
	Diorama.add_terrain(parent, island)
	Diorama.add_deck_collision(parent, island)
	Diorama.attach_viewer(parent)

	var camera := Camera3D.new()
	camera.name = "AgentLabCamera"
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = 28.0
	camera.near = 0.1
	camera.far = 400.0
	var focus := PROGRAM_STAGE_CENTER + Vector3(0.0, 1.5, 0.0)
	camera.position = focus + Vector3(14.0, 19.0, 22.0)
	camera.current = true
	parent.add_child(camera)
	camera.look_at(focus)
	return camera


static func _is_transport_actor(node: Node3D) -> bool:
	return _is_road(node) or node.name in [
		"Roadblock",
		"DeliveryBay", "Carrier", "货物", "蓝方块", "黄方块"]


static func _is_road(node: Node3D) -> bool:
	# Godot replaces duplicate sibling names with generic @MeshInstance3D@N names.
	return node.has_meta("transport_road")


static func _contains_text_tile(node: Node) -> bool:
	if node is MeshInstance3D and node.has_meta("text") and node.has_meta("px"):
		return true
	for child in node.get_children():
		if _contains_text_tile(child):
			return true
	return false


static func _set_road_material(node: Node3D) -> void:
	if not node is MeshInstance3D:
		return
	var source := node.material_override as StandardMaterial3D
	if source == null:
		return
	var material := source.duplicate() as StandardMaterial3D
	material.albedo_color = Color("765f50")
	node.material_override = material
