extends "res://scripts/asset_lib/asset_node.gd"

## base_gate 闸门：可开关的通断件。门板沿导柱升降，_physics_process 里
## 以固定速率滑向目标高度（不用动画播放器，逻辑状态 is_open 即真相）。
## assets/base_gate/asset.yaml: defaults {door_width: 1.0, open_by_default: false}

@export var door_width: float = 1.0
@export var open_by_default: bool = false

const DOOR_H := 1.0
const POST_H := 1.5
const DOOR_SPEED := 2.0          # m/s，门板升降速率

var is_open := false
var _target_y := 0.0
var _built := false


func _ready() -> void:
	_build()


func _physics_process(delta: float) -> void:
	var door := get_node_or_null("Door") as Node3D
	if door == null:
		return
	door.position.y = move_toward(door.position.y, _target_y, DOOR_SPEED * delta)


func set_open(open: bool) -> void:
	is_open = open
	# 关 = 挡住通道（门板中心 0.5）；开 = 升到柱顶（1.5 = 3U，
	# 抬升 1.0 = 门高，门底净空恰好过一整个门洞）
	_target_y = 1.5 if open else DOOR_H * 0.5


func door_lifted() -> float:
	# 门板相对关闭位的抬起量（测试用）
	var door := get_node_or_null("Door") as Node3D
	if door == null:
		return 0.0
	return door.position.y - DOOR_H * 0.5


func _build() -> void:
	if _built:
		return
	_built = true
	# 柱位 = 门半宽 0.5 + 半柱距 0.125 = 0.625（外延落格口径：柱心须落半格奇数位，
	# 比原 0.75 外移半格，门洞内缘 ±0.5 恰含门宽）；方柱 0.25 见方（半块）
	var post_x := snappedf(door_width * 0.5, 0.25) + 0.125
	add_box(self, "PostA", Vector3(0.25, POST_H, 0.25),
		Vector3(-post_x, POST_H * 0.5, 0.0), PAL_FRAME)
	add_box(self, "PostB", Vector3(0.25, POST_H, 0.25),
		Vector3(post_x, POST_H * 0.5, 0.0), PAL_FRAME)
	# 横梁：0.25×0.25 方梁，长 = 柱外距（端面与柱外缘齐平，盖满两柱顶）；
	# 坐柱顶（心 y = POST_H + 0.125 = 1.625 落格，梁底贴柱顶 1.5，原「半嵌」改叠放）
	add_box(self, "Beam", Vector3(snappedf(door_width * 0.5, 0.25) * 2.0 + 0.5, 0.25, 0.25),
		Vector3(0.0, POST_H + 0.125, 0.0), PAL_FRAME)

	var door := Node3D.new()
	door.name = "Door"
	add_child(door)
	# 门板：厚 0.25（半块），心 y 0.5 关 / 1.5 开（门洞 ±0.5 与门宽齐贴，原 0.125
	# 净空让位给柱外移——柱心落格的代价；滑动接触面法向相反，不闪面）
	add_box(door, "Panel", Vector3(door_width, DOOR_H, 0.25),
		Vector3.ZERO, PAL_MACHINE)
	door.position.y = DOOR_H * 0.5

	is_open = open_by_default
	set_open(is_open)

	# 端口方标 0.25³（位置纯视觉/交互参考，编译器不读）：
	# in/out 贴柱外立面（柱外缘 ±0.75，标心 x ±(post_x+0.25) 落格，y 0.625 落格）；
	# control 贴梁前立面（+z：标心 y 1.625 / z 0.25 落格，x 0.125 落格）
	add_port("in", Vector3(-post_x - 0.25, 0.625, 0.0))
	add_port("out", Vector3(post_x + 0.25, 0.625, 0.0))
	add_port("control", Vector3(0.125, POST_H + 0.125, 0.25))
