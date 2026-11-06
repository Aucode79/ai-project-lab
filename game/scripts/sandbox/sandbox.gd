extends "res://scripts/scene/level_scene_base.gd"

## 自由沙盒场景（spec §9.1：自由沙盒与关卡同时提供，不受关卡约束；
## §9.3 验收 3：已解锁组件可在沙盒里自由拼装）。五关之外的一块自由工区。
##
## 场景内容全部代码搭建（tscn 只挂根节点 + 脚本，同 l1_scene.gd 模式）：
##   箱庭浮空岛（sandbox_diorama.gd 配方）：浮空岛体素地形（sandbox_island.gd）
##     + 黄金时刻天空/暖阳/移轴景深（无自然装饰：树石与浮尘粒子已按 2026-09-17
##       用户裁定全删，只留结构性工艺件）
##   + 生成台：28 件资产各摆一个实例（按 base_/mach_/l2_/conc_ 分组排布，
##     基座按 blockTypes 分色），实例是冻结刚体——长按可搬走自由拼装
##   + 播放器方块（占位）+ 求助屏（concept_map 可配置）
##   + 三块 3D 按钮块（存档/读档/导出 Python）+ Label3D 读数与反馈
##   + 交互总装（InteractionHub）：轨道相机/长按搬/虚影/点按开/空格跑
##
## 世界配方是沙盒专属的一份（不复用关卡的 world_builder）：岛顶面仍在
## WorldBuilder.DECK_TOP_Y = 23，故工位摆位/物理/交互全部照旧，换的只有观感。
##
## 世界注册：28 件资产全量 register_asset（ports/defaults 来自
## scripts/sandbox/sandbox_assets.gd 常量表——硬编码 + 测试对账 assets.yaml），
## 生成台各摆一实例（首实例自动绑定，直接可连可跑）。
##
## 「空格跑」：run_start 直调 WorldToolsCore 的 world.run（复用内核，不另写
## 演化逻辑）；存/读档走 DeviceStore（user://saves/sandbox_*.json）；
## 导出走 WorldToolsCore.export_python() → 写 user://sandbox_export.py。
##
## 入口：
##   窗口围观：godot --path game scenes/sandbox/sandbox.tscn
##   窗口演示：… scenes/sandbox/sandbox.tscn -- --demo
##   截图：    … scenes/sandbox/sandbox.tscn -- --shot（出 tests/sandbox/sandbox_preview.png）
##   判定：headless 走 tests/sandbox/run_sandbox_tests.gd

const PlayerBlockScene := preload("res://scenes/blocks/player_block.tscn")
const HelpScreenScene := preload("res://scenes/blocks/help_screen.tscn")
const AssetsScript := preload("res://scripts/sandbox/sandbox_assets.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
# 箱庭浮空岛配方（沙盒专属，替换关卡用的 world_builder 那四个装配点）
const DioramaScript := preload("res://scripts/sandbox/sandbox_diorama.gd")
const IslandScript := preload("res://scripts/sandbox/sandbox_island.gd")
# 交互/状态侧走 preload（同 interaction 包纪律：不依赖 .godot 全局类缓存）
const HubScript := preload("res://scripts/interaction/interaction_hub.gd")
const CatalogScript := preload("res://scripts/sandbox/sandbox_catalog.gd")
## 沙盒里打开「组件目录」的键：与新组件体系对照，可在沙盒内四层展开到真实源码。
const CATALOG_KEY := KEY_K
const OrbitCamScript := preload("res://scripts/interaction/orbit_camera.gd")
const WorldStateScript := preload("res://scripts/core/world_state_core.gd")
const WorldToolsScript := preload("res://scripts/core/world_tools_core.gd")
const PhysicsBridgeScript := preload("res://scripts/core/physics_bridge.gd")
const DeviceStoreScript := preload("res://scripts/persistence/device_store.gd")

const OUT_SHOT := "res://tests/sandbox/sandbox_preview.png"
const EXPORT_PATH := "user://sandbox_export.py"

# ---- 生成台布局：同向、按**实测可见包围盒**占整数格 ----
# 用户口径（2026-09-16）：资产都是方块组成的、方向一致，所以每件的位置应当由一组
# 整数格坐标唯一确定，并且彼此不穿模。据此：
#   ① 每件先量**实例化后的可见包围盒**，不按声明的 footprint —— 实测 21/28 件的几何
#      超出 footprint（最大 conc_loop_gallery 深 +2.13 m、mach_splitter 宽 +1.25 m、
#      conc_thinker 宽 +1.19 m），只按 footprint 排必然穿模；
#   ② 占格 = ceil((实测 + 净距) / LAYOUT_CELL)：占格是整数个标准方块，
#      位置与占格都在 0.5 m 网格上（⊂ 世界度量体系的"摆位 n×0.25"）；
#   ③ 行宽按岛台面形状算（L4 半径推该行的可用半宽），不写死"甲板 13 m"；
#   ④ **一律 yaw = 0**：不再把深比宽长的件转 90° —— 同向是"坐标唯一确定"的前提。
const LAYOUT_CELL := 0.5                # 占格格距（米）= 一个标准方块
const PLINTH_H := 0.25                  # 基座厚（米）= 0.25 m 格厚：顶面落在 0.25 m 世界格上（甲板 23.0 + 0.25 = 23.25）
const VIEW_ON_PLINTH_Y := PLINTH_H      # 资产视图坐在基座上的抬升（= 基座厚，顶面恰在 0.25 m 格上）
const LAYOUT_GAP := 0.25                # 净距（米）= 半块，计入占格 → 相邻两件的可见体之间必有 ≥0.25 m
const DECK_EDGE_MARGIN := 0.75          # 离夯土台面外边界（PAD_L4）留的边
const BENCH_BACK_Z := -8.5              # 最靠后一排的起始 z
const BENCH_END_Z := 4.0                # 生成台收口 z：再往前就是南侧工区（播放器/求助屏/按钮）
const TAG_HEIGHT := 1.15                # 资产铭牌高度的下限（实际取"件高 + 0.35"，免得埋进机身）
const TAG_VISIBLE_END := 22.0           # 名称按距离及屏幕相交筛选，最多四张

# ---- 南侧工区：播放器方块 + 求助屏 + 三块按钮 + 读数牌 ----
const PLAYER_POS := Vector3(-3.5, DECK_TOP_Y, 7.0)
const PLAYER_YAW := 0.0              # 轴向对齐口径（2026-09-16）：一律 0；原 −0.58 是「转朝镜头」的任意角
const HELP_POS := Vector3(3.5, DECK_TOP_Y, 7.0)
const HELP_YAW := 0.0                # 同上
const BUTTON_SPOTS := {
	"sandbox_btn_save": Vector3(-1.0, DECK_TOP_Y + 0.25, 7.0),
	"sandbox_btn_load": Vector3(0.0, DECK_TOP_Y + 0.25, 7.0),
	"sandbox_btn_export": Vector3(1.0, DECK_TOP_Y + 0.25, 7.0),
}
const BUTTON_COLORS := {
	"sandbox_btn_save": Color(0.373, 0.816, 0.451),   # 存=绿
	"sandbox_btn_load": Color(0.498, 0.851, 0.659),   # 读=薄荷绿
	"sandbox_btn_export": Color(0.929, 0.471, 0.345),  # 导出=珊瑚橙
}
const BUTTON_LABELS := {
	"sandbox_btn_save": "存档",
	"sandbox_btn_load": "读档",
	"sandbox_btn_export": "导出 Python",
}
const COUNTS_POS := Vector3(0.0, DECK_TOP_Y + 2.0, 7.0)
const FEEDBACK_POS := Vector3(0.0, DECK_TOP_Y + 2.6, 7.0)

# ---- 相机轨道 ----
const ORBIT_LOOK_AT := Vector3(0.0, DECK_TOP_Y + 1.2, -0.4)

## 空格 run_toggle 驱动的场景回调（headless 测试观察口，同 l1_scene.gd）。
## 存档槽位（DeviceStore 落 user://saves/{slot}.json）。
var save_slot := "sandbox_1"
## 求助屏概念映射（沙盒默认无诊断配置；场景持有者可在进树前后改写）。
var sandbox_concept_map := {}

var world_tools = null               # scripts/core/world_tools_core.gd（own 内核）
var state = null                     # scripts/core/world_state_core.gd（场景级状态层）
var store = null                     # scripts/persistence/device_store.gd
var _help = null                    # scenes/blocks/help_screen.gd
var _hub = null                     # scripts/interaction/interaction_hub.gd
var _bridge = null                  # scripts/core/physics_bridge.gd
var _counts_label: Label3D = null
var _feedback_label: Label3D = null
var _island_query = null             # IslandScript 的查询实例（甲板碰撞代理的轮廓判定）
var _counter_accum := 0.0
var _dof_distance := -1.0            # 上一帧的轨道半径（移轴对焦带去重用）


# ---------- 基座覆写点 ----------

func _level_label() -> String:
	return "SANDBOX"


func _shot_path() -> String:
	return OUT_SHOT


func _demo_pause() -> float:
	return 1.2
func _ready() -> void:
	super._ready()
	_refresh_counters()
func _process(delta: float) -> void:
	_counter_accum += delta
	if _counter_accum >= 0.25:
		_counter_accum = 0.0
		_refresh_counters()
		_refresh_asset_labels()
	# 移轴对焦带跟着轨道半径走：滚轮缩放后要重新对焦。值是同一份就不写，
	# 免得每帧都触发 CameraAttributes 的 changed。
	if _orbit_cam != null and is_instance_valid(_orbit_cam) \
			and _orbit_cam.has_method("current_distance"):
		var d: float = _orbit_cam.current_distance()
		if not is_equal_approx(d, _dof_distance):
			_dof_distance = d
			DioramaScript.sync_dof(_orbit_cam)


# ---------- 模式入口（照抄 l1_scene.gd） ----------

## 可视演示：生成台上真连一条线（base_block:out → base_track:entry），
## 推端口值、空格跑一拍——端到端用真实内核，逻辑与测试同一条路径。
func _drive_visual_demo(pause_s: float) -> void:
	var r1: Dictionary = world_tools.call_tool("world.connect",
		{"from": "base_block#1:out", "to": "base_track#1:entry"})
	world_tools.call_tool("world.set_param",
		{"entityId": "base_block#1", "key": "@out", "value": true})
	world_tools.call_tool("world.run", {"duration": 1.0})
	_refresh_counters()
	print("SANDBOX DEMO: 连线=%s，读数=%s" % [str(r1.get("ok", false)), _counts_label.text])
	await _sleep(pause_s)


# ---------- 对外（给测试用） ----------

func get_interaction_hub():
	return _hub


func get_help_screen():
	return _help


func get_player_screen():
	return get_node_or_null("Utility/PlayerScreen")


func get_counts_label() -> Label3D:
	return _counts_label


func get_feedback_label() -> Label3D:
	return _feedback_label


## 生成台实体刚体列表（meta 带 entity_id/asset_id）。
func get_bench_items() -> Array:
	var out: Array = []
	var bench := get_node_or_null("Bench")
	if bench == null:
		return out
	for c in bench.get_children():
		if c is RigidBody3D and c.has_meta("asset_id"):
			out.append(c)
	return out


## 求助屏概念映射：进树前后都可改（转发屏本体与其 hint_service）。
func set_concept_map(map: Dictionary) -> void:
	sandbox_concept_map = map
	if _help != null and is_instance_valid(_help):
		_help.concept_map = map.duplicate()
		if _help.hint_service != null:
			_help.hint_service.concept_map = _help.concept_map


# ---------- 存档 / 读档 / 导出 ----------

## 存当前装置到槽位（DeviceStore：只存装置与参数，位置不进档）。
func save_now() -> Dictionary:
	var r: Dictionary = store.save(state, save_slot, "sandbox")
	if bool(r.get("ok", false)):
		_set_feedback("已存 %d 实体 / %d 连线 → %s.json" % [
			int(r.get("entities", 0)), int(r.get("edges", 0)), save_slot])
	else:
		_set_feedback("存档失败：%s" % str(r.get("message", "")))
	_refresh_counters()
	return r


## 清场重放：读槽位复原装置，再把生成台的实体指向拨到复原后的绑定实例。
func load_now() -> Dictionary:
	var r: Dictionary = store.load(state, save_slot)
	if bool(r.get("ok", false)):
		_sync_bench_entity_meta()
		_set_feedback("已读 %d 实体 / %d 连线（%s）" % [
			int(r.get("entities", 0)), int(r.get("edges", 0)), save_slot])
	else:
		_set_feedback("读档失败：%s" % str(r.get("message", "")))
	_refresh_counters()
	return r


## 导出 Python：复用内核 export_python → 写 user://sandbox_export.py，
## 反馈牌显示前几行摘要。
func export_now() -> Dictionary:
	var r: Dictionary = world_tools.export_python()
	if not bool(r.get("ok", false)):
		_set_feedback("导出失败：%s" % str(r.get("error", {}).get("message", "")))
		return r
	var code := str(r.get("result", {}).get("python", ""))
	var f := FileAccess.open(EXPORT_PATH, FileAccess.WRITE)
	if f == null:
		_set_feedback("导出失败：写不出 %s" % EXPORT_PATH)
		return {"ok": false, "error": {"code": "io_error", "message": "写不出 %s" % EXPORT_PATH}}
	f.store_string(code)
	f.close()
	var lines := code.split("\n")
	var head := ""
	for line in lines:
		var t := str(line).strip_edges()
		if t != "":
			head = t
			break
	_set_feedback("导出 %d 行 → %s｜%s" % [lines.size(), EXPORT_PATH, head.substr(0, 60)])
	_refresh_counters()
	return r


func _set_feedback(text: String) -> void:
	if _feedback_label != null:
		_feedback_label.text = text
	print("SANDBOX: %s" % text)


## 读数牌：已放置实体数 / 连线数（状态层快照，不含物理量）。
func _refresh_counters() -> void:
	if _counts_label == null or state == null:
		return
	var snap: Dictionary = state.logical_snapshot()
	_counts_label.text = "沙盒装置：实体 %d · 连线 %d" % [
		(snap["entities"] as Dictionary).size(), (snap["edges"] as Array).size()]


## 读档后生成台刚体的 entity_id 指向复原世界的绑定实例（同资产多实例时
## 保住「可操作的是绑定实例」口径；单实例时 eid 不变，纯兜底）。
func _sync_bench_entity_meta() -> void:
	var snap: Dictionary = state.logical_snapshot()
	var bindings: Dictionary = snap["bindings"]
	for body in get_bench_items():
		var aid := str(body.get_meta("asset_id"))
		body.set_meta("entity_id", str(bindings.get(aid, "")))


func _build_world() -> void:
	# 独立 own 内核（沙盒不碰共享 autoload）；须先建好——_add_interaction 与 _add_workstation 都要用
	state = WorldStateScript.new()
	world_tools = WorldToolsScript.new()
	world_tools.own_state = state
	world_tools.own_recorder = StepRecorderCore.new()
	world_tools.own_cost = CostModelCore.new()
	store = DeviceStoreScript.new()
	_bridge = PhysicsBridgeScript.new(state)
	super._build_world()
	# 甲板碰撞代理：轮廓判定用**另一个** IslandScript 实例（地形那份跑在 worker 线程，
	# 共享实例读噪声不安全；形状是纯函数，两份实例结果必然一致）。
	# 自然装饰（树石粒子）按用户裁定 2026-09-17 全删；**草不再是几何** —— 草是顶层
	# 方块的草皮表面（sandbox_block.gdshader 的 pattern_kind 3），岛形与方块轮廓仍是正方体。
	_island_query = IslandScript.new()
	DioramaScript.add_deck_collision(self, _island_query)


# ---------- 世界配方覆写：整套换成箱庭浮空岛（替代 world_builder 的四个装配点）----------

func _add_environment() -> void:
	DioramaScript.add_environment(self)


func _add_sun() -> void:
	DioramaScript.add_sun(self)


## 粒子：**这个覆写必须留着**（整个删掉就回落到 world_builder 的关卡 Sparks 火花）——
## 沙盒不出任何粒子（自然装饰全删，2026-09-17），配方那份 add_particles 已是空函数。
func _add_particles() -> void:
	DioramaScript.add_particles(self)


func _add_terrain_recipe() -> VoxelTerrain:
	return DioramaScript.add_terrain(self)


func _add_camera() -> void:
	# 注视主体=台面中部（工位全景）。--shot 出一张整岛全景（效果最完整），
	# 交互围观给工作视角（工位读得清，滚轮能缩到全景）
	_orbit_cam = DioramaScript.make_orbit_camera(self, ORBIT_LOOK_AT,
		"diorama" if _resolve_mode() == "shot" else "bench")
	DioramaScript.attach_viewer(self)
# ---------- 生成台（28 件资产实例，按整数格排布） ----------

## 生成台总装。三步，顺序不能换：
##   ① 量占格：把每件的视图放进一个**临时挂点**里量完就丢。
##      **不能拿真载体去量**，因为真载体必须"先定位置、再进树" —— 见下条。
##   ② 排布：同向（yaw 全 0）、落格、互不穿模。
##   ③ 建载体：**先把位置/朝向摆好，再 add_child 进树**。
##
##   为什么 ③ 的顺序是铁律：资产里有 `AnimatableBody3D`（传送带的带面，
##   `sync_to_physics = true`）。它进树那一刻会把自己的世界变换当成绝对值交给物理
##   服务器，之后父节点再移动时，服务器把节点局部变换"补偿"回去 —— 带面就留在原地。
##   实测：载体先进树（在原点）再摆到工位，传送带带面的局部坐标被写成
##   (2.5, −22.5, −1.75)，落到了世界原点。原实现是"先摆位再进树"，所以没暴露。
func _add_workstation() -> void:
	var bench := Node3D.new()
	bench.name = "Bench"
	add_child(bench)

	# ① 量占格（临时挂点，量完即弃）
	var holder := Node3D.new()
	holder.name = "MeasureHolder"
	add_child(holder)
	var pending: Array = []
	for aid in AssetsScript.asset_ids():
		var spec := AssetsScript.spec_of(aid)
		var view: Node3D = load(str(spec["scene"])).instantiate()
		view.position = Vector3(0.0, VIEW_ON_PLINTH_Y, 0.0)
		holder.add_child(view)
		var box := _local_aabb(view, view.transform)
		var c := box.get_center()
		var metrics := {"w": box.size.x, "d": box.size.z, "h": box.size.y,
			"cx": c.x, "cy": c.y, "cz": c.z}
		var r := _reserve(metrics)
		pending.append({"aid": aid, "spec": spec, "metrics": metrics, "rw": r.x, "rd": r.y})
		holder.remove_child(view)
		view.free()
	holder.free()

	# ② 排布
	var slots := _pack_slots(pending)

	# ③ 建载体（先摆位、后进树）+ 世界侧注册/放置
	for slot in slots:
		var aid := str(slot["aid"])
		var body := _make_bench_body(aid, slot["spec"], slot)
		body.position = slot["pos"]
		body.rotation.y = float(slot["yaw"])
		bench.add_child(body)
		var reg: Dictionary = state.register_asset(aid, str((slot["spec"] as Dictionary)["kind"]),
			(slot["spec"] as Dictionary)["defaults"], (slot["spec"] as Dictionary)["ports"])
		if not bool(reg.get("ok", false)):
			push_error("沙盒资产注册失败：%s（%s）" % [aid, str(reg.get("message", ""))])
		var placed: Dictionary = state.place(aid, slot["cell"])
		var eid := str(placed.get("entityId", ""))
		body.set_meta("entity_id", eid)
		body.set_meta("desc", _describe_asset(aid, eid))


## 生成台实体：冻结刚体载体（拾取/拖拽/落定上报都归它）+ 占格基座 +
## 资产 tscn 视图 + 铭牌 Label3D + 碰撞体。**不含位置/朝向**——那些由调用方在
## `add_child` 之前设好（见 _add_workstation ③ 的顺序铁律）。
##
## 碰撞体与基座都取**实测可见范围**，不再截短：原来把进深 clampf 到 1.5 m 是为了
## "行距 1.5 m 相邻行不叠"——那是拿截短的碰撞体掩盖排布问题。现在排布按实测占格、
## 相邻件的可见体之间必有 ≥0.25 m，碰撞体（= 可见体）自然互不相压。
func _make_bench_body(aid: String, spec: Dictionary, slot: Dictionary) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = "Item_%s" % aid
	body.set_meta("asset_id", aid)
	body.mass = 1.0
	body.freeze = true
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.05
	body.physics_material_override = pm

	var m: Dictionary = slot["metrics"]
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(maxf(float(m["w"]), LAYOUT_CELL),
		maxf(float(m["h"]), LAYOUT_CELL), maxf(float(m["d"]), LAYOUT_CELL))
	cs.shape = shape
	cs.position = Vector3(0.0, float(m["cy"]), 0.0)
	body.add_child(cs)

	# 占格基座：平面尺寸是"这件占了几个 0.5 m 格"，一眼看得出占位；厚 = PLINTH_H，
	# 顶面落 0.25 m 世界格（部件外延落格口径，2026-09-17）
	var plinth := MeshInstance3D.new()
	plinth.name = "Plinth"
	var plinth_mesh := BoxMesh.new()
	plinth_mesh.size = Vector3(float(slot["rw"]), PLINTH_H, float(slot["rd"]))
	plinth_mesh.material = _mat(AssetsScript.block_type_color(aid), 0.85, 0.0)
	plinth.mesh = plinth_mesh
	plinth.position = Vector3(0.0, PLINTH_H * 0.5, 0.0)
	body.add_child(plinth)

	# 资产视图：平移到"可见包围盒中心落在刚体原点"——有件是偏心的
	# （conc_thinker 的纸条伸向 -x、托盘伸向 +z），不居中就等于占格没算准
	var view: Node3D = load(str(spec["scene"])).instantiate()
	view.name = "View"
	view.position = Vector3(-float(m["cx"]), VIEW_ON_PLINTH_Y, -float(m["cz"]))
	body.add_child(view)

	# 中文铭牌。只在近处显示：全景机位读形状与配色即可，
	# 缩进来干活时铭牌才出来 —— 远景因此干净，是箱庭观感的一部分。
	# 高度取"件高 + 0.35"（下限 TAG_HEIGHT）：高件（任务牌 3.1 m）的牌子才不会埋进机身。
	var tag := _make_label(AssetsScript.display_name(aid), 28, Style.INK)
	tag.name = "Tag"
	tag.position = Vector3(0.0, maxf(TAG_HEIGHT, float(m["h"]) + 0.35), 0.0)
	tag.visible = false
	body.add_child(tag)
	return body


## 子树在 `base` 标架下的包围盒（迭代遍历，避免深递归；只算 MeshInstance3D ——
## Label3D 是文字叠层，不参与占格）。
func _local_aabb(node: Node, base: Transform3D) -> AABB:
	var acc := AABB()
	var first := true
	var stack: Array = [[node, base]]
	while not stack.is_empty():
		var pair: Array = stack.pop_back()
		var n: Node = pair[0]
		var t: Transform3D = pair[1]
		if n is MeshInstance3D:
			var wb: AABB = t * (n as MeshInstance3D).get_aabb()
			if first:
				acc = wb
				first = false
			else:
				acc = acc.merge(wb)
		for child in n.get_children():
			if child is Node3D:
				stack.append([child, t * (child as Node3D).transform])
	return acc


## 占格（米）＝ ceil((实测 + 净距) / 格距) 个标准方块。件居格中，所以相邻两件的
## 可见体之间至少留出 LAYOUT_GAP（各让一半）。
func _reserve(metrics: Dictionary) -> Vector2:
	var w: float = maxf(float(metrics["w"]), 0.0)
	var d: float = maxf(float(metrics["d"]), 0.0)
	var rw: float = ceil((w + LAYOUT_GAP) / LAYOUT_CELL) * LAYOUT_CELL
	var rd: float = ceil((d + LAYOUT_GAP) / LAYOUT_CELL) * LAYOUT_CELL
	return Vector2(maxf(rw, LAYOUT_CELL), maxf(rd, LAYOUT_CELL))


## 台面在 |z| 处的可用半宽（米）：夯土台面是 L4 半径 PAD_L4 的圆角方，
## x ≤ (p⁴ − z⁴)^(¼)。减去边距；越靠边越窄，所以行宽不该是常数。
func _usable_half_width(z: float) -> float:
	var p := IslandScript.PAD_L4 - DECK_EDGE_MARGIN
	var zz := minf(absf(z), p - 0.5)
	return sqrt(sqrt(maxf(pow(p, 4.0) - pow(zz, 4.0), 0.0)))


## 排布：行内贪心换行（行宽按台面形状）、行内居中、行中心按该行最大进深对齐；
## 组序 = assets.yaml 分组序。items 里的每件须已带 w/d/rw/rd（见 _add_workstation ②）。
## 返回 = items 的副本 + {pos, cell, yaw}。
func _pack_slots(items: Array) -> Array:
	# 行内贪心（行宽取该行**起始 z** 决定的可用宽度：z 从后往前推进，
	# 起始 z 是该行最靠后的位置、半宽最小，用它做判据是保守的）
	# 按**占格进深降序**排：同进深的件排进同一行，行带（按最深件算）才不浪费
	# （不排序时一行里混着 4.5 m 与 0.5 m 的件，浅的件白占掉一整条行带）。
	# 排布顺序因此与资产枚举顺序解耦 —— 世界侧的注册/放置另走一遍枚举顺序。
	#
	# **确定性契约**：排序是全序（进深降序，并列按资产 id 升序），摆位由此成为
	# 「实测可见包围盒 → 占格」的纯函数——同代码同几何下逐次运行逐字节一致
	# （headless 三连跑 [extent] 逐字节 diff 为空，2026-09-17 实证）。
	# 为什么并列也要钉死：sort_custom 是不稳定排序（introsort），单靠 rd 比较
	# 时并列件的相对次序由实现内部细节决定；某件的量测在格界上翻转一档，并列组
	# 就可能整体换序、整排重排，摆位漂移远大于几何改动本身（跨运行 z 差 0.5 m
	# 的「布局漂移」就是这么被 sub-cell 几何改动放大的）。id 决胜后，几何微动
	# 只影响自己那件的占格，不再连带洗牌。注意反命题不成立：改了几何（如外延
	# 落格修复改了包围盒），布局确定地跟着变——那是输入变了，不是随机。
	var ordered: Array = items.duplicate()
	ordered.sort_custom(func(a, b) -> bool:
		var da: float = float(a["rd"])
		var db: float = float(b["rd"])
		if not is_equal_approx(da, db):
			return da > db
		return str(a["aid"]) < str(b["aid"]))
	var rows: Array = []
	var cur: Array = []
	var cur_w := 0.0
	var z_cursor := BENCH_BACK_Z
	for it in ordered:
		var limit: float = 2.0 * _usable_half_width(z_cursor)
		if not cur.is_empty() and cur_w + float(it["rw"]) > limit:
			rows.append({"items": cur, "width": cur_w})
			cur = []
			cur_w = 0.0
			z_cursor += _row_depth(rows[rows.size() - 1]["items"])
		cur.append(it)
		cur_w += float(it["rw"])
	if not cur.is_empty():
		rows.append({"items": cur, "width": cur_w})

	# 摆放：行内居中、行中心的 z 由该行最大进深定（同排前后缘对齐，成行成列）
	var slots: Array = []
	var z := BENCH_BACK_Z
	for row in rows:
		var row_items: Array = row["items"]
		var depth: float = _row_depth(row_items)
		var x := -float(row["width"]) * 0.5
		for it in row_items:
			var rw: float = float(it["rw"])
			var pos := Vector3(x + rw * 0.5, DECK_TOP_Y, z + depth * 0.5)
			var slot: Dictionary = it.duplicate()
			slot["pos"] = pos
			slot["cell"] = [int(round(pos.x)), int(DECK_TOP_Y), int(round(pos.z))]
			slot["yaw"] = 0.0
			slots.append(slot)
			x += rw
		z += depth
	if z > BENCH_END_Z:
		push_error("生成台排布到 z=%.1f，越过南侧工区分界 %.1f（资产会叠进工区）" % [z, BENCH_END_Z])
	return slots


## 一行需要的进深（米）：该行里最深的那个占格。
func _row_depth(row_items: Array) -> float:
	var d := 0.0
	for it in row_items:
		d = maxf(d, float(it["rd"]))
	return d


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


func _make_label(text: String, font_size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.font_size = font_size
	l.modulate = color
	l.outline_size = 4
	l.outline_modulate = Color(0.95, 0.97, 0.99, 0.85)
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.no_depth_test = false
	return l


## Keep a bounded set of names near the view center, independent of asset count.
func _refresh_asset_labels() -> void:
	if _orbit_cam == null:
		return
	var candidates: Array = []
	var viewport_rect := get_viewport().get_visible_rect()
	var center := viewport_rect.get_center()
	for body in get_bench_items():
		var tag := body.get_node("Tag") as Label3D
		tag.visible = false
		var p := tag.global_position
		if _orbit_cam.is_position_behind(p) or _orbit_cam.global_position.distance_to(p) > TAG_VISIBLE_END:
			continue
		var screen := _orbit_cam.unproject_position(p)
		var rect := Rect2(screen - Vector2(80, 16), Vector2(160, 32))
		if not viewport_rect.encloses(rect):
			continue
		candidates.append({"tag": tag, "rect": rect, "score": screen.distance_squared_to(center)})
	candidates.sort_custom(func(a, b): return a["score"] < b["score"])
	var occupied: Array[Rect2] = []
	for entry in candidates:
		var rect: Rect2 = entry["rect"]
		var overlaps := false
		for other in occupied:
			if rect.intersects(other):
				overlaps = true
		if overlaps:
			continue
		(entry["tag"] as Label3D).visible = true
		occupied.append(rect)
		if occupied.size() == 4:
			break


func _describe_asset(aid: String, eid: String) -> String:
	var spec: Dictionary = AssetsScript.spec_of(aid)
	var port_parts: Array = []
	for p in spec["ports"]:
		port_parts.append("%s(%s,%s)" % [str(p["id"]), str(p["kind"]), str(p["dir"])])
	var param_parts: Array = []
	var params: Dictionary = spec["defaults"]
	for key in params:
		param_parts.append("%s=%s" % [str(key), str(params[key])])
	return "%s（%s）\n端口：%s\n参数：%s\n沙盒生成台实例——长按搬走自由拼装，点按看参数" % [
		aid, eid,
		"，".join(PackedStringArray(port_parts)),
		"，".join(PackedStringArray(param_parts)),
	]


# ---------- 南侧工区：播放器 / 求助屏 / 按钮块 / 读数牌 ----------

func _add_extras() -> void:
	var util := Node3D.new()
	util.name = "Utility"
	add_child(util)

	var screen := PlayerBlockScene.instantiate()
	screen.name = "PlayerScreen"
	screen.position = PLAYER_POS
	screen.rotation.y = PLAYER_YAW
	util.add_child(screen)

	var help := HelpScreenScene.instantiate()
	help.name = "HelpScreen"
	help.position = HELP_POS
	help.rotation.y = HELP_YAW
	help.level_id = "sandbox"
	help.concept_map = sandbox_concept_map.duplicate()
	util.add_child(help)   # 进树（_ready 建屏与服务）
	_help = help

	for eid in BUTTON_SPOTS:
		util.add_child(_make_button(eid))

	_counts_label = _make_label("沙盒装置：实体 0 · 连线 0", 34, Color(0.30, 0.26, 0.22))
	_counts_label.name = "CountsLabel"
	_counts_label.position = COUNTS_POS
	util.add_child(_counts_label)

	_feedback_label = _make_label("", 28, Style.INK)
	_feedback_label.name = "FeedbackLabel"
	_feedback_label.position = FEEDBACK_POS
	util.add_child(_feedback_label)


## 3D 按钮块：0.5 立方冻结刚体 + 颜色 + 顶上标签。点按（hub 的 tap →
## view_opened）触发对应动作——复用交互系统的手势路由，不自造输入通道。
func _make_button(eid: String) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = eid
	body.freeze = true
	body.position = BUTTON_SPOTS[eid]
	body.set_meta("entity_id", eid)
	body.set_meta("drag_locked", true)
	body.set_meta("desc", "%s 按钮（%s）：点按执行" % [
		str(BUTTON_LABELS[eid]), eid])

	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * 0.5
	cs.shape = shape
	body.add_child(cs)

	var mi := MeshInstance3D.new()
	mi.name = "Block"
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * 0.5
	var mat := _mat(BUTTON_COLORS[eid], 0.5, 0.15)
	mat.emission_enabled = true
	mat.emission = BUTTON_COLORS[eid]
	mat.emission_energy_multiplier = 0.35
	mesh.material = mat
	mi.mesh = mesh
	body.add_child(mi)

	var tag := _make_label(str(BUTTON_LABELS[eid]), 30, Color(0.30, 0.26, 0.22))
	tag.name = "Tag"
	tag.position = Vector3(0.0, 1.0, 0.0)
	body.add_child(tag)
	return body


# ---------- 交互 hub 接线（docs/10-契约/交互方案.md §二/§四） ----------

## setup 必须在任何输入到来之前完成（hub._unhandled_input 未 setup 会崩），
## 全部在 _ready 的同步段里做完。
var _catalog = CatalogScript.new()


func _add_interaction() -> void:
	_hub = HubScript.new()
	_hub.name = "InteractionHub"
	add_child(_hub)                          # 先进树（_ready 连手势信号、挂控制器子节点）
	_hub.setup(self, _orbit_cam, world_tools)  # tools 注入：空格跑/单步直通 world.* 内核
	_hub.entity_of = Callable(self, "_entity_id_of")
	_hub.drag.landed_reporter = _bridge.report_contact   # 物理→逻辑单向上报（一次）
	# 点按的 code_provider 换成资产描述（默认是导出 python，信息量不如逐件规格）
	_hub.open_view.code_provider = Callable(self, "_describe_target")
	# 目录模式的按键（数字/Tab/B）走阅读器；普通点开仍是资产描述。
	_hub.open_view.key_provider = Callable(self, "_catalog_key")
	_hub.open_view.open_hook = Callable(self, "_on_view_target")
	# 空格跑：包一层场景回调（计数/读数/测试观察口），内核调用原样保留
	_hub.run.run_start = Callable(self, "_on_run_started")
	_hub.run.run_stop = Callable(self, "_on_run_stopped")
	# 按钮块动作：点按开全屏时按 entity_id 分发（存/读/导出），随即关掉全屏
	_hub.open_view.view_opened.connect(_on_view_opened)
	# 关掉全屏就退出目录模式（Esc、再点一下、按钮块都走 close）。
	_hub.open_view.view_closed.connect(_catalog.deactivate)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var k := event as InputEventKey
		if k.pressed and not k.echo and k.keycode == CATALOG_KEY:
			_catalog.open(_hub, self)
			get_viewport().set_input_as_handled()


func _entity_id_of(node: Node3D) -> String:
	if node != null and node.has_meta("entity_id"):
		return str(node.get_meta("entity_id"))
	return ""   # hub 兜底用节点名


func _describe_target(target: Node3D) -> String:
	# 目录模式：用生产阅读器渲染四层展开（与工作台同一套模块）。
	if _catalog.active:
		return _catalog.text()
	if target != null and target.has_meta("desc"):
		return str(target.get_meta("desc"))
	return "%s：沙盒里的物件（点按查看）" % str(target.name)


## 目录模式下的按键交给阅读器；其他情况不拦截。
func _catalog_key(keycode: int) -> bool:
	if not _catalog.handle_key(keycode):
		return false
	_hub.open_view.refresh()
	_hub.open_view.reset_scroll()
	return true


## 只有目录入口用四层阅读器；点普通物件时退出目录模式。
func _on_view_target(target: Node3D) -> void:
	if target != self:
		_catalog.deactivate()


func _on_view_opened(eid: String) -> void:
	if not eid.begins_with("catalog:"):
		_catalog.deactivate()
	match eid:
		"sandbox_btn_save":
			save_now()
			_hub.open_view.close()
		"sandbox_btn_load":
			load_now()
			_hub.open_view.close()
		"sandbox_btn_export":
			export_now()
			_hub.open_view.close()


## 空格 run_toggle 的语义：直调 world.run（复用内核驱动已连线装置）。
func _on_run_started() -> void:
	run_drive_count += 1
	run_drive_toggled.emit(true)
	world_tools.call_tool("world.run", {"duration": 1.0})
	_refresh_counters()


func _on_run_stopped() -> void:
	run_drive_count += 1
	run_drive_toggled.emit(false)
	_refresh_counters()
