extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 旁路组件（docs/10-契约/mini-codex.md §一 #11；L5 四件之一）。
## 世界形态：岔路管道——校验门拒绝后货物走的弯管，绕回回廊入口；
## 管道旁挂重试计数器（Label3D，"重试 n/上限"）。
## 失败走它回到回廊（导出 Python 里对应 recover：except 分支里重试再 continue）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：由步记录派生，本节点只显示计数与灯色。
## 派生口径（L5）：
##   待命：还没有 set_param(retry_count)
##   正在：旁路记录过一次重试（retry_count >= 1）
##   完成：其后的世界写出结果步（跑完，旁路完成兜底使命）
##   出错：重试计数超过上限（retry_count > max_retries，上限被突破）

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

const PIPE_COLOR := Style.SIGNAL
const PIPE_DARK := Style.STRUCTURE
const TEXT_COLOR := Style.INK

var _retry_count := 0
var _max_retries := 3
var _retry_label: Label3D
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D


func _ready() -> void:
	_build()
	set_max_retries(3)
	set_retry_count(0)
	set_state_visual(STATE_IDLE)


# ---------- 对外 API ----------

## 重试计数器（纯显示；计数逻辑在 l5_flow 的 set_param 步记录里）。
func set_retry_count(count: int) -> void:
	_retry_count = count
	_refresh()


func get_retry_count() -> int:
	return _retry_count


## 重试上限（tune 阶段 3→2 改的就是它）。
func set_max_retries(max_retries: int) -> void:
	_max_retries = maxi(1, max_retries)
	_refresh()


func get_max_retries() -> int:
	return _max_retries


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

## 全轨迹：traj[k] = 看完前 k+1 步后旁路应处的状态。
## retry_count / max_retries 都来自针对本实体的 set_param 步。
static func state_trajectory(steps: Array, bypass_eid: String, files_eid := "") -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	var count := 0
	var limit := 1
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and step_ok and str(args.get("entityId", "")) == bypass_eid:
				var key := str(args.get("key", ""))
				if key == "retry_count":
					count = int(args.get("value", 0))
					state = STATE_RUNNING if count >= 1 else STATE_IDLE
				elif key == "max_retries":
					limit = int(args.get("value", 1))
				if count > limit:
					state = STATE_ERROR
			elif tool == "world.set_param" and step_ok and files_eid != "" \
					and str(args.get("entityId", "")) == files_eid \
					and str(args.get("key", "")) == "@result_out":
				state = STATE_DONE
		traj.append(state)
	return traj


static func derive_state_from_steps(steps: Array, bypass_eid: String, files_eid := "") -> String:
	var traj := state_trajectory(steps, bypass_eid, files_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _refresh() -> void:
	_retry_label.text = "重试 %d/%d" % [_retry_count, _max_retries]


func _build() -> void:
	# 岔路管道：三段弯管（拒绝货物绕回回廊入口；R4 圆管改方管，断面 0.25）
	var pipe_mat := StandardMaterial3D.new()
	pipe_mat.albedo_color = PIPE_COLOR
	pipe_mat.roughness = 0.4
	pipe_mat.metallic = 0.3

	# 段一：横管（从岔路来；心挪 (0.125, 0.375, 0.125) 使六面落 0.25 格，2026-09-17 外延落格口径）
	var seg1 := MeshInstance3D.new()
	seg1.name = "PipeSeg"
	var seg1_mesh := BoxMesh.new()
	seg1_mesh.size = Vector3(1.25, 0.25, 0.25)
	seg1.mesh = seg1_mesh
	seg1.position = Vector3(0.125, 0.375, 0.125)
	seg1_mesh.material = pipe_mat
	add_child(seg1)

	# 段二：立弯（抬头，压段一顶 0.5，隙 0）
	var seg2 := MeshInstance3D.new()
	seg2.name = "PipeSeg"
	var seg2_mesh := BoxMesh.new()
	seg2_mesh.size = Vector3(0.5, 0.25, 0.25)
	seg2.mesh = seg2_mesh
	seg2.position = Vector3(0.5, 0.625, 0.125)
	seg2_mesh.material = pipe_mat
	add_child(seg2)

	# 段三：回程横管（绕回回廊，压段二顶 0.75，隙 0）
	var seg3 := MeshInstance3D.new()
	seg3.name = "PipeSeg"
	var seg3_mesh := BoxMesh.new()
	seg3_mesh.size = Vector3(0.25, 0.25, 1.0)
	seg3.mesh = seg3_mesh
	seg3.position = Vector3(0.625, 0.875, 0.25)
	seg3_mesh.material = pipe_mat
	add_child(seg3)

	# 管道支架（顶 0.25 托段一管底 0.25，隙 0；心 x 挪到格点）
	var stand_mat := StandardMaterial3D.new()
	stand_mat.albedo_color = PIPE_DARK
	stand_mat.roughness = 0.6
	stand_mat.metallic = 0.2
	for sx in [-0.375, 0.375]:
		var stand := MeshInstance3D.new()
		stand.name = "PipeStand"
		var stand_mesh := BoxMesh.new()
		stand_mesh.size = Vector3(0.25, 0.25, 0.25)
		stand.mesh = stand_mesh
		stand.position = Vector3(sx, 0.125, 0.125)
		stand_mesh.material = stand_mat
		add_child(stand)

	# 重试计数器（Label3D）
	_retry_label = Label3D.new()
	_retry_label.name = "RetryLabel"
	_retry_label.position = Vector3(0.0, 1.1, 0.0)
	_retry_label.font_size = 42
	_retry_label.pixel_size = 0.003
	_retry_label.modulate = TEXT_COLOR
	_retry_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_retry_label.double_sided = false
	add_child(_retry_label)

	# 四态灯（管道上方小灯杆，栽地；灯落杆顶隙 0）
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 0.75, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(-0.625, 0.375, 0.125)
	mast_mesh.material = stand_mat
	add_child(mast)

	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(-0.625, 0.875, 0.125)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(-0.5, 1.25, 0.0)
	_state_label.font_size = 32
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)
