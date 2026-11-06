extends Node3D

## 基准场景：接近第 1 关的最小场景，四个测量（数一~数四）共用。
##
## 布局全部落在原点附近 13×13 的机器平台（甲板）上，保证物理测量的地面是平的：
##   - 体素地面：复用 spike 的 terrain_generator.gd（甲板 + 四角矮灯柱），开碰撞
##   - 第一关风格道具：一块任务牌 + 一块角色铭牌（MeshInstance3D + Label3D 近似）
##   - 50 个可推倒刚体方块 = 10 塔身 + 30 方墙 + 10 传送带上
##   - 10 米传送带：AnimatableBody3D 平台在 _physics_process 里平移模拟
##   - WorldEnvironment + 主光/补光 + 小粒子：按「粉彩玩具沙盘」配方配置（bench 专属）
##   - 第三人称轨道相机，持续慢速环绕（相机路线：第三人称轨道为主，预设位可换）
##
## 两种入口共用本脚本一套逻辑：
##   场景直跑：godot --path game res://bench/scenes/bench_world.tscn -- --mode=<m>
##   脚本入口：godot --headless --path game -s res://bench/bench_main.gd -- --mode=<m>
##             （bench_main 用 meta "bench_mode" 把 mode 传进来）
## mode ∈ smoke | physics | bake | predict | render | render-pure | ""（交互围观）

const GeneratorScript := preload("res://scripts/terrain_generator.gd")

const OUT_DIR := "res://bench/out"

# ---- 地形常量（与 terrain_generator.gd 保持一致）----
const WorldBuilder := preload("res://scripts/scene/world_builder.gd")

# 地形常量与调色板的唯一真源在 world_builder
const TERRAIN_BASE_HEIGHT := WorldBuilder.TERRAIN_BASE_HEIGHT
const PLAZA_RADIUS := WorldBuilder.PLAZA_RADIUS
const PLAZA_LIFT := WorldBuilder.PLAZA_LIFT
const DECK_TOP_Y := WorldBuilder.DECK_TOP_Y
const PALETTE := WorldBuilder.PALETTE
const EMISSIVE := WorldBuilder.EMISSIVE

# ---- 刚体方块布局（合计 50）----
const CUBE_SIZE := 0.5
const TOWER_COUNT := 10
const TOWER_X := -4.0
const TOWER_Z := 5.0
const WALL_W := 5                     # x 方向 5 列
const WALL_D := 3                     # z 方向 3 排
const WALL_H := 2                     # 高 2 层
const WALL_X0 := 0.0
const WALL_Z0 := 4.0
const BELT_CUBES := 10
const CUBE_TOTAL := TOWER_COUNT + WALL_W * WALL_D * WALL_H + BELT_CUBES

# ---- 传送带 ----
const BELT_SPEED := 0.8               # m/s，单向
const BELT_TRAVEL := 8.0              # 10 秒 bench 只走前 8 米
const BELT_Z := -4.0
const BELT_LEN := 10.0
const BELT_WIDTH := 2.0
const BELT_H := 0.3

# ---- 相机轨道 ----
const ORBIT_RADIUS := 26.0
const ORBIT_HEIGHT := DECK_TOP_Y + 7.0
const ORBIT_SPEED := 0.15             # rad/s，10 秒约 86°

var cubes: Array[RigidBody3D] = []
var belt: AnimatableBody3D = null
## 物理是否已放行：碰撞体就绪前方块全部冻结，arm_physics() 后才落体/开带
var armed := false

var _terrain: VoxelTerrain = null
var _library: VoxelBlockyLibrary = null
var _cam: Camera3D = null
var _belt_travel := 0.0
var _orbit_t := 0.0
var _collisions_ready := false


func _ready() -> void:
	_build_world()
	_dispatch(_resolve_mode())


func _process(delta: float) -> void:
	_orbit_t += delta
	_update_camera(_orbit_t)


func _physics_process(delta: float) -> void:
	if not _collisions_ready:
		# 体素碰撞体是流式异步生成的：从甲板上空向下打射线，命中甲板才算就绪。
		# 就绪前放行物理，方块会整个穿下去（第一版实测：16 块穿透、飞出 367 m）。
		_collisions_ready = _probe_deck_hit()
	if armed and belt != null and is_instance_valid(belt) and _belt_travel < BELT_TRAVEL:
		# 传送带单向前进 8 m 后停住（bench 只有 10 s；交互围观时它停在尽头也够看）
		var step := minf(BELT_TRAVEL - _belt_travel, BELT_SPEED * delta)
		_belt_travel += step
		belt.global_position = Vector3(_belt_travel, belt.global_position.y, BELT_Z)


## 碰撞探针点：覆盖甲板四个 16 m 体素块（体素碰撞按块流式生成，单点命中
## 不代表塔那块也好了）。点要避开：矮灯柱（plaza 四角 |x|,|z|≥5 有柱，顶面 y≈24）、
## 传送带（z∈[-5,-3], |x|≤5）、冻结的方块与道具，让射线能真正打到甲板面 y=23。
const PROBE_POINTS := [
	Vector2(0.0, 0.0),      # 块 (0,1,0)，甲板中心
	Vector2(-4.0, 3.0),     # 块 (-1,1,0)，塔旁边（塔本体在 (-4,5)）
	Vector2(5.5, 2.0),      # 块 (0,1,0)，避开灯柱角（az=2）
	Vector2(-5.5, 2.0),     # 块 (-1,1,0)，避开灯柱角
	Vector2(2.0, -2.0),     # 块 (0,1,-1)，带后方
	Vector2(-2.0, -2.0),    # 块 (-1,1,-1)，带后方
]


func _probe_deck_hit() -> bool:
	for pt in PROBE_POINTS:
		var from := Vector3(pt.x, DECK_TOP_Y + 8.0, pt.y)
		var to := Vector3(pt.x, DECK_TOP_Y - 6.0, pt.y)
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collide_with_areas = false
		var hit: Dictionary = get_world_3d().direct_space_state.intersect_ray(query)
		if not (hit.has("position") and absf(float(hit["position"].y) - DECK_TOP_Y) < 0.5):
			return false
	return true


func wait_collisions(max_physics_frames: int) -> bool:
	for i in max_physics_frames:
		if _collisions_ready:
			return true
		await get_tree().physics_frame
	return _collisions_ready


func arm_physics() -> void:
	# 碰撞体就绪后调用：解冻全部方块，传送带开始走
	if armed:
		return
	armed = true
	for i in cubes.size():
		cubes[i].freeze = false
		if i < TOWER_COUNT:
			# 实测：解冻瞬间接触求解会往 10 层塔里注入横向抖动，直接把塔震塌。
			# 塔以睡眠状态保住——这也是游戏里堆叠物（货箱塔、方块堆）的常规做法。
			cubes[i].sleeping = true


func physics_sane() -> bool:
	# 甲板区域内不该有任何方块沉到甲板面以下（翻倒的方块只会躺在甲板上）
	for c in cubes:
		var p := c.global_position
		if absf(p.x) <= 6.0 and absf(p.z) <= 6.0 and p.y < 21.5:
			return false
	return true


# ---------- 入口与分发 ----------

func _resolve_mode() -> String:
	if has_meta("bench_mode"):
		return str(get_meta("bench_mode"))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			return a.substr("--mode=".length())
	return ""


func _dispatch(mode: String) -> void:
	match mode:
		"smoke":
			_run_smoke()
		"physics", "bake", "predict", "render", "render-pure":
			var map := {
				"physics": ["res://bench/bench_physics.gd", "physics_report.json"],
				"bake": ["res://bench/bench_bake.gd", "bake_report.json"],
				"predict": ["res://bench/bench_predict.gd", "predict_report.json"],
				"render": ["res://bench/bench_render.gd", "render_movie.json"],
				"render-pure": ["res://bench/bench_render.gd", "render_pure.json"],
			}
			var pair: Array = map[mode]
			var bench := (load(str(pair[0])) as GDScript).new() as Node
			bench.set("world", self)
			bench.set("outfile", str(pair[1]))
			add_child(bench)
		_:
			pass   # 交互围观：世界自己转


func _run_smoke() -> void:
	var ready_now: bool = await wait_ready(600)
	var col_ready: bool = await wait_collisions(600)
	var ok := true
	var report: Array[String] = []
	ok = _expect(ready_now, "体素地形已生成数据块", report) and ok
	ok = _expect(col_ready, "体素碰撞体已就绪（射线命中甲板）", report) and ok
	ok = _expect(cubes.size() == CUBE_TOTAL, "刚体方块 %d/%d" % [cubes.size(), CUBE_TOTAL], report) and ok
	var in_tree := true
	for c in cubes:
		in_tree = in_tree and c.is_inside_tree()
	ok = _expect(in_tree, "全部方块已进场景树", report) and ok
	ok = _expect(belt != null and is_instance_valid(belt), "传送带就位", report) and ok
	ok = _expect(_cam != null and _cam.current, "相机就位且为当前", report) and ok
	ok = _expect(has_node("WorldEnvironment"), "环境就位", report) and ok
	ok = _expect(has_node("Sun") and has_node("Fill"), "主光与补光就位", report) and ok
	ok = _expect(has_node("TaskSign") and has_node("NamePlate"), "任务牌与铭牌就位", report) and ok
	for line in report:
		print(line)
	print("BENCH SMOKE: %s" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)


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


func _expect(cond: bool, label: String, report: Array[String]) -> bool:
	report.append("  [%s] %s" % ["ok" if cond else "XX", label])
	return cond


# ---------- 世界搭建 ----------

func _build_world() -> void:
	# GDExtension 必须有 VoxelEngineUpdater 驱动，否则异步流式任务永不完成
	var updater := VoxelEngineUpdater.new()
	updater.name = "VoxelEngineUpdater"
	add_child(updater)

	_library = _build_library()
	_add_environment()
	_add_sun()
	_add_particles()
	_add_camera()
	_add_terrain()
	_add_belt()
	_add_props()
	_spawn_cubes()


func _build_library() -> VoxelBlockyLibrary:
	var lib := VoxelBlockyLibrary.new()
	var air := VoxelBlockyModelEmpty.new()
	lib.add_model(air)
	for i in range(1, PALETTE.size()):
		var cube := VoxelBlockyModelCube.new()
		cube.color = PALETTE[i]
		cube.culls_neighbors = true
		cube.set_material_override(0, _block_material(i))
		lib.add_model(cube)
	return lib


func _block_material(i: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = PALETTE[i]
	m.vertex_color_use_as_albedo = true
	if EMISSIVE.has(i):
		m.emission_enabled = true
		m.emission = PALETTE[i]
		m.emission_energy_multiplier = float(EMISSIVE[i])
		m.roughness = 0.60
		m.metallic = 0.0
	else:
		m.roughness = 0.80
		m.metallic = 0.0
	return m


func _add_terrain() -> void:
	var terrain := VoxelTerrain.new()
	terrain.name = "Terrain"
	terrain.mesh_block_size = 16
	terrain.max_view_distance = 256
	terrain.generate_collisions = true      # 基准场景要接物理，与 spike 不同
	terrain.generator = GeneratorScript.new()

	var mesher := VoxelMesherBlocky.new()
	mesher.library = _library
	mesher.tint_mode = VoxelMesherBlocky.TINT_NONE
	mesher.occlusion_enabled = true
	mesher.occlusion_darkness = 0.35
	terrain.mesher = mesher

	_terrain = terrain
	add_child(terrain)


func _add_camera() -> void:
	var cam := Camera3D.new()
	cam.name = "Camera"
	# 第三人称轨道相机（美术方向的相机路线裁决）：透视 + 慢速环绕
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 50.0
	cam.near = 0.1
	cam.far = 600.0
	add_child(cam)
	cam.current = true
	_cam = cam
	_update_camera(0.0)

	# VoxelViewer 当"玩家"放在世界里（挂远处的相机上会被 bounds 裁掉）
	var anchor := Node3D.new()
	anchor.name = "ViewerAnchor"
	anchor.position = Vector3(0.0, 20.0, 0.0)
	add_child(anchor)
	var viewer := VoxelViewer.new()
	viewer.name = "Viewer"
	viewer.view_distance = 96
	viewer.requires_visuals = true
	viewer.requires_collisions = true     # 甲板要出碰撞体
	anchor.add_child(viewer)


func _update_camera(t: float) -> void:
	if _cam == null:
		return
	var a := t * ORBIT_SPEED + PI * 0.25
	_cam.position = Vector3(cos(a) * ORBIT_RADIUS, ORBIT_HEIGHT, sin(a) * ORBIT_RADIUS)
	_cam.look_at(Vector3(0.0, DECK_TOP_Y + 1.0, 2.0), Vector3.UP)


func _add_environment() -> void:
	# 「粉彩玩具沙盘」环境配方（bench 专属，不再与 main.gd 共用明亮定稿）
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.549,0.745,0.918)
	sky_mat.sky_horizon_color = Color(0.949,0.914,0.863)
	sky_mat.ground_bottom_color = Color(0.910,0.863,0.784)
	sky_mat.ground_horizon_color = Color(0.941,0.902,0.839)
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

	env.glow_enabled = true
	env.glow_intensity = 0.28
	env.glow_bloom = 0.02
	env.glow_hdr_threshold = 1.30
	env.glow_strength = 0.95

	env.fog_enabled = true
	env.fog_light_color = Color(0.941,0.914,0.863)
	env.fog_light_energy = 1.0
	env.fog_density = 0.0002
	env.fog_sky_affect = 0.20
	env.fog_aerial_perspective = 0.10

	env.adjustment_enabled = true
	env.adjustment_saturation = 1.30
	env.adjustment_contrast = 1.06
	env.adjustment_brightness = 0.93

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	add_child(we)


func _add_sun() -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0,0.95,0.86)
	sun.light_energy = 2.3
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.5
	sun.directional_shadow_max_distance = 320.0
	sun.rotation_degrees = Vector3(-48.0, 45.0, 0.0)
	add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.95,0.90,0.85)
	fill.light_energy = 0.70
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-26.0, -125.0, 0.0)
	add_child(fill)


func _add_particles() -> void:
	# 四座矮灯柱顶端的小颗粒上浮粒子（粉彩配方：小、多、慢、淡）
	for a in [
		Vector2(-PLAZA_RADIUS + 1, -PLAZA_RADIUS + 1),
		Vector2(PLAZA_RADIUS - 1, -PLAZA_RADIUS + 1),
		Vector2(-PLAZA_RADIUS + 1, PLAZA_RADIUS - 1),
		Vector2(PLAZA_RADIUS - 1, PLAZA_RADIUS - 1),
	]:
		var emitter := _make_spark_emitter()
		emitter.position = Vector3(a.x, float(TERRAIN_BASE_HEIGHT + PLAZA_LIFT + 2) + 0.6, a.y)
		add_child(emitter)


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
	proc.color = Color(1.0,0.96,0.86,0.75)
	p.process_material = proc

	var quad := QuadMesh.new()
	quad.size = Vector2(0.22, 0.22)

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	mat.disable_receive_shadows = true
	mat.albedo_color = Color(1.0,0.96,0.86,0.80)
	mat.emission_enabled = true
	mat.emission = Color(1.0,0.96,0.86)
	mat.emission_energy_multiplier = 0.6
	quad.material = mat

	p.draw_pass_1 = quad
	p.emitting = true
	return p


func _add_belt() -> void:
	# 10 米传送带：AnimatableBody3D 平台在 _physics_process 里平移，
	# 靠摩擦把上面的刚体方块带走（"传送带能带走东西"的最低配近似）
	var body := AnimatableBody3D.new()
	body.name = "Belt"
	body.position = Vector3(0.0, DECK_TOP_Y + BELT_H * 0.5, BELT_Z)

	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(BELT_LEN, BELT_H, BELT_WIDTH)
	shape.shape = box
	body.add_child(shape)

	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(BELT_LEN, BELT_H, BELT_WIDTH)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = PALETTE[5]
	mat.roughness = 0.8
	mat.metallic = 0.0
	mesh.material = mat
	body.add_child(mi)

	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	pm.bounce = 0.0
	body.physics_material_override = pm

	belt = body
	add_child(body)


func _add_props() -> void:
	# 第一关的两件道具：任务牌 + 角色铭牌（简单 MeshInstance3D + Label3D 近似）
	_add_sign("TaskSign", Vector3(-5.5, 0.0, -1.0), Vector2(2.4, 1.2),
		"任务 L1\n给它接第一件活", PALETTE[5], PI * 0.35)
	_add_sign("NamePlate", Vector3(4.8, 0.0, 2.8), Vector2(1.8, 0.9),
		"mini codex\n工位 01", PALETTE[6], -PI * 0.35)


func _add_sign(sign_name: String, xz: Vector3, panel_size: Vector2, text: String,
		frame_color: Color, face_yaw: float) -> void:
	var root := Node3D.new()
	root.name = sign_name
	root.position = Vector3(xz.x, 0.0, xz.z)
	root.rotation.y = face_yaw
	add_child(root)

	# 柱子
	var post := MeshInstance3D.new()
	var post_mesh := BoxMesh.new()
	post_mesh.size = Vector3(0.12, 1.3, 0.12)
	post.mesh = post_mesh
	post.position = Vector3(0.0, DECK_TOP_Y + 0.65, 0.0)
	var post_mat := StandardMaterial3D.new()
	post_mat.albedo_color = PALETTE[3]
	post_mesh.material = post_mat
	root.add_child(post)

	# 面板
	var panel := MeshInstance3D.new()
	var panel_mesh := BoxMesh.new()
	panel_mesh.size = Vector3(panel_size.x, panel_size.y, 0.06)
	panel.mesh = panel_mesh
	panel.position = Vector3(0.0, DECK_TOP_Y + 1.55, 0.0)
	var panel_mat := StandardMaterial3D.new()
	panel_mat.albedo_color = PALETTE[4]
	panel_mesh.material = panel_mat
	root.add_child(panel)

	# 面板边框（暖色强调）
	var frame := MeshInstance3D.new()
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(panel_size.x + 0.1, panel_size.y + 0.1, 0.04)
	frame.mesh = frame_mesh
	frame.position = Vector3(0.0, DECK_TOP_Y + 1.55, -0.015)
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = frame_color
	frame_mesh.material = frame_mat
	root.add_child(frame)

	# 文字
	var label := Label3D.new()
	label.text = text
	label.position = Vector3(0.0, DECK_TOP_Y + 1.55, 0.05)
	label.font_size = 72
	label.pixel_size = 0.0035
	label.modulate = Color(0.30,0.26,0.22)
	label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	label.double_sided = false
	root.add_child(label)


func _spawn_cubes() -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(CUBE_SIZE, CUBE_SIZE, CUBE_SIZE)
	var mesh := BoxMesh.new()
	mesh.size = Vector3(CUBE_SIZE, CUBE_SIZE, CUBE_SIZE)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.05

	var i := 0
	# 塔：10 层，精确贴合堆放（不留缝：2 mm 落差就足以把 10 层塔抖塌，第一版实测）
	for h in TOWER_COUNT:
		var pos := Vector3(TOWER_X, DECK_TOP_Y + 0.25 + float(h) * 0.5, TOWER_Z)
		_add_cube(_make_cube(shape, mesh, pm, pos, _cube_color(i)))
		i += 1
	# 方墙：5×3×2 = 30，留 2 cm 缝（能传力推倒，又不初始互穿）
	for h in WALL_H:
		for d in WALL_D:
			for w in WALL_W:
				var pos := Vector3(WALL_X0 + float(w) * 0.52,
					DECK_TOP_Y + 0.25 + float(h) * 0.5,
					WALL_Z0 + float(d) * 0.52)
				_add_cube(_make_cube(shape, mesh, pm, pos, _cube_color(i)))
				i += 1
	# 传送带上 10 个，传送带搬运看它们
	for b in BELT_CUBES:
		var pos := Vector3(-4.0 + float(b) * 0.9, DECK_TOP_Y + BELT_H + 0.27, BELT_Z)
		_add_cube(_make_cube(shape, mesh, pm, pos, _cube_color(i)))
		i += 1


func _add_cube(body: RigidBody3D) -> void:
	add_child(body)
	cubes.append(body)


func _cube_color(i: int) -> Color:
	# 甲板蓝灰打底 + 少量暖橙强调（限定调色板）
	return PALETTE[[4, 3, 2, 5, 3][i % 5]]


func _make_cube(shape: BoxShape3D, mesh: BoxMesh, pm: PhysicsMaterial,
		pos: Vector3, color: Color) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.position = pos
	body.mass = 1.0
	body.physics_material_override = pm
	# 体素碰撞体生成前先冻结，等 arm_physics() 放行，防止整摞穿进甲板
	body.freeze = true
	body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC

	var cs := CollisionShape3D.new()
	cs.shape = shape
	body.add_child(cs)

	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.8
	mat.metallic = 0.0
	mi.material_override = mat   # mesh 是共享的，颜色走每实例的 override
	body.add_child(mi)
	return body


func wall_cube_index(d: int, w: int, h: int) -> int:
	return TOWER_COUNT + h * WALL_D * WALL_W + d * WALL_W + w


func belt_cube_index(b: int) -> int:
	return TOWER_COUNT + WALL_W * WALL_D * WALL_H + b
