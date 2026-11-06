extends "res://scripts/asset_lib/asset_node.gd"

## base_track 轨道/滑道：token 在上面滑行的静态导向件，占 length×1 格。
## assets/base_track/asset.yaml: defaults {length: 4.0}

@export var length: float = 4.0

var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	var half := snappedf(length * 0.5, 0.25)   # 端点吸附半块格（默认 4.0 不变）
	# 床身：z 宽 1.0（2U），厚 0.5（1U 整块），心 y 0.25 落格，顶 0.5
	add_box(self, "Bed", Vector3(half * 2.0, 0.5, 1.0),
		Vector3(0.0, 0.25, 0.0), PAL_DECK)
	# 导轨：0.25×0.25 方条坐在床顶（心 y 0.625 落格，原「半嵌」改叠放——底面贴
	# 床顶法向相反不闪面），轨长与床身齐（端面与床身端面同面但 y 向错层，不闪面），
	# z ±0.375 落格（内缘 ±0.25，轨距恰一个标准块宽）
	add_box(self, "RailA", Vector3(half * 2.0, 0.25, 0.25),
		Vector3(0.0, 0.625, -0.375), PAL_FRAME)
	add_box(self, "RailB", Vector3(half * 2.0, 0.25, 0.25),
		Vector3(0.0, 0.625, 0.375), PAL_FRAME)
	# 端口方标 0.25³ 坐床顶两端、卡在两轨之间贴床身端面
	#（标心 x ±(half−0.125) / y 0.625 / z 0.125 落格）
	add_port("entry", Vector3(-(half - 0.125), 0.625, 0.125))
	add_port("exit", Vector3(half - 0.125, 0.625, 0.125))
