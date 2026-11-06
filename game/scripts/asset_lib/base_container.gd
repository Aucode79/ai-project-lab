extends "res://scripts/asset_lib/asset_node.gd"

## base_container 容器：敞口接料、侧面排料，占 2×2 格（外廓 2.0 = 4U）。
## assets/base_container/asset.yaml: defaults {capacity: 8, wall_height: 0.5}

@export var capacity: int = 8
@export var wall_height: float = 0.5

const WALL_T := 0.25   # 壁厚 0.5U
const INNER := 1.5     # 内腔 3U，外廓 = INNER + 2·WALL_T = 2.0（4U）

var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	var outer := INNER + WALL_T * 2.0
	# 底板：2.0×2.0（4U）见方，厚 0.5（1U 整块），心 y 0.25 落格，顶 0.5
	add_box(self, "Floor", Vector3(outer, 0.5, outer),
		Vector3(0.0, 0.25, 0.0), PAL_DECK)
	# 墙坐 Floor 顶 0.5：墙心 = 0.5 + 墙半高 0.25 = 0.75（1.5U）
	var wall_y := 0.5 + wall_height * 0.5
	# 四面围板：+Z 面留低一点，当作排料口（drain 在那一侧）
	add_box(self, "WallBack", Vector3(outer, wall_height, WALL_T),
		Vector3(0.0, wall_y, -INNER * 0.5 - WALL_T * 0.5), PAL_FRAME)
	# 前墙半高（排料口）：高 0.25，坐 Floor 顶（心 y 0.625 落格），
	# 顶 0.75 = 侧墙半高；叠放而非半嵌，避免与 Floor 前立面共面闪面
	add_box(self, "WallFront", Vector3(outer, wall_height * 0.5, WALL_T),
		Vector3(0.0, 0.5 + wall_height * 0.25, INNER * 0.5 + WALL_T * 0.5), PAL_FRAME)
	add_box(self, "WallLeft", Vector3(WALL_T, wall_height, INNER),
		Vector3(-INNER * 0.5 - WALL_T * 0.5, wall_y, 0.0), PAL_FRAME)
	add_box(self, "WallRight", Vector3(WALL_T, wall_height, INNER),
		Vector3(INNER * 0.5 + WALL_T * 0.5, wall_y, 0.0), PAL_FRAME)
	# 端口方标 0.25³（位置纯视觉/交互参考，编译器不读，docs/10-契约/方块体系.md §6.2）：
	# mouth 坐 WallBack 顶（标心 y = 墙顶 1.0 + 半标 0.125，x −0.125 落格）；
	# drain 坐腔内排料口一侧的 Floor 顶、贴 WallFront 内立面
	#（标心 x −0.125 / y 0.625 / z 0.625 落格——原「贴外立面」外伸半格带偏整件
	# z 相位，收进腔内后全件 z 外延落 2.0 m 整格）
	add_port("mouth", Vector3(-0.125, wall_y + wall_height * 0.5 + 0.125,
		-INNER * 0.5 - WALL_T * 0.5))
	add_port("drain", Vector3(-0.125, 0.625, INNER * 0.5 - 0.125))
