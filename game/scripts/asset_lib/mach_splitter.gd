extends "res://scripts/asset_lib/asset_node.gd"

## mach_splitter 分流器：一路进、两路出，翻板偏向流量大的一侧
## （分岔/扇出拓扑的空间化）。split_ratio 是 ANALOG 参数的例子。
## assets/mach_splitter/asset.yaml: defaults {split_ratio: 0.5}

@export var split_ratio: float = 0.5

const EXIT_GAP := 1.0           # 2U 出口间距

var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	add_box(self, "Entry", Vector3(1.0, 0.5, 1.0),
		Vector3(-1.0, 0.25, 0.0), PAL_DECK)          # 2U 轨道整块（厚 0.5 心 0.25）
	add_box(self, "Hub", Vector3(1.0, 0.5, EXIT_GAP * 2.0 + 0.5),
		Vector3(0.0, 0.25, 0.0), PAL_FRAME)          # 2U 宽 × 5U 长（厚 0.5）
	add_box(self, "ExitA", Vector3(1.0, 0.5, 1.0),
		Vector3(1.0, 0.25, -EXIT_GAP), PAL_DECK)     # 2U 轨道，出口中心 ±2U
	add_box(self, "ExitB", Vector3(1.0, 0.5, 1.0),
		Vector3(1.0, 0.25, EXIT_GAP), PAL_DECK)

	# 翻板：>0.5 偏 B 侧（+Z），<=0.5 偏 A 侧。轴向对齐口径下只用 90° 的整数倍
	# （原为 ±45° 斜角；两个状态照样一眼可辨 —— 板面朝向差 90°）
	# 外延落格：0.25 厚板的心挪到 +0.125（z 廓 0..0.25 落格）
	var flap := add_box(self, "Flap", Vector3(0.5, 0.5, 0.25),
		Vector3(0.0, 0.5, 0.125), PAL_MACHINE)       # 1U×1U 翻板，中心 2U，厚半块
	flap.rotation.y = PI * 0.5 if split_ratio > 0.5 else 0.0

	# 端口方标 0.25 嵌入轨道端面 0.125（外面与轨道面平齐），y 廓 0..0.25（底坐台面）
	add_port("feed", Vector3(-1.375, 0.125, -0.125))
	add_port("out_a", Vector3(1.375, 0.125, -EXIT_GAP - 0.125))
	add_port("out_b", Vector3(1.375, 0.125, EXIT_GAP + 0.125))
