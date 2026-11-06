extends Node3D

## 第一个 godot_voxel 方块世界。
##
## 美术方向（见 docs/10-契约/美术方向.md）在这一版就带上，不是后补：
##   ① 正交等距镜头 —— 画面读作"微缩沙盘"而不是"我在里面生存"
##   ② 限定调色板   —— 粉彩玩具沙盘：奶油沙地表 + 鼠尾草绿台地镶边 + 薄荷树冠 + 珊瑚平台 + 柔黄核心微辉光，避开 MC 的绿草蓝天土黄
##   ③ 纯色烘色     —— 不用像素贴图，方块颜色由 mesher 烘进网格
##
## 用法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -- --check
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --path game -- --shot

const SHOT_DIR := "res://shots"
const GeneratorScript := preload("res://scripts/terrain_generator.gd")

## 与 terrain_generator.gd 保持一致的常量（粒子要摆在矮灯柱顶端，得知道高度）
const WorldBuilder := preload("res://scripts/scene/world_builder.gd")

# 地形常量与调色板的唯一真源在 world_builder（本文件是 spike 自检场景，只共享常量）
const TERRAIN_BASE_HEIGHT := WorldBuilder.TERRAIN_BASE_HEIGHT
const PLAZA_RADIUS := WorldBuilder.PLAZA_RADIUS
const PLAZA_LIFT := WorldBuilder.PLAZA_LIFT
const PALETTE := WorldBuilder.PALETTE
const EMISSIVE := WorldBuilder.EMISSIVE

var _terrain: VoxelTerrain = null
var _library: VoxelBlockyLibrary = null
var _viewer: VoxelViewer = null
var _cam: Camera3D = null
var _env: Environment = null
var _particle_emitters := 0


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	_build_world()

	if args.has("--check"):
		# 不能等 RenderingServer.frame_post_draw：--headless 下没有渲染，那个信号永不触发
		var got := await _wait_until(func(): return _world_ready(), 600)
		print("等待地形生成：%s" % ("完成" if got else "超时"))
		_do_check()
		get_tree().quit(0)
		return

	if args.has("--shot"):
		await _wait_until(func(): return _world_ready(), 900)
		await _wait_frames(240)     # 再多画几帧，网格化与 AO 才稳定
		await _do_shot()
		get_tree().quit(0)
		return


func _wait_frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame


func _wait_until(pred: Callable, max_frames: int) -> bool:
	for i in max_frames:
		if pred.call():
			return true
		if i % 60 == 0:
			print("  …等待中 第 %d 帧，地块就绪 %s" % [i, str(_world_ready())])
		await get_tree().process_frame
	return pred.call()


func _world_ready() -> bool:
	# 别读 get_statistics()：VoxelTerrain 的统计里根本没有 mesh_blocks 这类键，
	# 按不存在的键去数会永远得到 0，看起来像"没生成"，其实是测错了指标。
	# 直接问地形：原点附近那几个数据块到底有没有数据。
	if _terrain == null or not is_instance_valid(_terrain):
		return false
	for probe in [Vector3i(0, 20, 0), Vector3i(16, 20, 0), Vector3i(0, 20, 16)]:
		if _terrain.has_data_block(_terrain.voxel_to_data_block(probe)):
			return true
	return false


# ---------- 世界搭建 ----------

func _build_world() -> void:
	# GDExtension 版本必须往场景里放一个 VoxelEngineUpdater。
	# 扩展挂不进引擎主循环，没有这个节点逐帧驱动 VoxelEngine，
	# 异步任务永远不完成——症状是 time_request_blocks_to_load 有值、
	# process_load_responses 恒为 0、网格块永远 0，看起来像卡死。
	var updater := VoxelEngineUpdater.new()
	updater.name = "VoxelEngineUpdater"
	add_child(updater)

	_library = _build_library()
	_add_environment()
	_add_sun()
	_add_particles()
	_add_camera()          # 先建相机，再建观察者与地形
	_add_terrain()


func _build_library() -> VoxelBlockyLibrary:
	var lib := VoxelBlockyLibrary.new()

	# 0 号必须是空气，VoxelBuffer 里 0 表示空
	var air := VoxelBlockyModelEmpty.new()
	lib.add_model(air)

	for i in range(1, PALETTE.size()):
		var cube := VoxelBlockyModelCube.new()
		cube.color = PALETTE[i]
		cube.culls_neighbors = true

		# 颜色走每个模型自己的材质，而不是 TINT_RAW_COLOR。
		# TINT_RAW_COLOR 会去读体素数据的颜色通道，那个通道没配深度就直接报
		# "Color channel depth not supported"，网格化整个卡死。
		#
		# 注意：material_override 的索引只有 2 个槽（不是立方体的 6 个面），
		# 传 0..5 会报 "Index out of bounds (size = 2)"。
		var mat := _block_material(i)
		cube.set_material_override(0, mat)

		lib.add_model(cube)

	return lib


func _block_material(i: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = PALETTE[i]
	m.vertex_color_use_as_albedo = true   # 让 mesher 烘进去的 AO 生效
	if EMISSIVE.has(i):
		# 发光方块：金属度归零、粗糙度压低，核心亮点走发光+轻微后处理辉光
		m.emission_enabled = true
		m.emission = PALETTE[i]
		m.emission_energy_multiplier = float(EMISSIVE[i])
		m.roughness = 0.60
		m.metallic = 0.0
	else:
		# 结构方块零金属度，读作"哑光玩具塑料"而不是金属加工件
		m.roughness = 0.80
		m.metallic = 0.0
	return m


func _add_terrain() -> void:
	var terrain := VoxelTerrain.new()
	terrain.name = "Terrain"
	terrain.mesh_block_size = 16
	terrain.max_view_distance = 256
	terrain.generate_collisions = false     # 这一版只做画面，不接物理
	# 先用内置的 C++ 生成器做判别实验：如果它能出地形，说明卡点在脚本生成器的异步路径上。
	terrain.generator = _make_generator()

	var mesher := VoxelMesherBlocky.new()
	mesher.library = _library
	mesher.tint_mode = VoxelMesherBlocky.TINT_NONE   # 颜色在模型的材质上，不走体素颜色通道
	mesher.occlusion_enabled = true                  # 烘焙 AO，方块之间的暗缝靠它
	mesher.occlusion_darkness = 0.35
	terrain.mesher = mesher

	_terrain = terrain
	add_child(terrain)


func _make_generator() -> VoxelGenerator:
	# 用自己写的分层生成器：表层/土/岩分层 + 原点附近的机器平台。
	# 内置的 VoxelGeneratorNoise2D 只写单一实心类型，没有配色可言。
	return GeneratorScript.new()


func _add_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "Camera"

	# ① 正交等距：投影方式一换，观感立刻从"第一人称生存"变成"微缩沙盘"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 74.0
	cam.near = 0.1
	cam.far = 600.0
	cam.position = Vector3(94.0, 36.0, 94.0)
	add_child(cam)
	cam.look_at(Vector3(0.0, 14.0, 0.0), Vector3.UP)
	cam.current = true
	_cam = cam

	# VoxelTerrain 靠 VoxelViewer 决定加载哪块区域。
	# 注意：viewer 不能挂在远处的正交相机上——相机的 Y 远高于地形 bounds，
	# 需求区被 bounds 裁掉之后会变成空，表现就是"请求了但永远不生成"。
	# 正确做法是把它当作"玩家"放在世界里。
	var anchor := Node3D.new()
	anchor.name = "ViewerAnchor"
	anchor.position = Vector3(0.0, 20.0, 0.0)
	add_child(anchor)

	var viewer := VoxelViewer.new()
	viewer.name = "Viewer"
	viewer.view_distance = 96
	viewer.requires_visuals = true
	viewer.requires_collisions = false
	anchor.add_child(viewer)
	_viewer = viewer


func _add_environment() -> void:
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.549, 0.745, 0.918)
	sky_mat.sky_horizon_color = Color(0.949, 0.914, 0.863)
	sky_mat.ground_bottom_color = Color(0.910, 0.863, 0.784)
	sky_mat.ground_horizon_color = Color(0.941, 0.902, 0.839)
	sky_mat.sun_angle_max = 20.0

	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.80

	env.tonemap_mode = Environment.TONE_MAPPER_REINHARDT
	env.tonemap_white = 4.0
	env.tonemap_exposure = 1.00

	env.ssao_enabled = true
	env.ssao_intensity = 1.35
	env.ssao_radius = 1.8

	# 微辉光：低强度衬托核心发光，不做泛光 bloom（粉彩哑光风）
	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_bloom = 0.02
	env.glow_hdr_threshold = 1.30
	env.glow_strength = 0.95

	env.fog_enabled = true
	env.fog_light_color = Color(0.941, 0.914, 0.863)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0002
	env.fog_sky_affect = 0.20
	env.fog_aerial_perspective = 0.10

	env.adjustment_enabled = true
	env.adjustment_saturation = 1.30
	env.adjustment_contrast = 1.06
	env.adjustment_brightness = 0.93

	_env = env
	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)


func _add_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 2.3
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.5
	sun.directional_shadow_max_distance = 320.0
	# 方位角要对着相机那一侧（相机在 +X+Z），否则整个地形逆光发黑
	sun.rotation_degrees = Vector3(-48.0, 45.0, 0.0)
	add_child(sun)

	# 补光用暖白而不是冷蓝：亮场景的暗面该是"暖灰"，不是"死黑"
	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.95, 0.90, 0.85)
	fill.light_energy = 0.70
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-26.0, -125.0, 0.0)
	add_child(fill)


## 小颗粒飘浮粒子：用来替代"刺眼的光源"。
## 要点是**小、多、慢、淡**——颗粒直径 0.22，每座矮灯柱 64 颗，
## 缓慢上浮淡出，读作"这台机器在运转"，而不是"这里挂了个灯泡"。
func _add_particles() -> void:
	for a in [
		Vector2(-PLAZA_RADIUS + 1, -PLAZA_RADIUS + 1),
		Vector2(PLAZA_RADIUS - 1, -PLAZA_RADIUS + 1),
		Vector2(-PLAZA_RADIUS + 1, PLAZA_RADIUS - 1),
		Vector2(PLAZA_RADIUS - 1, PLAZA_RADIUS - 1),
	]:
		var emitter := _make_spark_emitter()
		# 灯柱核心顶部＝地形基准高 + 平台抬升 + 柱身 1 + 核心 1
		emitter.position = Vector3(a.x, float(TERRAIN_BASE_HEIGHT + PLAZA_LIFT + 2) + 0.6, a.y)
		add_child(emitter)
		_particle_emitters += 1


func _make_spark_emitter() -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.name = "Sparks"
	p.amount = 64
	p.lifetime = 4.5
	p.preprocess = 3.0
	p.randomness = 0.6
	p.local_coords = false

	var proc := ParticleProcessMaterial.new()
	proc.direction = Vector3(0, 1, 0)
	proc.spread = 32.0
	proc.initial_velocity_min = 0.12
	proc.initial_velocity_max = 0.40
	proc.gravity = Vector3(0, 0.06, 0)
	proc.scale_min = 0.5
	proc.scale_max = 1.3
	proc.color = Color(1.0, 0.96, 0.86, 0.75)
	p.process_material = proc

	# 正交相机下 1 世界单位 ≈ 10 像素，所以 0.22 的颗粒大约是 2 像素。
	# 给 0.085 会小到 0.8 像素，等于看不见——"小"不等于"不可见"。
	var quad := QuadMesh.new()
	quad.size = Vector2(0.22, 0.22)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.disable_receive_shadows = true
	mat.albedo_color = Color(1.0, 0.96, 0.86, 0.80)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.96, 0.86)
	mat.emission_energy_multiplier = 0.6
	quad.material = mat

	p.draw_pass_1 = quad
	p.emitting = true
	return p


# ---------- 两种模式 ----------

func _do_check() -> void:
	var ok := true
	var report: Array[String] = []

	ok = _expect(_terrain != null and is_instance_valid(_terrain), "VoxelTerrain 已建立", report) and ok
	ok = _expect(_terrain.generator != null, "generator 已挂（地形直接走生成器，不挂 stream）", report) and ok
	ok = _expect(_terrain.mesher != null, "mesher 已挂", report) and ok
	var colored := 0
	for i in range(1, _library.get_models().size()):
		var mdl := _library.get_model(i) as VoxelBlockyModel
		if mdl != null and mdl.get_material_override(0) != null:
			colored += 1
	ok = _expect(colored == PALETTE.size() - 1,
		"每种方块都带自己的材质（%d/%d）" % [colored, PALETTE.size() - 1], report) and ok
	ok = _expect(_library != null and _library.get_models().size() == PALETTE.size(),
		"方块库模型数 = %d（实际 %d）" % [PALETTE.size(), _library.get_models().size() if _library else -1], report) and ok

	var mesher := _terrain.mesher as VoxelMesherBlocky
	ok = _expect(mesher != null and mesher.get_tint_mode() == VoxelMesherBlocky.TINT_NONE,
		"mesher 不走体素颜色通道（避开 tint sampler 报错）", report) and ok
	ok = _expect(mesher != null and mesher.get_occlusion_enabled(),
		"mesher 开启烘焙 AO", report) and ok
	ok = _expect(mesher != null and mesher.get_library() != null, "mesher 已绑定方块库", report) and ok

	ok = _expect(_cam != null and _cam.projection == Camera3D.PROJECTION_ORTHOGONAL,
		"相机是正交投影（微缩沙盘感）", report) and ok
	ok = _expect(_viewer != null and _viewer.get_view_distance() > 0 and _viewer.is_requiring_visuals(),
		"VoxelViewer 就位且要求视觉", report) and ok
	ok = _expect(_env != null and _env.ssao_enabled and _env.fog_enabled, "SSAO 与距离雾已开", report) and ok
	ok = _expect(has_node("Sun") and (get_node("Sun") as DirectionalLight3D).shadow_enabled,
		"方向光投射阴影", report) and ok
	ok = _expect(has_node("Fill"), "补光就位（亮场景的暗面不该死黑）", report) and ok
	ok = _expect(_particle_emitters == 4, "四座矮灯柱各挂一组小颗粒粒子（实际 %d）" % _particle_emitters, report) and ok

	# 地形是否真的产出了数据块——这是"能看见东西"的硬证据
	var ready_now := _world_ready()
	var db := _terrain.voxel_to_data_block(Vector3i(0, 20, 0))
	print("  原点数据块 %s 存在: %s" % [str(db), str(_terrain.has_data_block(db))])
	print("  地形统计：%s" % str(_terrain.get_statistics()))
	ok = _expect(ready_now, "地形已生成数据块", report) and ok

	for line in report:
		print(line)
	print("SMOKE RESULT: %s" % ("PASS" if ok else "FAIL"))


func _expect(cond: bool, label: String, report: Array[String]) -> bool:
	report.append("  [%s] %s" % ["ok" if cond else "XX", label])
	return cond


func _do_shot() -> void:
	DirAccess.make_dir_recursive_absolute(SHOT_DIR)
	var path := SHOT_DIR + "/world.png"
	var abs_path := ProjectSettings.globalize_path(path)
	var img := get_viewport().get_texture().get_image()
	var err := img.save_png(abs_path)
	print("SHOT: %s  err=%d  size=%dx%d" % [abs_path, err, img.get_width(), img.get_height()])
