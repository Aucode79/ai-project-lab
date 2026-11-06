extends "res://scripts/asset_lib/asset_node.gd"

## base_slot 插槽：只认 accepted_kind 的接口插槽（接口签名的空间化）。
## 腔体朝 +X 敞开，底座 1×1 格。
## assets/base_slot/asset.yaml: defaults {accepted_kind: "code_block", slot_width: 0.5}

@export var accepted_kind: String = "code_block"
@export var slot_width: float = 0.5

const SOCKET_H := 0.5   # 腔高 1U
const SOCKET_T := 0.25  # 壁厚 0.5U

var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	# 底座：1×1 格（2U 见方），厚 0.5（1U 整块），心 y 0.25 落格，顶 0.5
	add_box(self, "Base", Vector3(1.0, 0.5, 1.0), Vector3(0.0, 0.25, 0.0), PAL_DECK)
	# 墙坐 Base 顶 0.5：墙心 = 0.5 + 半高 0.25 = 0.75（1.5U）
	var wall_y := 0.5 + SOCKET_H * 0.5
	# 侧壁中心 = 半宽 0.25 + 半厚 0.125 = 0.375（1.5U，落格）；外缘 ±0.5 贴底座边
	var side_z := slot_width * 0.5 + SOCKET_T * 0.5
	# 三面围出 U 形腔：背板挡 -X（外缘贴底座边 -0.5，中心 -0.375），
	# 两侧板限位（x 0.5 = 1U，内缘贴背板），+X 是插入口
	add_box(self, "Back", Vector3(SOCKET_T, SOCKET_H, slot_width + SOCKET_T * 2.0),
		Vector3(-0.5 + SOCKET_T * 0.5, wall_y, 0.0), PAL_FRAME)
	add_box(self, "SideA", Vector3(0.5, SOCKET_H, SOCKET_T),
		Vector3(0.0, wall_y, -side_z), PAL_FRAME)
	add_box(self, "SideB", Vector3(0.5, SOCKET_H, SOCKET_T),
		Vector3(0.0, wall_y, side_z), PAL_FRAME)
	# 端口方标 0.25³ 坐腔底（Base 顶 0.5）靠 +X 插入口（心 x/z 0.125 / y 0.625 落格；
	# 位置纯视觉/交互参考）。原腔底 0.02 衬垫（豁免检测面）厚度落不进 0.25 m 格
	# 且全库无引用，随外延落格口径删除。
	add_port("slot", Vector3(0.125, 0.625, 0.125))
