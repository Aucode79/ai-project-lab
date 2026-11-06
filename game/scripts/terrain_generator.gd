extends VoxelGeneratorScript

## Flat teaching stage. Natural decorations are excluded from the art direction.
## World height and voxel indices retain the existing level/physics contract.
const CHANNEL := VoxelBuffer.CHANNEL_TYPE
const T_AIR := 0
const T_DEEP := 1
const T_ROCK := 2
const T_STRUCT := 3
const T_DECK := 4
const T_MACHINE := 5
const T_CORE := 6
const T_TRACE := 7
const BASE_HEIGHT := 20
const PLAZA_RADIUS := 6
const PLAZA_LIFT := 2


func _get_used_channels_mask() -> int:
	return 1 << CHANNEL


func _generate_block(buffer: VoxelBuffer, origin_in_voxels: Vector3i, _lod: int) -> void:
	var size := buffer.get_size()
	for z in size.z:
		var wz := origin_in_voxels.z + z
		for x in size.x:
			var wx := origin_in_voxels.x + x
			var h := _surface_height(wx, wz)
			for y in size.y:
				var wy := origin_in_voxels.y + y
				buffer.set_voxel(_type_at(wx, wy, wz, h, 0), x, y, z, CHANNEL)


func _surface_height(wx: int, wz: int) -> int:
	return BASE_HEIGHT + PLAZA_LIFT if _in_plaza(wx, wz) else BASE_HEIGHT


func _in_plaza(wx: int, wz: int) -> bool:
	return absi(wx) <= PLAZA_RADIUS and absi(wz) <= PLAZA_RADIUS


func _type_at(wx: int, wy: int, wz: int, h: int, _veg: int) -> int:
	if wy > h:
		return _decoration_at(wx, wy, wz, h, 0)
	if wy == h:
		return T_STRUCT if _in_plaza(wx, wz) else T_DECK
	if wy >= h - 2:
		return T_STRUCT
	if wy >= h - 8:
		return T_ROCK
	return T_DEEP


func _decoration_at(wx: int, wy: int, wz: int, h: int, _veg: int) -> int:
	if not _in_plaza(wx, wz):
		return T_AIR
	var on_corner := absi(wx) >= PLAZA_RADIUS - 1 and absi(wz) >= PLAZA_RADIUS - 1
	if not on_corner:
		return T_AIR
	if wy == h + 1:
		return T_ROCK
	if wy == h + 2:
		return T_CORE
	return T_AIR
