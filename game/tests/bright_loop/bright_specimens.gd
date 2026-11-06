extends RefCounted

# Isolated 26-piece visual study, not registered among the 28 gameplay assets.
# Geometry source: docs/10-契约/specs/2026-09-18-component-atlas.html components.
# Original four: docs/10-契约/specs/2026-09-18-unfolding-study.html machines.
# [minX,minZ,minY,width,depth,height,role], origin at northwest bottom, q = 0.25 m.
# Palette: docs/30-决策/2026-09-18-组件功能色大面积应用定稿.md (bright scheme A).
# Compatible API for bright_workbench.gd: MACHINES[0..3], build_machine(index).
const Asset := preload("res://scripts/asset_lib/asset_node.gd")
const Block := preload("res://scripts/sandbox/sandbox_block.gd")
const Q := Asset.STANDARD_CUBE_SIZE / 2.0
const PAPER := Color("f7f0d8")
const INK := Color("263b40")
const ACCENT_ACTION := Color("ef743b")
const ACCENT_SIGNAL := Color("24b9cf")
const ACCENT_CORE := Color("f2c43d")
const ACCENT_SUCCESS := Color("68ab5d")
const ACCENT_ERROR := Color("db6268")
const SHELL_NEUTRAL := Color("b9cbcb")
const LABEL_SIZE := Vector2(6.0, 3.0)
const STATUS_TEXT := "空闲 · 状态示意"
const FLOW_TEXT := "IN ▶ 接口示意 ▶ OUT"
## Display order is the atlas components order, not category grouping.
const ATLAS_ORDER := [
	"agent_task_dock", "agent_loop_table", "agent_plan_steps", "agent_memory_rack",
	"agent_message_table", "agent_model_well", "agent_tool_rack", "agent_argument_gate",
	"agent_execution_table", "agent_state_cabinet", "agent_observation_tray",
	"agent_answer_dock", "agent_parallel_bridge", "agent_budget_rail",
	"code_assign", "code_call", "code_branch", "code_loop",
	"code_define", "code_read", "code_guard", "code_return",
	"studio_session_walker", "studio_text_tile", "studio_flow_strip", "studio_lesson_screen",
]
## Human-approved four bright specimens; consumers reference them by id, not index.
const ORIGINAL_IDS := ["agent_loop_table", "agent_memory_rack", "agent_model_well",
	"agent_execution_table"]
const FONT_NAMES := ["Microsoft YaHei", "SimHei", "Noto Sans CJK SC"]

const ORIGINAL_FOUR := [
	{"id": "agent_loop_table", "cat": "module", "zh": "跑圈台", "en": "LOOP", "color": Color("9261c5"),
		"summary": "每步经过这里，决定继续、停止，或交付尽力答案。", "boxes": [
		[0,0,0,8,8,1,"STRUCTURE"], [0,0,1,8,1,1,"ACTION"],
		[0,1,1,1,7,1,"SHELL"], [7,1,1,1,7,1,"SHELL"],
		[1,7,1,2,1,1,"SHELL"], [5,7,1,2,1,1,"SHELL"], [2,2,1,4,3,1,"PAPER"]]},
	{"id": "agent_memory_rack", "cat": "module", "zh": "记忆架", "en": "MEMORY", "color": Color("4279d4"),
		"summary": "失败也留档。保存走过的步骤，与执行变量分开。", "boxes": [
		[0,0,0,10,6,1,"STRUCTURE"], [0,0,1,10,1,5,"STRUCTURE"],
		[0,1,1,1,5,5,"SHELL"], [2,1,1,1,5,5,"SHELL"], [4,1,1,1,5,5,"SHELL"],
		[7,1,1,1,5,5,"SHELL"], [9,1,1,1,5,5,"SHELL"],
		[1,1,1,1,5,1,"INK"], [3,1,1,1,5,1,"INK"], [5,1,1,2,5,1,"INK"], [8,1,1,1,5,1,"SIGNAL"]]},
	{"id": "agent_model_well", "cat": "module", "zh": "点子井", "en": "MODEL", "color": Color("f2c43d"),
		"summary": "只呈现请求和返回。琥珀色标出正在发生的模型调用。", "boxes": [
		[0,0,0,8,8,2,"STRUCTURE"], [0,0,2,2,8,4,"SHELL"],
		[6,0,2,2,8,4,"SHELL"], [2,0,2,4,2,4,"SHELL"],
		[2,6,2,4,2,1,"PAPER"], [2,2,2,4,4,1,"INK"], [3,3,3,2,2,1,"CORE"]]},
	{"id": "agent_execution_table", "cat": "module", "zh": "干活台", "en": "EXECUTION", "color": Color("ef743b"),
		"summary": "代码拆成语法节点求值；当前行和失败位置都能看到。", "boxes": [
		[0,0,0,10,8,1,"STRUCTURE"], [0,0,1,2,8,3,"SHELL"],
		[2,0,1,8,2,3,"SHELL"], [8,2,1,2,6,1,"SHELL"],
		[2,2,1,6,6,1,"INK"], [2,6,2,4,2,1,"ACTION"], [6,6,2,2,2,1,"PAPER"]]}
]

# Remaining 22 entries copied verbatim from the atlas components array.
const CATALOG_REST := [
	{"id": "agent_task_dock", "cat": "module", "zh": "任务信箱", "en": "TASK DOCK", "color": Color("24b9cf"),
		"summary": "一轮任务从这里进入；接着聊与重新开始有明确区别。", "boxes": [[0,0,0,8,6,1,'PAPER'], [0,0,1,1,6,1,'SHELL'], [7,0,1,1,6,1,'SHELL'], [1,0,1,6,1,1,'SHELL'], [3,5,1,2,1,1,'SIGNAL']]},
	{"id": "agent_plan_steps", "cat": "module", "zh": "行程表", "en": "PLAN STEPS", "color": Color("f2c43d"),
		"summary": "需要重看计划时，展示已有事实与接下来的安排。", "boxes": [[0,0,0,6,2,3,'SHELL'], [1,0,3,5,2,1,'SHELL'], [0,0,3,1,2,1,'SIGNAL'], [0,2,0,6,2,3,'SHELL'], [0,4,0,6,2,2,'PAPER']]},
	{"id": "agent_message_table", "cat": "module", "zh": "传话筒", "en": "MESSAGE TABLE", "color": Color("24b9cf"),
		"summary": "将历史转成一次请求的消息；没有偷偷裁去旧步骤。", "boxes": [[0,0,0,10,6,1,'STRUCTURE'], [0,1,1,8,5,1,'PAPER'], [0,0,1,1,1,1,'SHELL'], [2,0,1,1,1,1,'SHELL'], [4,0,1,1,1,1,'SHELL'], [6,0,1,1,1,1,'SHELL'], [8,0,1,1,1,1,'SHELL'], [8,4,1,2,2,1,'SIGNAL']]},
	{"id": "agent_tool_rack", "cat": "module", "zh": "工具架", "en": "TOOL RACK", "color": Color("ef743b"),
		"summary": "工具是可登记的能力。子智能体也从同一个接口挂接。", "boxes": [[0,0,0,2,6,4,'STRUCTURE'], [2,0,0,8,1,2,'SHELL'], [2,3,0,8,1,2,'SHELL'], [2,5,0,8,1,2,'SHELL'], [2,1,0,2,1,2,'ACTION'], [2,4,0,2,1,2,'ACTION']]},
	{"id": "agent_argument_gate", "cat": "module", "zh": "检票口", "en": "ARGUMENT GATE", "color": Color("546066"),
		"summary": "调用前核对名称与参数。通过这里不代表答案正确。", "boxes": [[0,0,0,6,6,1,'STRUCTURE'], [0,0,1,2,6,3,'SHELL'], [2,0,1,1,1,3,'SHELL'], [4,0,1,2,6,1,'SHELL'], [3,5,1,1,1,1,'SHELL'], [3,0,1,1,1,1,'SIGNAL'], [2,5,1,1,1,1,'ACTION']]},
	{"id": "agent_state_cabinet", "cat": "module", "zh": "储物柜", "en": "STATE CABINET", "color": Color("4279d4"),
		"summary": "上一步定义的变量留给下一步，不与历史记录混为一谈。", "boxes": [[0,0,0,6,6,2,'STRUCTURE'], [0,0,2,2,6,4,'SHELL'], [4,0,2,2,6,4,'SHELL'], [2,0,2,2,6,1,'INK'], [2,0,3,2,2,1,'SIGNAL']]},
	{"id": "agent_observation_tray", "cat": "module", "zh": "回音盘", "en": "OBSERVATION TRAY", "color": Color("24b9cf"),
		"summary": "工具结果、print 和错误都回到这里，成为下次输入。", "boxes": [[0,0,0,8,4,1,'PAPER'], [0,0,1,8,1,1,'SHELL'], [6,1,1,2,3,1,'SIGNAL']]},
	{"id": "agent_answer_dock", "cat": "module", "zh": "交卷台", "en": "ANSWER DOCK", "color": Color("68ab5d"),
		"summary": "最终答案在此交付；步数用尽的回答保留明确标记。", "boxes": [[0,2,0,6,4,1,'STRUCTURE'], [0,0,0,4,2,1,'STRUCTURE'], [0,2,1,6,4,1,'PAPER'], [0,0,1,4,2,1,'PAPER']]},
	{"id": "agent_parallel_bridge", "cat": "module", "zh": "分头桥", "en": "PARALLEL BRIDGE", "color": Color("ef743b"),
		"summary": "同一步发出多个工具调用，逐路返回，再汇合。", "boxes": [[0,0,0,10,1,1,'STRUCTURE'], [0,7,0,10,1,1,'STRUCTURE'], [0,1,0,2,6,2,'SHELL'], [4,1,0,2,6,2,'SHELL'], [8,1,0,2,6,2,'SHELL'], [2,1,0,2,1,1,'ACTION'], [6,1,0,2,1,1,'ACTION']]},
	{"id": "agent_budget_rail", "cat": "module", "zh": "体力尺", "en": "BUDGET RAIL", "color": Color("546066"),
		"summary": "节点、循环次数和墙钟是三个边界，不能只画一根血条。", "boxes": [[0,0,0,10,4,1,'STRUCTURE'], [0,0,1,10,1,1,'PAPER'], [0,1,1,7,1,1,'PAPER'], [0,3,1,4,1,1,'PAPER']]},
	{"id": "code_assign", "cat": "primitive", "zh": "赋值块", "en": "ASSIGN", "color": Color("4279d4"),
		"summary": "一个逻辑语句对应一个代码块；它不是 token 计数体。", "boxes": [[0,0,0,4,2,1,'STRUCTURE'], [0,0,1,4,1,1,'SHELL'], [0,1,1,1,1,1,'SIGNAL'], [3,1,1,1,1,1,'SHELL']]},
	{"id": "code_call", "cat": "primitive", "zh": "调用块", "en": "CALL", "color": Color("ef743b"),
		"summary": "把参数交给实际工具或函数。", "boxes": [[0,0,0,4,4,1,'STRUCTURE'], [0,0,1,4,2,1,'PAPER'], [0,2,1,1,2,1,'SHELL'], [3,2,1,1,2,1,'ACTION']]},
	{"id": "code_branch", "cat": "primitive", "zh": "判断块", "en": "BRANCH", "color": Color("f2c43d"),
		"summary": "只有真实选择的分支获得执行标记。", "boxes": [[0,0,0,6,2,1,'SHELL'], [0,0,1,2,2,1,'SHELL'], [4,0,1,2,2,1,'SHELL'], [2,2,0,2,2,2,'STRUCTURE'], [2,0,1,2,2,1,'SIGNAL']]},
	{"id": "code_loop", "cat": "primitive", "zh": "循环块", "en": "LOOP", "color": Color("9261c5"),
		"summary": "循环体可展开，次数只取真实执行记录。", "boxes": [[0,0,0,6,1,2,'ACTION'], [0,1,0,1,5,2,'SHELL'], [5,1,0,1,5,2,'SHELL'], [1,5,0,1,1,2,'SHELL'], [4,5,0,1,1,2,'SHELL']]},
	{"id": "code_define", "cat": "primitive", "zh": "定义块", "en": "DEFINE", "color": Color("f2c43d"),
		"summary": "定义函数时不执行函数体。", "boxes": [[0,0,0,6,1,2,'SHELL'], [0,1,0,1,3,1,'STRUCTURE'], [2,1,0,1,3,1,'STRUCTURE'], [5,1,0,1,3,1,'STRUCTURE']]},
	{"id": "code_read", "cat": "primitive", "zh": "取值块", "en": "READ", "color": Color("24b9cf"),
		"summary": "显示本行求值与实际查名，导入策略在详情区分。", "boxes": [[0,0,0,4,2,1,'STRUCTURE'], [0,0,1,4,1,1,'SIGNAL'], [0,1,1,2,1,1,'PAPER']]},
	{"id": "code_guard", "cat": "primitive", "zh": "异常块", "en": "GUARD", "color": Color("db6268"),
		"summary": "捕获、抛出与 finally 各自是一条语句。", "boxes": [[0,0,0,1,3,2,'SHELL'], [0,3,0,1,1,1,'SHELL'], [1,3,0,3,1,2,'STRUCTURE'], [0,3,1,1,1,1,'ERROR']]},
	{"id": "code_return", "cat": "primitive", "zh": "返回块", "en": "RETURN", "color": Color("68ab5d"),
		"summary": "普通函数返回；不与 final_answer 特殊控制流混用。", "boxes": [[0,0,0,4,2,1,'STRUCTURE'], [0,0,1,3,2,1,'PAPER'], [3,0,1,1,2,1,'SHELL']]},
	{"id": "studio_session_walker", "cat": "facility", "zh": "会话分身", "en": "SESSION WALKER", "color": Color("24b9cf"),
		"summary": "每个真实 agent 会话一个身体；工具并行不复制身体。", "boxes": [[0,0,0,1,2,1,'STRUCTURE'], [1,0,0,1,2,1,'STRUCTURE'], [0,0,1,2,2,2,'SHELL'], [0,0,3,2,1,1,'PAPER'], [0,1,3,2,1,1,'SIGNAL']]},
	{"id": "studio_text_tile", "cat": "facility", "zh": "字砖", "en": "TEXT TILE", "color": Color("b9cbcb"),
		"summary": "所有世界文字共用一种实体；长名字沿宽度拼砖。", "boxes": [[0,0,0,4,2,1,'STRUCTURE'], [0,0,1,4,2,1,'PAPER']]},
	{"id": "studio_flow_strip", "cat": "facility", "zh": "连接带", "en": "FLOW STRIP", "color": Color("b9cbcb"),
		"summary": "0.5 m 一段，只在表面画方向，不制造新计数方块。", "boxes": [[0,0,0,2,2,2,'INK']]},
	{"id": "studio_lesson_screen", "cat": "facility", "zh": "微课地屏", "en": "LESSON SCREEN", "color": Color("b9cbcb"),
		"summary": "8×4.5 m 的 16:9 有效画面，四周 0.5 m 边框。", "boxes": [[0,0,0,36,22,1,'STRUCTURE'], [0,0,1,36,2,1,'PAPER'], [0,20,1,36,2,1,'PAPER'], [0,2,1,2,18,1,'PAPER'], [34,2,1,2,18,1,'PAPER'], [2,2,1,32,18,1,'INK']]}
]

static var MACHINES: Array = []
static var MODULES: Array = []
static var PRIMITIVES: Array = []
static var FACILITIES: Array = []

static func _static_init() -> void:
	var by_id := {}
	for source in ORIGINAL_FOUR:
		by_id[source.id] = source
	for source in CATALOG_REST:
		by_id[source.id] = source
	for id in ATLAS_ORDER:
		MACHINES.append(_prepare(by_id[id]))
	for machine in MACHINES:
		match machine.cat:
			"module": MODULES.append(machine)
			"primitive": PRIMITIVES.append(machine)
			"facility": FACILITIES.append(machine)


static func index_of(id: String) -> int:
	for i in MACHINES.size():
		if MACHINES[i].id == id:
			return i
	return -1


static func original_indices() -> Array:
	var out: Array = []
	for id in ORIGINAL_IDS:
		var found := index_of(id)
		if found >= 0:
			out.append(found)
	return out

## const 字典在运行时只读，拷贝成可变字典后补上标注派生字段。
static func _prepare(source: Dictionary) -> Dictionary:
	var machine: Dictionary = source.duplicate()
	machine["footprint"] = _footprint_of(machine)
	machine["label_lines"] = _label_lines_of(machine)
	return machine

static func build_machine(index: int, mono := false) -> Node3D:
	var machine: Dictionary = MACHINES[index]
	var root := Node3D.new()
	root.name = machine.id
	for i in machine.boxes.size():
		var row: Array = machine.boxes[i]
		var size := Vector3(row[3], row[5], row[4]) * Q
		var part := MeshInstance3D.new()
		part.name = "%02d_%s" % [i, row[6]]
		part.mesh = chamfered_box(size)
		part.position = Vector3(row[0], row[2], row[1]) * Q
		var color: Color = machine.color
		match row[6]:
			"STRUCTURE": color = machine.color.darkened(0.24)
			"PAPER": color = PAPER
			"INK": color = INK
			"ACTION": color = ACCENT_ACTION
			"SIGNAL": color = ACCENT_SIGNAL
			"CORE": color = ACCENT_CORE
			"SUCCESS": color = ACCENT_SUCCESS
			"ERROR": color = ACCENT_ERROR
			"SHELL": color = machine.color
		if mono:
			var luminance := color.srgb_to_linear().get_luminance()
			color = Color(luminance, luminance, luminance).linear_to_srgb()
		var material := StandardMaterial3D.new()
		material.albedo_color = color
		material.roughness = 0.82
		part.material_override = material
		root.add_child(part)
	return root

static func _footprint_of(machine: Dictionary) -> Vector2:
	var width := 0.0
	var depth := 0.0
	for row in machine.boxes:
		width = maxf(width, (row[0] + row[3]) * Q)
		depth = maxf(depth, (row[1] + row[4]) * Q)
	return Vector2(width, depth)


static func _label_lines_of(machine: Dictionary) -> PackedStringArray:
	return PackedStringArray([
		machine.zh + " " + machine.en,
		machine.summary,
		FLOW_TEXT,
		STATUS_TEXT,
	])


static func footprint(index: int) -> Vector2:
	return MACHINES[index].footprint


static func label_lines(index: int) -> PackedStringArray:
	return MACHINES[index].label_lines

static func build_label(index: int) -> Node3D:
	var machine: Dictionary = MACHINES[index]
	var root := Node3D.new()
	root.name = String(machine.id) + "_label"
	var quad := MeshInstance3D.new()
	quad.name = "Glyphs"
	var mesh := QuadMesh.new()
	mesh.size = LABEL_SIZE
	quad.mesh = mesh
	quad.rotation_degrees = Vector3(-90, 0, 0)
	quad.position = Vector3(footprint(index).x * 0.5, 0.006, footprint(index).y + LABEL_SIZE.y * 0.5 + 0.5)
	quad.set_meta("text", label_lines(index))
	quad.set_meta("px", Vector2i(1024, 512))
	quad.set_meta("centered", false)
	var material := StandardMaterial3D.new()
	material.albedo_color = PAPER
	material.roughness = 0.92
	quad.material_override = material
	root.add_child(quad)
	return root

static func build_arrows(index: int) -> Node3D:
	var machine: Dictionary = MACHINES[index]
	var root := Node3D.new()
	root.name = String(machine.id) + "_arrows"
	var extent := footprint(index)
	var words := {"IN": "▶ IN", "OUT": "OUT ▶"}
	var offsets := {"IN": Vector3(extent.x * 0.5 - 3.75, 0.006, extent.y + 1.5),
			"OUT": Vector3(extent.x * 0.5 + 3.75, 0.006, extent.y + 1.5)}
	for word in words:
		var quad := MeshInstance3D.new()
		quad.name = "Arrow_" + word
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(0.5, 0.5)
		quad.mesh = mesh
		quad.position = offsets[word]
		quad.set_meta("text", word)
		quad.set_meta("glyph", words[word])
		quad.set_meta("px", Vector2i(256, 256))
		quad.set_meta("centered", true)
		var material := StandardMaterial3D.new()
		material.albedo_color = PAPER
		material.roughness = 0.92
		quad.material_override = material
		root.add_child(quad)
	return root

## Bake label/arrow glyphs through SubViewport + SystemFont (no Label3D).
## Call after the stage entered the tree, inside a windowed run.
static func bake_glyph_textures(stage: Node) -> void:
	var quads: Array[MeshInstance3D] = []
	_collect_glyph_quads(stage, quads)
	for quad in quads:
		var viewport := SubViewport.new()
		viewport.size = quad.get_meta("px")
		viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		viewport.transparent_bg = false
		stage.add_child(viewport)
		var background := ColorRect.new()
		background.color = PAPER
		background.size = Vector2(viewport.size.x, viewport.size.y)
		viewport.add_child(background)
		var lines: PackedStringArray = quad.get_meta("text")
		var font := SystemFont.new()
		font.font_names = PackedStringArray(FONT_NAMES)
		var stack := VBoxContainer.new()
		var centered: bool = quad.get_meta("centered", false)
		stack.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		stack.alignment = BoxContainer.ALIGNMENT_CENTER
		viewport.add_child(stack)
		var sizes := [88, 36, 40, 40]
		for i in lines.size():
			var line := Label.new()
			line.text = lines[i]
			line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if centered else HORIZONTAL_ALIGNMENT_LEFT
			line.add_theme_font_override("font", font)
			line.add_theme_font_size_override("font_size", sizes[i] if i < sizes.size() else 40)
			line.add_theme_color_override("font_color", Color("22313a"))
			line.add_theme_constant_override("line_spacing", 14)
			stack.add_child(line)
		for frame in 3:
			await viewport.get_tree().process_frame
		var image := viewport.get_texture().get_image()
		(quad.material_override as StandardMaterial3D).albedo_texture = ImageTexture.create_from_image(image)
		viewport.queue_free()

static func _collect_glyph_quads(node: Node, quads: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.has_meta("text"):
		quads.append(node)
	for child in node.get_children():
		_collect_glyph_quads(child, quads)

static func scene_has_label3d(node: Node) -> bool:
	if node is Label3D:
		return true
	for child in node.get_children():
		if scene_has_label3d(child):
			return true
	return false

static func chamfered_box(size: Vector3) -> ArrayMesh:
	# Reuse the existing 44-triangle topology/normals/winding. Remap its four
	# coordinates per axis instead of scaling: scaling would distort 0.05 m cuts.
	var arrays: Array = Block.block_mesh().surface_get_arrays(0).duplicate(true)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	for i in vertices.size():
		var vertex := vertices[i]
		for axis in 3:
			if vertex[axis] > 0.5:
				vertex[axis] = size[axis] - (1.0 - vertex[axis])
		vertices[i] = vertex
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
