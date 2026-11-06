extends RefCounted

## 沙盒「箱庭浮空岛」配方（沙盒专属，不碰五关与 bench 的 world_builder）：
## 天空 / 光照 / 岛体素地形与方块材质库 / VoxelViewer / 相机（含移轴景深）。
## **自然装饰一律不要**（用户裁定 2026-09-17）：树 / 露头石 / 浮尘粒子全删，
## 只留结构性工艺件（灯笼柱 / 地层 / 岛体等）。**草不是几何**，
## 是顶层方块的草皮表面（sandbox_block.gdshader 的 pattern_kind 3）。
##
## 对标对象是任天堂风箱庭探索游戏《Zoy》的前瞻片：一小块悬在天空里的陆地，
## 暖砂台面 + 陶砖镶边 + 草皮外缘（草是顶层方块的表面） + 崖壁四段地层 +
## 收成一点的岛底；黄金时刻的暖光打在饱和蓝天前，轻微移轴虚化读作微缩玩具。
##
## 与 scripts/scene/world_builder.gd 的关系：两者是同一套静态方法名的"配方脚本"，
## 由 level_scene_base 的 _add_environment / _add_sun / _add_particles /
## _add_terrain_recipe 四个覆写点切换（沙盒覆写成这一份）。world_builder 是关卡配方，
## 本文件是沙盒配方，各自演进互不影响。
##
## 用法：const Diorama := preload("res://scripts/sandbox/sandbox_diorama.gd")
## 纯静态工具，不实例化；调用形如 Diorama.add_sun(self)。

const IslandScript := preload("res://scripts/sandbox/sandbox_island.gd")
const BlockScript := preload("res://scripts/sandbox/sandbox_block.gd")
const OrbitCamScript := preload("res://scripts/interaction/orbit_camera.gd")

const TOP_Y := 23.0                     # 岛顶面（= WorldBuilder.DECK_TOP_Y）
# 甲板碰撞代理的盒子栅格（米）。**必须小到"轮廓吻合"**：代理是按"盒中心是否
# is_land"铺的，所以轮廓误差是格距的量级（实测按 L4 半径计，见下），
#   2.0 m → 175 盒，岛外多出最多 1.10 m 的隐形地板、岛内最多 0.95 m 的洞
#   0.5 m → 2665 盒，误差 ≤ 0.20 m（不到一个标准方块 0.5 m）
#   0.25 m → 10661 盒，误差 ≤ 0.10 m
# 取 0.5 m：误差落进"半块"口径以内，盒子数仍在千级（静态体，一次建好、
# 每帧只在宽相里躺着）。曾用 2.0 m —— 那会让拖拽落定停在离崖口两格远的空气上。
const DECK_CELL_M := 0.5
const CELL_BOX_H := 1.0                 # 盒子厚（米）：顶面对齐岛顶面，够挡射线与落体

# ---- 黄金时刻环境：饱和蓝天 + 暖阳 + 轻雾 + 移轴 ----
const SKY_TOP := Color(0.243, 0.451, 0.722)       # #3E73B8 天顶蓝
const SKY_HORIZON := Color(0.549, 0.729, 0.894)   # #8CBAE4 地平雾蓝
const SUN_COLOR := Color(1.000, 0.867, 0.659)     # 暖阳
const FILL_COLOR := Color(0.612, 0.729, 0.902)    # 天空补光（冷）

# ---- 相机机位 ----
const CAMERA_FOV := 42.0            # 长焦：透视更弱，读作微缩沙盘而不是"我站在里面"
# pitch 0.80 rad ≈ 46°：箱庭的经典俯角，既能看见台面又看得见崖壁与岛底
const PRESET_BENCH := {"yaw": 0.7854, "pitch": 0.80, "distance": 24.0, "fov": CAMERA_FOV}
# 全景机位：俯角压到 26° 才有"浮空"可言 —— 俯角一高，岛顶自身就会把崖壁与
# 岛底全挡住，画面读作一张平放的桌子。--shot 截图用这个，效果最完整。
const PRESET_DIORAMA := {"yaw": -0.65, "pitch": 0.50, "distance": 46.0,
	"fov": CAMERA_FOV, "focus_offset": Vector3(0.0, -5.0, 0.0)}

# ---------- 环境 / 光照 ----------

## 黄金时刻环境：饱和蓝天穹 + AgX + 轻辉光 + 极淡距离雾 + 暖调校正。
## 与关卡那份（明亮粉彩）刻意分开：沙盒要的是"微缩箱庭在夕照里"。
static func add_environment(parent: Node3D) -> void:
	# 天与地同色系：岛悬在天上，镜头压低时脚下也是天，不该看见奶油色地平带
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = SKY_TOP
	sky_mat.sky_horizon_color = SKY_HORIZON
	sky_mat.sky_curve = 0.12
	sky_mat.ground_horizon_color = SKY_HORIZON
	sky_mat.ground_bottom_color = Color(0.361, 0.549, 0.761)
	sky_mat.ground_curve = 0.12
	sky_mat.sun_angle_max = 24.0
	sky_mat.sun_curve = 0.10
	sky_mat.use_debanding = true

	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.12

	# 曝光与色彩。AgX 会把暖色高光压得很平（实测整座岛洗成奶粉色），
	# 黄金时刻要的是"饱和且亮而不白" → Filmic + 提饱和 + 压环境光。
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_white = 6.0
	env.tonemap_exposure = 0.98

	# 接触阴影只做一点点：方块接缝与铺装边线的接触阴影要克制，SSAO 一重就成噪点
	env.ssao_enabled = true
	env.ssao_intensity = 0.70
	env.ssao_radius = 0.65

	# 辉光只给"被阳光打亮的亮面"（台面 / 崖顶 / 发光灯笼核心）：阈值压到 1.55，
	# 只有过阈值的高光参与。草改成顶层方块表面之后，参与辉光的是方块的顶面。
	env.glow_enabled = true
	env.glow_intensity = 0.26
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.55
	env.glow_strength = 1.0

	# 雾只留一丝空气透视（sky_affect=0 不动天空）：第一版 0.0035 把整幅洗白了
	env.fog_enabled = true
	env.fog_light_color = SKY_HORIZON
	env.fog_light_energy = 1.0
	env.fog_density = 0.0005
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.10

	env.adjustment_enabled = true
	env.adjustment_saturation = 1.12
	env.adjustment_contrast = 1.12
	env.adjustment_brightness = 0.99

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	we.environment = env
	parent.add_child(we)


## 暖阳（投影）+ 天空补光（不投影）。低仰角是黄金时刻的关键：
## 阴影拉长、台面出现方向明确的明暗面，微缩感一半来自这里。
static func add_sun(parent: Node3D) -> void:
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_color = SUN_COLOR
	sun.light_energy = 1.95
	sun.shadow_enabled = true
	sun.shadow_bias = 0.03
	sun.shadow_normal_bias = 1.2
	# 岛只有 ~28 m：投影距离收到 96 m，阴影贴图的分辨率就全花在岛上了
	sun.directional_shadow_max_distance = 96.0
	sun.shadow_blur = 1.4
	sun.rotation_degrees = Vector3(-40.0, -35.0, 0.0)
	parent.add_child(sun)

	var fill := DirectionalLight3D.new()
	fill.name = "Fill"
	fill.light_color = FILL_COLOR
	fill.light_energy = 0.30
	fill.shadow_enabled = false
	fill.rotation_degrees = Vector3(-22.0, 145.0, 0.0)
	parent.add_child(fill)


## 粒子：**空覆写**。这一处是 level_scene_base 的四个装配点之一，沙盒保留覆写但不出
## 任何粒子 —— 原「四角灯笼上浮的暖色微粒（Zoy 的萤火）」按用户裁定 2026-09-17
## （自然装饰全删）整段移除。**不能把覆写整个删掉**：删掉就回落到 world_builder 的
## 关卡配方（四角 Sparks 火花），那不是沙盒要的东西。
static func add_particles(_parent: Node3D) -> void:
	return


# ---------- 体素岛体 ----------

## 浮空岛体素地形 + 方块材质库；返回 VoxelTerrain 供场景存引用。
static func add_terrain(parent: Node3D, island_generator = null) -> VoxelTerrain:
	var terrain := VoxelTerrain.new()
	terrain.name = "Terrain"
	terrain.mesh_block_size = 16
	# 岛约 38 m：48 m 视野足以覆盖全岛与岛底，同时限制无用的空气块生成。
	terrain.max_view_distance = 48
	# 地形自身不出碰撞：倒角方块用的 VoxelBlockyModelMesh 实测不出任何碰撞体，
	# 甲板改由 add_deck_collision() 的代理盒子提供（实测记录见那里的注释）
	terrain.generate_collisions = false
	terrain.generator = island_generator if island_generator != null else IslandScript.new()

	var mesher := VoxelMesherBlocky.new()
	mesher.library = build_library()
	mesher.tint_mode = VoxelMesherBlocky.TINT_NONE
	mesher.occlusion_enabled = true
	mesher.occlusion_darkness = 0.30
	terrain.mesher = mesher

	parent.add_child(terrain)
	return terrain


## 依 IslandScript.PALETTE 建方块材质库。
## 方块本体是**倒角砖块**（BlockScript 的共享网格），不是立方体：
##   - 倒角让方块不再贴到体素边界 → 邻面剔除失效（culls_neighbors = false），
##     岛体内部的面也会生成。代价与实测值记在 sandbox_block.gd 文件头。
##   - 碰撞不走网格三角形（太贵），走 collision_aabbs 的整格包围盒 —— 与原立方体
##     模型同一口径；`tests/sandbox/run_island_tests.gd` 用射线打甲板把它锁住。
## 颜色分工与 world_builder 不同：那里 albedo 与顶点色都是调色板色（等于自乘一遍），
## 这里 albedo 留白、颜色全走顶点色 —— 取色所见即所得，调箱庭色更好控。
static func build_library() -> VoxelBlockyLibrary:
	var lib := VoxelBlockyLibrary.new()
	lib.add_model(VoxelBlockyModelEmpty.new())
	var shared_mesh := BlockScript.block_mesh()
	for i in range(1, IslandScript.PALETTE.size()):
		var block := VoxelBlockyModelMesh.new()
		block.mesh = shared_mesh
		block.color = IslandScript.PALETTE[i]
		block.culls_neighbors = false
		block.set_material_override(0, BlockScript.material_for(i))
		lib.add_model(block)
	return lib


## 甲板碰撞代理：一层贴岛顶的盒子栅格（静态）。
##
## 为什么不用体素地形自带的碰撞：倒角方块必须用 VoxelBlockyModelMesh（自定义网格），
## 而实测**它一个碰撞体都不出** —— 同一套 VoxelTerrain 配置下把模型换成
## VoxelBlockyModelCube 就能命中射线，换成 mesh 模型则连 collision_aabbs +
## set_mesh_collision_enabled 都救不回来（`run_island_tests.gd` 的 T9 是这条的回归锁）。
##
## 代理盒子还有一样好处：它是**同步**建好的，不像体素碰撞那样异步流式到位 ——
## 甲板在场景搭好的那一刻就是实心的，拖拽落定不再有"头几帧没有地面"的窗口。
##
## 覆盖范围按形状函数走（is_land），所以挡的正好是岛顶那一圈，海岸线外是真的空。
static func add_deck_collision(parent: Node3D, island) -> StaticBody3D:
	var body := StaticBody3D.new()
	body.name = "DeckCollision"
	parent.add_child(body)
	var cell := DECK_CELL_M
	var half := CELL_BOX_H * 0.5
	var shape := BoxShape3D.new()
	shape.size = Vector3(cell, CELL_BOX_H, cell)
	var span := IslandScript.COAST_MAX + cell
	var steps := int(ceil(span * 2.0 / cell))
	for iz in steps:
		for ix in steps:
			var x := -span + (float(ix) + 0.5) * cell
			var z := -span + (float(iz) + 0.5) * cell
			if not island.is_land(x, z):
				continue
			var cs := CollisionShape3D.new()
			cs.shape = shape
			cs.position = Vector3(x, TOP_Y - half, z)   # 盒顶正好与岛顶面平齐
			body.add_child(cs)
	return body


## VoxelViewer 当"玩家"放在岛上空——视野距离与地形一致（岛小，不必外扩）。
static func attach_viewer(parent: Node3D) -> void:
	var anchor := Node3D.new()
	anchor.name = "ViewerAnchor"
	anchor.position = Vector3(0.0, TOP_Y, 0.0)
	parent.add_child(anchor)
	var viewer := VoxelViewer.new()
	viewer.name = "Viewer"
	viewer.view_distance = 48
	viewer.requires_visuals = true
	viewer.requires_collisions = false   # 碰撞由 add_deck_collision 代理，不走体素地形
	anchor.add_child(viewer)


# ---------- 相机 ----------

## 轨道相机 + 移轴景深属性 + 两个机位（bench 工作视角 / diorama 全景）。
## 岛外是天空，没有旧版"甲板外台地挡视线"的约束，机位可以从岛外自由取景。
static func make_orbit_camera(parent: Node3D, look_at: Vector3, preset_name: String) -> Camera3D:
	var target := Node3D.new()
	target.name = "OrbitTarget"
	target.position = look_at
	parent.add_child(target)

	var cam = OrbitCamScript.new()
	cam.name = "Camera"
	cam.fov = CAMERA_FOV
	cam.near = 0.1
	cam.far = 400.0
	cam.attributes = make_camera_attributes()
	cam.target = target
	parent.add_child(cam)          # _ready 里 make_current + 应用初始姿态
	cam.presets["bench"] = PRESET_BENCH
	cam.presets["diorama"] = PRESET_DIORAMA
	# Existing Tab slots use island-sized compositions in the sandbox.
	cam.presets["iso"] = {"yaw": 0.7854, "pitch": 0.80, "distance": 32.0,
		"ortho": true, "size": 32.0}
	cam.presets["front"] = {"yaw": 0.0, "pitch": 0.55, "distance": 30.0, "ortho": false}
	cam.presets["top"] = {"yaw": 0.0, "pitch": 1.52, "distance": 39.0, "ortho": false}
	cam.presets["close"] = {"yaw": 0.7854, "pitch": 0.80, "distance": 18.0, "ortho": false}
	cam.presets["vista"] = PRESET_DIORAMA
	for key in ["bench", "iso", "front", "top", "close"]:
		cam.presets[key] = cam.presets[key].duplicate()
		cam.presets[key]["focus_offset"] = Vector3.ZERO
		cam.presets[key]["fov"] = CAMERA_FOV
	# 进场机位直接就位（不补间）：见 OrbitCamera.snap_preset 的理由
	cam.snap_preset(preset_name if cam.presets.has(preset_name) else "bench")
	return cam


## 移轴景深属性。Godot 4.7 的 CameraAttributesPractical 只有一个全局
## dof_blur_amount（近/远各自只有距离与过渡），所以"虚化强度"这一档是共用的。
static func make_camera_attributes() -> CameraAttributesPractical:
	var a := CameraAttributesPractical.new()
	a.dof_blur_amount = 0.24       # 要"轻微移轴"：过了 0.4 整座岛都在糊，读不出形状
	a.dof_blur_far_enabled = true
	a.dof_blur_near_enabled = true
	return a


## 对焦带跟着当前轨道半径走：中间一条清晰带，近景台面细节与远景岛底各自虚化。
## 这就是"微缩"读感的核心——真实物件不会同时有前景和后景的虚化。
## 带宽刻意放宽（近 0.55d / 远 1.15d）：岛本身就有 28 m 纵深，收窄会把台面也糊掉。
static func sync_dof(cam: Camera3D) -> void:
	if cam == null or not is_instance_valid(cam):
		return
	if not (cam.attributes is CameraAttributesPractical):
		return
	if not cam.has_method("current_distance"):
		return
	var d: float = cam.current_distance()
	var a := cam.attributes as CameraAttributesPractical
	a.dof_blur_near_distance = d * 0.55
	a.dof_blur_near_transition = d * 0.28
	a.dof_blur_far_distance = d * 1.28
	a.dof_blur_far_transition = d * 0.48
