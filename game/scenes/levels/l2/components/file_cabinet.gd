extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 文件柜组件（docs/10-契约/mini-codex.md §一 #8；L2 三件之一）。
## 世界形态：一排 6 格，每格一个文件（Label3D 文件名）+ 三态灯
## （绿=可读 / 绿且门开=可写 / 红锁=禁读，mini-codex §2.2）。
## 作用域（哪格可读、哪格可写、哪格上锁）来自世界初始化声明（l2_flow.setup_world），
## 本节点只把声明显示出来——setup_files() 是纯显示入口，不私设状态机。
##
## 痕迹规则（mini-codex §2.3：读不留物、写留物）：
##   * show_scan_mark(i, fade_seconds)：扫描器扫过柜格留下的**淡痕**——
##     半透明发光贴片，按参数化时长淡出后消失（读不留物）；
##   * show_write_mark(i, mode)：机械臂落点留下的**一格高度标记**——
##     常驻不消失；新增（空格放入）珊瑚橙、修改（先取旧再放新）薄荷绿，颜色区分。
##
## 四态硬规则（mini-codex §2.1）：柜顶状态灯（待命/正在/完成/出错）由步记录的
## actor/phase 派生，派生函数是纯函数（本文件底部），本节点不保存状态变量，
## set_state_visual() 只改灯色灯字。

# ---- 三态灯（作用域声明，§2.2）----
const PERM_READ := "read"     # 绿：可读
const PERM_WRITE := "write"   # 绿 + 门开：可读可写
const PERM_LOCK := "lock"     # 红锁：禁读（扫过去没有反应，机械臂被挡回）
const PERM_LAMP_COLORS := {
	PERM_READ: Color(0.373, 0.816, 0.451),
	PERM_WRITE: Color(0.373, 0.816, 0.451),
	PERM_LOCK: Color(0.914, 0.325, 0.325),
}

# ---- 四态（步记录派生，§2.1）----
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

# ---- 写痕颜色：新增=珊瑚橙，修改=薄荷绿 ----
const MARK_COLOR_ADD := Style.ACTION
const MARK_COLOR_MODIFY := Style.SIGNAL

# 粉彩玩具沙盘调色板里的相关色（docs/10-契约/美术方向.md）
const BODY_COLOR := Style.MEMORY
const PANEL_COLOR := Style.PAPER
const TEXT_COLOR := Style.INK
const SCAN_COLOR := Style.SIGNAL

const CELL_COUNT := 6
const CELL_WIDTH := 1.0   # 块状化 v2：格距落 0.25 格（1.02→1.0），格心 ±0.5k 全落格
const CELL_LABEL_FONT := 40

var _permissions: Array = []
var _file_names: Array[String] = []
var _cell_lamp_mats: Array = []
var _door_pivots: Array = []
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D

# 活动痕迹（纯显示）：scan 淡出后自毁；write 常驻。
var _scan_marks := {}   # cell -> {node, age, duration}
var _write_marks := {}  # cell -> {node, mode}


func _ready() -> void:
	_build()
	for i in CELL_COUNT:
		set_cell_visual(i, PERM_READ, "file%d.txt" % i)
	set_state_visual(STATE_IDLE)


func _process(delta: float) -> void:
	# 扫描淡痕：透明度随参数化时长衰减到 0 后自毁（读不留物）。
	for cell in _scan_marks.keys():
		var mark: Dictionary = _scan_marks[cell]
		mark["age"] = float(mark["age"]) + delta
		var k := float(mark["age"]) / maxf(0.0001, float(mark["duration"]))
		var node := mark["node"] as MeshInstance3D
		if node == null or not is_instance_valid(node):
			_scan_marks.erase(cell)
			continue
		if k >= 1.0:
			node.queue_free()
			_scan_marks.erase(cell)
		else:
			var mat := node.get_active_material(0) as StandardMaterial3D
			if mat != null:
				mat.albedo_color.a = 0.55 * (1.0 - k)
				mat.emission_energy_multiplier = 1.36 * (1.0 - k)


# ---------- 对外 API（作用域显示） ----------

## files 每项 {name, permission("read"|"write"|"lock"), content}，
## 来自 setup_world 的作用域声明；content 只在世界状态里，本节点不存。
func setup_files(files: Array) -> void:
	_permissions = []
	_file_names = []
	for i in CELL_COUNT:
		var entry: Dictionary = files[i] if i < files.size() and files[i] is Dictionary else {}
		var perm := str(entry.get("permission", PERM_READ))
		var fname := str(entry.get("name", ""))
		_permissions.append(perm)
		_file_names.append(fname)
		set_cell_visual(i, perm, fname)


func get_cell_permission(i: int) -> String:
	return str(_permissions[i]) if i >= 0 and i < _permissions.size() else PERM_READ


func get_cell_file_name(i: int) -> String:
	return _file_names[i] if i >= 0 and i < _file_names.size() else ""


## 可写格=门开（绿且门开），上锁格=门关且红锁灯。
func is_door_open(i: int) -> bool:
	return get_cell_permission(i) == PERM_WRITE


func is_locked(i: int) -> bool:
	return get_cell_permission(i) == PERM_LOCK


func get_cell_lamp_material(i: int) -> StandardMaterial3D:
	return _cell_lamp_mats[i] as StandardMaterial3D


# ---------- 对外 API（痕迹） ----------

## 扫描淡痕：半透明发光贴片贴在柜格正面，fade_seconds 后淡出消失（读不留物）。
func show_scan_mark(i: int, fade_seconds := 3.0) -> void:
	if i < 0 or i >= CELL_COUNT:
		return
	if _scan_marks.has(i):
		var old: Dictionary = _scan_marks[i]
		var old_node := old["node"] as Node3D
		if old_node != null and is_instance_valid(old_node):
			old_node.queue_free()
		_scan_marks.erase(i)
	var node := MeshInstance3D.new()
	node.name = "ScanMark%d" % i
	var quad := PlaneMesh.new()
	quad.size = Vector2(0.5, 1.0)   # 淡痕贴片 0.25 倍格（0.5×1.0）
	node.mesh = quad
	node.position = _cell_face_local(i)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(SCAN_COLOR, 0.55)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.emission_enabled = true
	mat.emission = SCAN_COLOR
	mat.emission_energy_multiplier = 1.36
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.no_depth_test = false
	quad.material = mat
	add_child(node)
	_scan_marks[i] = {"node": node, "age": 0.0, "duration": maxf(0.05, fade_seconds)}


func has_scan_mark(i: int) -> bool:
	return _scan_marks.has(i)


## 机械臂落点：一格高度标记，常驻（写留物）。mode："add"=新增（空格放入），
## "modify"=修改（先取旧再放新）——颜色区分（珊瑚橙 / 薄荷绿）。
func show_write_mark(i: int, mode := "add") -> void:
	if i < 0 or i >= CELL_COUNT:
		return
	if _write_marks.has(i):
		var old: Dictionary = _write_marks[i]
		var old_node := old["node"] as Node3D
		if old_node != null and is_instance_valid(old_node):
			old_node.queue_free()
		_write_marks.erase(i)
	var color := MARK_COLOR_ADD if mode == "add" else MARK_COLOR_MODIFY
	var holder := Node3D.new()
	holder.name = "WriteMark%d" % i
	holder.position = Vector3(_cell_x(i), _top_y() + 0.5, 0.0)
	var cube := MeshInstance3D.new()
	cube.name = "Block"
	var cube_mesh := BoxMesh.new()
	cube_mesh.size = Vector3(0.5, 1.0, 0.5)   # 一格高度（体素一格 = 1.0 世界单位）
	cube.mesh = cube_mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.emission_enabled = true
	mat.emission = color
	mat.emission_energy_multiplier = 0.9
	mat.roughness = 0.35
	cube_mesh.material = mat
	holder.add_child(cube)
	var tag := Label3D.new()
	tag.name = "Tag"
	tag.text = "新增" if mode == "add" else "改"
	tag.position = Vector3(0.0, 0.75, 0.0)
	tag.font_size = 34
	tag.pixel_size = 0.003
	tag.modulate = TEXT_COLOR
	tag.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	tag.double_sided = false
	holder.add_child(tag)
	add_child(holder)
	_write_marks[i] = {"node": holder, "mode": mode}


func has_write_mark(i: int) -> bool:
	return _write_marks.has(i)


func get_write_mark_mode(i: int) -> String:
	return str(_write_marks.get(i, {}).get("mode", ""))


# ---------- 对外 API（四态显示） ----------

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

## 四态轨迹（L2 口径，mini-codex §2.1）：
##   待命：还没有任何针对本柜格的 fs.read / fs.write
##   正在：扫描器经 fs.read 读到本柜的格子（内容进上下文）
##   完成：机械臂经 fs.write 把结果写进本柜的格子
##   出错：fs.write 失败（机械臂被挡回等）；被拒的上锁读取不算柜子出错
static func state_trajectory(steps: Array, cabinet_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a.get("args", {}) is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if (tool == "fs.read" or tool == "fs.write") and str(args.get("entityId", "")) == cabinet_eid:
				if tool == "fs.read" and step_ok:
					state = STATE_RUNNING
				elif tool == "fs.write":
					state = STATE_DONE if step_ok else STATE_ERROR
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, cabinet_eid: String) -> String:
	var traj := state_trajectory(steps, cabinet_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 柜体：一排 6 格的矮柜（块状化 v2：6.5×2.0×1.0 全落 0.25 格，高 2.0 合规保持）
	# 外延落格（2026-09-17）：前脸件（仓面板/门/灯）六面在半格相位上，柜体心 z=-0.125 同相位，
	# 整体 z 跨度 -0.625..0.875 是 0.5 的倍数 → 六面全落格。
	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(CELL_COUNT * CELL_WIDTH + 0.5, 2.0, 1.0)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 1.0, -0.125)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = BODY_COLOR
	body_mat.roughness = 0.6
	body_mat.metallic = 0.2
	body_mesh.material = body_mat
	add_child(body)

	# 每格：格仓面板 + 文件名 + 三态灯 + 门（可写格门开）
	for i in CELL_COUNT:
		var cell := Node3D.new()
		cell.name = "Cell%d" % i
		cell.position = Vector3(_cell_x(i), 1.0, 0.0)
		add_child(cell)

		var slot := MeshInstance3D.new()
		slot.name = "Slot"
		var slot_mesh := BoxMesh.new()
		slot_mesh.size = Vector3(CELL_WIDTH - 0.5, 1.5, 0.25)
		slot.mesh = slot_mesh
		# 贴前脸：心 z=0.5（面板 0.375..0.625，凸出柜面 0.25）；宽 0.5 → 格心 ±0.25
		# 六面落格、相邻仓面板缝隙均匀 0.5（缝隙均匀优先于保 0.75 旧宽，2026-09-17）
		slot.position = Vector3(0.0, 0.0, 0.5)
		var slot_mat := StandardMaterial3D.new()
		slot_mat.albedo_color = PANEL_COLOR
		slot_mat.roughness = 0.55
		slot_mesh.material = slot_mat
		cell.add_child(slot)

		var name_label := Label3D.new()
		name_label.name = "FileName"
		name_label.text = ""
		# 贴在门外面（z=0.89 在关闭的门面 0.875 之前，门开时门旋走、名字留在格上）
		name_label.position = Vector3(0.0, 0.1, 0.89)
		name_label.font_size = CELL_LABEL_FONT
		name_label.pixel_size = 0.0028
		name_label.modulate = TEXT_COLOR
		name_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		name_label.double_sided = false
		cell.add_child(name_label)

		# 三态灯（格顶小方灯；R4 球→0.25³，坐格仓顶线、顶与柜体顶平齐；x 偏 0.125 六面落格）
		var lamp := MeshInstance3D.new()
		lamp.name = "PermLamp"
		var lamp_mesh := BoxMesh.new()
		lamp_mesh.size = Vector3.ONE * 0.25
		lamp.mesh = lamp_mesh
		lamp.position = Vector3(0.125, 0.875, 0.5)
		var lamp_mat := StandardMaterial3D.new()
		lamp_mat.albedo_color = PERM_LAMP_COLORS[PERM_READ]
		lamp_mat.emission_enabled = true
		lamp_mat.emission = PERM_LAMP_COLORS[PERM_READ]
		lamp_mat.emission_energy_multiplier = 1.2
		lamp_mat.roughness = 0.3
		lamp_mesh.material = lamp_mat
		cell.add_child(lamp)
		_cell_lamp_mats.append(lamp_mat)

		# 门：铰链在格左缘，可写格=门开（旋开），其余关（门 0.25 厚贴面板前脸；宽随仓面板 0.5）
		var pivot := Node3D.new()
		pivot.name = "DoorPivot"
		pivot.position = Vector3(-(CELL_WIDTH - 0.5) * 0.5, 0.0, 0.75)
		cell.add_child(pivot)
		var door := MeshInstance3D.new()
		door.name = "Door"
		var door_mesh := BoxMesh.new()
		door_mesh.size = Vector3(CELL_WIDTH - 0.5, 1.5, 0.25)
		door.mesh = door_mesh
		door.position = Vector3((CELL_WIDTH - 0.5) * 0.5, 0.0, 0.0)
		var door_mat := StandardMaterial3D.new()
		door_mat.albedo_color = Color(0.851, 0.780, 0.655)
		door_mat.roughness = 0.5
		door_mat.metallic = 0.1
		door_mesh.material = door_mat
		pivot.add_child(door)
		_door_pivots.append(pivot)

	# 柜顶四态灯（与任务牌同款：柱 + 灯 + 灯字；R4 球→0.25³，坐顶/相贴全落格）
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3.ONE * 0.25
	mast.mesh = mast_mesh
	# 坐于柜顶：底面 _top_y() 落顶面线（柱 y 2.0..2.25）；x 偏 0.125 六面落格
	mast.position = Vector3(0.125, _top_y() + 0.125, -0.25)
	mast_mesh.material = body_mat
	add_child(mast)

	var lamp4 := MeshInstance3D.new()
	lamp4.name = "Lamp"
	var lamp4_mesh := BoxMesh.new()
	lamp4_mesh.size = Vector3.ONE * 0.25
	lamp4.mesh = lamp4_mesh
	# 相贴柱顶：柱顶 _top_y()+0.25，灯底贴上（心 _top_y()+0.375）
	lamp4.position = Vector3(0.125, _top_y() + 0.375, -0.25)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	_lamp_mat.roughness = 0.3
	lamp4_mesh.material = _lamp_mat
	add_child(lamp4)

	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(0.0, _top_y() + 0.75, -0.25)
	_state_label.font_size = 40
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)

	var title := Label3D.new()
	title.name = "CabinetTitle"
	title.text = "文件柜 · 一格一文件"
	# 柜体前脸在 z=0.375，标题在脸外 0.51
	title.position = Vector3(0.0, 0.25, 0.51)
	title.font_size = 34
	title.pixel_size = 0.0028
	title.modulate = TEXT_COLOR
	title.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	title.double_sided = false
	add_child(title)


## 单格显示：三态灯颜色 + 门开合 + 文件名。
func set_cell_visual(i: int, perm: String, file_name: String) -> void:
	if i < 0 or i >= CELL_COUNT:
		return
	var color: Color = PERM_LAMP_COLORS.get(perm, PERM_LAMP_COLORS[PERM_READ])
	if i < _cell_lamp_mats.size():
		var mat := _cell_lamp_mats[i] as StandardMaterial3D
		mat.albedo_color = color
		mat.emission = color
	if i < _door_pivots.size():
		var pivot := _door_pivots[i] as Node3D
		pivot.rotation.y = -1.9 if perm == PERM_WRITE else 0.0
	var cell := get_node_or_null("Cell%d" % i)
	if cell != null:
		var label := cell.get_node_or_null("FileName") as Label3D
		if label != null:
			label.text = file_name
			# 上锁格文件名偏红，与红锁灯呼应（mini-codex §2.2"上锁=禁读"）
			label.modulate = Color(0.55, 0.30, 0.30) if perm == PERM_LOCK else TEXT_COLOR


func _cell_x(i: int) -> float:
	return (float(i) - float(CELL_COUNT - 1) * 0.5) * CELL_WIDTH


func _top_y() -> float:
	return 2.0   # 柜体顶面（body 高 2.0，中心 1.0）


func _cell_face_local(i: int) -> Vector3:
	return Vector3(_cell_x(i), 1.0, 1.0)   # 关闭门面 0.875 之前 0.125
