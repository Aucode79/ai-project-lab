extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 思考机组件（docs/10-契约/mini-codex.md §一 #5；L4 三件之一）。
## 世界形态：一台机器——**一侧进纸条**（提示词方块，Label3D 显示摘要），
## **一侧吐 token 方块**（小方块按生成次序排成串，数量 = 模拟 token 数）。
## 它是家族一代码结构方块的预设装配，不是新方块类型（mini-codex §一）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：待命/正在/完成/出错由步记录派生，
## **不另做状态机**。本节点只做显示；派生口径（L4）：
##   待命：还没有针对本实体的 set_param(prompt)
##   正在：提示词已喂入（set_param prompt 成功）
##   完成：其后出现 actor=codex 的 model.think 步且 tokens > 0
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

# 粉彩玩具沙盘调色板里的相关色（docs/10-契约/美术方向.md）
const BODY_COLOR := Style.CORE
const ACCENT_COLOR := Style.ACTION
const STRUCT_COLOR := Style.STRUCTURE
const TEXT_COLOR := Style.INK
const TOKEN_COLOR := Style.SIGNAL

## token 方块在出料托盘上按行排布：每行 TOKENS_PER_ROW 个，行序即生成次序。
## 块状化 v2：token 是可见小件，一律 0.25³（R1），行内步距 0.25（R2 半块格）。
const TOKENS_PER_ROW := 9
const TOKEN_SIZE := 0.25
const TOKEN_GAP := 0.25

const PROMPT_SUMMARY_LEN := 26

var _prompt := ""
var _tokens := 0
var _prompt_label: Label3D
var _token_tray: Node3D
var _token_proto_mat: StandardMaterial3D
var _lamp_mat: StandardMaterial3D
var _state_label: Label3D


func _ready() -> void:
	_build()
	set_prompt("")
	set_state_visual(STATE_IDLE)


# ---------- 对外 API ----------

## 喂纸条：左侧提示词方块换内容，Label3D 显示摘要（长提示词截断折行）。
func set_prompt(text: String) -> void:
	_prompt = text
	_prompt_label.text = _summary(text)


func get_prompt() -> String:
	return _prompt


## 吐 token：先清空托盘，再按生成次序铺 n 个小方块（数量 = 模拟 token 数）。
func emit_tokens(count: int) -> void:
	clear_tokens()
	_tokens = maxi(0, count)
	for i in _tokens:
		_token_tray.add_child(_make_token_cube(i))


func clear_tokens() -> void:
	# 立即 free 而非 queue_free：托盘计数要同步精确（headless 测试当帧就读
	# get_child_count()），且 token 方块是纯展示 mesh、无信号回调，立即删安全。
	for c in _token_tray.get_children():
		c.free()
	_tokens = 0


func get_token_count() -> int:
	return _tokens


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

## 全轨迹：traj[k] = 看完前 k+1 步后思考机应处的状态。
static func state_trajectory(steps: Array, thinker_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	var prompted := false
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and str(args.get("entityId", "")) == thinker_eid:
				if str(args.get("key", "")) == "prompt":
					if step_ok:
						prompted = true
						state = STATE_RUNNING
					else:
						state = STATE_ERROR
			elif tool == "model.think" and prompted and int(s.get("tokens", 0)) > 0:
				state = STATE_DONE
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, thinker_eid: String) -> String:
	var traj := state_trajectory(steps, thinker_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 机身（卧式主机箱；块状化 v2：主载体 0.5 量级，心落半块格）。
	# 心 (-0.125, 1.0, 0.125)：生成台按实测 AABB 重新居中后，六面外延须落 0.25 m
	# 世界格（run_ground_tests T7），故 x/z 各让半格的 1/4。
	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(2.0, 1.0, 1.0)
	body.mesh = body_mesh
	body.position = Vector3(-0.125, 1.0, 0.125)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = BODY_COLOR
	body_mat.roughness = 0.55
	body_mat.metallic = 0.15
	body_mesh.material = body_mat
	add_child(body)

	# 顶部装饰条（暖色强调，与任务牌同款语言；落格口径下整条坐在机身顶面）
	var trim := MeshInstance3D.new()
	trim.name = "Trim"
	var trim_mesh := BoxMesh.new()
	trim_mesh.size = Vector3(2.0, 0.25, 1.0)
	trim.mesh = trim_mesh
	trim.position = Vector3(-0.125, 1.625, 0.125)
	trim_mesh.material = _mat(ACCENT_COLOR, 0.5, 0.1)
	add_child(trim)

	# 四条短腿（0.25²×0.5，顶面托住机身底，间隙 0）
	for lx in [-0.75, 0.75]:
		for lz in [-0.25, 0.25]:
			var leg := MeshInstance3D.new()
			leg.name = "Leg"
			var leg_mesh := BoxMesh.new()
			leg_mesh.size = Vector3(0.25, 0.5, 0.25)
			leg.mesh = leg_mesh
			leg.position = Vector3(lx, 0.25, lz)
			leg_mesh.material = _mat(STRUCT_COLOR, 0.6, 0.2)
			add_child(leg)

	# ---- 左侧：进纸条 ----
	# 进纸口（深色缝，0.25 厚半嵌进机身左面）
	var slot := MeshInstance3D.new()
	slot.name = "SlipSlot"
	var slot_mesh := BoxMesh.new()
	slot_mesh.size = Vector3(0.25, 0.5, 0.75)
	slot.mesh = slot_mesh
	slot.position = Vector3(-1.0, 1.0, 0.0)
	slot_mesh.material = _mat(Color(0.30, 0.26, 0.22), 0.8, 0.0)
	add_child(slot)

	# 纸条本体（竖直的 0.25 厚小板 + 摘要文字，右缘贴进纸口外脸；y 与进纸口底对齐）
	# 原为 −12° 斜插；轴向对齐口径下不留任意角（2026-09-16）
	var slip := Node3D.new()
	slip.name = "PromptSlip"
	slip.position = Vector3(-1.5, 1.125, 0.0)
	add_child(slip)

	var plate := MeshInstance3D.new()
	plate.name = "SlipPlate"
	var plate_mesh := BoxMesh.new()
	plate_mesh.size = Vector3(0.75, 0.75, 0.25)
	plate.mesh = plate_mesh
	var plate_mat := StandardMaterial3D.new()
	plate_mat.albedo_color = Color(0.96, 0.97, 0.98)
	plate_mat.roughness = 0.7
	plate_mesh.material = plate_mat
	slip.add_child(plate)

	_prompt_label = Label3D.new()
	_prompt_label.name = "PromptSummary"
	_prompt_label.position = Vector3(0.0, 0.0, 0.13)
	_prompt_label.font_size = 30
	_prompt_label.pixel_size = 0.0028
	_prompt_label.modulate = TEXT_COLOR
	_prompt_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_prompt_label.double_sided = false
	slip.add_child(_prompt_label)

	# ---- 右侧：吐 token 方块的托盘（0.5 高落地台，与机身前面齐平贴） ----
	var tray := MeshInstance3D.new()
	tray.name = "TrayBase"
	var tray_mesh := BoxMesh.new()
	tray_mesh.size = Vector3(2.5, 0.5, 0.5)
	tray.mesh = tray_mesh
	tray.position = Vector3(-0.125, 0.25, 0.875)
	tray_mesh.material = _mat(STRUCT_COLOR, 0.6, 0.15)
	add_child(tray)

	_token_tray = Node3D.new()
	_token_tray.name = "TokenTray"
	_token_tray.position = Vector3(-(TOKENS_PER_ROW - 1) * TOKEN_GAP * 0.5, 0.5, 0.75)
	add_child(_token_tray)

	# token 原型材质（每个方块独立实例，颜色随次序微调出"流"的感觉）
	_token_proto_mat = StandardMaterial3D.new()
	_token_proto_mat.albedo_color = TOKEN_COLOR
	_token_proto_mat.emission_enabled = true
	_token_proto_mat.emission = TOKEN_COLOR
	_token_proto_mat.emission_energy_multiplier = 1.2
	_token_proto_mat.roughness = 0.35

	# 出料口标牌
	var out_label := Label3D.new()
	out_label.name = "TokenCaption"
	out_label.text = "token"
	out_label.position = Vector3(0.0, 0.75, 1.05)
	out_label.font_size = 28
	out_label.pixel_size = 0.003
	out_label.modulate = TEXT_COLOR
	out_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	out_label.double_sided = false
	add_child(out_label)

	# ---- 状态灯（0.25² 方灯杆顶在机身上方，0.25³ 方灯坐在杆顶，同任务牌模式） ----
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 0.5, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(0.0, 1.75, 0.0)
	mast_mesh.material = _mat(STRUCT_COLOR, 0.6, 0.2)
	add_child(mast)

	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.0, 2.125, 0.0)
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
	_state_label.position = Vector3(0.0, 1.25, 0.51)
	_state_label.font_size = 38
	_state_label.pixel_size = 0.003
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)


## 第 i 个 token 方块：行内左→右 为生成次序，行间前→后 续排。
func _make_token_cube(i: int) -> MeshInstance3D:
	var cube := MeshInstance3D.new()
	cube.name = "Token%d" % i
	var mesh := BoxMesh.new()
	mesh.size = Vector3(TOKEN_SIZE, TOKEN_SIZE, TOKEN_SIZE)
	cube.mesh = mesh
	var mat := _token_proto_mat.duplicate() as StandardMaterial3D
	var k := 1.2 + 0.5 * float(i % TOKENS_PER_ROW) / float(TOKENS_PER_ROW)
	mat.emission_energy_multiplier = k
	mesh.material = mat
	var row := i / TOKENS_PER_ROW
	var col := i % TOKENS_PER_ROW
	cube.position = Vector3(col * TOKEN_GAP, 0.0, -row * TOKEN_GAP)
	return cube


## 提示词摘要：截断 + CJK 折行（Label3D 无自动换行）。
func _summary(text: String) -> String:
	if text == "":
		return "（等一张纸条）"
	var shown := text.substr(0, PROMPT_SUMMARY_LEN)
	if text.length() > PROMPT_SUMMARY_LEN:
		shown += "…"
	var lines: Array[String] = []
	var line := ""
	var count := 0
	for ch in shown:
		line += ch
		count += 1
		if count >= 8:
			lines.append(line)
			line = ""
			count = 0
	if line != "":
		lines.append(line)
	return "\n".join(lines)


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m
