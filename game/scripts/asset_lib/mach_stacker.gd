extends "res://scripts/asset_lib/asset_node.gd"

## mach_stacker 堆叠架：把 token 方块码成摞的框架。堆叠刚体遵守 bench
## 踩平的两条纪律：
##   1. 就绪门前一律冻结（freeze + FREEZE_MODE_STATIC）——世界碰撞没就绪就
##      解冻，整摞会穿进地面（bench 第一版实测：方块穿透飞出 367 m）
##   2. arm() 解冻后置 sleeping=true——解冻瞬间的接触求解会注入横向抖动把
##      高摞震塌，睡眠态是堆叠物保稳的常规做法
## 码放的方块是标准方块：STANDARD_CUBE_SIZE（基座常量，0.5 m 正立方体，
## 不可调）——1 方块 = 1 个 token/样本（docs/10-契约/方块体系.md「标准方块 · 基本量」）。
## y 链全按 0.5 m（1U）整格：基座厚 0.5（顶面 y=0.5），第 i 块中心
## = 0.5 + 0.5*(i-0.5)，塔底块贴基座顶。
## assets/mach_stacker/asset.yaml: defaults {stack_height: 3}

@export var stack_height: int = 3

const FRAME_H := 2.0            # 4U

var _cubes: Array[RigidBody3D] = []
var _built := false


func _ready() -> void:
	_build()


func arm() -> void:
	# 就绪门之后调用：解冻 + 睡眠保稳
	for c in _cubes:
		c.freeze = false
		c.sleeping = true


func stack_cubes() -> Array[RigidBody3D]:
	return _cubes


func _build() -> void:
	if _built:
		return
	_built = true
	# 基座 3U×1U×3U：进堆叠高度链，厚度必须整格（原 0.08 升 0.5），顶面 y=0.5
	add_box(self, "Base", Vector3(1.5, 0.5, 1.5), Vector3(0.0, 0.25, 0.0), PAL_DECK)
	# 柱贴基座缘（柱心 ±0.625，柱廓 ±0.5..±0.75 与基座缘平齐；外延落格口径
	# 要求 0.25 粗柱的心在奇半格上）
	var post := 0.625
	add_box(self, "PostA", Vector3(0.25, FRAME_H, 0.25),
		Vector3(-post, FRAME_H * 0.5, -post), PAL_FRAME)
	add_box(self, "PostB", Vector3(0.25, FRAME_H, 0.25),
		Vector3(post, FRAME_H * 0.5, -post), PAL_FRAME)
	add_box(self, "PostC", Vector3(0.25, FRAME_H, 0.25),
		Vector3(-post, FRAME_H * 0.5, post), PAL_FRAME)
	add_box(self, "PostD", Vector3(0.25, FRAME_H, 0.25),
		Vector3(post, FRAME_H * 0.5, post), PAL_FRAME)

	var shape := BoxShape3D.new()
	shape.size = Vector3.ONE * STANDARD_CUBE_SIZE
	var mesh := BoxMesh.new()
	mesh.size = Vector3.ONE * STANDARD_CUBE_SIZE
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.05
	for i in maxi(1, stack_height):
		var body := RigidBody3D.new()
		body.name = "StackCube%d" % i
		# y = 0.5（Base 顶 1U）+ 0.25（半块）+ 0.5*(i-1)，i 从 1 计：每块一整格
		body.position = Vector3(0.0, 0.5 + STANDARD_CUBE_SIZE * (0.5 + float(i - 1)), 0.0)
		body.mass = 1.0
		body.physics_material_override = pm
		body.freeze = true
		body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC

		var cs := CollisionShape3D.new()
		cs.shape = shape
		body.add_child(cs)

		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var mat := StandardMaterial3D.new()
		mat.albedo_color = PALETTE[PAL_MACHINE if i % 2 == 0 else PAL_DECK]
		mat.roughness = 0.6
		mat.metallic = 0.1
		mi.material_override = mat
		body.add_child(mi)
		add_child(body)
		_cubes.append(body)

	# 端口方标 0.25 嵌入基座侧面 0.125（外面与基座面平齐），底坐台面（y 廓 0..0.25）
	add_port("intake", Vector3(-0.875, 0.125, -0.125))
	add_port("release", Vector3(0.875, 0.125, -0.125))
