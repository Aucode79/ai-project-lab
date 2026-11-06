extends "res://scripts/asset_lib/asset_node.gd"

## base_label 标签牌：世界内的标注件（文字本体，走沙盒不走图层——图层管
## 公式/字幕这类版式，世界里的指向牌仍是空间物）。无端口。
## assets/base_label/asset.yaml: defaults {label_text: "标签", panel_width: 1.5}

@export var label_text: String = "标签"
@export var panel_width: float = 1.5

var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	# 立柱：0.25 见方（半块方柱），高 1.0（2U），心 y 0.5 落格；
	# 心 x/z 偏半格（0.125 落格口径：0.25 方柱心在 0 时四面都落不进格），柱背贴牌背
	add_box(self, "Post", Vector3(0.25, 1.0, 0.25), Vector3(0.125, 0.5, -0.125), PAL_FRAME)
	# 牌面：0.5 整块厚（厚 = 高 = 0.5），底坐柱顶 1.0（间隙 0），心 y 1.25 落格；
	# 块状化 v2：旧 Frame 包边（厚 0.04 无法落格）删除，牌面即全部
	add_box(self, "Panel", Vector3(panel_width, 0.5, 0.5),
		Vector3(0.0, 1.25, 0.0), PAL_DECK)

	var label := Label3D.new()
	label.name = "Label"
	label.text = label_text
	# Label3D 贴牌面 +Z 面（纯视觉豁免件，不入格审计）
	label.position = Vector3(0.0, 1.25, 0.26)
	label.font_size = 64
	label.pixel_size = 0.004
	label.modulate = Style.INK
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.double_sided = false
	add_child(label)
