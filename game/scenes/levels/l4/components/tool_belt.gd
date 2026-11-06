extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 工具带组件（docs/10-契约/mini-codex.md §一 #7；L4 三件之一）。
## 世界形态：**墙上四把工具**——读 / 写 / 跑 / 搜 四个形状，**被选中那把发光**。
## 它是家族一代码结构方块的预设装配，不是新方块类型（mini-codex §一）。
##
## 工具 id 与 mini_brain.gd 的步骤 tool 值一一对应：read / write / run / search。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：由步记录派生，不另做状态机。派生口径（L4）：
##   待命：还没有针对本实体的 set_param(selected_tool)
##   正在：已选中过至少一把工具（set_param selected_tool 成功）
##   完成：最后一次选 tool 之后出现 actor=codex 的 world.run
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

const WALL_COLOR := Style.ACTION
const PANEL_COLOR := Style.PAPER
const STRUCT_COLOR := Style.STRUCTURE
const TEXT_COLOR := Style.INK
const LIT_COLOR := Style.SIGNAL
const DIM_COLOR := Style.MUTED

const TOOL_READ := "read"
const TOOL_WRITE := "write"
const TOOL_RUN := "run"
const TOOL_SEARCH := "search"

const TOOL_ORDER := [TOOL_READ, TOOL_WRITE, TOOL_RUN, TOOL_SEARCH]
const TOOL_CAPTIONS := {TOOL_READ: "读", TOOL_WRITE: "写", TOOL_RUN: "跑", TOOL_SEARCH: "搜"}

const SLOT_GAP := 0.75
const LIT_ENERGY := 1.36

var _selected := ""
var _tool_nodes: Dictionary = {}      # tool id -> Node3D（"ToolRead" 等）
var _tool_mats: Dictionary = {}       # tool id -> 材质（选中发光用）
var _lamp_mat: StandardMaterial3D
var _state_label: Label3D


func _ready() -> void:
	_build()
	select_tool("")
	set_state_visual(STATE_IDLE)


# ---------- 对外 API ----------

## 被选中那把发光：tool 取 read/write/run/search；"" = 全部熄灭。
func select_tool(tool: String) -> void:
	_selected = tool
	for tid in TOOL_ORDER:
		var lit: bool = str(tid) == tool
		var mat: StandardMaterial3D = _tool_mats[tid]
		mat.emission_enabled = lit
		mat.emission_energy_multiplier = LIT_ENERGY if lit else 0.0
		mat.albedo_color = LIT_COLOR if lit else DIM_COLOR


func get_selected_tool() -> String:
	return _selected


func is_tool_lit(tool: String) -> bool:
	if not _tool_mats.has(tool):
		return false
	var mat: StandardMaterial3D = _tool_mats[tool]
	return mat.emission_enabled and mat.emission_energy_multiplier > 0.0


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

## 选中轨迹：[{i, tool}]——哪一步选中了哪把工具（测试与回放的依据）。
static func selection_trajectory(steps: Array, belt_eid: String) -> Array:
	var picks: Array = []
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			if str(a.get("tool", "")) == "world.set_param":
				var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
				if str(args.get("entityId", "")) == belt_eid and str(args.get("key", "")) == "selected_tool":
					var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
					if bool(output.get("ok", true)):
						picks.append({"i": int(s.get("i", -1)), "tool": str(args.get("value", ""))})
	return picks


## 状态全轨迹：待命 → 正在（首次选中）→ 完成（其后有 codex 的 world.run）。
static func state_trajectory(steps: Array, belt_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	var picked := false
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and str(args.get("entityId", "")) == belt_eid:
				if str(args.get("key", "")) == "selected_tool":
					if step_ok:
						picked = true
						state = STATE_RUNNING
					else:
						state = STATE_ERROR
			elif tool == "world.run" and str(s.get("actor", "")) == "codex" and picked:
				state = STATE_DONE
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, belt_eid: String) -> String:
	var traj := state_trajectory(steps, belt_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 墙板（挂工具的那面墙；v2 (3.0,1.5,0.25) 心落半块格，底面坐在
	# l4_scene 工具墙基座 (3.5,0.5,0.5)@y0.25 的顶面 y=0.5 上，间隙 0）
	var wall := MeshInstance3D.new()
	wall.name = "WallPanel"
	var wall_mesh := BoxMesh.new()
	wall_mesh.size = Vector3(3.0, 1.5, 0.25)
	wall.mesh = wall_mesh
	wall.position = Vector3(0.0, 1.25, 0.25)
	wall_mesh.material = _mat(WALL_COLOR, 0.65, 0.15)
	add_child(wall)

	# 底板条（工具挂架；半嵌进墙板前脸，顶面 y=1.25 托住工具底 1.25。
	# 进深加深到 0.5：四把头前移后仍坐满挂架，外延全部落 0.25 m 格，T7）
	var rack := MeshInstance3D.new()
	rack.name = "Rack"
	var rack_mesh := BoxMesh.new()
	rack_mesh.size = Vector3(2.5, 0.25, 0.5)
	rack.mesh = rack_mesh
	rack.position = Vector3(0.0, 1.125, 0.625)
	rack_mesh.material = _mat(PANEL_COLOR, 0.5, 0.1)
	add_child(rack)

	# 四把工具：读=扫描板 / 写=楔形笔头 / 跑=滚筒 / 搜=圆环。
	# 形状类被 run_l4_tests 钉死（Box/Prism/Cylinder/Torus 各一），v2 只把
	# 外接尺寸收到 0.25（圆件外接 Ø0.25，方化豁免于类型断言）。
	# 四把头统一偏移 (0, +0.125, +0.25)：块数与排布不动，外延落 0.25 m 格（T7）。
	for idx in TOOL_ORDER.size():
		var tid: String = TOOL_ORDER[idx]
		var node := Node3D.new()
		node.name = "Tool" + tid.capitalize()
		node.position = Vector3((float(idx) - float(TOOL_ORDER.size() - 1) * 0.5) * SLOT_GAP, 1.375, 0.75)
		add_child(node)
		var head := Node3D.new()
		head.name = "Head"
		node.add_child(head)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = DIM_COLOR
		mat.emission_enabled = false
		mat.emission = LIT_COLOR
		mat.emission_energy_multiplier = 0.0
		mat.roughness = 0.4
		mat.metallic = 0.25
		# 一把工具 = 若干 0.25 方块，共用同一份材质（亮/暗切换只改材质，不动几何）
		for off in _tool_block_offsets(tid):
			var block := MeshInstance3D.new()
			var bm := BoxMesh.new()
			bm.size = Vector3.ONE * TOOL_BLOCK_SIZE
			bm.material = mat
			block.mesh = bm
			block.position = off
			head.add_child(block)
		var cap := Label3D.new()
		cap.name = "Caption"
		cap.text = str(TOOL_CAPTIONS[tid])
		cap.position = Vector3(0.0, -0.5, 0.02)
		cap.font_size = 40
		cap.pixel_size = 0.0028
		cap.modulate = TEXT_COLOR
		cap.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		cap.double_sided = false
		node.add_child(cap)
		_tool_nodes[tid] = node
		_tool_mats[tid] = mat

	# 状态灯（挂架右端上方的 0.25³ 方灯，贴墙板前脸；x/y 让半格的 1/4 落格外延格）
	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3(0.25, 0.25, 0.25)
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(1.375, 1.875, 0.5)
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
	_state_label.position = Vector3(-1.25, 1.75, 0.52)
	_state_label.font_size = 38
	_state_label.pixel_size = 0.0028
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)


## 四个工具头**全部由方块拼**（2026-09-16 口径：资产一律由方块组成，不再用
## Prism / Cylinder / Torus）。区分度改由**块数与排布**承担，一眼仍可辨：
##   读 = 1 块（板）/ 写 = 2 块竖叠（笔）/ 跑 = 3 块横排（滚筒）/ 搜 = 4 块 2×2（筛）
## 每块 0.25（半块格），外接尺寸与 v2 一致；偏移取 0.25 的整数倍。
## 这条同时替换了原来那三条"形状类被钉死"的断言（run_l4_tests）。
const TOOL_BLOCK_SIZE := 0.25

static func _tool_block_offsets(tid: String) -> Array:
	match tid:
		TOOL_WRITE:
			return [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.25, 0.0)]
		TOOL_RUN:
			return [Vector3(0.0, 0.0, 0.0), Vector3(0.0, 0.0, 0.25), Vector3(0.0, 0.0, -0.25)]
		TOOL_SEARCH:
			return [Vector3(0.0, 0.0, 0.0), Vector3(0.25, 0.0, 0.0),
				Vector3(0.0, 0.0, 0.25), Vector3(0.25, 0.0, 0.25)]
	return [Vector3.ZERO]      # 读 / 兜底：一块


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m
