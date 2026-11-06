extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 上下文容器组件（docs/10-契约/mini-codex.md §一 #4；L3 两件之一）。
## 世界形态：带容量刻度的容器——正面下缘一排"刻度段"（Mesh3D 分段，
## 段数 = 容量上限），亮起的段数 = 当前占用；装入的文件码成一摞小方块。
## 超出容量上限时最旧的被裁掉，且**裁掉的动作可见**：被裁方块淡出下沉
## （play_trim 生成的 TrimGhost 方块，在 _process 里下坠并透明消失）。
## 它是家族一代码结构方块的预设装配，不是新方块类型（mini-codex §一）。
##
## 四态硬规则（docs/10-契约/mini-codex.md §2.1）：待命/正在/完成/出错由步记录的
## actor 与 phase 派生，**不另做状态机**。本节点只负责把派生结果显示出来：
##   * set_state_visual() 只改灯色与灯字，不保存状态变量；
##   * derive_state_from_steps() / state_trajectory() 是纯函数，输入步记录数组。
## 派生口径（L3）：
##   待命：还没有任何针对本实体的 set_param(files) 装入
##   正在：装入过文件（set_param files 成功且非空），其后还没有 codex 的 world.run
##   完成：装入之后出现 actor=codex 的 world.run，且该步世界摘要里本实体
##         的 files 非空（上下文已随演算被消费）
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

# 粉彩玩具沙盘调色板里的相关色（docs/10-契约/美术方向.md，与 l1_scene.gd 一致）
const BODY_COLOR := Style.MEMORY
const PAPER_COLOR := Style.PAPER
const SEG_FILLED_COLOR := Style.SIGNAL
const SEG_EMPTY_COLOR := Style.SHELL
const TRIM_COLOR := Style.SIGNAL
const TEXT_COLOR := Style.INK

const DEFAULT_CAPACITY := 8
const SEG_WIDTH := 0.25              # v2：刻度段 = 0.25³ 半块方块
const SEG_GAP := 0.0                 # v2：段间无缝，capacity 段正好铺满 2.0 宽身（8 段 = 4 块）
const FILE_SIZE := 0.25              # v2：文件小方块 = 0.25³ 半块
const FILE_LIFT := 0.25              # v2：层距 = 半块，摞内块块相贴
const GHOST_SECONDS := 0.9           # 被裁方块淡出下沉的可见时长
const GHOST_SINK_PER_SEC := 0.85     # 下沉速度（体素单位/秒）

var _capacity := DEFAULT_CAPACITY
var _stack_count := 0
var _segs: Array[MeshInstance3D] = []
var _scale_root: Node3D
var _stack_root: Node3D
var _ghost_root: Node3D
var _occ_label: Label3D
var _state_label: Label3D
var _lamp_mat: StandardMaterial3D
var _seg_mat_filled: StandardMaterial3D
var _seg_mat_empty: StandardMaterial3D
var _ghosts: Array[Dictionary] = []   # {node: MeshInstance3D, t: float}


func _ready() -> void:
	_build()
	set_occupancy_visual(0, DEFAULT_CAPACITY)
	set_state_visual(STATE_IDLE)


func _process(delta: float) -> void:
	if _ghosts.is_empty():
		return
	var done: Array[int] = []
	for gi in _ghosts.size():
		var g: Dictionary = _ghosts[gi]
		g["t"] = float(g.get("t", 0.0)) + delta
		var node := g.get("node") as MeshInstance3D
		if node == null or not is_instance_valid(node):
			done.append(gi)
			continue
		node.position.y -= GHOST_SINK_PER_SEC * delta   # 下沉
		var k := float(g["t"]) / GHOST_SECONDS
		var mat := node.get_active_material(0) as StandardMaterial3D
		var c := TRIM_COLOR
		c.a = clampf(1.0 - k, 0.0, 1.0)                 # 淡出
		mat.albedo_color = c
		mat.emission_energy_multiplier = 1.1 * clampf(1.0 - k, 0.0, 1.0)
		node.scale = Vector3.ONE * (1.0 - 0.25 * k)
		if k >= 1.0:
			node.queue_free()
			done.append(gi)
	done.reverse()
	for gi in done:
		_ghosts.remove_at(gi)


# ---------- 对外 API ----------

## 重建容量刻度（段数 = 容量上限）。改参后调用。
func set_capacity_visual(capacity: int) -> void:
	_capacity = maxi(1, capacity)
	_rebuild_scale()


## 亮起 count 个刻度段并更新占用读数（"占用 n/cap"）。count 超段数按满亮处理。
func set_occupancy_visual(count: int, capacity: int) -> void:
	if capacity != _capacity:
		_capacity = maxi(1, capacity)
		_rebuild_scale()
	var n := clampi(count, 0, _capacity)
	for i in _segs.size():
		var seg := _segs[i]
		if seg.mesh != null:
			seg.material_override = _seg_mat_filled if i < n else _seg_mat_empty
	_occ_label.text = "占用 %d/%d" % [count, _capacity]


## 把 files 码成一摞（每件一个小方块，从容器口向上堆叠）。
func set_stack_visual(files: Array) -> void:
	for c in _stack_root.get_children():
		_stack_root.remove_child(c)
		c.queue_free()
	for i in files.size():
		var cube := MeshInstance3D.new()
		cube.name = "FileCube%d" % i
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * FILE_SIZE
		mesh.material = _paper_mat()
		cube.mesh = mesh
		# v2 方块美学：整齐码放（原轻微错位偏移破坏落格，去掉）
		cube.position = Vector3(0.0, _stack_y(i), 0.0)
		_stack_root.add_child(cube)
	_stack_count = files.size()


## 裁剪可见：为被裁掉的文件生成淡出下沉的方块（TrimGhost），返回生成数。
func play_trim(removed_files: Array) -> int:
	var base := _stack_count
	for i in removed_files.size():
		var ghost := MeshInstance3D.new()
		ghost.name = "TrimGhost%d" % i
		var mesh := BoxMesh.new()
		mesh.size = Vector3.ONE * FILE_SIZE
		var mat := StandardMaterial3D.new()
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.albedo_color = TRIM_COLOR
		mat.emission_enabled = true
		mat.emission = TRIM_COLOR
		mat.emission_energy_multiplier = 1.1
		mesh.material = mat
		ghost.mesh = mesh
		# 落格生成位：前脸之外贴面（z 0.5..0.75），x 半块步进左移
		ghost.position = Vector3(-0.25 - 0.25 * i, _stack_y(base + i), 0.625)
		_ghost_root.add_child(ghost)
		_ghosts.append({"node": ghost, "t": 0.0})
	return removed_files.size()


func get_trim_ghost_count() -> int:
	return _ghosts.size()


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

## 全轨迹：traj[k] = 看完前 k+1 步后容器应处的状态。
static func state_trajectory(steps: Array, container_eid: String) -> Array:
	var traj: Array = []
	var state := STATE_IDLE
	for s in steps:
		if s is Dictionary:
			var a: Dictionary = s.get("action", {})
			var tool := str(a.get("tool", ""))
			var args: Dictionary = a.get("args", {}) if a is Dictionary else {}
			var actor := str(s.get("actor", ""))
			var output: Dictionary = s.get("output", {}) if s.get("output", {}) is Dictionary else {}
			var step_ok := bool(output.get("ok", true))
			if tool == "world.set_param" and str(args.get("entityId", "")) == container_eid:
				if str(args.get("key", "")) == "files":
					if not step_ok:
						state = STATE_ERROR
					else:
						var files: Variant = args.get("value", [])
						if files is Array and not (files as Array).is_empty():
							state = STATE_RUNNING
				elif not step_ok:
					state = STATE_ERROR
			elif tool == "world.run" and actor == "codex":
				var world: Dictionary = s.get("world", {}) if s.get("world", {}) is Dictionary else {}
				var entities: Dictionary = world.get("entities", {}) if world.get("entities", {}) is Dictionary else {}
				if entities.has(container_eid):
					var params: Dictionary = entities[container_eid].get("params", {}) if entities[container_eid].get("params", {}) is Dictionary else {}
					var files: Variant = params.get("files", [])
					if files is Array and not (files as Array).is_empty():
						state = STATE_DONE
		traj.append(state)
	return traj


## 终态 = 看完全部步记录后的状态。
static func derive_state_from_steps(steps: Array, container_eid: String) -> String:
	var traj := state_trajectory(steps, container_eid)
	if traj.is_empty():
		return STATE_IDLE
	return str(traj[traj.size() - 1])


# ---------- 内部：搭建 ----------

func _build() -> void:
	# 盘式容器体（开口朝上，文件码在里面）。v2 主轮廓 4U×1U×2U（0.5 m 整格）
	var body := MeshInstance3D.new()
	body.name = "Body"
	var body_mesh := BoxMesh.new()
	body_mesh.size = Vector3(2.0, 0.5, 1.0)
	body.mesh = body_mesh
	body.position = Vector3(0.0, 0.25, 0.0)   # 高度链：底 0.0 + 半高 0.25，顶到 0.5
	body_mesh.material = _mat(BODY_COLOR, 0.6, 0.25)
	add_child(body)

	# 背沿（挡住那摞文件不往后倒）。v2 半块背板：贴身顶 0.5，后缘凸出 0.25（整格凸出——
	# 凸 0.125 会把背板推到 1/16 格位，六面无法全落 0.25 世界格（T7））
	var rim := MeshInstance3D.new()
	rim.name = "Rim"
	var rim_mesh := BoxMesh.new()
	rim_mesh.size = Vector3(2.0, 0.5, 0.25)
	rim.mesh = rim_mesh
	rim.position = Vector3(0.0, 0.75, -0.625)   # 身顶 0.5 + 半高 0.25；背板跨 z -0.75..-0.5
	rim_mesh.material = _mat(BODY_COLOR * 0.85, 0.55, 0.25)
	add_child(rim)

	# 容量刻度（正面一排 0.25³ 分段，贴前脸外侧）。心 (0.125, 0.625)：0.25 立方
	# 六面落格必须心落半格奇位；y 落身下半（0..0.25，"下缘"），z 跨 0.5..0.75 贴前脸
	_scale_root = Node3D.new()
	_scale_root.name = "CapacityScale"
	_scale_root.position = Vector3(0.0, 0.125, 0.625)
	add_child(_scale_root)

	_seg_mat_filled = StandardMaterial3D.new()
	_seg_mat_filled.albedo_color = SEG_FILLED_COLOR
	_seg_mat_filled.emission_enabled = true
	_seg_mat_filled.emission = SEG_FILLED_COLOR
	_seg_mat_filled.emission_energy_multiplier = 1.2
	_seg_mat_filled.roughness = 0.35
	_seg_mat_empty = StandardMaterial3D.new()
	_seg_mat_empty.albedo_color = SEG_EMPTY_COLOR
	_seg_mat_empty.roughness = 0.7
	_seg_mat_empty.metallic = 0.15

	# 占用读数（Label3D，贴在刻度上方——"界面上不放东西，世界里有东西"）
	_occ_label = Label3D.new()
	_occ_label.name = "OccupancyLabel"
	_occ_label.position = Vector3(0.0, 0.72, 0.74)
	_occ_label.font_size = 40
	_occ_label.pixel_size = 0.003
	_occ_label.modulate = TEXT_COLOR
	_occ_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_occ_label.double_sided = false
	add_child(_occ_label)

	# 文件摞与被裁方块的挂点
	_stack_root = Node3D.new()
	_stack_root.name = "FileStack"
	add_child(_stack_root)
	_ghost_root = Node3D.new()
	_ghost_root.name = "TrimGhosts"
	add_child(_ghost_root)

	# 状态灯（右侧小灯杆）。v2 半块柱：贴身顶 0.5，灯叠在杆顶。
	# 心 (0.625, 0.125)：0.25 方柱/灯六面落格必须心落半格奇位，仍全落身面内
	var mast := MeshInstance3D.new()
	mast.name = "Mast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 0.5, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(0.625, 0.75, 0.125)   # 身顶 0.5 + 半高 0.25；柱跨 x 0.5..0.75、z 0..0.25
	mast_mesh.material = _mat(BODY_COLOR, 0.6, 0.25)
	add_child(mast)

	var lamp := MeshInstance3D.new()
	lamp.name = "Lamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.625, 1.125, 0.125)   # 杆顶 1.0 上叠灯：灯跨 1.0..1.25
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
	_state_label.position = Vector3(0.75, 0.45, 0.515)   # Label3D 豁免；贴前脸 z=0.5 + 0.015 防 z-fight
	_state_label.font_size = 36
	_state_label.pixel_size = 0.0028
	_state_label.modulate = TEXT_COLOR
	_state_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_state_label.double_sided = false
	add_child(_state_label)

	_rebuild_scale()


func _rebuild_scale() -> void:
	for c in _scale_root.get_children():
		_scale_root.remove_child(c)
		c.queue_free()
	_segs.clear()
	# 段间无缝（pitch=0.25）：capacity 段恰好铺满整数个半块，段排外缘全部落 0.25 格
	# （capacity=8 时正好铺满 2.0 宽身；段心 ±0.125 为排布派生位，同 base_slot 壁心豁免口径）
	var pitch := SEG_WIDTH + SEG_GAP
	var x0 := pitch * (0.5 - _capacity * 0.5)
	for i in _capacity:
		var seg := MeshInstance3D.new()
		seg.name = "Seg%d" % i
		var mesh := BoxMesh.new()
		mesh.size = Vector3(SEG_WIDTH, SEG_WIDTH, SEG_WIDTH)
		mesh.material = _seg_mat_empty
		seg.mesh = mesh
		seg.position = Vector3(x0 + i * pitch, 0.0, 0.0)
		_scale_root.add_child(seg)
		_segs.append(seg)


func _stack_y(i: int) -> float:
	# 首块半嵌身顶（中心 = 身顶 0.5，R3 半嵌实现），其上块块相贴（层距 0.25）
	return 0.5 + i * FILE_LIFT


func _paper_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = PAPER_COLOR
	m.roughness = 0.75
	m.metallic = 0.0
	return m


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m
