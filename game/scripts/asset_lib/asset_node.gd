extends Node3D
const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 三层资产库 · 基础件 base_ 与机械 mach_ 的公共基座（spec §3.3 / §4.3）。
## 与 scripts/compiler 同一约定：不用 class_name，消费方一律
## extends "res://scripts/asset_lib/asset_node.gd"（check-only 不读全局类缓存，
## class_name 在干净缓存下解析不到，实测报 Could not find base class）。
##
## 只提供三样东西：
##   1. 教学资产颜色角色（asset_style.gd；地形与历史 bench 配方独立）
##   2. 纯色材质工厂：哑光底 + 少量精确发光（发光不是越多越高科技）
##   3. 端口挂接：Marker3D 名为 Port_{id}，附 0.25 半块发光方标（块状化 v2：
##      端口标记也是可见工艺件，尺寸/中心入半块格），与 asset.yaml 的
##      ports 一一对应（tests/assets/run_asset_tests.gd 逐件核对）
##
## 几何与参数由各资产脚本在 _ready 里自建；本基座不含任何 @export，
## 不干扰"export 参数集 == defaults 键集"的测试断言。
## 物理纪律（bench_world.gd 踩平的坑）也在这里留档：
##   - 刚体在体素碰撞就绪前一律冻结，就绪门（射线探针）放行后再 arm
##   - 堆叠刚体解冻后置 sleeping，靠睡眠态保住稳定

## 标准方块边长——全库唯一尺寸来源。标准方块 = 正立方体，边长固定 0.5 m，
## 形状大小不可调：它是这套世界的基本量（1 方块 = 1 个 token/样本，尺寸恒定
## 才能度量）。任何 token 方块不得自定尺寸；例外只有 bench（历史测量复现
## 环境）与纯装饰非 token 部件（见 docs/10-契约/方块体系.md「标准方块 · 基本量」）。
const STANDARD_CUBE_SIZE := 0.5

enum { PAL_DEEP, PAL_ROCK, PAL_FRAME, PAL_DECK, PAL_MACHINE, PAL_CORE, PAL_CIRCUIT }

const PALETTE := Style.PALETTE

const PORT_PREFIX := "Port_"
## 端口方标边长：半块 0.25（块状化 v2，最小可见单位；编译器不读端口位置，
## 位置纯视觉/交互参考，见 docs/10-契约/方块体系.md §6.2）
const PORT_MARK_SIZE := 0.25


func make_material(palette_index: int, metallic := 0.0, roughness := 0.80) -> StandardMaterial3D:
	var idx := clampi(palette_index, 0, PALETTE.size() - 1)
	var m := StandardMaterial3D.new()
	m.albedo_color = PALETTE[idx]
	if idx == PAL_CORE:
		# 核心只保留轻微自发光，其余角色使用哑光材质。
		m.emission_enabled = true
		m.emission = PALETTE[idx]
		m.emission_energy_multiplier = 0.35
		m.roughness = 0.60
		m.metallic = 0.0
	else:
		m.roughness = roughness
		m.metallic = metallic
	return m


func add_box(parent: Node, box_name: String, size: Vector3, position: Vector3,
		palette_index: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = box_name
	var mesh := Surface.mesh(size)
	mi.material_override = make_material(palette_index)
	mi.mesh = mesh
	mi.position = position
	parent.add_child(mi)
	return mi


func add_port(port_id: String, position: Vector3) -> Marker3D:
	var marker := Marker3D.new()
	marker.name = PORT_PREFIX + port_id
	marker.position = position
	add_child(marker)
	add_box(marker, "Mark", Vector3.ONE * PORT_MARK_SIZE, Vector3.ZERO, PAL_CORE)
	return marker


func port(port_id: String) -> Marker3D:
	return get_node_or_null(NodePath(PORT_PREFIX + port_id)) as Marker3D


func port_ids() -> Array[String]:
	var out: Array[String] = []
	for c in get_children():
		if c is Marker3D and str(c.name).begins_with(PORT_PREFIX):
			out.append(str(c.name).substr(PORT_PREFIX.length()))
	return out
