extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 回廊组件（docs/10-契约/mini-codex.md §一 #12；L5 四件之一）。
## 世界形态：带环的走廊——环形地板 + 四角柱 + 入口缺口 + 到循环上限打开的
## 显式出口；步数计数器（Label3D）显示"第 n/上限 轮"，循环上限是参数（如 3）。
## 它是家族一代码结构方块的预设装配，不是新方块类型（mini-codex §一）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：待命/正在/完成/出错由步记录派生，
## **不另做状态机**——本节点只负责把派生结果显示出来：
##   * set_rounds()/set_exit_open() 只改显示，不保存逻辑状态；
##   * derive_state_from_steps() / state_trajectory() 是纯函数，输入步记录数组。
## 派生口径（L5）：
##   待命：还没有任何针对本实体的 set_param(rounds)
##   正在：进入某一轮（set_param rounds 成功）
##   完成：set_param(@done) 置真（回廊走到显式出口）
##   出错：针对本实体的写操作返回失败

const STATE_IDLE := "idle"
const STATE_RUNNING := "running"
const STATE_DONE := "done"
const STATE_ERROR := "error"

const STATE_COLORS := {
	STATE_IDLE: Color(0.564, 0.533, 0.471),
	STATE_RUNNING: Color(0.929, 0.471, 0.345),
	STATE_DONE: Color(0.373, 0.816, 0.451),
	STATE_ERROR: Color(0.914, 0.325, 0.325),
}
const STATE_CAPTIONS := {
	STATE_IDLE: "待命",
	STATE_RUNNING: "正在",
	STATE_DONE: "完成",
	STATE_ERROR: "出错",
}

# 明亮定稿调色板（docs/10-契约/美术方向.md）
const FLOOR_COLOR := Style.LOOP
const POST_COLOR := Style.STRUCTURE
const EXIT_COLOR := Style.SUCCESS
const TEXT_COLOR := Style.INK
const TILE := 0.5    # 2×0.25（格距与砖尺寸全落 0.25 网格；T7 外延落格：5 列×0.5 砖
                     # → x 跨度 2.5、z 跨度 2.0+出口 1.5，都是 0.5 整数倍，六面才能全落世界格
                     # —— 0.75 砖时 x 跨度 3.75 非 0.5 整数倍，视图按可见包围盒居中后必离格）

var _rounds := 0
var _limit := 3
var _exit_open := false
var _counter_label: Label3D
var _limit_label: Label3D
var _exit_mat: StandardMaterial3D
var _exit_label: Label3D
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D


func _ready() -> void:
	_build()
	set_limit(3)
	set_rounds(0)
	set_exit_open(false)
	set_state_visual(STATE_IDLE)


# ---------- 对外 API ----------

## 循环上限参数（显式出口在第 limit 轮后打开）。
func set_limit(limit: int) -> void:
	_limit = maxi(1, limit)
	_limit_label.text = "循环上限 %d" % _limit
	_refresh_counter()


func get_limit() -> int:
	return _limit


## 步数计数器（纯显示；轮数逻辑在 l5_flow 的步记录里）。
func set_rounds(rounds: int) -> void:
	_rounds = rounds
	_refresh_counter()
	set_exit_open(_rounds >= _limit)


func get_rounds() -> int:
	return _rounds


## 显式出口：到上限时亮（绿色发光 + 出口文案）。
func set_exit_open(open: bool) -> void:
	_exit_open = open
	_exit_mat.emission_energy_multiplier = 1.275 if open else 0.0
	_exit_label.modulate = EXIT_COLOR if open else Color(0.67, 0.60, 0.55)
	_exit_label.text = ("出口（达上限 %d 轮）" % _limit) if open else "出口（未达上限）"


func is_exit_open() -> bool:
	return _exit_open


## 四态显示（灯色 + 灯字）。state 来自步记录派生，见类头注释。
func set_state_visual(state: String) -> void:
	var color: Color = STATE_COLORS.get(state, STATE_COLORS[STATE_IDLE])
	var caption: String = STATE_CAPTIONS.get(state, STATE_CAPTIONS[STATE_IDLE])
	_lamp_mat.albedo_color = color
	_lamp_mat.emission = color
	_state_label.text = caption


func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


# ---------- 状态派生（纯函数，输入步记录） ----------

## 全轨迹：traj[k] = 看完前 k+1 步后回廊应处的状态。
static func state_trajectory(steps: Array, gallery_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and str(args.get("entityId", "")) == gallery_eid:
				var key := str(args.get("key", ""))
				if key == "rounds" and step_ok:
					state = STATE_RUNNING
				elif key == "@done" and step_ok and bool(args.get("value", false)):
					state = STATE_DONE
				elif not step_ok:
					state = STATE_ERROR
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, gallery_eid: String) -> String:
	var traj := state_trajectory(steps, gallery_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _refresh_counter() -> void:
	_counter_label.text = "第 %d/%d 轮" % [_rounds, _limit]


func _build() -> void:
	# 环形地板：5×4 格网的周界（带环走廊的"环"），南侧中央留入口缺口
	var ring_positions: Array = []
	for col in 5:
		for row in 4:
			var on_edge := col == 0 or col == 4 or row == 0 or row == 3
			if not on_edge:
				continue
			var x := (col - 2) * TILE
			var z := (row - 1.5) * TILE
			if col == 2 and row == 3:
				continue   # 入口缺口
			ring_positions.append(Vector3(x, 0.125, z))
	for p in ring_positions:
		add_child(_tile(p, FLOOR_COLOR))

	# 出口引道：北侧中央向北延伸两格（绿色 = 显式出口方向）。
	# 2.5 起：与环北缘（-TILE）齐平对接、不再叠进环砖（原 2.0 起会与北行砖重叠 0.375）
	for k in 2:
		add_child(_tile(Vector3(0.0, 0.125, -TILE * (2.5 + k)), EXIT_COLOR))

	# 四角柱（走廊的"墙"意象）。柱落角砖外缘四分位（±2.25 / ±1.75 砖位 =
	# ±1.125 / ±0.875 m），六面落 0.25 世界格且整柱踩在角砖上（角砖跨 ±1.0±0.25 / ±0.75±0.25）
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = POST_COLOR
	post_mat.roughness = 0.6
	post_mat.metallic = 0.2
	for cx in [-2.25, 2.25]:
		for cz in [-1.75, 1.75]:
			var post := MeshInstance3D.new()
			post.name = "Post"
			var post_mesh := BoxMesh.new()
			post_mesh.size = Vector3(0.25, 0.75, 0.25)
			post.mesh = post_mesh
			post.position = Vector3(cx * TILE, 0.375, cz * TILE)
			post_mesh.material = post_mat
			add_child(post)

	# 出口牌（发光框 + 文案，set_exit_open 翻亮）。z 心 3.25 砖（半块奇位）→ 六面落格，
	# 悬在出口引道正上方（引道砖跨 z -1.0..-2.0）
	var sign := MeshInstance3D.new()
	sign.name = "ExitSign"
	var sign_mesh := BoxMesh.new()
	sign_mesh.size = Vector3(1.0, 0.5, 0.25)
	sign.mesh = sign_mesh
	sign.position = Vector3(0.0, 1.0, -TILE * 3.25)
	_exit_mat = StandardMaterial3D.new()
	_exit_mat.albedo_color = EXIT_COLOR
	_exit_mat.emission_enabled = true
	_exit_mat.emission = EXIT_COLOR
	_exit_mat.emission_energy_multiplier = 0.0
	sign_mesh.material = _exit_mat
	add_child(sign)

	_exit_label = Label3D.new()
	_exit_label.name = "ExitLabel"
	_exit_label.position = Vector3(0.0, 1.0, -TILE * 3.25 + 0.16)
	_exit_label.font_size = 30
	_exit_label.pixel_size = 0.003
	_exit_label.modulate = Color(0.67, 0.60, 0.55)
	_exit_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_exit_label.double_sided = false
	add_child(_exit_label)

	# 步数计数器（环中央上空）。杆心 (−0.125, −0.125)：0.25 方柱要六面落格必须
	# 心落半格奇位，环中央净空（±0.75/±0.5）内目测仍居中
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 1.25, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(-0.125, 0.625, -0.125)
	mast_mesh.material = post_mat
	add_child(mast)

	_counter_label = Label3D.new()
	_counter_label.name = "CounterLabel"
	_counter_label.position = Vector3(-0.125, 2.05, -0.125)
	_counter_label.font_size = 44
	_counter_label.pixel_size = 0.003
	_counter_label.modulate = TEXT_COLOR
	_counter_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_counter_label.double_sided = false
	add_child(_counter_label)

	_limit_label = Label3D.new()
	_limit_label.name = "LimitLabel"
	_limit_label.position = Vector3(-0.125, 1.7, -0.125)
	_limit_label.font_size = 28
	_limit_label.pixel_size = 0.003
	_limit_label.modulate = TEXT_COLOR
	_limit_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_limit_label.double_sided = false
	add_child(_limit_label)

	# 四态灯（环中央顶端，叠在灯杆顶上；R4 圆改方）
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(-0.125, 1.375, -0.125)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(-0.125, 2.4, -0.125)
	_state_label.font_size = 34
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)


func _tile(p: Vector3, color: Color) -> MeshInstance3D:
	var tile := MeshInstance3D.new()
	tile.name = "FloorTile"
	var tile_mesh := BoxMesh.new()
	tile_mesh.size = Vector3(TILE, 0.25, TILE)   # 满格砖：厚 0.25，心 y 0.125 落甲板上
	tile.mesh = tile_mesh
	tile.position = p
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.68
	mat.metallic = 0.28
	tile_mesh.material = mat
	return tile
