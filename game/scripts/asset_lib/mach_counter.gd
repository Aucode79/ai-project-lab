extends "res://scripts/asset_lib/asset_node.gd"

## mach_counter 计数器：tick 进、count 出（ANALOG 端口的例子：计数值是
## 模拟量，spec §7.2），溢出走 overflow BOOL 口。显示为补零数码。
## assets/mach_counter/asset.yaml: defaults {count_start: 0, digit_count: 3}

@export var count_start: int = 0
@export var digit_count: int = 3

var count: int = 0
var overflow := false
var _label: Label3D = null
var _built := false


func _ready() -> void:
	_build()


func bump(delta := 1) -> int:
	count += delta
	if count >= int(pow(10.0, digit_count)):
		overflow = true
	_refresh()
	return count


func reset() -> void:
	count = count_start
	overflow = false
	_refresh()


func _refresh() -> void:
	if _label != null:
		_label.text = str(count).pad_zeros(digit_count)


func _build() -> void:
	if _built:
		return
	_built = true
	add_box(self, "Pedestal", Vector3(1.0, 0.5, 0.5),
		Vector3(0.0, 0.25, 0.0), PAL_FRAME)          # 2U×1U×1U，中心 1U
	add_box(self, "Display", Vector3(1.0, 0.5, 0.5),
		Vector3(0.0, 0.75, 0.0), PAL_DEEP)           # 2U×1U×1U 整块；底贴 Pedestal 顶 0.5

	_label = Label3D.new()
	_label.name = "Digits"
	_label.position = Vector3(0.0, 0.75, 0.26)   # 贴 Display 前面 z=0.25（Label3D 豁免，+0.01 防 z-fight）
	_label.font_size = 64
	_label.pixel_size = 0.004
	_label.modulate = Style.SIGNAL
	_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_label.double_sided = false
	add_child(_label)

	count = count_start
	_refresh()

	# 端口方标 0.25：tick/count 嵌入机身侧面 0.125（外面平齐，y 廊 0.5..0.75 贴 Display 下半），
	# overflow 坐在 Display 顶（y 廓 1.0..1.25）
	add_port("tick", Vector3(-0.375, 0.625, -0.125))
	add_port("count", Vector3(0.375, 0.625, -0.125))
	add_port("overflow", Vector3(-0.125, 1.125, -0.125))
