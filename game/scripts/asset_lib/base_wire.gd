extends "res://scripts/asset_lib/asset_node.gd"

## base_wire 连线段：两端口之间的信号线。BOOL 线亮青，ANALOG 线用饱和青
##（spec §7.2：模拟量是连线上可见的显式端口类型）；块状化 v2 梁/帽半块方料、
## 柱 z 向加深半块（外延落格口径），粗细一致，模拟/数字靠配色区分。
## assets/base_wire/asset.yaml: defaults {length: 1.0, carries_analog: false}

@export var length: float = 1.0
@export var carries_analog: bool = false

const WIRE_Y := 0.5   # 走线高度 1U

var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	var half := snappedf(length * 0.5, 0.25)   # 端点吸附半块格（默认 1.0 不变）
	var color := PAL_CIRCUIT if carries_analog else PAL_CORE
	# 柱：截面 0.25×0.5（z 加深半块——0.25 深没法让全件 z 外延落 0.5 m 格），
	# 心 x ±(half+0.125) 落格，高 0.5（1U），心 y 0.25 落格
	add_box(self, "PostA", Vector3(0.25, WIRE_Y, 0.5),
		Vector3(-half - 0.125, WIRE_Y * 0.5, 0.0), PAL_FRAME)
	add_box(self, "PostB", Vector3(0.25, WIRE_Y, 0.5),
		Vector3(half + 0.125, WIRE_Y * 0.5, 0.0), PAL_FRAME)
	# 梁：0.25×0.25 方梁坐在柱顶（心 y 0.625 落格）、贴 +z 半边柱顶（心 z 0.125 落格）；
	# 长 = 两柱内侧面间距（端面贴柱免共面闪面），模拟/数字线同粗细，靠配色区分
	add_box(self, "Beam", Vector3(half * 2.0, 0.25, 0.25),
		Vector3(0.0, WIRE_Y + 0.125, 0.125), color)
	# 端帽：0.25³ 方块坐柱顶，与梁同层同 z（心 y 0.625 / z 0.125 落格）
	add_box(self, "CapA", Vector3.ONE * 0.25,
		Vector3(-half - 0.125, WIRE_Y + 0.125, 0.125), color)
	add_box(self, "CapB", Vector3.ONE * 0.25,
		Vector3(half + 0.125, WIRE_Y + 0.125, 0.125), color)
	# 端口方标 0.25³：贴帽外端面（标心 x = ±(half + 0.375) 落格，y 0.625 / z 0.125 落格）
	add_port("a", Vector3(-half - 0.375, WIRE_Y + 0.125, 0.125))
	add_port("b", Vector3(half + 0.375, WIRE_Y + 0.125, 0.125))
