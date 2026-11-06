extends Node3D

## 五关与沙盒共用的场景基座：模式解析（--demo / --shot）、世界装配模板、体素就绪等待、
## 小车移动、材质快捷方式、手动轨道相机、空格 run_toggle 语义。
## 各关场景脚本 `extends "res://scripts/scene/level_scene_base.gd"`，只留本关的工位布局
## 与组件安装代码。背后由来见 docs/30-决策/2026-09-15-场景与流程层去重重构.md。
##
## 子类必填覆写点：
##   _level_label() -> String              本关标签（打印用，如 "L1" / "SANDBOX"）
##   _shot_path() -> String                --shot 截图落盘路径
##   _drive_visual_demo(pause_s: float)    可视演示（本关 flow 与节奏）
##   _add_workstation() -> void            工位总装（组件安装位与 codex 小车）
##   _face_cart(cart, target) -> void      小车朝向（codex_goto 末步回调）
## 可选覆写：_add_extras() / _add_interaction() / _build_world()（前置状态）/ _ready()
##   （后置刷新）/ _init()（环绕相机取景）/ _demo_pause() / _shot_pause() /
##   _on_run_started() / _on_run_stopped() / _process()
## 世界配方覆写（换一整套环境/光照/粒子/地形）：_add_environment() / _add_sun() /
##   _add_particles() / _add_terrain_recipe()（沙盒就是这么换成箱庭浮空岛的）

const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const WorldBuilder := preload("res://scripts/scene/world_builder.gd")
const AssetNodeScript := preload("res://scripts/asset_lib/asset_node.gd")   # STANDARD_CUBE_SIZE：标准方块唯一尺寸来源

# 世界常量与调色板的唯一出口在 world_builder；子类用这些继承名直接引用
const TERRAIN_BASE_HEIGHT := WorldBuilder.TERRAIN_BASE_HEIGHT
const PLAZA_RADIUS := WorldBuilder.PLAZA_RADIUS
const PLAZA_LIFT := WorldBuilder.PLAZA_LIFT
const DECK_TOP_Y := WorldBuilder.DECK_TOP_Y
const PALETTE := WorldBuilder.PALETTE
const EMISSIVE := WorldBuilder.EMISSIVE

## 空格 run_toggle 驱动的场景回调（headless 测试可关掉真跑演示）。
signal run_drive_toggled(running: bool)

var _terrain: VoxelTerrain = null
var _orbit_cam: Camera3D = null      # OrbitCam 接管的主相机（全部场景）
var _cam: Camera3D = null            # 旧相机兼容字段；现行场景均走 _orbit_cam

# ---- 默认轨道相机取景（子类在 _init 里按本关覆写；l1/sandbox 用 OrbitCam 不吃这组值）----
var orbit_radius := 16.0
var orbit_height := DECK_TOP_Y + 6.5
var orbit_speed := 0.12              # rad/s，慢速环绕
var orbit_look_at := Vector3(0.0, DECK_TOP_Y + 1.5, 0.0)
var _orbit_t := 0.0
## --shot 机位覆写生效后置真：停掉自动环绕的逐帧改机位（见 _process）。
var _shot_camera_pinned := false

var run_drive_count := 0             # 空格触达 run_start/run_stop 的次数（测试观察口）


func _ready() -> void:
	add_child(preload("res://scripts/scene/scene_menu.gd").new())
	_build_world()
	Surface.apply(self)
	get_tree().node_added.connect(_finish_added_mesh)
	match _resolve_mode():
		"demo":
			_run_mode_demo()
		"shot":
			_run_mode_shot()
		_:
			if get_tree().get_meta("start_lesson_demo", false):
				get_tree().set_meta("start_lesson_demo", false)
				_run_mode_demo()


# ---------- 世界装配（模板方法：子类填覆写点）----------

func _build_world() -> void:
	# GDExtension 必须有 VoxelEngineUpdater 驱动，否则异步流式任务永不完成
	var updater := VoxelEngineUpdater.new()
	updater.name = "VoxelEngineUpdater"
	add_child(updater)

	# 世界配方的四个可替换点（默认关卡配方 world_builder；沙盒换成箱庭浮空岛配方）。
	# 组装顺序只此一处，配方各自演进互不影响。
	_add_environment()
	_add_sun()
	_add_particles()
	_add_camera()
	_terrain = _add_terrain_recipe()
	_add_workstation()
	_add_extras()
	_add_interaction()


func _add_environment() -> void:
	WorldBuilder.add_environment(self)


func _add_sun() -> void:
	WorldBuilder.add_sun(self)


func _add_particles() -> void:
	WorldBuilder.add_particles(self)


func _add_terrain_recipe() -> VoxelTerrain:
	return WorldBuilder.add_terrain(self)


## 工位总装（子类必填）。
func _add_workstation() -> void:
	pass


## 工位之外的附加装置（求助屏 / 沙盒按钮台等）；默认无。
func _add_extras() -> void:
	pass


## 交互 hub 接线（l1 / sandbox）；默认无。
func _add_interaction() -> void:
	pass


## 本关标签（打印用，如 "L1" / "SANDBOX"；子类必填）。
func _level_label() -> String:
	return ""


## --shot 截图落盘路径（子类必填）。
func _shot_path() -> String:
	return ""


## 可视演示（子类必填：本关 flow 与节奏）。
func _drive_visual_demo(_pause_s: float) -> void:
	pass


# ---------- 相机 ----------

## 默认：可手动旋转、平移、缩放的第三人称相机（L2–L5）；L1 / sandbox 自定初始姿态。
func _add_camera() -> void:
	var height := orbit_height - orbit_look_at.y
	var distance := sqrt(orbit_radius * orbit_radius + height * height)
	var preset := {"yaw": PI * 0.25, "pitch": atan2(height, orbit_radius), "distance": distance, "ortho": false}
	_orbit_cam = WorldBuilder.make_orbit_camera(self, orbit_look_at, "lesson", preset)
	_orbit_cam.orbit_requires_middle = true
	_orbit_cam.snap_preset("lesson")
	WorldBuilder.attach_viewer(self)


func _process(delta: float) -> void:
	# 机位被 --shot 覆写钉住之后就不能再让自动环绕改机位：否则覆写每帧被覆盖回去，
	# 截到的仍是"跑到第几帧就是哪个角度"的时机机位，同机位对照根本不成立。
	if _cam == null or _shot_camera_pinned:
		return
	_orbit_t += delta
	_update_camera(_orbit_t)


func _update_camera(t: float) -> void:
	if _cam == null:
		return
	var a := t * orbit_speed + PI * 0.25
	_cam.position = Vector3(cos(a) * orbit_radius, orbit_height, sin(a) * orbit_radius)
	_cam.look_at(orbit_look_at, Vector3.UP)


# ---------- 模式入口 ----------

func _resolve_mode() -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			return a.substr("--mode=".length())
		if a == "--demo":
			return "demo"
		if a == "--shot":
			return "shot"
	return ""


func _run_mode_demo() -> void:
	# 窗口演示：跑一遍完整流程的可视版（独立内核，不落盘），跑完保持围观
	var ready_now: bool = await wait_ready(900)
	print("%s DEMO: 体素地形就绪=%s，开始演示流程" % [_level_label(), str(ready_now)])
	await _drive_visual_demo(_demo_pause())
	print("%s DEMO: 演示完毕，继续围观（Ctrl+C 退出）" % _level_label())


func _run_mode_shot() -> void:
	# 截图：等体素就绪 → 跑可视演示 → 存 png → 退出
	var ready_now: bool = await wait_ready(900)
	print("%s SHOT: 体素地形就绪=%s" % [_level_label(), str(ready_now)])
	await _drive_visual_demo(_shot_pause())
	_apply_camera_overrides()          # 取证用的机位覆写（不给参数则不动）
	for i in 12:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var out := _shot_output_path()
	var err := img.save_png(out)
	print("%s SHOT: %s 已保存（err=%d）" % [_level_label(), out, err])
	get_tree().quit(0 if err == OK else 1)


# ---------- --shot 的机位与落盘覆写（美术取证）----------
# 同机位对照（前/后、四个对照机位）必须能精确指定姿态与输出路径，否则只能靠人工
# 操作截图，图与图之间没可比性。缺省不给这些参数时，行为与从前逐字一致。
#   --yaw=<rad> --pitch=<rad> --dist=<m>   摆到指定球坐标姿态
#   --out=res://<路径>                      截图落盘路径（可带子目录，自动创建）

func _shot_argize(prefix: String) -> String:
	for a in OS.get_cmdline_user_args():
		if a.begins_with(prefix):
			return a.substr(prefix.length())
	return ""


func _shot_output_path() -> String:
	var out := _shot_argize("--out=")
	if out == "":
		return _shot_path()
	DirAccess.make_dir_recursive_absolute(out.get_base_dir())
	return out


## 把当前相机摆到 --yaw/--pitch/--dist 指定的姿态。轨道相机走 snap_pose；
## 其余（l2-l5 的自动环绕相机）按同一套球坐标绕 orbit_look_at 摆位。
func _apply_camera_overrides() -> void:
	var yaw := _shot_argize("--yaw=")
	var pitch := _shot_argize("--pitch=")
	var dist := _shot_argize("--dist=")
	if yaw == "" and pitch == "" and dist == "":
		return
	var cam: Camera3D = _orbit_cam if _orbit_cam != null and is_instance_valid(_orbit_cam) else _cam
	if cam == null or not is_instance_valid(cam):
		return
	_shot_camera_pinned = true
	if cam.has_method("snap_pose"):
		var pose: Dictionary = cam.current_pose()
		cam.snap_pose(
			float(yaw) if yaw != "" else float(pose["yaw"]),
			float(pitch) if pitch != "" else float(pose["pitch"]),
			float(dist) if dist != "" else float(pose["distance"]))
		return
	var p := float(pitch) if pitch != "" else atan2(orbit_height - orbit_look_at.y, orbit_radius)
	var y := float(yaw) if yaw != "" else PI * 0.25
	var d := float(dist) if dist != "" else orbit_radius
	cam.position = orbit_look_at + Vector3(cos(p) * sin(y), sin(p), cos(p) * cos(y)) * d
	cam.look_at(orbit_look_at, Vector3.UP)


func _demo_pause() -> float:
	return 0.6


func _shot_pause() -> float:
	return 0.25


func _sleep(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout


# ---------- 体素就绪（纪律抄 bench_world.gd）----------

func wait_ready(max_frames: int) -> bool:
	for i in max_frames:
		if _world_ready():
			return true
		if i % 120 == 0:
			print("  …等待地形 第 %d 帧 就绪=%s" % [i, str(_world_ready())])
		await get_tree().process_frame
	return _world_ready()


func _world_ready() -> bool:
	if _terrain == null or not is_instance_valid(_terrain):
		return false
	for probe in [Vector3i(0, 20, 0), Vector3i(16, 20, 0), Vector3i(0, 20, 16)]:
		if _terrain.has_data_block(_terrain.voxel_to_data_block(probe)):
			return true
	return false


# ---------- 小车 ----------

## 小车走到目标位（带一点 Q 弹小跳）。逐帧插值，纯显示，不接物理。
func codex_goto(target: Vector3, seconds := 0.8) -> void:
	var cart := get_node("Workstation/CodexCart") as Node3D
	var from := cart.global_position
	var frames := maxi(4, int(seconds * 30.0))
	for i in range(1, frames + 1):
		var k := float(i) / float(frames)
		var p := from.lerp(target, k)
		p.y += sin(k * PI) * 0.22
		cart.global_position = p
		await get_tree().process_frame
	cart.global_position = target
	_face_cart(cart, target)


## 小车朝向（子类必填：各自盯的组件不同）。
func _face_cart(cart: Node3D, target: Vector3) -> void:
	pass


# ---------- 空格 run_toggle 语义（子类按需覆写）----------

func _on_run_started() -> void:
	run_drive_count += 1
	run_drive_toggled.emit(true)


func _on_run_stopped() -> void:
	run_drive_count += 1
	run_drive_toggled.emit(false)


# ---------- 交互 hub 辅助 ----------

## hub 的 entity_of 回调：物件 → 状态层实体 id（拾取代理与散块带 meta）。
func _entity_id_of(node: Node3D) -> String:
	if node != null and node.has_meta("entity_id"):
		return str(node.get_meta("entity_id"))
	return ""   # hub 兜底用节点名


# ---------- 材质快捷 ----------

func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	return WorldBuilder.mat(color, roughness, metallic)


func _finish_added_mesh(node: Node) -> void:
	if node is MeshInstance3D and is_ancestor_of(node):
		_finish_mesh_deferred.call_deferred(weakref(node))

func _finish_mesh_deferred(reference: WeakRef) -> void:
	var node = reference.get_ref()
	if node != null: Surface.apply(node)

func _exit_tree() -> void:
	if get_tree().node_added.is_connected(_finish_added_mesh):
		get_tree().node_added.disconnect(_finish_added_mesh)
