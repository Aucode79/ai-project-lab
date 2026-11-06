extends SceneTree

## 自由沙盒场景测试（headless，spec §9.1/§9.3 验收 3）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/sandbox/run_sandbox_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准，8 条）：
##  T1  场景实例化：生成台 28 件资产实体就位（视觉刚体 + 状态层实体一一对应）、
##      播放器方块与求助屏在场
##  T2  交互 hub setup 成功：轨道相机接管、entity_of 映射 28 件全部可交互、
##      落定上报/跑键回调已注入
##  T3  真实内核连线传播：world.connect + world.set_param + world.run 后
##      base_track:entry 读到 true（端口沿边传播）
##  T4  存档→改→读档复原：DeviceStore 存 28/1 → 改参 + 加实体（29/1）→
##      读档回 28 实体、参数复原、连线复原（再 run 一次传播照旧）
##  T5  导出按钮：export_now 产出非空 python 并写 user://sandbox_export.py、
##      反馈 Label3D 有摘要
##  T6  求助屏在场景里且 concept_map 可配置：set_concept_map 转发到屏与
##      hint_service、report_fail 计数链路活
##  T7  空格翻转：run_toggle true→false、场景回调两次、world.run 真推进 tick
##  T8  常量表对账：全量 28 件与 assets/assets.yaml（kind/footprint/端口数）及
##      assets/{id}/asset.yaml（端口 id/kind/dir、defaults 键集）逐字段一致

const SandboxScene := preload("res://scenes/sandbox/sandbox.tscn")
const AssetsScript := preload("res://scripts/sandbox/sandbox_assets.gd")

# 对账范围：全部 28 件（曾有抽样漏掉漂移的教训——见 2026-09-14 review）

var _passed := 0
var _failed := 0
var _scene: Node3D = null
var _hub = null


func _initialize() -> void:
	_run_all.call_deferred()


func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	return e


func _run_all() -> void:
	_scene = SandboxScene.instantiate()
	root.add_child(_scene)
	for i in 5:
		await create_timer(0.02).timeout
	_hub = _scene.get_interaction_hub()

	_t01_scene_and_bench()
	_t02_hub_setup()
	_t03_kernel_wire_propagation()
	await _t04_save_modify_load()
	_t05_export_python()
	_t06_help_screen_concept_map()
	_t07_space_toggle()
	_t08_assets_yaml_audit()

	_scene.free()
	await physics_frame   # 让释放落地，干净退出
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ---------- T1 场景实例化 + 生成台 28 件 ----------

func _t01_scene_and_bench() -> void:
	var items: Array = _scene.get_bench_items()
	var snap: Dictionary = _scene.state.logical_snapshot()
	var entities: Dictionary = snap["entities"]
	var ids_ok := items.size() == 28 and entities.size() == 28
	var mapped_ok := true
	var seen: Dictionary = {}
	for item in items:
		var eid := str(item.get_meta("entity_id"))
		var aid := str(item.get_meta("asset_id"))
		if eid == "" or not entities.has(eid) or seen.has(aid):
			mapped_ok = false
			break
		if str((entities[eid] as Dictionary).get("assetId", "")) != aid:
			mapped_ok = false
			break
		seen[aid] = true
	var utility_ok: bool = _scene.get_player_screen() != null and _scene.get_help_screen() != null
	_check(ids_ok and mapped_ok and seen.size() == 28 and utility_ok,
		"T1 场景实例化：生成台 28 件实体就位（视觉刚体 ↔ 状态层实体一一对应、28 资产各一件）、播放器方块与求助屏在场")


# ---------- T2 交互 hub setup ----------

func _t02_hub_setup() -> void:
	var cam := _scene.get_node_or_null("Camera") as Camera3D
	var ok := _hub != null and cam != null and cam.current
	ok = ok and cam.get_script() == preload("res://scripts/interaction/orbit_camera.gd")
	ok = ok and _hub.camera == cam and _hub.world_root == _scene
	ok = ok and _hub.drag.predictor == _hub.predictor and _hub.router != null
	ok = ok and _hub.open_view != null and _hub.run != null
	ok = ok and _hub.drag.landed_reporter.is_valid() and _hub.run.run_start.is_valid()
	ok = ok and _hub.run.step_forward_fn.is_valid()      # setup 注入的 world.step 仍在
	var interactable := true
	for item in _scene.get_bench_items():
		if str(_hub.entity_of.call(item)) == "":
			interactable = false
			break
	_check(ok and interactable,
		"T2 交互 hub setup 成功：轨道相机接管主相机、world_root/entity_of 接好、落定上报与跑键回调注入、28 件生成台实体全部可交互（entity_of 非空）")


# ---------- T3 真实内核：连线 → run → 端口传播 ----------

func _t03_kernel_wire_propagation() -> void:
	var tools = _scene.world_tools
	var r1: Dictionary = tools.call_tool("world.connect",
		{"from": "base_block#1:out", "to": "base_track#1:entry"})
	var r2: Dictionary = tools.call_tool("world.set_param",
		{"entityId": "base_block#1", "key": "@out", "value": true})
	var r3: Dictionary = tools.call_tool("world.run", {"duration": 1.0})
	var read: Dictionary = tools.call_tool("world.read", {"ref": "base_track#1:entry"})
	_check(bool(r1.get("ok", false)) and bool(r2.get("ok", false)) and bool(r3.get("ok", false)) \
		and bool(read.get("ok", false)) and bool(read.get("result", {}).get("value", false)),
		"T3 两件组件经 world 工具连线后 run 有端口传播：base_block:out → base_track:entry，@out=true 经 world.run 传播，读回 true（真实内核）")


# ---------- T4 存档 → 改 → 读档复原 ----------

func _t04_save_modify_load() -> void:
	_scene.save_slot = "sandbox_test"   # 测试槽位，不碰学员的 sandbox_1
	var before: Dictionary = _scene.state.logical_snapshot()
	var save_r: Dictionary = _scene.save_now()
	var slot_path := "user://saves/sandbox_test.json"
	var saved_file: bool = FileAccess.file_exists(slot_path)

	# 改：参数改色 + 多放一件 base_block + 删不掉的连线留着（29 实体状态）
	_scene.state.set_param("base_block#1", "color_index", 9)
	_scene.state.place("base_block", [30, 5, 30])
	var changed: Dictionary = _scene.state.logical_snapshot()
	var changed_ok: bool = (changed["entities"] as Dictionary).size() == 29 \
		and int((changed["entities"]["base_block#1"] as Dictionary)["params"]["color_index"]) == 9
	await create_timer(0.02).timeout

	var load_r: Dictionary = _scene.load_now()
	var after: Dictionary = _scene.state.logical_snapshot()
	var entities_after: Dictionary = after["entities"]
	var restored_entities: bool = (entities_after.size() as int) == 28
	var restored_param: bool = restored_entities \
		and int((entities_after["base_block#1"] as Dictionary)["params"]["color_index"]) == 3
	var restored_edges: Array = after["edges"]
	var restored_wiring: bool = restored_edges.size() == (before["edges"] as Array).size() \
		and restored_edges.size() == 1 \
		and str((restored_edges[0] as Dictionary).get("from", "")) == "base_block#1:out"
	# 连线复原的硬证据：再 run 一拍，传播照旧
	_scene.world_tools.call_tool("world.run", {"duration": 1.0})
	var read: Dictionary = _scene.world_tools.call_tool("world.read", {"ref": "base_track#1:entry"})
	var propagated: bool = bool(read.get("result", {}).get("value", false))
	# 生成台刚体的 entity_id 指向复原后的绑定实例
	var meta_ok := true
	var bindings: Dictionary = after["bindings"]
	for item in _scene.get_bench_items():
		if str(item.get_meta("entity_id")) != str(bindings.get(str(item.get_meta("asset_id")), "")):
			meta_ok = false
			break
	_check(bool(save_r.get("ok", false)) and saved_file and changed_ok \
		and bool(load_r.get("ok", false)) and restored_entities and restored_param \
		and restored_wiring and propagated and meta_ok,
		"T4 存档→改→读档复原：存 28 实体/1 连线落盘 → 改参+加实体（29）→ 读档回 28、参数与连线复原、再 run 传播照旧、生成台 entity_id 拨回绑定实例")


# ---------- T5 导出 Python ----------

func _t05_export_python() -> void:
	var out_path := "user://sandbox_export.py"
	var global_out := ProjectSettings.globalize_path(out_path)
	if FileAccess.file_exists(out_path):
		DirAccess.remove_absolute(global_out)   # 先清场：存在即旧产物，不算本次产出
	var r: Dictionary = _scene.export_now()
	var code := str(r.get("result", {}).get("python", ""))
	var written: bool = FileAccess.file_exists(out_path) \
		and FileAccess.get_file_as_string(out_path).length() > 0
	var feedback_ok: bool = _scene.get_feedback_label() != null \
		and _scene.get_feedback_label().text.contains("导出")
	_check(bool(r.get("ok", false)) and code.length() > 0 and written and feedback_ok,
		"T5 导出按钮产出 python 非空且写盘：export_now ok、code 非空、user://sandbox_export.py 已写入、反馈 Label3D 显示摘要")


# ---------- T6 求助屏 + concept_map 可配置 ----------

func _t06_help_screen_concept_map() -> void:
	var help = _scene.get_help_screen()
	var present: bool = help != null and help.level_id == "sandbox"
	_scene.set_concept_map({"sandbox": "c10.1"})
	var forwarded: bool = help != null \
		and (help.concept_map as Dictionary).get("sandbox", "") == "c10.1" \
		and help.hint_service != null \
		and (help.hint_service.concept_map as Dictionary).get("sandbox", "") == "c10.1"
	var counter_ok: bool = help != null and help.report_fail() == 1   # 计数链路活
	_check(present and forwarded and counter_ok,
		"T6 求助屏在场景里且 concept_map 可配置：level_id=sandbox、set_concept_map 转发屏本体与 hint_service、report_fail 计数链路活")


# ---------- T7 空格翻转 ----------

func _t07_space_toggle() -> void:
	var flips: Array = []
	_scene.run_drive_toggled.connect(func(r: bool): flips.append(r))
	var tick_before: int = _scene.state.tick()
	var space := _key(32)   # physical 32 = run_toggle 映射（同 l1 接线测试）
	_hub._unhandled_input(space)
	var first: bool = _hub.run.running and flips == [true] \
		and _scene.state.tick() > tick_before   # world.run 真推进（内核跑过）
	_hub._unhandled_input(space.duplicate())
	var second: bool = not _hub.run.running and flips == [true, false]
	_check(first and second and _scene.run_drive_count >= 2,
		"T7 空格翻转：run_toggle true→false、场景回调被调（run_drive_toggled 两次）、空格跑真推进世界 tick")


# ---------- T8 常量表对账（assets.yaml 抽 5 件） ----------

func _t08_assets_yaml_audit() -> void:
	var game_root := ProjectSettings.globalize_path("res://")
	var index_text := _read_text((game_root + "/../assets/assets.yaml").simplify_path())
	var all_ok := index_text != ""
	var problems: Array = []
	for aid in AssetsScript.asset_ids():
		var spec: Dictionary = AssetsScript.spec_of(aid)
		# 主索引：kind / footprint / ports 数
		var entry := _index_entry(index_text, aid)
		if entry.is_empty():
			all_ok = false
			problems.append("%s 不在主索引" % aid)
			continue
		if str(entry["kind"]) != str(spec["kind"]):
			all_ok = false
			problems.append("%s kind %s≠%s" % [aid, entry["kind"], spec["kind"]])
		if str(entry["block_types"]) != str(spec["block_types"]):
			all_ok = false
			problems.append("%s blockTypes %s≠%s" % [aid, entry["block_types"], spec["block_types"]])
		if str(entry["footprint"]) != str(spec["footprint"]):
			all_ok = false
			problems.append("%s footprint %s≠%s" % [aid, entry["footprint"], spec["footprint"]])
		if int(entry["ports"]) != (spec["ports"] as Array).size():
			all_ok = false
			problems.append("%s 端口数 %d≠%d" % [aid, entry["ports"], (spec["ports"] as Array).size()])
		# 单件真相：端口 id/kind/dir 逐个、defaults 键集
		var single := _read_text((game_root + "/../assets/%s/asset.yaml" % aid).simplify_path())
		var yaml_ports := _yaml_ports(single)
		var spec_ports: Array = spec["ports"]
		if yaml_ports.size() != spec_ports.size():
			all_ok = false
			problems.append("%s 单件端口数 %d≠%d" % [aid, yaml_ports.size(), spec_ports.size()])
		else:
			for i in yaml_ports.size():
				var yp: Dictionary = yaml_ports[i]
				var sp: Dictionary = spec_ports[i]
				if str(yp["id"]) != str(sp["id"]) or str(yp["kind"]) != str(sp["kind"]) \
						or str(yp["dir"]) != str(sp["dir"]):
					all_ok = false
					problems.append("%s 端口[%d] %s≠%s" % [aid, i, str(yp), str(sp)])
		var yaml_keys := _yaml_default_keys(single)
		var spec_keys: Array = (spec["defaults"] as Dictionary).keys()
		if yaml_keys.size() != spec_keys.size():
			all_ok = false
			problems.append("%s defaults 键数 %s≠%s" % [aid, str(yaml_keys), str(spec_keys)])
		else:
			for k in yaml_keys:
				if not (spec["defaults"] as Dictionary).has(k):
					all_ok = false
					problems.append("%s defaults 多出键 %s" % [aid, k])
	var detail := "；".join(PackedStringArray(problems)) if not problems.is_empty() else "28 件全对"
	_check(all_ok, "T8 常量表对账：全部 28 件与 assets.yaml 逐件一致（%s）" % [detail])


# ---------- 对账用的极简文本抽取（只服务本测试，不做通用 yaml） ----------

func _read_text(path: String) -> String:
	if not FileAccess.file_exists(path):
		push_error("对账文件缺失：%s" % path)
		return ""
	return FileAccess.get_file_as_string(path)


func _strip_comment(line: String) -> String:
	var cut := line.find(" #")
	if cut >= 0:
		return line.substr(0, cut)
	return line


## 主索引条目：抓 "- assetId: X" 到下一个条目之间的 kind/blockTypes/footprint/ports。
func _index_entry(text: String, aid: String) -> Dictionary:
	var lines := text.split("\n")
	var entry: Dictionary = {}
	var in_entry := false
	for line in lines:
		var l := _strip_comment(str(line))
		if l.begins_with("  - assetId: "):
			if in_entry:
				break   # 下一个条目开始
			in_entry = l.strip_edges() == "- assetId: " + aid
			continue
		if not in_entry:
			continue
		var t := l.strip_edges()
		if t.begins_with("kind: "):
			entry["kind"] = t.substr("kind: ".length())
		elif t.begins_with("blockTypes: "):
			entry["block_types"] = t.substr("blockTypes: ".length()).trim_prefix("[").trim_suffix("]").split(", ")
		elif t.begins_with("footprint: "):
			var inner := t.substr("footprint: ".length()).trim_prefix("[").trim_suffix("]")
			var parts := inner.split(",")
			entry["footprint"] = [int(parts[0].strip_edges()), int(parts[1].strip_edges())]
		elif t.begins_with("ports: "):
			entry["ports"] = int(t.substr("ports: ".length()))
	return entry


## 单件 yaml 的 ports 段：连续的 "- id:" 三行组（id/kind/dir）。
func _yaml_ports(text: String) -> Array:
	var out: Array = []
	var section := ""
	for line in text.split("\n"):
		var l := _strip_comment(str(line))
		var t := l.strip_edges()
		if t == "ports:":
			section = "ports"
			continue
		if t == "defaults:" or t == "shots:" or t == "scene:":
			section = ""
			continue
		if section != "ports":
			continue
		if t.begins_with("- id: "):
			out.append({"id": t.substr("- id: ".length()), "kind": "", "dir": ""})
		elif t.begins_with("kind: ") and not out.is_empty():
			(out[out.size() - 1] as Dictionary)["kind"] = t.substr("kind: ".length())
		elif t.begins_with("dir: ") and not out.is_empty():
			(out[out.size() - 1] as Dictionary)["dir"] = t.substr("dir: ".length())
	return out


## 单件 yaml 的 defaults 段：两空格缩进的 "key:" 行。
func _yaml_default_keys(text: String) -> Array:
	var out: Array = []
	var section := ""
	for line in text.split("\n"):
		var l := _strip_comment(str(line))
		var t := l.strip_edges()
		if t == "defaults:":
			section = "defaults"
			continue
		if t == "shots:" or t == "scene:" or t == "ports:":
			section = ""
			continue
		if section != "defaults" or t == "":
			continue
		if l.begins_with("  ") and not l.begins_with("    ") and t.contains(":") \
				and not t.begins_with("- "):
			out.append(t.split(":")[0])
	return out
