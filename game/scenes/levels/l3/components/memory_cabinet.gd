extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 记忆柜组件（docs/10-契约/mini-codex.md §一 #6；L3 两件之一）。
## 世界形态：三屉抽屉柜——读写时抽屉沿正面滑出/滑回（开合动画，
## 时长参数化：open_drawer(i, seconds)，seconds<0 用默认 anim_seconds）。
## 跨轮笔记（key-value，如 last_result）存在抽屉里，抽屉面上贴便签（Label3D）。
## 裁决（mini-codex §七-3）：codex 的记忆柜与学员的记忆柜是
## **两个柜子**，本组件是 codex 那只。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：待命/正在/完成/出错由步记录派生，
## **不另做状态机**。本节点只负责把派生结果显示出来。
## 派生口径（L3）：
##   待命：还没有任何针对本实体的抽屉写（set_param drawer1/2/3）
##   正在：抽屉里写过笔记（写成功），其后还没有 codex 的 world.read 读本柜
##   完成：写过之后出现 actor=codex 的 world.read（ref 指向本柜）——
##         "记得住"被证实：写下的东西被取回过
##   出错：针对本实体的操作返回失败
##
## 抽屉开合是纯显示动作，不参与判定（判定只看步记录里的 memory.read /
## memory.write 步，它们带 motion 字段——"开合动作进步记录"）。

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

# 粉彩玩具沙盘调色板里的相关色（docs/10-契约/美术方向.md，与 l1_scene.gd 一致）
const BODY_COLOR := Style.MEMORY
const DRAWER_COLOR := Style.MEMORY
const TRAY_COLOR := Style.SHELL
const HANDLE_COLOR := Style.INK
const NOTE_COLOR := Style.PAPER
const TEXT_COLOR := Style.INK

const DRAWER_COUNT := 3
const DRAWER_OPEN_OFFSET := 0.52      # 抽屉滑出行程（动画量，不参与占格审计）
const DEFAULT_ANIM_SECONDS := 0.5     # 开/合默认时长
const DRAWER_Y := [0.25, 0.75, 1.25]  # 三屉高度（1 基最下；v2 半块格：0.5 高屉带恰好叠放进 2.0 高柜身）

## 开合时长参数（读写时开合可见；可被 open/close_drawer 的 seconds 参数覆盖）。
var anim_seconds := DEFAULT_ANIM_SECONDS

var _drawer_nodes: Array[Node3D] = []
var _note_labels: Array[Label3D] = []
var _drawer_offset: Array[float] = []
var _drawer_target: Array[float] = []
var _drawer_dur: Array[float] = []
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D


func _ready() -> void:
	_build()
	set_state_visual(STATE_IDLE)


func _process(delta: float) -> void:
	for i in DRAWER_COUNT:
		var target := _drawer_target[i]
		var cur := _drawer_offset[i]
		if is_equal_approx(cur, target):
			continue
		var dur := maxf(0.016, _drawer_dur[i])
		# 速度 = 行程 / 时长，匀速滑动（慢速可视，不追求动画表现力）
		cur = move_toward(cur, target, delta * DRAWER_OPEN_OFFSET / dur)
		_drawer_offset[i] = cur
		_drawer_nodes[i].position.z = cur


# ---------- 对外 API ----------

## 开抽屉（1 基索引）。seconds < 0 用默认 anim_seconds；await 到完全打开。
func open_drawer(index: int, seconds := -1.0) -> void:
	_set_drawer_target(index, DRAWER_OPEN_OFFSET, seconds)
	await _await_drawer(index)


## 合抽屉。参数同 open_drawer。
func close_drawer(index: int, seconds := -1.0) -> void:
	_set_drawer_target(index, 0.0, seconds)
	await _await_drawer(index)


func is_drawer_open(index: int) -> bool:
	if index < 1 or index > DRAWER_COUNT:
		return false
	return _drawer_offset[index - 1] >= DRAWER_OPEN_OFFSET * 0.99


## 当前滑出行程（0 = 合上）。测试与回放核对用。
func get_drawer_offset(index: int) -> float:
	if index < 1 or index > DRAWER_COUNT:
		return -1.0
	return _drawer_offset[index - 1]


## 抽屉面上的便签文本（key=value 之类的跨轮笔记）。
func set_drawer_note(index: int, text: String) -> void:
	if index >= 1 and index <= DRAWER_COUNT:
		_note_labels[index - 1].text = text


func get_drawer_note(index: int) -> String:
	if index < 1 or index > DRAWER_COUNT:
		return ""
	return _note_labels[index - 1].text


## 只改显示（灯色 + 灯字）。state 来自步记录派生，见类头注释。
func set_state_visual(state: String) -> void:
	var color: Color = STATE_COLORS.get(state, STATE_COLORS[STATE_IDLE])
	var caption: String = STATE_CAPTIONS.get(state, STATE_CAPTIONS[STATE_IDLE])
	_lamp_mat.albedo_color = color
	_lamp_mat.emission = color
	_state_label.text = caption


func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


# ---------- 状态派生（纯函数，输入步记录） ----------

## 全轨迹：traj[k] = 看完前 k+1 步后记忆柜应处的状态。
static func state_trajectory(steps: Array, cabinet_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	var written := false
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var actor := str(s.get("actor", ""))
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and str(args.get("entityId", "")) == cabinet_eid:
				var key := str(args.get("key", ""))
				if key.begins_with("drawer"):
					if step_ok:
						written = true
						state = STATE_RUNNING
					else:
						state = STATE_ERROR
				elif not step_ok:
					state = STATE_ERROR
			elif tool == "world.read" and actor == "codex" and written:
				var ref := str(args.get("ref", ""))
				if ref == cabinet_eid or ref.begins_with(cabinet_eid + ":"):
					state = STATE_DONE if step_ok else STATE_ERROR
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, cabinet_eid: String) -> String:
	var traj := state_trajectory(steps, cabinet_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部 ----------

func _set_drawer_target(index: int, target: float, seconds: float) -> void:
	if index < 1 or index > DRAWER_COUNT:
		return
	var i := index - 1
	_drawer_target[i] = target
	_drawer_dur[i] = anim_seconds if seconds < 0.0 else seconds


## 等抽屉滑到位（树在跑就逐帧等；树停了（headless 一次性脚本）直接返回）。
func _await_drawer(index: int) -> void:
	var i := index - 1
	for guard in 2400:   # 上限防挂死（约 40 秒 @60fps）
		if is_equal_approx(_drawer_offset[i], _drawer_target[i]):
			return
		await get_tree().process_frame


func _build() -> void:
	# 柜体。v2 主轮廓 3U×4U×2U（0.5 m 整格）：0.5 高屉带 ×3 叠放进下部，上部留 0.5 檐带
	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(1.5, 2.0, 1.0)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 1.0, 0.0)   # 高度链：底 0.0 + 半高 1.0，顶到 2.0
	body_mesh.material = _mat(BODY_COLOR, 0.55, 0.2)
	add_child(body)

	# 顶檐（比柜体大一圈的整块厚檐，左右挑出 0.25、前后挑出 0.5）。
	# 进深 2.0 是 T7 外延落格的跨度约束：前脸抽屉全凸出后最远到 z 1.0（把手前缘），
	# 檐只有出到 -1.0 整格，z 跨度才是 0.5 的整数倍（视图按包围盒居中后六面才落世界格）
	var top := MeshInstance3D.new()
	top.name = "Top"
	var top_mesh := BoxMesh.new()
	top_mesh.size = Vector3(2.0, 0.5, 2.0)
	top.mesh = top_mesh
	top.position = Vector3(0.0, 2.25, 0.0)   # 柜顶 2.0 + 半高 0.25，顶到 2.5
	top_mesh.material = _mat(BODY_COLOR * 0.85, 0.5, 0.25)
	add_child(top)

	# 三只抽屉（沿 +Z 滑出）
	for i in DRAWER_COUNT:
		var drawer := Node3D.new()
		drawer.name = "Drawer%d" % (i + 1)
		drawer.position = Vector3(0.0, DRAWER_Y[i], 0.0)
		add_child(drawer)

		# 抽屉面板（0.5 高屉带；整面凸出前脸 0.25 —— 半嵌（凸 0.125）会把面推到
		# 1/16 格位上，六面无法全落 0.25 世界格（T7），故贴前脸外侧整格凸出）
		var face := MeshInstance3D.new()
		face.name = "Face"
		var face_mesh := BoxMesh.new()
		face_mesh.size = Vector3(1.0, 0.5, 0.25)
		face.mesh = face_mesh
		face.position = Vector3(0.0, 0.0, 0.625)   # 面跨 z 0.5..0.75（前脸 0.5 外侧贴齐）
		face_mesh.material = _mat(DRAWER_COLOR, 0.5, 0.15)
		drawer.add_child(face)

		# 抽屉内盘（拉开才看得见，上面搁便签）。y 落屉带下半（d−0.25..d）：
		# 0.25 厚盘的心必须落半格奇位才落格
		var tray := MeshInstance3D.new()
		tray.name = "Tray"
		var tray_mesh := BoxMesh.new()
		tray_mesh.size = Vector3(1.0, 0.25, 0.5)
		tray.mesh = tray_mesh
		tray.position = Vector3(0.0, -0.125, 0.0)   # 合上时全藏进柜身（z -0.25..0.25）
		tray_mesh.material = _mat(TRAY_COLOR, 0.7, 0.1)
		drawer.add_child(tray)

		# 把手（半块横条，贴面板前面，间隙 0）。y 落屉带上半（d..d+0.25）
		var handle := MeshInstance3D.new()
		handle.name = "Handle"
		var handle_mesh := BoxMesh.new()
		handle_mesh.size = Vector3(0.5, 0.25, 0.25)
		handle.mesh = handle_mesh
		handle.position = Vector3(0.0, 0.125, 0.875)   # 贴面板前面 0.75，跨 z 0.75..1.0
		handle_mesh.material = _mat(HANDLE_COLOR, 0.4, 0.5)
		drawer.add_child(handle)

		# 便签（贴在抽屉面上，写 key=value）
		var note := Label3D.new()
		note.name = "Note"
		note.position = Vector3(0.0, 0.02, 0.765)   # Label3D 豁免；面板前面 0.75 + 0.015 防 z-fight
		note.font_size = 34
		note.pixel_size = 0.0026
		note.modulate = TEXT_COLOR
		note.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		note.double_sided = false
		note.text = "（空）"
		drawer.add_child(note)
		_note_labels.append(note)

		_drawer_nodes.append(drawer)
		_drawer_offset.append(0.0)
		_drawer_target.append(0.0)
		_drawer_dur.append(DEFAULT_ANIM_SECONDS)

	# 状态灯（柜顶小灯杆）。v2 半块柱立于檐上，灯叠在杆顶。
	# 心 (0.125, -0.625)：0.25 方柱/灯六面落格必须心落半格奇位；杆后缘与檐后缘（-1.0
	# 内的 -0.75）齐平
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 0.5, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(0.125, 2.75, -0.625)   # 檐顶 2.5 + 半高 0.25，杆跨 2.5..3.0
	mast_mesh.material = _mat(BODY_COLOR, 0.6, 0.25)
	add_child(mast)

	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.125, 3.125, -0.625)   # 杆顶 3.0 上叠灯：灯跨 3.0..3.25
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	_lamp_mat.roughness = 0.3
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(0.0, 2.1, 1.015)   # Label3D 豁免；贴顶檐前面 1.0 + 0.015 防 z-fight
	_state_label.font_size = 38
	_state_label.pixel_size = 0.0028
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m
