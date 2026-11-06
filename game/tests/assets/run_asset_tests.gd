extends SceneTree

## 资产库测试（三层资产库前两层：基础件 base_ 7 件 + 机械 mach_ 5 件，spec §3.3）。
##
## 跑法：
##   "$GODOT" --headless --path game -s res://tests/assets/run_asset_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##  - 12 件场景全部可加载、可实例化、进树完成自建
##  - 每件 @export 参数名集合 == asset.yaml defaults 键集合，且出厂默认值一致
##    （defaults 是出厂参数唯一来源，spec §4.3）
##  - 每件 Marker3D 端口与 yaml ports 一一对应（双向不重不漏）
##  - mach_conveyor 真搬运：就绪门（射线探针）放行后，2 秒内刚体方块位移 >0.5 m
##    （AnimatableBody3D + 摩擦，bench_world.gd 已踩平的做法）
##  - mach_verify_gate 开/关切换：is_open 翻转且门板实际位移；set_verdict 走关岔
##  - mach_stacker 物理纪律：就绪门前全冻结，arm 后睡眠保稳、1 秒内不散架

const YAML_LITE := preload("res://scripts/asset_lib/yaml_lite.gd")

const ASSET_IDS := [
	"base_block", "base_track", "base_container", "base_gate", "base_slot",
	"base_wire", "base_label",
	"mach_conveyor", "mach_splitter", "mach_stacker", "mach_counter",
	"mach_verify_gate",
]

const PORT_PREFIX := "Port_"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("== 资产库测试 ==")
	_run()


func _run() -> void:
	# SceneTree._initialize 阶段 root 自身尚未 ready，此时 add_child 的节点
	# 要等首帧后才补发 _ready（几何/端口都是 _ready 里建的）。统一等一帧再开测。
	await process_frame
	_t_instantiate_all()
	_t_exports_match_defaults()
	_t_ports_match_yaml()
	await _t_conveyor_carries()
	await _t_verify_gate_toggles()
	await _t_stacker_discipline()
	print("")
	print("结果：PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(name: String, cond: bool, note := "") -> void:
	if cond:
		_pass += 1
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name, "" if note == "" else "  —— %s" % note)


# ---------- 路径与记录 ----------

func _repo_assets_dir() -> String:
	# assets/ 在仓库根（game/ 的上一级），不在 res:// 内
	var game_dir := String(ProjectSettings.globalize_path("res://")).trim_suffix("/")
	return game_dir.get_base_dir().path_join("assets")


func _scene_path(asset_id: String) -> String:
	return "res://scenes/assets/%s.tscn" % asset_id


func _load_record(asset_id: String) -> Dictionary:
	return YAML_LITE.parse_file(
		_repo_assets_dir().path_join(asset_id).path_join("asset.yaml"))


func _instantiate(asset_id: String, parent: Node = null) -> Node3D:
	var packed := load(_scene_path(asset_id)) as PackedScene
	if packed == null:
		return null
	var inst := packed.instantiate() as Node3D
	if parent == null:
		parent = root
	parent.add_child(inst)
	return inst


# ---------- 1. 场景可实例化 ----------

func _t_instantiate_all() -> void:
	for id in ASSET_IDS:
		var inst := _instantiate(id)
		var ok := inst != null and inst.get_child_count() > 0
		if inst != null:
			inst.queue_free()
		_check("场景实例化 %s" % id, ok)


# ---------- 2. @export 参数 == defaults 键 ----------

func _t_exports_match_defaults() -> void:
	for id in ASSET_IDS:
		var record := _load_record(id)
		if record.is_empty():
			_check("@export == defaults 键 %s" % id, false, "asset.yaml 解析失败")
			continue
		var inst := _instantiate(id)
		var defaults: Dictionary = record.get("defaults", {})

		var yaml_keys: Array[String] = []
		for k in defaults.keys():
			yaml_keys.append(str(k))
		yaml_keys.sort()
		var export_keys := _exported_param_names(inst)
		var same := yaml_keys.size() == export_keys.size()
		if same:
			for i in yaml_keys.size():
				if yaml_keys[i] != export_keys[i]:
					same = false
					break
		_check("@export == defaults 键 %s" % id, same,
			"yaml=%s export=%s" % [str(yaml_keys), str(export_keys)])

		var notes: Array[String] = []
		var values_ok := true
		for key in export_keys:
			if not _scalar_equals(defaults.get(key), inst.get(key)):
				values_ok = false
				notes.append("%s: yaml=%s gd=%s" % [key, str(defaults.get(key)), str(inst.get(key))])
		_check("出厂默认值一致 %s" % id, values_ok, "；".join(notes))
		inst.queue_free()


func _exported_param_names(inst: Node) -> Array[String]:
	# 只取"@export 的脚本变量"：SCRIPT_VARIABLE + EDITOR 两个 usage 位同时置位
	var out: Array[String] = []
	if inst == null:
		return out
	for p in inst.get_property_list():
		var usage := int(p.get("usage", 0))
		var pname := str(p.get("name", ""))
		if pname != "" and (usage & PROPERTY_USAGE_SCRIPT_VARIABLE) \
				and (usage & PROPERTY_USAGE_EDITOR):
			out.append(pname)
	out.sort()
	return out


func _scalar_equals(a: Variant, b: Variant) -> bool:
	if a is float or b is float:
		if a is int or a is float:
			if b is int or b is float:
				return is_equal_approx(float(a), float(b))
		return false
	if typeof(a) != typeof(b):
		return false
	return a == b


# ---------- 3. Marker3D 端口 == yaml ports ----------

func _t_ports_match_yaml() -> void:
	for id in ASSET_IDS:
		var record := _load_record(id)
		if record.is_empty():
			_check("端口一一对应 %s" % id, false, "asset.yaml 解析失败")
			continue
		var inst := _instantiate(id)

		var yaml_ids: Array[String] = []
		for p in record.get("ports", []):
			yaml_ids.append(str(p.get("id", "")))
		yaml_ids.sort()

		var marker_ids: Array[String] = []
		var all_markers := true
		for c in inst.get_children():
			if str(c.name).begins_with(PORT_PREFIX):
				marker_ids.append(str(c.name).substr(PORT_PREFIX.length()))
				if not (c is Marker3D):
					all_markers = false
		marker_ids.sort()

		var same := all_markers and yaml_ids == marker_ids
		_check("Marker3D 端口一一对应 %s" % id, same,
			"yaml=%s 场景=%s" % [str(yaml_ids), str(marker_ids)])
		inst.queue_free()


# ---------- 4. mach_conveyor 真搬运 ----------

func _t_conveyor_carries() -> void:
	var rig := Node3D.new()
	rig.name = "ConveyorRig"
	root.add_child(rig)
	rig.add_child(_make_ground())

	var conv := _instantiate("mach_conveyor", rig)
	var top_y := float(conv.call("surface_top_y"))

	var cube := _make_cargo(Vector3(0.0, top_y + 0.27, 0.0))
	rig.add_child(cube)

	# 就绪门纪律：射线探针确认地面碰撞体就绪，才放行物理（bench_world.gd）
	var gate_ready := false
	for i in 120:
		await physics_frame
		var query := PhysicsRayQueryParameters3D.create(Vector3(6.0, 4.0, 6.0),
			Vector3(6.0, -2.0, 6.0))
		query.collide_with_areas = false
		var hit: Dictionary = root.get_world_3d().direct_space_state.intersect_ray(query)
		if hit.has("position") and absf(float(hit["position"].y)) < 0.1:
			gate_ready = true
			break
	_check("mach_conveyor 就绪门放行（射线命中地面）", gate_ready)

	var start := cube.global_position
	cube.freeze = false
	conv.call("arm")

	var moved := false
	var frames := 0
	for i in 130:            # ~2.2 s @60 Hz，验收口径 2 秒
		await physics_frame
		frames += 1
		if cube.global_position.distance_to(start) > 0.5:
			moved = true
			break
	var disp := cube.global_position.distance_to(start)
	_check("mach_conveyor 2 秒内搬走刚体（位移>0.5 m）", moved,
		"位移 %.2f m / %d 帧" % [disp, frames])
	rig.queue_free()


# ---------- 5. mach_verify_gate 开/关 ----------

func _t_verify_gate_toggles() -> void:
	var gate := _instantiate("mach_verify_gate")
	var lifted0 := float(gate.call("door_lifted"))
	_check("mach_verify_gate 初始关闭", not bool(gate.get("is_open")) and lifted0 < 0.05,
		"抬升 %.2f" % lifted0)

	gate.call("set_open", true)
	await _wait_physics(50)
	var lifted1 := float(gate.call("door_lifted"))
	_check("mach_verify_gate set_open(true) 门板抬升", bool(gate.get("is_open")) and lifted1 > 0.5,
		"抬升 %.2f" % lifted1)

	gate.call("set_verdict", false)   # 拒绝 → fail_closed=true → 关门走岔
	await _wait_physics(50)
	var lifted2 := float(gate.call("door_lifted"))
	_check("mach_verify_gate 拒绝后关门（set_verdict 路径）",
		not bool(gate.get("is_open")) and str(gate.get("verdict")) == "reject" and lifted2 < 0.05,
		"抬升 %.2f verdict=%s" % [lifted2, str(gate.get("verdict"))])
	gate.queue_free()


# ---------- 6. mach_stacker 堆叠纪律 ----------

func _t_stacker_discipline() -> void:
	var rig := Node3D.new()
	rig.name = "StackerRig"
	root.add_child(rig)
	rig.add_child(_make_ground())

	var stacker := _instantiate("mach_stacker", rig)
	var cubes: Array = stacker.call("stack_cubes")

	var frozen_before := cubes.size() > 0
	for c in cubes:
		frozen_before = frozen_before and (c as RigidBody3D).freeze
	_check("mach_stacker 就绪门前全部冻结", frozen_before)

	stacker.call("arm")
	var armed := true
	for c in cubes:
		var body := c as RigidBody3D
		armed = armed and not body.freeze and body.sleeping
	_check("mach_stacker arm 后解冻且置睡眠（保稳纪律）", armed)

	await _wait_physics(60)           # 1 s：睡眠态的摞不该散
	var stable := cubes.size() > 0
	for c in cubes:
		var body := c as RigidBody3D
		var drift := Vector2(body.global_position.x, body.global_position.z).length()
		if drift > 0.4 or body.global_position.y < 0.1:
			stable = false
	_check("mach_stacker 睡眠态 1 秒内不散架", stable)
	rig.queue_free()


# ---------- 公共小件 ----------

func _make_ground() -> StaticBody3D:
	# 测试自带静态地面（顶面 y=0），不依赖体素地形的流式碰撞
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(40.0, 0.5, 40.0)
	cs.shape = box
	ground.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(40.0, 0.5, 40.0)
	mi.mesh = mesh
	ground.add_child(mi)
	ground.position = Vector3(0.0, -0.25, 0.0)
	return ground


func _make_cargo(pos: Vector3) -> RigidBody3D:
	# 被搬运的刚体方块（bench 同款参数：摩擦 0.9、先冻结，就绪门后才解冻）
	var cube := RigidBody3D.new()
	cube.name = "Cargo"
	cube.mass = 1.0
	cube.freeze = true
	cube.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	var cs := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.5, 0.5, 0.5)
	cs.shape = box
	cube.add_child(cs)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.5, 0.5, 0.5)
	mi.mesh = mesh
	cube.add_child(mi)
	var pm := PhysicsMaterial.new()
	pm.friction = 0.9
	pm.bounce = 0.05
	cube.physics_material_override = pm
	cube.position = pos
	return cube


func _wait_physics(frames: int) -> void:
	for i in frames:
		await physics_frame
