class_name OrbitCamera
extends Camera3D
# 类型走 preload（不依赖 .godot 全局类缓存，headless -s 直跑可解析）
const IC := preload("res://scripts/interaction/interaction_config.gd")

## 第三人称轨道相机（docs/10-契约/美术方向.md 相机路线裁决：Besiege 式，相机是玩家的工具）。
##
##   鼠标移动   = 视角（绕主体旋转）
##   右键拖动   = 平移（挪注视点，不动主体）
##   滚轮       = 缩放
##   Tab        = 预设位轮换 iso / front / top / close / vista（存姿态，平滑 Tween 过渡）
##
## iso 预设是正交等距（讲机制用），其余透视；预设只是存下来的机位姿态，不是限制。

const PRESET_ORDER: Array[String] = ["iso", "front", "top", "close", "vista"]

var config: IC

## 注视主体（轨道中心）。pan 平移的是内部枢轴偏移，绝不移动主体本身。
var target: Node3D = null
## 拖物件时宿主把视角旋转关掉，避免拖拽中镜头乱转。
var look_enabled := true
var orbit_requires_middle := false
var _orbiting := false

var _yaw := 0.7854          # 45°
var _pitch := 0.55
var _distance := 14.0
var _pivot_offset := Vector3.ZERO
var _panning := false
var _tween: Tween = null
var _preset_index := 0
var presets: Dictionary = {}


func _init(cfg: IC = null) -> void:
	config = cfg if cfg != null else IC.new()
	_make_default_presets()


func _ready() -> void:
	make_current()
	_apply_pose()


# ---------- 预设位 ----------

func _make_default_presets() -> void:
	presets = {
		# 正交等距：经典 35.264° 俯角，结构最可读（美术方向 §一的手段①）
		"iso": {"yaw": deg_to_rad(45.0), "pitch": deg_to_rad(35.264), "distance": 18.0,
			"ortho": true, "size": 10.0},
		"front": {"yaw": 0.0, "pitch": 0.10, "distance": 14.0, "ortho": false},
		"top": {"yaw": 0.0, "pitch": 1.52, "distance": 16.0, "ortho": false},
		"close": {"yaw": deg_to_rad(30.0), "pitch": 0.35, "distance": 5.0, "ortho": false},
		"vista": {"yaw": deg_to_rad(-60.0), "pitch": 0.25, "distance": 40.0, "ortho": false},
	}


func preset_names() -> Array[String]:
	return PRESET_ORDER.duplicate()


## Tab：切到下一个预设位。返回切到的名字。
func cycle_preset() -> String:
	_preset_index = (_preset_index + 1) % PRESET_ORDER.size()
	return switch_preset(PRESET_ORDER[_preset_index])


## 平滑过渡到某个预设位（Tween，TRANS_CUBIC / EASE_OUT）。返回名字；未知名字返回 ""。
func switch_preset(preset_name: String) -> String:
	if not presets.has(preset_name):
		return ""
	_kill_tween()
	var to: Dictionary = presets[preset_name]
	var idx := PRESET_ORDER.find(preset_name)
	if idx >= 0:
		_preset_index = idx
	var from := {"yaw": _yaw, "pitch": _pitch, "distance": _distance, "focus_offset": _pivot_offset}
	var goal := {
		"yaw": from["yaw"] + wrapf(float(to["yaw"]) - from["yaw"], -PI, PI),
		"pitch": float(to["pitch"]),
		"distance": float(to["distance"]),
		"focus_offset": to.get("focus_offset", _pivot_offset),
	}
	_tween = create_tween()
	_tween.tween_method(_lerp_pose.bind(from, goal), 0.0, 1.0,
		config.preset_transition_s).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.finished.connect(_finish_preset.bind(to))
	return preset_name


func transitioning() -> bool:
	return _tween != null and _tween.is_valid() and _tween.is_running()


## 直接就位，不走补间。进场机位用它：开局从默认姿态动画到工作机位没有意义
## （那一秒的过渡帧没人要看），而且一旦补间被后续输入打断（orbit/zoom 都会
## kill 掉它），相机会永远停在默认姿态——实测进场机位的补间就是没跑完，
## 沙盒的首帧因此停在了 14 m 的默认距离上。
func snap_preset(preset_name: String) -> String:
	if not presets.has(preset_name):
		return ""
	_kill_tween()
	var to: Dictionary = presets[preset_name]
	var idx := PRESET_ORDER.find(preset_name)
	if idx >= 0:
		_preset_index = idx
	_yaw = float(to["yaw"])
	_pitch = float(to["pitch"])
	_distance = float(to["distance"])
	_finish_preset(to)
	return preset_name


## 直接摆到指定球坐标姿态（不留补间）。美术取证用：--shot 的 --yaw/--pitch/--dist
## 要的就是"同机位对照"，机位必须是精确给定的值，不能是补间途中的某一帧。
func snap_pose(yaw: float, pitch: float, distance: float) -> void:
	_kill_tween()
	_yaw = wrapf(yaw, -PI, PI)
	_pitch = clampf(pitch, -0.2, 1.52)
	_distance = clampf(distance, 2.0, 90.0)
	_apply_pose()


## 当前姿态（测试用）：yaw/pitch/distance + 投影。
func current_pose() -> Dictionary:
	return {"yaw": _yaw, "pitch": _pitch, "distance": _distance,
		"ortho": projection == Camera3D.PROJECTION_ORTHOGONAL}


## 当前距离（hub 用它把屏幕点换算成鼠标射线上的世界点）。
func current_distance() -> float:
	return _distance


func _lerp_pose(t: float, from: Dictionary, to: Dictionary) -> void:
	_yaw = lerpf(float(from["yaw"]), float(to["yaw"]), t)
	_pitch = lerpf(float(from["pitch"]), float(to["pitch"]), t)
	_distance = lerpf(float(from["distance"]), float(to["distance"]), t)
	_pivot_offset = (from["focus_offset"] as Vector3).lerp(to["focus_offset"], t)
	_apply_pose()


func _finish_preset(to: Dictionary) -> void:
	_tween = null
	if to.has("focus_offset"):
		_pivot_offset = to["focus_offset"]
	if bool(to.get("ortho", false)):
		projection = Camera3D.PROJECTION_ORTHOGONAL
		size = float(to.get("size", 10.0))
	else:
		projection = Camera3D.PROJECTION_PERSPECTIVE
		# 预设可以自带焦距：长焦的透视更弱，箱庭/微缩读感一半来自这里
		fov = float(to.get("fov", 50.0))
	_apply_pose()


func _kill_tween() -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = null


# ---------- 姿态换算 ----------

func pivot_world() -> Vector3:
	var center := _pivot_offset
	if target != null and is_instance_valid(target):
		center += target.global_position
	return center


func _apply_pose() -> void:
	var pivot := pivot_world()
	var cp := cos(_pitch)
	var offset := Vector3(cp * sin(_yaw), sin(_pitch), cp * cos(_yaw)) * _distance
	global_position = pivot + offset
	look_at(pivot)


# ---------- 输入（真实走 _unhandled_input，测试直接 feed） ----------

func feed(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _panning:
			_pan(mm.relative)
		elif look_enabled and (not orbit_requires_middle or _orbiting):
			orbit(deg_to_rad(mm.relative.x) * 0.25, deg_to_rad(mm.relative.y) * 0.25)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		match mb.button_index:
			MOUSE_BUTTON_MIDDLE:
				_orbiting = mb.pressed
			MOUSE_BUTTON_RIGHT:
				_panning = mb.pressed
			MOUSE_BUTTON_WHEEL_UP:
				zoom_by(0.88)
			MOUSE_BUTTON_WHEEL_DOWN:
				zoom_by(1.14)


func _unhandled_input(event: InputEvent) -> void:
	if get_parent().get_meta("scene_menu_open", false): return
	if event.is_action_pressed("camera_preset_next"):
		cycle_preset()
		get_viewport().set_input_as_handled()
		return
	feed(event)


## 聚焦到世界坐标某点：清掉平移残留后重新摆位。
## 取景算尺寸时必须先调它——否则 _pivot_offset 还留着上次右键平移的偏移，
## 相机看的点与包围盒中心不一致，边角会被裁掉（实测第二页字砖被切）。
func focus_on(point: Vector3) -> void:
	_kill_tween()
	_pivot_offset = Vector3.ZERO
	if target != null and is_instance_valid(target):
		target.position = point
	_apply_pose()


func orbit(delta_yaw: float, delta_pitch: float) -> void:
	_kill_tween()
	_yaw = wrapf(_yaw + delta_yaw, -PI, PI)
	_pitch = clampf(_pitch + delta_pitch, -0.2, 1.52)
	_apply_pose()


func _pan(screen_delta: Vector2) -> void:
	_kill_tween()
	var scale := _distance * 0.0016
	var right := global_transform.basis.x
	var up := global_transform.basis.y
	_pivot_offset += -right * screen_delta.x * scale + up * screen_delta.y * scale
	_apply_pose()


func zoom_by(factor: float) -> void:
	_kill_tween()
	if projection == Camera3D.PROJECTION_ORTHOGONAL:
		# 正交投影下改距离不改变成像大小；必须改 size，否则滚轮看起来失效。
		size = clampf(size * factor, 2.0, 90.0)
	else:
		_distance = clampf(_distance * factor, 2.0, 90.0)
	_apply_pose()
