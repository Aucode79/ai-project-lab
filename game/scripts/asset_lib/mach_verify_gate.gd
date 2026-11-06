extends "res://scripts/asset_lib/asset_node.gd"

## mach_verify_gate 校验门：schema 校验的空间化——通过走直道（青），
## 拒绝走侧岔（橙），fail_closed=true 时校验未过即关门。
## 与 base_gate 同款门板机制：is_open 是逻辑真相，门板只是跟随。
## assets/mach_verify_gate/asset.yaml: defaults {door_width: 1.0, fail_closed: true}

@export var door_width: float = 1.0
@export var fail_closed: bool = true

const DOOR_H := 1.0
const POST_H := 1.5
const DOOR_SPEED := 2.5

var is_open := false
var verdict := "idle"           # idle | pass | reject
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
	_target_y = 1.5 if open else DOOR_H * 0.5   # 3U：开门目标（n×0.25）


func set_verdict(passes: bool) -> void:
	# 通过 → 开门放行；拒绝 → fail_closed 时关门（旁路岔道仍可走）
	verdict = "pass" if passes else "reject"
	if passes:
		set_open(true)
	elif fail_closed:
		set_open(false)


func door_lifted() -> float:
	var door := get_node_or_null("Door") as Node3D
	if door == null:
		return 0.0
	return door.position.y - DOOR_H * 0.5


func _build() -> void:
	if _built:
		return
	_built = true
	# 部件外延落格口径（T7）：0.25 厚件的心必须在奇半格（±0.125 mod 0.25），
	# 门柱内缘贴门板缘（door_width 1.0 时柱心 ±0.625，柱廓 ±0.75 与梁端平齐）
	var post_x := door_width * 0.5 + 0.125
	add_box(self, "PostA", Vector3(0.25, POST_H, 0.25),
		Vector3(-post_x, POST_H * 0.5, -0.125), PAL_FRAME)
	add_box(self, "PostB", Vector3(0.25, POST_H, 0.25),
		Vector3(post_x, POST_H * 0.5, -0.125), PAL_FRAME)
	add_box(self, "Beam", Vector3(door_width + 0.5, 0.25, 0.25),
		Vector3(0.0, POST_H + 0.125, -0.125), PAL_FRAME)   # x = 3U（door_width 2U 时），坐在柱顶（底 = 柱顶 POST_H）

	var door := Node3D.new()
	door.name = "Door"
	add_child(door)
	add_box(door, "Panel", Vector3(door_width, DOOR_H, 0.25),
		Vector3(0.0, 0.0, -0.125), PAL_MACHINE)
	door.position.y = DOOR_H * 0.5
	set_open(false)

	# 两条去路的地衬：通过直道（青）与拒绝侧岔（橙）——坐在台面上（厚 0.25 心 0.125），贴门出口、延至端口
	add_box(self, "PassLane", Vector3(1.5, 0.25, 1.0),
		Vector3(door_width * 0.5 + 0.75, 0.125, 0.0), PAL_CORE)
	add_box(self, "RejectLane", Vector3(1.0, 0.25, 1.5),
		Vector3(0.0, 0.125, door_width * 0.5 + 0.75), PAL_MACHINE)

	# 端口方标：0.25 块嵌入宿主面 0.125（外面与宿主面平齐）或坐在台面（底贴面）
	add_port("input", Vector3(-post_x - 0.25, 0.625, -0.125))      # 贴 PostA 外面， y 半柱高处
	add_port("pass", Vector3(post_x + 1.25, 0.375, -0.125))        # 坐 PassLane 顶、背贴其 +x 端面
	add_port("reject", Vector3(-0.125, 0.375, post_x + 1.25))      # 坐 RejectLane 顶、背贴其 +z 端面
	add_port("control", Vector3(-0.125, POST_H + 0.375, -0.125))   # 坐梁顶（梁顶 = POST_H + 0.25）
