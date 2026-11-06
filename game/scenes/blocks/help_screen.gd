extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 求助屏（docs/10-契约/交互方案.md §5.1、docs/10-契约/方块体系.md §5.1）：世界里的一大块
## **竖屏**，不是 HUD。与播放器方块同族不同块（家族二·幕布）：播放器是横版
## 看片，求助屏是竖版问答——"一事一物"（看片被动接收 / 问答主动交互，
## 分成两块屏）。空间成本就是摩擦：要走过来才能问，正好保护"三次失败阈值"
## 想保护的东西。
##
## 本节点只做"感应 + 显示 + 接线"：
##   * 失败计数（fail_counter）与三级提示（hint_service）是纯逻辑服务，屏持有
##     并驱动它们；L2 诊断的唯一数据源是 concepts.yaml 的 fail 条目（concept_map
##     是 @export 的关卡→conceptId 映射，concept_reader 载入）；
##   * 屏不进步记录：对话与 task 运行分开存（§5.1 记录口径），服务自己写
##     runs/help/{level}.json 轻量日志；
##   * L1 变红：发 request_highlight 信号（变红指令回调，由所在场景接——
##     屏不直接去涂别人家组件的材质）；锚点气泡是屏自带的子节点。
##
## 施工参照 player_block.gd（底座 + 支柱 + 边框 + 幕面 + Label3D），
## 形状区分：竖版 2.05×3.0 vs 播放器横版 3.6×2.025。

const FailCounterScript := preload("res://scripts/help/fail_counter.gd")
const HintServiceScript := preload("res://scripts/help/hint_service.gd")
const ConceptReaderScript := preload("res://scripts/help/concept_reader.gd")
const AnchorBubbleScript := preload("res://scripts/help/anchor_bubble.gd")

const SCREEN_SIZE := Vector2(2.0, 3.0)           # 竖版幕布（窄而高；块状化 v2：全 0.25 格）
const FRAME_COLOR := Style.ACTION
const STAND_COLOR := Style.STRUCTURE
const PANEL_COLOR := Style.INK
const TEXT_COLOR := Style.PAPER
const CONTENT_COLS := 14

## 有人走到屏前的感应距离（水平距离，米）。走到屏前才开始对话。
@export var sense_radius := 2.4
## 本屏服务的关卡（失败计数与提示进度的键）。
@export var level_id := "l1"
## 解锁阈值：同关失败几次后开始给提示（Code.org 实测参数 3，参数化）。
@export var fail_threshold := 3
## 关卡 -> conceptId 映射（L2 诊断读 concepts.yaml 的 fail 条目；概念不自造）。
@export var concept_map := {"l1": "c10.1"}
## concepts.yaml 路径；空 = concept_reader.default_path()（仓库根）。
@export var concepts_yaml_path := ""

## 屏前的"人"（感应对象；codex 实体/替身小车）。
signal visitor_entered
signal visitor_left
## L1 现象：问题组件变红的指令回调（目标节点由参数给出）。
signal request_highlight(target: Node3D)
## L3 代做请求（转发 hint_service；执行依赖 sidecar，后续接入）。
signal request_demo(level_id: String)

var visitor: Node3D = null
var problem_component: Node3D = null   # L1/L2 气泡指向的问题组件
var fail_anchor: Node3D = null         # L2 专用 fail 锚点（空 = 用 problem_component）
var task_board: Node3D = null          # L3 气泡指向的任务牌

var fail_counter = null
var hint_service = null

var _bubble = null
var _screen_mat: StandardMaterial3D
var _lamp_mat: StandardMaterial3D
var _content: Label3D
var _status: Label3D
var _last_text := "（走到屏前，问一句）"
var _visitor_in_range := false
var _content_shown := false


func _ready() -> void:
	_build()
	_wire_services()
	_refresh_status()
	_refresh_glow()


# ---------- 对外 API ----------

## 感应对象：谁走到屏前（null = 不感应；headless 逻辑测试可不设）。
func set_visitor(v: Node3D) -> void:
	visitor = v
	_update_sense()


## 装置上下文：问题组件（L1/L2 锚点 + 变红目标 + 组件名进 L1 文案）。
## 进树前调用走 n 记录路径；服务在 _ready 才建，由 _wire_services 补登记。
func set_problem_component(n: Node3D) -> void:
	problem_component = n
	if hint_service != null:
		hint_service.problem_names[level_id] = n.name if n != null else "任务牌"


## L2 的 fail 锚点（缺省与问题组件同体）。
func set_fail_anchor(n: Node3D) -> void:
	fail_anchor = n


## L3 锚点：任务牌。
func set_task_board(n: Node3D) -> void:
	task_board = n


## 记一次失败（关卡流程在尝试失败时调用），返回该关累计。
func report_fail() -> int:
	var n: int = fail_counter.count_fail(level_id)
	_refresh_status()
	return n


## 走到屏前问一句。太远不答；未解锁只回鼓励语；解锁后按 1→2→3 递进。
func ask(question := "") -> Dictionary:
	if visitor != null and not is_visitor_in_range():
		var far := {"kind": "too_far", "level": 0,
			"text": "走近一点，站到屏前再说——我在屏里等你。"}
		_display(far)
		return far
	var result: Dictionary = hint_service.ask(level_id, question)
	_display(result)
	return result


func is_visitor_in_range() -> bool:
	return _visitor_in_range


func get_last_text() -> String:
	return _last_text


func get_screen_material() -> StandardMaterial3D:
	return _screen_mat


## 感应顶灯的材质（测试断言"有人走到屏前才亮"用）。
func get_lamp_material() -> StandardMaterial3D:
	return _lamp_mat


func get_bubble():
	return _bubble


func get_fail_counter():
	return fail_counter


func get_hint_service():
	return hint_service


# ---------- 感应 ----------

func _process(_delta: float) -> void:
	_update_sense()


func _update_sense() -> void:
	var in_range := visitor != null and is_instance_valid(visitor) \
		and visitor_in_range_of(visitor.global_position)
	if in_range == _visitor_in_range:
		return
	_visitor_in_range = in_range
	if in_range:
		visitor_entered.emit()
	else:
		visitor_left.emit()
	_refresh_glow()


## 水平距离判定（"走到屏前"是 XZ 平面上的事）。
func visitor_in_range_of(pos: Vector3) -> bool:
	var d := global_position - pos
	d.y = 0.0
	return d.length() <= sense_radius


func _refresh_glow() -> void:
	_screen_mat.emission_energy_multiplier = 1.15 if (_visitor_in_range or _content_shown) else 0.0
	_lamp_mat.emission_energy_multiplier = 1.8 if _visitor_in_range else 0.0


# ---------- 显示 ----------

func _display(result: Dictionary) -> void:
	_last_text = str(result.get("text", ""))
	_content.text = _wrap_cjk(_last_text, CONTENT_COLS)
	_content_shown = true
	if str(result.get("kind", "")) == "hint":
		match int(result.get("level", 0)):
			1:
				_point_bubble(problem_component, "现象：看这台")
				if problem_component != null:
					request_highlight.emit(problem_component)   # 变红指令回调
			2:
				_point_bubble(fail_anchor if fail_anchor != null else problem_component,
					"诊断：看它的表现")
			3:
				_point_bubble(task_board, "代做：从任务牌开始")
	else:
		if _bubble != null:
			_bubble.clear_target()
	_refresh_status()
	_refresh_glow()


func _point_bubble(n: Node3D, text: String) -> void:
	if _bubble == null:
		return
	if n != null and is_instance_valid(n):
		_bubble.set_target(n, text)
	else:
		_bubble.clear_target()


func _refresh_status() -> void:
	_status.text = "求助屏 · %s · 失败 %d/%d · 走到屏前来问" % [
		level_id, fail_counter.fails(level_id), int(fail_counter.threshold)]


# ---------- 服务接线 ----------

func _wire_services() -> void:
	fail_counter = FailCounterScript.new()
	fail_counter.threshold = fail_threshold
	hint_service = HintServiceScript.new()
	hint_service.fail_counter = fail_counter
	hint_service.concept_map = concept_map
	hint_service.concepts = ConceptReaderScript.new().load_concepts(concepts_yaml_path)
	hint_service.request_demo.connect(func(l: String): request_demo.emit(l))
	# set_problem_component 若在进树前调过，这里补登记组件名
	if problem_component != null:
		hint_service.problem_names[level_id] = problem_component.name


# ---------- 搭建（参照 player_block.gd，竖版） ----------

func _build() -> void:
	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.25, 0.5, 0.75)   # 块状化 v2：底座 0.5 厚块（心 0.25 落格，顶平 0.5）
	base.mesh = base_mesh
	base.position = Vector3(0.0, 0.25, 0.0)
	base_mesh.material = _mat(STAND_COLOR, 0.6, 0.2)
	add_child(base)

	var post := MeshInstance3D.new()
	post.name = "Post"
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.25, 1.5, 0.25)   # 细杆→0.25 方柱（同 task_board）
	post.mesh = post_mesh
	post.position = Vector3(0.0, 0.75, 0.0)   # 0..1.5：穿底座、上端嵌进框底 0.875
	post_mesh.material = _mat(STAND_COLOR, 0.6, 0.2)
	add_child(post)

	var frame := MeshInstance3D.new()
	frame.name = "ScreenFrame"
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(SCREEN_SIZE.x + 0.25, SCREEN_SIZE.y + 0.25, 0.25)   # 2.25×3.25×0.25，四周露 0.125 边
	frame.mesh = frame_mesh
	frame.position = Vector3(0.0, 2.5, 0.0)   # 0.875..4.125，柱顶 1.5 嵌进框内
	frame_mesh.material = _mat(FRAME_COLOR, 0.45, 0.1)
	add_child(frame)

	# 幕布：**竖直的方块面板**（不是无厚度的平面）。
	# 改前是 PlaneMesh —— Godot 的 PlaneMesh 默认 orientation = FACE_Y，也就是**水平**的一片
	# （和玩家幕布同一个 bug）；它的 size 还是 Vector2，换成 BoxMesh 必须给 Vector3。
	var screen := MeshInstance3D.new()
	screen.name = "Screen"
	var screen_mesh := BoxMesh.new()
	screen_mesh.size = Vector3(SCREEN_SIZE.x, SCREEN_SIZE.y, 0.125)
	screen.mesh = screen_mesh
	screen.position = Vector3(0.0, 2.5, 0.25)   # 悬框前面 0.125（框前面 z=0.125），不共面不闪
	_screen_mat = StandardMaterial3D.new()
	_screen_mat.albedo_color = PANEL_COLOR
	_screen_mat.roughness = 0.35
	_screen_mat.metallic = 0.0
	_screen_mat.emission_enabled = true
	_screen_mat.emission = Color(0.498, 0.851, 0.659)
	_screen_mat.emission_energy_multiplier = 0.0
	screen_mesh.material = _screen_mat
	add_child(screen)

	var title := Label3D.new()
	title.name = "TitleLabel"
	title.text = "求助屏"
	title.position = Vector3(0.0, 3.72, 0.5)   # 框前面 0.125/幕面 0.25 之前（厚框会埋掉浅 z 的字）
	title.font_size = 64
	title.pixel_size = 0.0032
	title.modulate = TEXT_COLOR
	title.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	title.double_sided = false
	add_child(title)

	_content = Label3D.new()
	_content.name = "ContentLabel"
	_content.text = _wrap_cjk(_last_text, CONTENT_COLS)
	_content.position = Vector3(0.0, 2.45, 0.5)   # 同上：悬在幕面前，不落框体内
	_content.font_size = 40
	_content.pixel_size = 0.0028
	_content.modulate = TEXT_COLOR
	_content.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_content.double_sided = false
	add_child(_content)

	_status = Label3D.new()
	_status.name = "StatusCaption"
	_status.position = Vector3(0.0, 1.38, 0.5)   # 同上：悬在幕面前，不落框体内
	_status.font_size = 30
	_status.pixel_size = 0.003
	_status.modulate = Color(0.949, 0.894, 0.753)
	_status.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_status.double_sided = false
	add_child(_status)

	# 顶灯：有人走到屏前才亮（感应的可读暗示）
	# 高度链（v2）：框顶 4.125 → 杆 0.25×0.5×0.25 心 4.25（底 4.0 半嵌框顶 0.125、顶 4.5）
	# → 灯 0.25³ 心 4.5 半嵌杆顶（嵌 0.125，同 task_board 的 Lamp）
	var mast := MeshInstance3D.new()
	mast.name = "LampMast"
	var mast_mesh := BoxMesh.new()
	mast_mesh.size = Vector3(0.25, 0.5, 0.25)
	mast.mesh = mast_mesh
	mast.position = Vector3(0.0, 4.25, 0.0)
	mast_mesh.material = _mat(STAND_COLOR, 0.6, 0.2)
	add_child(mast)
	var lamp := MeshInstance3D.new()
	lamp.name = "NearLamp"
	var lamp_mesh := BoxMesh.new()
	lamp_mesh.size = Vector3.ONE * 0.25   # R4 圆件方化：球灯 → 0.25³ 方灯
	lamp.mesh = lamp_mesh
	lamp.position = Vector3(0.0, 4.5, 0.0)   # 心=杆顶 4.5：灯底 4.375 嵌进杆 0.125
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.albedo_color = Color(0.498, 0.851, 0.659)
	_lamp_mat.emission_enabled = true
	_lamp_mat.emission = Color(0.498, 0.851, 0.659)
	_lamp_mat.emission_energy_multiplier = 0.0
	lamp_mesh.material = _lamp_mat
	add_child(lamp)

	# 锚点气泡（世界空间，提示钉到具体方块上）
	_bubble = AnchorBubbleScript.new()
	_bubble.name = "AnchorBubble"
	add_child(_bubble)


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


## CJK 按列数折行（同 task_board.gd）。
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
