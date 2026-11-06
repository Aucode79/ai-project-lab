extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 播放器方块（家族二 player_ 前缀的展示方块；docs/10-契约/方块体系.md）。
## L1 只播**占位内容**：运行时生成一张 1920×1080 占位贴图（纯色 + 画面区/进度条/
## 播放符号都画进像素），幕布上叠加视频区、播放/暂停指示器与状态字。
## **不引真视频文件**——真成片走后续的 studio 管线。
##
## 幕布亮 / 暗 = 自发光能量 + 指示器切换；播放/暂停是纯显示状态，
## 不参与判定（判定只看步记录，见 mini-codex §2.1 的同一条纪律）。

const PLACEHOLDER_TEXT := "L1 · E49 占位视频"
const TEX_W := 1920
const TEX_H := 1080

const SCREEN_SIZE := Vector2(3.5, 2.0)     # 幕面（原 16:9 的 3.6×2.025；为外延落格收成 0.25 整格倍，
										   # 宽高比 1.75:1，与 16:9 差 1.6%，贴图拉伸肉眼不可辨——2026-09-17 口径）
const FRAME_COLOR := Style.SIGNAL
const STAND_COLOR := Style.STRUCTURE

var _playing := false
var _screen_mat: StandardMaterial3D
var _play_indicator: MeshInstance3D
var _pause_indicator: Node3D
var _caption: Label3D
var _title: Label3D


func _ready() -> void:
	_build()
	pause()


# ---------- 对外 API ----------

func play() -> void:
	_set_playing(true)


func pause() -> void:
	_set_playing(false)


func is_playing() -> bool:
	return _playing


func get_title() -> String:
	return PLACEHOLDER_TEXT


# ---------- 内部 ----------

func _set_playing(v: bool) -> void:
	_playing = v
	_screen_mat.emission_energy_multiplier = 1.05 if v else 0.0
	_play_indicator.visible = v
	_pause_indicator.visible = not v
	_caption.text = "正在播放 · 占位内容（不引真视频）" if v else "待播放"


## 1920×1080 占位贴图：纯色底 + 标题条 + 视频区 + 进度条 + 中央播放符号。
## 全部 CPU 像素绘制，无渲染依赖（headless 也能生成，判定不依赖它）。
func _make_placeholder_texture() -> ImageTexture:
	var img := Image.create_empty(TEX_W, TEX_H, false, Image.FORMAT_RGB8)
	img.fill(Color(0.17, 0.15, 0.12))                                   # 暖深灰底
	img.fill_rect(Rect2i(0, 0, TEX_W, 128), Color(0.498, 0.851, 0.659))   # 顶部标题条（薄荷绿）
	img.fill_rect(Rect2i(48, 178, TEX_W - 96, 12), Color(0.29, 0.27, 0.22))
	img.fill_rect(Rect2i(240, 300, 1440, 560), Color(0.22, 0.20, 0.16))  # 视频区
	# 视频区四角小标记（"画面范围"的可读暗示）
	for c in [Vector2i(240, 300), Vector2i(1680, 300), Vector2i(240, 860), Vector2i(1680, 860)]:
		img.fill_rect(Rect2i(c.x, c.y, 24, 24), Color(0.498, 0.851, 0.659))
	# 中央播放符号（右指三角形，逐行加宽）
	var tri_top := 480
	var tri_h := 200
	var tri_left := 880
	for r in tri_h:
		var w := int(float(r) * 0.9) + 4
		img.fill_rect(Rect2i(tri_left, tri_top + r, w, 1), Color(0.949, 0.894, 0.753))
	# 底部进度条（已播约 1/3）
	img.fill_rect(Rect2i(240, 948, 1440, 18), Color(0.29, 0.27, 0.22))
	img.fill_rect(Rect2i(240, 948, 480, 18), Color(0.498, 0.851, 0.659))
	return ImageTexture.create_from_image(img)


func _build() -> void:
	# 底座 + 支柱（六面落 0.25 格：底 1.5×0.25×1.0、柱 0.25 方柱心 (0.125,·,0.125)——2026-09-17 口径）
	# 底座 z 心前移到 0.25（z 面 -0.25..0.75）：整件 z 向占 1.0 m 整格，视图居中偏移才落格
	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := BoxMesh.new()
	base_mesh.size = Vector3(1.5, 0.25, 1.0)
	base.mesh = base_mesh
	base.position = Vector3(0.0, 0.125, 0.25)
	base_mesh.material = _mat(STAND_COLOR, 0.6, 0.2)
	add_child(base)

	var post := MeshInstance3D.new()
	post.name = "Post"
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.25, 1.0, 0.25)
	post.mesh = post_mesh
	post.position = Vector3(0.125, 0.75, 0.125)
	post_mesh.material = _mat(STAND_COLOR, 0.6, 0.2)
	add_child(post)

	# 幕布边框（描边 0.25、厚 0.25；与幕布同心 (0, 2.5)，y 面 1.25..3.75 落格）
	var frame := MeshInstance3D.new()
	frame.name = "ScreenFrame"
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(SCREEN_SIZE.x + 0.5, SCREEN_SIZE.y + 0.5, 0.25)
	frame.mesh = frame_mesh
	frame.position = Vector3(0.0, 2.5, 0.125)
	frame_mesh.material = _mat(FRAME_COLOR, 0.45, 0.1)
	add_child(frame)

	# 幕布：**竖直的方块面板**（不是无厚度的平面），厚 0.25、贴在边框前沿上（z 面 0.25..0.5 落格），
	# 与边框同心 (0, 2.5)（六面落格 + 不歪——2026-09-17 口径）。
	# 改前是 PlaneMesh —— Godot 的 PlaneMesh 默认 orientation = FACE_Y，也就是**水平**的一片；
	# 实测它的 AABB 是 (3.6, 0, 2.025)：厚度为 0，2.025 那条边躺在 Z 上，整片从边框前后穿出来。
	# 换成盒子既修掉这个朝向 bug，也满足"资产一律由方块组成"（2026-09-16 口径）。
	var screen := MeshInstance3D.new()
	screen.name = "Screen"
	var screen_mesh := BoxMesh.new()
	screen_mesh.size = Vector3(SCREEN_SIZE.x, SCREEN_SIZE.y, 0.25)
	screen.mesh = screen_mesh
	screen.position = Vector3(0.0, 2.5, 0.375)
	var tex := _make_placeholder_texture()
	_screen_mat = StandardMaterial3D.new()
	_screen_mat.albedo_texture = tex
	_screen_mat.roughness = 0.35
	_screen_mat.metallic = 0.0
	_screen_mat.emission_enabled = true
	_screen_mat.emission_texture = tex
	_screen_mat.emission_energy_multiplier = 0.0
	screen_mesh.material = _screen_mat
	add_child(screen)

	# 占位标题（Label3D，贴在幕布上——"界面上不放东西，世界里有东西"）
	_title = Label3D.new()
	_title.name = "ScreenLabel"
	_title.text = PLACEHOLDER_TEXT
	_title.position = Vector3(0.0, 2.34, 0.385)   # 幕布前沿 0.375，字悬出 0.01（同原 0.09/0.07 的出露量）
	_title.font_size = 72
	_title.pixel_size = 0.0032
	_title.modulate = Color(0.95, 0.97, 0.99)
	_title.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_title.double_sided = false
	_title.no_depth_test = false
	add_child(_title)

	# 播放指示（三角，薄荷绿发光）
	_play_indicator = MeshInstance3D.new()
	_play_indicator.name = "PlayIndicator"
	# 播放指示用方块（不再用 PrismMesh 三角）：与暂停的双条靠**块数**区分 —— 播放 1 块 / 暂停 2 块
	# 0.5 m 标准方块、嵌进幕布一半（z 面 0.25..0.75 骑在幕布前沿 0.5 上，六面落格口径）
	var play_mesh := BoxMesh.new()
	play_mesh.size = Vector3(0.5, 0.5, 0.5)
	_play_indicator.mesh = play_mesh
	_play_indicator.rotation_degrees = Vector3(0.0, 0.0, -90.0)
	_play_indicator.position = Vector3(-1.25, 1.75, 0.5)
	var play_mat := StandardMaterial3D.new()
	play_mat.albedo_color = Color(0.498, 0.851, 0.659)
	play_mat.emission_enabled = true
	play_mat.emission = Color(0.498, 0.851, 0.659)
	play_mat.emission_energy_multiplier = 1.35
	play_mesh.material = play_mat
	add_child(_play_indicator)

	# 暂停指示（双杠；0.5 m 标准块 ×2、间隙 0.5，六面落格口径）
	_pause_indicator = Node3D.new()
	_pause_indicator.name = "PauseIndicator"
	_pause_indicator.position = Vector3(-0.75, 1.75, 0.5)
	for side in [-0.5, 0.5]:
		var bar := MeshInstance3D.new()
		var bar_mesh := BoxMesh.new()
		bar_mesh.size = Vector3(0.5, 0.5, 0.5)
		bar.mesh = bar_mesh
		bar.position = Vector3(side, 0.0, 0.0)
		var bar_mat := StandardMaterial3D.new()
		bar_mat.albedo_color = Color(0.95, 0.97, 0.99)
		bar_mat.emission_enabled = true
		bar_mat.emission = Color(0.85, 0.89, 0.93)
		bar_mat.emission_energy_multiplier = 1.2
		bar_mesh.material = bar_mat
		_pause_indicator.add_child(bar)
	add_child(_pause_indicator)

	# 状态字（幕布下方）
	_caption = Label3D.new()
	_caption.name = "PlayerCaption"
	_caption.position = Vector3(0.0, 0.62, 0.265)   # 柱前沿 0.25，字悬出 0.015（柱心随落格挪到 x/z +0.125）
	_caption.font_size = 36
	_caption.pixel_size = 0.003
	_caption.modulate = Color(0.30, 0.26, 0.22)
	_caption.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_caption.double_sided = false
	add_child(_caption)


func _mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m
