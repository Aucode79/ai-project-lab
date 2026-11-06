extends RefCounted

## 场景总装的世界配方（唯一一份）：调色板 / 地形常量 / 环境 / 光照 / 粒子 / 体素地形 /
## 材质与相机工厂。l1-l5 与沙盒的场景脚本共用本文件，取代过去 6 份复制粘贴。
##
## 用法：const WorldBuilder := preload("res://scripts/scene/world_builder.gd")
## 纯静态工具，不实例化；调用形如 WorldBuilder.add_sun(self)。
## 背后由来见 docs/30-决策/2026-09-15-场景与流程层去重重构.md。

const GeneratorScript := preload("res://scripts/terrain_generator.gd")
const OrbitCamScript := preload("res://scripts/interaction/orbit_camera.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")

# ---- 地形常量（与 terrain_generator.gd 一致）----
const TERRAIN_BASE_HEIGHT := 20
const PLAZA_RADIUS := 6
const PLAZA_LIFT := 2
const DECK_TOP_Y := 23.0            # 甲板面：plaza 顶体素 wy=22 的上表面

# ---- 关卡调色板：与教学资产共用颜色角色，索引与生成器一致 ----
const PALETTE := [
	Color(0.000, 0.000, 0.000),   # 0 空气
	Style.INK,
	Style.STRUCTURE,
	Style.SHELL,
	Style.PAPER,
	Style.ACTION,
	Style.CORE,
	Style.SIGNAL,
]
const EMISSIVE := {6: 0.35}


# ---------- 环境 / 光照 / 粒子 ----------

## 明亮定稿环境（天空 / 环境光 / Reinhardt / SSAO / 辉光 / 距离雾 / 调色）。
## 教学关卡配方；历史 main/bench 保留各自的测量环境。
static func add_environment(parent: Node3D) -> void:
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
	env.adjustment_saturation = 1.05
	env.adjustment_contrast = 1.06
	env.adjustment_brightness = 0.93

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	parent.add_child(we)


## 主方向光（投影）+ 补光（不投影，避免亮场景暗面死黑）。
static func add_sun(parent: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = Color(1.0, 0.95, 0.86)
	sun.light_energy = 2.3
	sun.shadow_enabled = true
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.5
	sun.directional_shadow_max_distance = 320.0
	sun.rotation_degrees = Vector3(-48.0, 45.0, 0.0)
	parent.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = Color(0.95, 0.90, 0.85)
	fill.light_energy = 0.70
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-26.0, -125.0, 0.0)
	parent.add_child(fill)


## Keep the recipe hook; teaching stages contain no decorative particles.
static func add_particles(_parent: Node3D) -> void:
	return


# ---------- 体素地形 ----------

## 体素地面（生成器直挂，不挂 stream）+ 方块材质库；返回 VoxelTerrain 供场景存引用。
static func add_terrain(parent: Node3D) -> VoxelTerrain:
	var terrain := VoxelTerrain.new()
	terrain.name = "Terrain"
	terrain.mesh_block_size = 16
	terrain.max_view_distance = 256
	terrain.generate_collisions = true      # 碰撞体照常生成，后续关卡接物理用
	terrain.generator = GeneratorScript.new()

	var mesher := VoxelMesherBlocky.new()
	mesher.library = _build_library()
	mesher.tint_mode = VoxelMesherBlocky.TINT_NONE
	mesher.occlusion_enabled = true
	mesher.occlusion_darkness = 0.35
	terrain.mesher = mesher

	parent.add_child(terrain)
	return terrain


static func _build_library() -> VoxelBlockyLibrary:
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


static func _block_material(i: int) -> StandardMaterial3D:
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


# ---------- 材质工厂 ----------

## 组件与摆件的通用标准材质（场景脚本的 _mat 直接调它）。
static func mat(color: Color, roughness: float, metallic: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = roughness
	m.metallic = metallic
	return m


# ---------- 相机 ----------

## VoxelViewer 当"玩家"放在世界里（挂远处相机上会被 bounds 裁掉）。
## requires_collisions：甲板要出碰撞体，搬动的件才落得住。
static func attach_viewer(parent: Node3D) -> void:
	var anchor := Node3D.new()
	anchor.name = "ViewerAnchor"
	anchor.position = Vector3(0.0, 20.0, 0.0)
	parent.add_child(anchor)
	var viewer := VoxelViewer.new()
	viewer.name = "Viewer"
	viewer.view_distance = 96
	viewer.requires_visuals = true
	viewer.requires_collisions = true
	anchor.add_child(viewer)


## 轨道相机（OrbitCam 接管主相机：预设位 / 鼠标视角 / 滚轮缩放 / Tab 轮换）。
## 进场机位必须收在甲板空域内（水平距 ≤6 m）：甲板外是量化台地，碰撞体流式到位后
## 会挡住看工位的视线，拾取射线也打不到。
static func make_orbit_camera(parent: Node3D, look_at: Vector3,
		preset_name: String, preset: Dictionary) -> Camera3D:
	var target := Node3D.new()
	target.name = "OrbitTarget"
	target.position = look_at
	parent.add_child(target)

	var cam := OrbitCamScript.new()   # 不标注 Camera3D：要访问 OrbitCam 的 presets/target
	cam.name = "Camera"
	cam.fov = 50.0
	cam.near = 0.1
	cam.far = 600.0
	cam.target = target
	parent.add_child(cam)   # _ready 里 make_current + 应用初始姿态
	cam.presets[preset_name] = preset
	cam.switch_preset(preset_name)
	return cam


## 第三人称慢速环绕相机（透视；位置由场景 _update_camera 逐帧驱动）。
static func make_auto_orbit_camera(parent: Node3D) -> Camera3D:
	var cam := Camera3D.new()
	cam.name = "Camera"
	cam.projection = Camera3D.PROJECTION_PERSPECTIVE
	cam.fov = 50.0
	cam.near = 0.1
	cam.far = 600.0
	parent.add_child(cam)
	cam.current = true
	return cam
