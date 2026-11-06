extends "res://scripts/asset_lib/asset_node.gd"

## mach_conveyor 传送带。做法照抄 bench_world.gd 已踩平的路：
##   - 带面 = AnimatableBody3D 平台，在 _physics_process 里平移，
##     靠摩擦把上面的刚体带走（摩擦 PhysicsMaterial：friction 1.0、bounce 0）
##   - 就绪门纪律：running 只经 arm() 置位——调用方先用射线探针确认世界碰撞
##     就绪、放好被搬运物（冻结），再 arm 放行（防止整摞穿进地面）
##   - 单向前进到 travel_max 后停住；reset_run() 归零，供下一遍拍摄
##
## assets/mach_conveyor/asset.yaml: defaults {belt_speed: 0.8, belt_length: 4.0}

@export var belt_speed: float = 0.8
@export var belt_length: float = 4.0

const BELT_WIDTH := 1.0         # 2U：主轮廓宽（框与护栏；带面收窄 0.5 贴护栏内缘防共面闪面，见 _build）
const BELT_THICK := 0.25        # 带面厚半块（块状化 v2：最小可见单位 0.25）
const RAIL_H := 0.25            # 护栏高半块，坐在框顶（外延落格：心在奇半格 0.625）
const SURFACE_Y := 0.625        # 带面中心（坐在框顶：底 0.5 = 框顶，顶 0.75，凸 0.25）
# 高度链（v2）：Frame 厚 0.5 心 0.25 → 顶 0.5；带面厚 0.25 心 0.625（坐在框顶）→ 顶 0.75

var running := false
var _travel := 0.0
var _surface: AnimatableBody3D = null
var _built := false


func _ready() -> void:
	_build()


func _physics_process(delta: float) -> void:
	if not running or _surface == null:
		return
	var remaining := travel_max() - _travel
	if remaining <= 0.0:
		return
	var step := minf(remaining, belt_speed * delta)
	_travel += step
	_surface.position = Vector3(_travel, SURFACE_Y, 0.0)


func travel_max() -> float:
	return belt_length


func arm() -> void:
	# 放行传送带（就绪门之后调用）
	running = true


func reset_run() -> void:
	_travel = 0.0
	running = false
	if _surface != null:
		_surface.position = Vector3(0.0, SURFACE_Y, 0.0)


func surface_top_y() -> float:
	# 带面顶面的本地高度：测试/装配用来摆放被搬运的刚体
	return SURFACE_Y + BELT_THICK * 0.5


func _build() -> void:
	if _built:
		return
	_built = true

	# 静态框架：底板 + 两侧护栏（护栏纯视觉，不带碰撞，不磨带面）
	add_box(self, "Frame", Vector3(belt_length, 0.5, BELT_WIDTH),
		Vector3(0.0, 0.25, 0.0), PAL_FRAME)
	# 护栏贴框缘内侧（厚 0.25，z 廓 0.25..0.5，外面与框缘平齐；外延落格要求心在奇半格）
	var rail_z := 0.375
	add_box(self, "RailA", Vector3(belt_length, RAIL_H, 0.25),
		Vector3(0.0, SURFACE_Y, -rail_z), PAL_DECK)
	add_box(self, "RailB", Vector3(belt_length, RAIL_H, 0.25),
		Vector3(0.0, SURFACE_Y, rail_z), PAL_DECK)

	# 带面：AnimatableBody3D 平台（bench 同款），受 arm() 门控
	var body := AnimatableBody3D.new()
	body.name = "BeltSurface"
	body.position = Vector3(0.0, SURFACE_Y, 0.0)
	var plate_len := belt_length - 0.5   # 带面长=框长-0.5（默认 3.5，格上 14×0.25）
	# 带宽 0.5 = 2×0.25（BoxShape3D 与 BoxMesh 共用本值，物理+视觉同值）。
	# 防闪面口径（外延落格改版）：护栏贴框缘内侧 z 0.25..0.5，带面收进两护栏
	# 之间 z ±0.25——与护栏内缘面相贴、法向相反不闪；顶/底虽在 y 0.75/0.5 共面，
	# 但护栏与带面 z 向零重叠（在 0.25 面相触），共面无共面积，不闪。
	# 若改外移护栏到 z ±0.625，护栏会整体落到框缘之外，主轮廓超 2U，视觉不稳。
	var plate_size := Vector3(plate_len, BELT_THICK, 0.5)

	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = plate_size
	cs.shape = box
	body.add_child(cs)

	var mi := MeshInstance3D.new()
	mi.name = "Plate"
	var mesh := BoxMesh.new()
	mesh.size = plate_size
	mesh.material = make_material(PAL_MACHINE)
	mi.mesh = mesh
	body.add_child(mi)

	var pm := PhysicsMaterial.new()
	pm.friction = 1.0
	pm.bounce = 0.0
	body.physics_material_override = pm
	_surface = body
	add_child(body)

	# 端口方标 0.25 嵌入框端面/侧面 0.125（外面与框面平齐），y 廓与带面同层（0.5..0.75）
	add_port("feed", Vector3(-belt_length * 0.5 + 0.125, SURFACE_Y, -0.125))
	add_port("discharge", Vector3(belt_length * 0.5 - 0.125, SURFACE_Y, -0.125))
	add_port("power", Vector3(-0.125, SURFACE_Y, BELT_WIDTH * 0.5 - 0.125))
