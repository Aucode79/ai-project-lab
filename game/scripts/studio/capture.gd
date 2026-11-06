extends SceneTree

## studio.capture —— 资产片段捕获（spec §3.4 捕获规范 / §8 管线第一步）。
##
## SceneTree 脚本（-s 跑），必须配合 Godot Movie Maker 由壳脚本调起
## （tools/production/capture.sh：负责 --write-movie/--fixed-fps 与临时 override.cfg）：
##
##   $GODOT --path game --resolution 1920x1080 --fixed-fps 25 \
##     --write-movie <repo>/assets/<assetId>/<机位>_<动作>/frame.png \
##     -s res://scripts/studio/capture.gd -- \
##       --asset=<assetId> --shot=<机位> --action=<动作> --duration=<秒> [--task-text=...]
##         [--margin=<倍>]
##
## 行为：
##   * --asset 两种取件方式：assets/<assetId>/asset.yaml 的 scene: 行指到 tscn
##     （conc_* 组件场景在 game/scenes/levels/<关>/components/ 下；缺 scene 行回退
##     res://scenes/assets/<assetId>.tscn）；<assetId> 是工坊件 id（agent_* / code_* /
##     studio_*）时改由 component_catalog 现搭——工坊 26 件没有独立 tscn，
##     外形真源就是那份几何表（微课的 3D 插入镜头取这条）
##   * 实例化资产，按机位词表（iso/front/top/close/vista，§3.4）对资产 AABB 取景
##   * 透明清屏：环境 background_mode=BG_COLOR（全透明）+ 保留天空仅作环境光，
##     不渲天空、关雾、关 glow（bloom 会污染透明像素）
##   * 动作词表：idle 静止展示；run 若资产有 set_state_visual() 则按
##     待命→正在→完成 派生显示走一轮（组件不另做状态机的口径不变）；
##     spin（慢速旋转展示）录制期间相机绕资产 AABB center 水平慢旋，elapsed/duration
##     走满一圈（yaw = TAU * t），pitch 与半径沿用当前机位取景，微课"拉出来转着讲"用
##   * --margin 在词表取景上再放一圈留白（缺省 1.0 = 逐字照旧）。做成卡片插图时
##     件会被画面边切到，prep_plates.py 的 trim 会拒绝缺角图，此时给 --margin=1.35
##   * Movie Writer 固定 25 fps 写 alpha PNG，写满 duration*25 帧后 quit(0)，
##     结尾打印逐帧墙钟统计（对照 docs/20-验收/测量结果.md"写盘是瓶颈"口径）


const FPS := 25
const Catalog := preload("res://scripts/asset_lib/component_catalog.gd")
const SHOT_WORDS := ["iso", "front", "top", "close", "vista"]
const ACTION_WORDS := ["idle", "run", "open", "close", "fail", "spin"]

var _asset_id := ""
var _shot := "iso"
var _action := "idle"
var _duration := 3.0
var _margin := 1.0
var _task_text := ""

var _target := 75
var _frame := 0
var _t0_us := 0
var _last_us := 0
var _asset_root: Node3D = null
var _run_state := ""
var _wall_ms: Array[float] = []

# spin 旋转展示的取景基准（_add_camera 里按当前机位记下，_update_camera 每帧重建 transform）
var _cam: Camera3D = null
var _orbit_center := Vector3.ZERO
var _orbit_radius := 0.0
var _orbit_height := 0.0
var _orbit_yaw0 := 0.0
var _orbit_up := Vector3.UP


func _initialize() -> void:
	if not _parse_args():
		quit(2)
		return
	if Engine.get_write_movie_path() == "":
		push_error("capture.gd 必须配合 --write-movie 运行（用 tools/production/capture.sh 调起）")
		quit(2)
		return
	_target = int(round(_duration * FPS))
	root.transparent_bg = true
	_build_stage()
	process_frame.connect(_on_frame)
	print("CAPTURE: asset=%s shot=%s action=%s duration=%.1fs → %d 帧 @%dfps" % [
		_asset_id, _shot, _action, _duration, _target, FPS])


func _parse_args() -> bool:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--asset="):
			_asset_id = a.substr(8)
		elif a.begins_with("--shot="):
			_shot = a.substr(7)
		elif a.begins_with("--action="):
			_action = a.substr(9)
		elif a.begins_with("--duration="):
			_duration = float(a.substr(11))
		elif a.begins_with("--margin="):
			_margin = maxf(float(a.substr(9)), 0.1)
		elif a.begins_with("--task-text="):
			_task_text = a.substr("--task-text=".length())
	if _asset_id == "":
		push_error("缺 --asset=<assetId>")
		return false
	if not SHOT_WORDS.has(_shot):
		push_error("机位 %s 不在词表 %s（spec §3.4）" % [_shot, str(SHOT_WORDS)])
		return false
	if not ACTION_WORDS.has(_action):
		push_error("动作 %s 不在词表 %s（spec §3.4）" % [_action, str(ACTION_WORDS)])
		return false
	if _duration <= 0.0:
		push_error("--duration 必须 > 0")
		return false
	return true


# ---------- 场景搭建 ----------

func _build_stage() -> void:
	var stage := Node3D.new()
	stage.name = "CaptureStage"
	root.add_child(stage)

	_asset_root = _load_asset()
	stage.add_child(_asset_root)
	if _task_text != "" and _asset_root.has_method("set_task_text"):
		_asset_root.call("set_task_text", _task_text)

	_add_environment(stage)
	_add_lights(stage)
	_add_camera(stage)


## assets/<assetId>/asset.yaml 只取 scene: 行（扁平 YAML，一行一值）。
func _scene_path_for(asset_id: String) -> String:
	var repo := _repo_root()
	var yaml_path := repo.path_join("assets/%s/asset.yaml" % asset_id)
	var fallback := "res://scenes/assets/%s.tscn" % asset_id
	if not FileAccess.file_exists(yaml_path):
		return fallback
	var f := FileAccess.open(yaml_path, FileAccess.READ)
	if f == null:
		return fallback
	var scene_line := ""
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.begins_with("scene:"):
			scene_line = line.substr("scene:".length()).strip_edges()
			break
	f.close()
	if scene_line == "":
		return fallback
	# 仓库相对路径 game/scenes/... → res://scenes/...
	if scene_line.begins_with("game/"):
		scene_line = "res://" + scene_line.substr("game/".length())
	if not scene_line.begins_with("res://"):
		push_error("asset.yaml 的 scene 路径不认识：%s" % scene_line)
		return fallback
	return scene_line


func _load_asset() -> Node3D:
	var catalog_index := Catalog.index_of(_asset_id)
	if catalog_index >= 0:
		var built := Catalog.build_machine(catalog_index)
		print("CAPTURE: 工坊件 %s（component_catalog 索引 %d）" % [_asset_id, catalog_index])
		return built
	var path := _scene_path_for(_asset_id)
	var packed := load(path) as PackedScene
	if packed == null:
		push_error("无法加载资产场景 %s" % path)
		quit(3)
		return Node3D.new()
	var node := packed.instantiate() as Node3D
	if node == null:
		push_error("资产场景根节点不是 Node3D：%s" % path)
		quit(3)
		return Node3D.new()
	print("CAPTURE: 场景 %s" % path)
	return node


func _repo_root() -> String:
	# res:// 指向 game/，仓库根再上一级
	var proj := ProjectSettings.globalize_path("res://")
	return proj.get_base_dir().get_base_dir()


func _add_environment(parent: Node3D) -> void:
	# 光照与主题一致（bench_world.gd 粉彩沙盘同款），但背景改透明清屏：
	# 天空仍挂在 env 上仅作环境光源，background_mode=BG_COLOR(0,0,0,0) 不渲天空；
	# 雾关（雾色会糊进 alpha），glow 关（bloom 写进透明像素污染边缘）。
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.549, 0.745, 0.918)
	sky_mat.sky_horizon_color = Color(0.949, 0.914, 0.863)
	sky_mat.ground_bottom_color = Color(0.910, 0.863, 0.784)
	sky_mat.ground_horizon_color = Color(0.941, 0.902, 0.839)
	sky_mat.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.sky = sky
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.80

	env.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
	env.tonemap_white = 4.0
	env.tonemap_exposure = 1.00

	env.ssao_enabled = true
	env.ssao_intensity = 1.35
	env.ssao_radius = 1.8

	env.glow_enabled = false
	env.fog_enabled = false

	env.adjustment_enabled = true
	env.adjustment_saturation = 1.30
	env.adjustment_contrast = 1.06
	env.adjustment_brightness = 0.93

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	parent.add_child(we)


func _add_lights(parent: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 2.3
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.5
	sun.directional_shadow_max_distance = 60.0
	sun.rotation_degrees = Vector3(-48.0, 45.0, 0.0)
	parent.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.95, 0.90, 0.85)
	fill.light_energy = 0.70
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-26.0, -125.0, 0.0)
	parent.add_child(fill)


func _add_camera(parent: Node3D) -> void:
	var box := _world_aabb(_asset_root)
	if box.size == Vector3.ZERO:
		box = AABB(Vector3(-1, 0, -1), Vector3(2, 3, 2))
	var center := box.get_center()
	var r := maxf(box.size.length() * 0.5, 0.5)

	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.near = 0.05
	cam.far = maxf(r * 40.0, 100.0)
	var up := Vector3.UP

	match _shot:
		"iso":
			# 正交等距（讲结构用）：经典 (1,1,1) 方向 + 包围球取景
			var dir := Vector3(1, 1, 1).normalized()
			cam.projection = Camera3D.PROJECTION_ORTHOGONAL
			cam.size = 2.1 * r * _margin
			cam.position = center + dir * (4.0 * r)
		"front":
			var dir := Vector3(0, 0.16, 1).normalized()
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.fov = 35.0
			cam.position = center + dir * (r / tan(deg_to_rad(17.5)) * 1.25 * _margin)
		"top":
			var dir := Vector3(0.001, 1, 0.001).normalized()
			up = Vector3(0, 0, -1)
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.fov = 40.0
			cam.position = center + dir * (r / tan(deg_to_rad(20.0)) * 1.25 * _margin)
		"close":
			var dir := Vector3(0.6, 0.35, 1).normalized()
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.fov = 30.0
			cam.position = center + dir * (r / tan(deg_to_rad(15.0)) * 0.85 * _margin)
		"vista":
			var dir := Vector3(0, 0.25, 1).normalized()
			cam.projection = Camera3D.PROJECTION_PERSPECTIVE
			cam.fov = 50.0
			cam.position = center + dir * (r / tan(deg_to_rad(25.0)) * 4.0 * _margin)
	# _initialize 时机节点尚未进树，look_at() 会拒绝；用 Basis.looking_at 纯数学定向
	cam.transform = Transform3D(Basis.looking_at((center - cam.position).normalized(), up), cam.position)
	parent.add_child(cam)
	cam.current = true

	# 记下取景基准供 spin 复现：水平半径 / 高度 / 起始 yaw 都从当前机位偏移量分解而来，
	# 故旋转只改 yaw、pitch 与距离逐字沿用机位取景（不正交机位的 up 也一并沿用）。
	_cam = cam
	_orbit_center = center
	var off := cam.position - center
	_orbit_radius = sqrt(off.x * off.x + off.z * off.z)
	_orbit_height = off.y
	_orbit_yaw0 = atan2(off.x, off.z)
	_orbit_up = up


## AABB 是值类型，用成员变量累计（递归参数传不回父调用）。
var _aabb := AABB()
var _aabb_first := true


func _world_aabb(node: Node3D) -> AABB:
	_aabb = AABB()
	_aabb_first = true
	_collect_aabb(node)
	return _aabb


func _collect_aabb(node: Node) -> void:
	if node is MeshInstance3D:
		var mi := node as MeshInstance3D
		var wb: AABB = mi.get_global_transform() * mi.get_aabb()
		if _aabb_first:
			_aabb = wb
			_aabb_first = false
		else:
			_aabb = _aabb.merge(wb)
	for child in node.get_children():
		_collect_aabb(child)


# ---------- 帧循环 ----------

func _on_frame() -> void:
	var now := Time.get_ticks_usec()
	if _frame == 0:
		_t0_us = now
		_last_us = now
	var wall_ms := float(now - _last_us) / 1000.0
	_last_us = now
	_wall_ms.append(wall_ms)
	_frame += 1

	_update_action()
	_update_camera()

	if _frame % 25 == 0:
		print("CAPTURE: %d/%d 帧（mean %.1f ms/帧）" % [
			_frame, _target, _mean(_wall_ms)])
	if _frame >= _target:
		_finish()


func _update_action() -> void:
	if _action != "run" or _asset_root == null:
		return
	if not _asset_root.has_method("set_state_visual"):
		return
	# 一次完整运转（run）：状态显示按帧派生走 待命→正在→完成
	# （task_board.gd 的口径：状态只改显示，不存状态变量）
	var frac := float(_frame) / float(_target)
	var state := "idle"
	if frac >= 0.7:
		state = "done"
	elif frac >= 0.3:
		state = "running"
	if state != _run_state:
		_run_state = state
		_asset_root.call("set_state_visual", state)


## spin（慢速旋转展示）：只改 yaw，绕 AABB center 水平慢旋一整圈；
## elapsed/duration 走满一圈（TAU * t），pitch 与半径来自当前机位取景。
func _update_camera() -> void:
	if _action != "spin" or _cam == null:
		return
	var t := float(_frame) / float(_target)
	var yaw := _orbit_yaw0 + TAU * t
	var pos := _orbit_center + Vector3(sin(yaw) * _orbit_radius, _orbit_height, cos(yaw) * _orbit_radius)
	_cam.transform = Transform3D(Basis.looking_at((_orbit_center - pos).normalized(), _orbit_up), pos)


func _finish() -> void:
	var total_s := float(Time.get_ticks_usec() - _t0_us) / 1000000.0
	var bytes := 0
	var frames_on_disk := 0
	var out_dir := Engine.get_write_movie_path().get_base_dir()
	for fname in DirAccess.get_files_at(out_dir):
		if fname.ends_with(".png"):
			frames_on_disk += 1
			var pf := FileAccess.open(out_dir.path_join(fname), FileAccess.READ)
			if pf != null:
				bytes += int(pf.get_length())
				pf.close()
	print("CAPTURE DONE: %d 帧 @%dfps，%.2fs 墙钟（mean %.1f ms/帧，含 PNG 写盘）" % [
		frames_on_disk, FPS, total_s, _mean(_wall_ms)])
	print("CAPTURE DONE: 落盘 %d 帧 / %.2f MB → %s" % [
		frames_on_disk, float(bytes) / 1048576.0, out_dir])
	quit(0)


func _mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var s := 0.0
	for v in values:
		s += v
	return s / float(values.size())
