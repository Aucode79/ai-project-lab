extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 任务牌组件（docs/10-契约/mini-codex.md §一 #1；L1 两件之一）。
## 世界形态：插在工位的一块牌——柱、面板、任务文本（Label3D）、状态灯。
## 它是家族一代码结构方块的预设装配，不是新方块类型（mini-codex §一）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：待命/正在/完成/出错由步记录的 actor 与
## phase 派生，**不另做状态机**。本节点只负责把派生结果显示出来：
##   * set_state_visual() 只改灯色与灯字，不保存状态变量；
##   * derive_state_from_steps() / state_trajectory() 是纯函数，输入步记录数组——
##     状态永远是"从记录算出来"的，不是存出来的。
## 派生口径（L1）：
##   待命：还没有任何针对本实体的 set_param(task_text)
##   正在：学员下过任务（set_param task_text 成功），codex 尚未接下
##   完成：其后出现 actor=codex 的 world.run，且该步世界摘要里 task_in >= 1.0
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

# 粉彩玩具沙盘调色板里的相关色（docs/10-契约/美术方向.md，与 bench_world.gd 一致）
const PANEL_COLOR := Style.PAPER
const FRAME_COLOR := Style.SIGNAL
const POST_COLOR := Style.STRUCTURE
const TEXT_COLOR := Style.INK

const WRAP_COLS := 12

# ---------- 「我来」/「让它做」两键（docs/10-契约/交互方案.md §六） ----------
# 任务牌下沿的两块 3D 按钮块（世界里有东西，界面上不放东西；非 Control）。
# 本组件只广播选择，命中检测与后续流程（学员自己走 stage_run / 经桥代做）
# 由场景侧接线完成。

const MODE_ME := "me"
const MODE_AGENT := "agent"
const MODES := [MODE_ME, MODE_AGENT]
const MODE_CAPTIONS := {MODE_ME: "我来", MODE_AGENT: "让它做"}

## 按下模式键：mode 为 "me" | "agent"。
signal mode_selected(mode: String)

## 薄荷绿（树冠/点缀，docs/10-契约/美术方向.md 粉彩调色板 #7）
const BUTTON_AGENT_COLOR := Style.SIGNAL

var _task_text := ""
var _task_label: Label3D
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D


func _ready() -> void:
	_build()
	set_task_text("（等一条任务）")
	set_state_visual(STATE_IDLE)


# ---------- 对外 API ----------

func set_task_text(text: String) -> void:
	_task_text = text
	_task_label.text = _wrap_cjk(text, WRAP_COLS)


func get_task_text() -> String:
	return _task_text


## 只改显示（灯色 + 灯字）。state 来自步记录派生，见类头注释。
func set_state_visual(state: String) -> void:
	var color: Color = STATE_COLORS.get(state, STATE_COLORS[STATE_IDLE])
	var caption: String = STATE_CAPTIONS.get(state, STATE_CAPTIONS[STATE_IDLE])
	_lamp_mat.albedo_color = color
	_lamp_mat.emission = color
	_state_label.text = caption


func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


# ---------- 模式两键（§六：我来 / 让它做） ----------

## 按下一块模式键（输入命中检测由场景侧接线，本组件只验模式并广播）。
## 返回是否为合法模式。
func press_mode_button(mode: String) -> bool:
	if not MODES.has(mode):
		return false
	mode_selected.emit(mode)
	return true


## 取模式键节点（MeButton / AgentButton），供场景侧做射线命中；没有则 null。
func get_mode_button(mode: String) -> Node3D:
	if not MODES.has(mode):
		return null
	var found := get_node_or_null("MeButton" if mode == MODE_ME else "AgentButton")
	return found as Node3D


# ---------- 状态派生（纯函数，输入步记录） ----------

## 全轨迹：traj[k] = 看完前 k+1 步后任务牌应处的状态。
static func state_trajectory(steps: Array, board_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	var tasked := false
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var actor := str(s.get("actor", ""))
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and str(args.get("entityId", "")) == board_eid:
				if str(args.get("key", "")) == "task_text":
					if step_ok:
						tasked = true
						state = STATE_RUNNING
					else:
						state = STATE_ERROR
			elif tool == "world.run" and actor == "codex" and tasked:
				var world: Dictionary = s.get("world", {}) if s.get("world", {}) is Dictionary else {}
				var entities: Dictionary = world.get("entities", {}) if world.get("entities", {}) is Dictionary else {}
				if entities.has(board_eid):
					var entity: Dictionary = entities[board_eid]
					var ports: Dictionary = entity.get("ports", {}) if entity.get("ports", {}) is Dictionary else {}
					var port: Dictionary = ports.get("task_in", {}) if ports.get("task_in", {}) is Dictionary else {}
					if float(port.get("value", 0.0)) >= 1.0:
						state = STATE_DONE
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, board_eid: String) -> String:
	var traj := state_trajectory(steps, board_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 柱
	var post := MeshInstance3D.new()
	post.name = "Post"
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.25, 1.5, 0.25)   # 细杆→0.25 方柱（R1/R2）
	post.mesh = post_mesh
	post.position = Vector3(-0.125, 0.75, 0.125)   # 心挪半格：六面落 0.25 m 格（T7）
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = POST_COLOR
	post_mat.roughness = 0.6
	post_mat.metallic = 0.2
	post_mesh.material = post_mat
	add_child(post)

	# 面板
	var panel := MeshInstance3D.new()
	panel.name = "Panel"
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(2.5, 1.5, 0.25)
	panel.mesh = panel_mesh
	panel.position = Vector3(0.0, 1.75, 0.125)   # 完整落在 PickProxy 盒 (2.5,1.5,0.5)@y1.75 内（x/y 贴满、z 偏半格仍在盒内且六面落格，T7）
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = PANEL_COLOR
	panel_mat.roughness = 0.55
	panel_mesh.material = panel_mat
	add_child(panel)

	# 边框（暖色强调）
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(3.0, 2.0, 0.5)   # 放大/加深到 0.5 整倍是 T7 落格的最小改：
	# 生成台按可见包围盒中心对位，盒 x/z 尺寸是 0.25 奇数倍时六面全被判离格
	frame.mesh = frame_mesh
	frame.position = Vector3(0.0, 1.75, -0.25)   # 贴面板背面（z 面相接），四周露 0.25 边（对称）
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = FRAME_COLOR
	frame_mat.roughness = 0.5
	frame_mesh.material = frame_mat
	add_child(frame)

	# 任务文本
	_task_label = Label3D.new()
	_task_label.name = "TaskText"
	_task_label.position = Vector3(0.0, 1.75, 0.265)   # 悬在面板前面（前面 z=0.25，留 0.015 缝）
	_task_label.font_size = 44
	_task_label.pixel_size = 0.0028
	_task_label.modulate = TEXT_COLOR
	_task_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_task_label.double_sided = false
	add_child(_task_label)

	# 状态灯（顶在牌上方的小灯杆上）
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 0.5, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(-0.125, 2.75, 0.125)   # 坐面板顶 2.5 上，顶到 3.0；心挪半格落格（T7）
	mast_mesh.material = post_mat
	add_child(mast)

	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25   # R4 圆件方化：状态灯球 → 0.25³ 方灯
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(-0.125, 3.125, 0.125)   # 顶置灯杆顶（嵌 0.125 会把六面顶到半格，T7 判红）
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = STATE_COLORS[STATE_IDLE]
	_lamp_mat.emission_energy_multiplier = 1.4
	_lamp_mat.roughness = 0.3
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	# 状态灯字（待命/正在/完成/出错）
	_state_label = Label3D.new()
	_state_label.name = "StateCaption"
	_state_label.position = Vector3(0.0, 2.5, 0.265)   # 面板顶上方、灯杆前面（面板前面 z=0.25）
	_state_label.font_size = 40
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)

	# 模式两键（§六）：面板下沿左右各一块小按钮牌（心挪半格落格，T7；两牌间距 0.5 保持不相连）
	_build_mode_button("MeButton", MODE_ME, Vector3(-0.625, 1.375, 0.375), FRAME_COLOR)
	_build_mode_button("AgentButton", MODE_AGENT, Vector3(0.625, 1.375, 0.375), BUTTON_AGENT_COLOR)


func _build_mode_button(node_name: String, mode: String, at: Vector3, color: Color) -> void:
	var btn := Node3D.new()
	btn.name = node_name
	btn.position = at
	btn.set_meta("mode", mode)
	var plate := MeshInstance3D.new()
	plate.name = "Plate"
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.75, 0.25, 0.25)   # 全 0.25 格：贴面板前面（板前面 z=0.25）
	plate.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.5
	mesh.material = mat
	btn.add_child(plate)
	var cap := Label3D.new()
	cap.name = "Caption"
	cap.text = MODE_CAPTIONS[mode]
	cap.position = Vector3(0.0, 0.0, 0.135)   # 悬在按钮前面（前面 z=0.125）
	cap.font_size = 34
	cap.pixel_size = 0.003
	cap.modulate = TEXT_COLOR
	cap.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	cap.double_sided = false
	btn.add_child(cap)
	add_child(btn)


## CJK 按列数折行（Label3D 无自动换行，长任务文本手动折）。
func _wrap_cjk(text: String, cols: int) -> String:
	var lines: Array[String] = []
	var line := ""
	var count := 0
	for ch in text:
		line += ch
		count += 1
		if ch == "\n":
			lines.append(line.substr(0, line.length() - 1))
			line = ""
			count = 0
		elif count >= cols:
			lines.append(line)
			line = ""
			count = 0
	if line != "":
		lines.append(line)
	return "\n".join(lines)
