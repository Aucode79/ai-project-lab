extends SceneTree

## 存读档与跨 run diff 测试（docs/10-契约/交互方案.md §九 双轨）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/persistence/run_persistence_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##   1  存→改参数→加实体→读→装置复原：snapshot 逐字段一致（参数/端口/连接/绑定）
##   2  多槽位隔离与 list_slots / delete_slot
##   3  存档 JSON 不含位置坐标（编译器契约同款红线：逻辑不依赖摆法）
##   4  run_diff：两次 run 的 set_param 差异被逐条列出（参数名/旧值/新值；
##      含 4 与 4.0 数值相等不列、终值取最后一次写入、失败写入不算配置）
##   5  结果差：末步 world 摘要的端口终值与实体增删被点名（BOOL 差不与数字混淆）
##   6  评分差：五句中变化的维度被点名
##   7  totals 步数与 ops 数字正确
##   8  format_text 输出含中文差异句
##   9  坏槽位（文件损坏）load 结构化失败不崩、世界原样不动
##
## 装置示例（任务 3「接入示例」）：注入内核搭小装置演示
## 存档→改参→读档→装置复原，不接真关卡。

const DeviceStoreScript := preload("res://scripts/persistence/device_store.gd")
const RunDiffScript := preload("res://scripts/persistence/run_diff.gd")

const ASSET_BELT := "conc_batch_belt"
const ASSET_GATE := "conc_tool_slot_gate"
const ASSET_BUTTON := "base_button"
const BELT := ASSET_BELT + "#1"
const GATE := ASSET_GATE + "#1"
const BUTTON := ASSET_BUTTON + "#1"
const SLOT_A := "persistence_demo_A"
const SLOT_B := "persistence_demo_B"
const SLOT_CORRUPT := "persistence_demo_corrupt"

const TASK_V1 := "读取 report.txt 并数出'错误'出现次数"
const TASK_V2 := "把 report.txt 里的'错误'全部替换成'warning'"
const SENT_EFF_1 := "本次运行共消耗 220 ops：写 9 次、演算 2 次。"
const SENT_EFF_2 := "本次运行共消耗 260 ops：写 11 次、演算 3 次。"
const SENT_READ_2 := "任务文本与说明文字覆盖率都有变化（换了一句）。"

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("== 存读档与跨 run diff 测试（交互方案 §九 双轨）==")
	_t01_save_mutate_load_restore()
	_t02_slots_isolated()
	_t03_no_positions_in_save()
	_t04_run_diff_config()
	_t05_run_diff_results()
	_t06_score_changes()
	_t07_totals()
	_t08_format_text()
	_t09_corrupt_slot()
	_t10_two_instances_diverged()
	_cleanup()
	print("")
	print("结果：PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _check(cond: bool, label: String) -> bool:
	if cond:
		_pass += 1
		print("PASS: " + label)
	else:
		_fail += 1
		print("FAIL: " + label)
	return cond


# ---------- 基础设施：注入内核 + 小装置 ----------

## 独立内核实例（不碰 autoload），注册三件资产后返回。
func _fresh_kernel() -> WorldStateCore:
	var st := WorldStateCore.new()
	st.register_asset(ASSET_BELT, WorldStateCore.KIND_PARAMETRIC,
		{"batch_size": 8}, [
			{"id": "samples_in", "kind": "ANALOG", "dir": "in"},
			{"id": "batch_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_GATE, WorldStateCore.KIND_PARAMETRIC,
		{"schema_fields": 3}, [
			{"id": "data_in", "kind": "ANALOG", "dir": "in"},
			{"id": "gate", "kind": "BOOL", "dir": "out", "value": false},
		])
	st.register_asset(ASSET_BUTTON, WorldStateCore.KIND_PARAMETRIC,
		{"threshold": 1}, [
			{"id": "touched", "kind": "BOOL", "dir": "in"},
			{"id": "pressed", "kind": "BOOL", "dir": "out"},
		])
	return st


## 接入示例的小装置：皮带→闸门连一条线，改两个参数，跑一遍让 in 口吃到值。
func _build_device(st: WorldStateCore) -> void:
	st.place(ASSET_BELT, [2, 0, 1])
	st.place(ASSET_GATE, [4, 0, 1])
	st.connect_ports(BELT + ":batch_out", GATE + ":data_in")
	st.set_param(BELT, "batch_size", 12)
	st.set_param(BELT, "@batch_out", 4.0)
	st.advance(1.0)
	st.propagate() # 模拟 world.run：沿边把 batch_out=4.0 写进 data_in


## snapshot 逐字段比较口径：位置不进存档（红线），t/tick 是世界时刻不是装置；
## 其余字段（含 signals/exists/ports/params/bindings/edges/schema）全比。
func _strip_for_compare(snap: Dictionary) -> Dictionary:
	var out: Dictionary = snap.duplicate(true)
	out.erase("t")
	out.erase("tick")
	var entities: Dictionary = out["entities"]
	for eid in entities:
		(entities[eid] as Dictionary).erase("pos")
	return out


## 数值相等口径：bool 严格按 bool 比，数值按容差比（JSON 往返 4 与 4.0 相等）。
func _veq(a: Variant, b: Variant) -> bool:
	if a is bool or b is bool:
		return (a is bool) and (b is bool) and bool(a) == bool(b)
	if (a is int or a is float) and (b is int or b is float):
		return absf(float(a) - float(b)) < 1e-9
	if a is Dictionary and b is Dictionary:
		return _deq(a, b)
	if a is Array and b is Array:
		return _aeq(a, b)
	if a is String or b is String:
		return (a is String) and (b is String) and str(a) == str(b)
	return JSON.stringify(a) == JSON.stringify(b)


func _deq(a: Dictionary, b: Dictionary) -> bool:
	if a.size() != b.size():
		return false
	for k in a:
		if not b.has(k) or not _veq(a[k], b[k]):
			return false
	return true


func _aeq(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if not _veq(a[i], b[i]):
			return false
	return true


func _delete_if_exists(store, slot: String) -> void:
	if FileAccess.file_exists("user://saves/%s.json" % slot):
		store.delete_slot(slot)


# ---------- 测试 ----------

## T1 存→改参数→加实体→读→装置复原（snapshot 逐字段一致）。
func _t01_save_mutate_load_restore() -> void:
	var st := _fresh_kernel()
	var store = DeviceStoreScript.new()
	_delete_if_exists(store, SLOT_A)
	_build_device(st)
	var snap_before := st.logical_snapshot()

	var saved: Dictionary = store.save(st, SLOT_A, "L1",
		[{"id": "g1", "members": [BELT, GATE]}])
	if not _check(bool(saved.get("ok", false)) and int(saved.get("entities", 0)) == 2 \
			and str(saved.get("level", "")) == "L1" and str(saved.get("path", "")).ends_with(SLOT_A + ".json"),
			"T1a save 成功：2 实体、带关卡号 L1、路径落在 user://saves/"):
		return

	# 改参数 + 改端口值 + 多放一个实体再连一条线（装置被弄乱）
	st.set_param(BELT, "batch_size", 99)
	st.set_param(BELT, "@batch_out", 0.0)
	st.place(ASSET_BUTTON, [6, 0, 1])
	st.connect_ports(BUTTON + ":pressed", GATE + ":data_in")
	st.set_param(GATE, "@gate", true)
	st.propagate()

	var loaded: Dictionary = store.load(st, SLOT_A)
	if not _check(bool(loaded.get("ok", false)) and int(loaded.get("entities", 0)) == 2 \
			and int(loaded.get("edges", 0)) == 1 and str(loaded.get("level", "")) == "L1",
			"T1b load 成功：清场重放回 2 实体 1 连接（按钮被清掉）、关卡号带回"):
		return
	var groups: Array = loaded.get("groups", [])
	var members: Array = (groups[0] as Dictionary).get("members", []) if groups.size() == 1 else []
	_check(groups.size() == 1 and str((groups[0] as Dictionary).get("id", "")) == "g1"
			and members.has(BELT) and members.has(GATE),
			"T1c 折叠组按编译器形状透传（g1 含皮带与闸门成员）")

	var snap_after := st.logical_snapshot()
	_check(_deq(_strip_for_compare(snap_before), _strip_for_compare(snap_after)),
		"T1d 读档后 snapshot 与存档时逐字段一致（除 pos/t/tick：位置不进档、时刻属世界）")

	# 逐字段抽查：参数、out 端口值、被连线驱动的 in 端口值、连接表、绑定表
	var gate_after: Dictionary = (snap_after["entities"] as Dictionary)[GATE]
	_check(_veq((snap_after["entities"] as Dictionary)[BELT]["params"]["batch_size"], 12)
			and _veq((snap_after["entities"] as Dictionary)[BELT]["ports"]["batch_out"]["value"], 4.0)
			and _veq(gate_after["ports"]["data_in"]["value"], 4.0)
			and _veq(gate_after["ports"]["gate"]["value"], false),
			"T1e 逐字段断言：batch_size=12、batch_out=4.0、data_in=4.0、gate=false 全部复原")
	var edges: Array = snap_after["edges"]
	_check(edges.size() == 1 and str(edges[0]["from"]) == BELT + ":batch_out" \
			and str(edges[0]["to"]) == GATE + ":data_in",
			"T1f 连接复原且只有存档时那条（后来加的按钮连线被清掉）")
	_check(_deq(snap_after["bindings"], snap_before["bindings"]),
		"T1g 绑定表复原")


## T2 多槽位隔离与列表/删除。
func _t02_slots_isolated() -> void:
	var st := _fresh_kernel()
	var store = DeviceStoreScript.new()
	_delete_if_exists(store, SLOT_A)
	_delete_if_exists(store, SLOT_B)
	_build_device(st)
	store.save(st, SLOT_A, "L1")
	st.set_param(BELT, "batch_size", 99) # 改参后再存 B：两槽位值不同
	store.save(st, SLOT_B, "L2")

	var slots: Array = store.list_slots()
	var names: Array = []
	for entry in slots:
		names.append(str((entry as Dictionary).get("slot", "")))
	var entry_a: Dictionary = {}
	for entry in slots:
		if str((entry as Dictionary).get("slot", "")) == SLOT_A:
			entry_a = entry
	_check(names.has(SLOT_A) and names.has(SLOT_B) and bool(entry_a.get("valid", false)) \
			and int(entry_a.get("entities", -1)) == 2 and int(entry_a.get("edges", -1)) == 1 \
			and str(entry_a.get("level", "")) == "L1" and str(entry_a.get("savedAt", "")).ends_with("Z"),
			"T2a list_slots 列出两个槽位（带实体/连接数、关卡号、Z 结尾时间戳）")

	store.load(st, SLOT_B)
	var v_b: Variant = (st.logical_snapshot()["entities"] as Dictionary)[BELT]["params"]["batch_size"]
	store.load(st, SLOT_A)
	var v_a: Variant = (st.logical_snapshot()["entities"] as Dictionary)[BELT]["params"]["batch_size"]
	_check(_veq(v_b, 99) and _veq(v_a, 12),
		"T2b 槽位隔离：B 读回 99、A 读回 12（互不串档）")

	var del: Dictionary = store.delete_slot(SLOT_A)
	var names2: Array = []
	for entry in store.list_slots():
		names2.append(str((entry as Dictionary).get("slot", "")))
	var gone: Dictionary = store.load(st, SLOT_A)
	_check(bool(del.get("ok", false)) and not names2.has(SLOT_A) and not bool(gone.get("ok", false)) \
			and str(gone.get("code", "")) == "no_such_slot",
			"T2c delete_slot 后列表消失、再 load 报 no_such_slot")


## T3 存档 JSON 不含位置坐标（红线）。
func _t03_no_positions_in_save() -> void:
	var st := _fresh_kernel()
	var store = DeviceStoreScript.new()
	_delete_if_exists(store, SLOT_A)
	_build_device(st)
	store.save(st, SLOT_A, "L1")
	var path := "user://saves/%s.json" % SLOT_A
	var raw := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(raw)
	var ok := parsed is Dictionary and not raw.contains("pos")
	if ok:
		ok = _no_key_deep(parsed, "pos") and _no_value_vector_deep(parsed)
	_check(ok, "T3 存档 JSON 不含位置坐标：原文无 'pos' 字样、解析后任意深度无 pos 键、无数组形坐标")


func _no_key_deep(v: Variant, key: String) -> bool:
	if v is Dictionary:
		var d: Dictionary = v
		if d.has(key):
			return false
		for k in d:
			if not _no_key_deep(d[k], key):
				return false
	if v is Array:
		for item in v:
			if not _no_key_deep(item, key):
				return false
	return true


## 粗筛数组形坐标：长度 3 的纯数字数组（实体 pos 的序列化形状）。
func _no_value_vector_deep(v: Variant) -> bool:
	if v is Array:
		var a: Array = v
		if a.size() == 3:
			var all_num := true
			for item in a:
				if not (item is int or item is float):
					all_num = false
			if all_num:
				return false
		for item in a:
			if not _no_value_vector_deep(item):
				return false
	if v is Dictionary:
		for k in v:
			if not _no_value_vector_deep((v as Dictionary)[k]):
				return false
	return true


# ---------- run 合成输入（schema v6 形状，scoring 测试同款拼法） ----------

func _step(i: int, phase: String, tool: String, args: Dictionary, ops: int,
		world: Dictionary = {"entities": {}, "highlight": []}) -> Dictionary:
	return {
		"i": i, "t": 0.0, "phase": phase, "actor": "agent", "causes": [],
		"input": {}, "action": {"tool": tool, "args": args},
		"output": {"ok": true}, "tokens": 0, "ops": ops, "costMs": 0.01,
		"world": world, "caption": "", "formula": "",
	}


func _sp_step(i: int, eid: String, key: String, value: Variant, ok := true) -> Dictionary:
	var s := _step(i, "build", "world.set_param",
		{"entityId": eid, "key": key, "value": value}, 20)
	if not ok:
		(s["output"] as Dictionary)["ok"] = false
	return s


func _score_step(i: int, dims: Array) -> Dictionary:
	return _step(i, "score", "level.score", {"stub": true, "dimensions": dims}, 0)


func _entities_world(entities: Dictionary) -> Dictionary:
	return {"entities": entities, "highlight": []}


func _port(kind: String, dir: String, value: Variant) -> Dictionary:
	return {"kind": kind, "dir": dir, "value": value}


## run A：task_text 写两次（终值 TASK_V2）、batch_size=8、schema_fields=3（B 没有）、
## @batch_out=4（int）、@samples=2；run B：task_text=TASK_V1、batch_size=12、
## @batch_out=9.0、@samples=2.0（与 A 数值相等，不应列出）、一次失败的写入。
func _run_a() -> Dictionary:
	return _mkrun("rA-001", [
		_sp_step(0, "board#1", "task_text", TASK_V1),
		_sp_step(1, BELT, "batch_size", 8),
		_sp_step(2, GATE, "schema_fields", 3),
		_sp_step(3, BELT, "@batch_out", 4),
		_sp_step(4, BELT, "@samples", 2),
		_sp_step(5, "board#1", "task_text", TASK_V2),
		_step(6, "run", "world.run", {"duration": 1.0}, 20,
			_entities_world({
				BELT: {"params": {"batch_size": 8}, "exists": true, "ports": {
					"samples_in": _port("ANALOG", "in", 0.0),
					"batch_out": _port("ANALOG", "out", 4.0)}},
				GATE: {"params": {"schema_fields": 3}, "exists": true, "ports": {
					"data_in": _port("ANALOG", "in", 4.0),
					"gate": _port("BOOL", "out", false)}},
			})),
		_score_step(7, _dims_a()),
	])


func _run_b() -> Dictionary:
	return _mkrun("rB-002", [
		_sp_step(0, "board#1", "task_text", TASK_V1),
		_sp_step(1, BELT, "batch_size", 12),
		_sp_step(2, BELT, "@batch_out", 9.0),
		_sp_step(3, BELT, "@samples", 2.0),
		_sp_step(4, GATE, "schema_fields", 999, false), # 失败的写入不算配置
		_step(5, "run", "world.run", {"duration": 1.0}, 20,
			_entities_world({
				BELT: {"params": {"batch_size": 12}, "exists": true, "ports": {
					"samples_in": _port("ANALOG", "in", 0.0),
					"batch_out": _port("ANALOG", "out", 9.0)}},
				GATE: {"params": {"schema_fields": 3}, "exists": true, "ports": {
					"data_in": _port("ANALOG", "in", 9.0),
					"gate": _port("BOOL", "out", true)}},
				BUTTON: {"params": {"threshold": 1}, "exists": true, "ports": {
					"touched": _port("BOOL", "in", false),
					"pressed": _port("BOOL", "out", false)}},
			})),
		_score_step(6, _dims_b()),
	])


func _mkrun(run_id: String, steps: Array) -> Dictionary:
	return {
		"schemaVersion": 6,
		"run": {"runId": run_id, "kind": "task", "episode": 49, "seed": 1,
			"rulesetVersion": "world-kernel/1", "engineHash": "godot-4.7.2-test",
			"startedAt": "2026-09-14T00:00:00Z"},
		"steps": steps,
		"failures": [],
	}


func _dims_a() -> Array:
	return [
		{"dim": "正确性", "sentence": "任务目标已达成（A 版）。"},
		{"dim": "结构", "sentence": "流程按 看→装→跑→改→评 分段推进（A 版）。"},
		{"dim": "效率", "sentence": SENT_EFF_1},
		{"dim": "鲁棒性", "sentence": "没有触发 failure（A 版）。"},
		{"dim": "可读性", "sentence": "任务文本直接写在任务牌上（A 版）。"},
	]


func _dims_b() -> Array:
	return [
		{"dim": "正确性", "sentence": "任务目标已达成（A 版）。"},   # 与 A 相同：不应点名
		{"dim": "结构", "sentence": "流程按 看→装→跑→改→评 分段推进（A 版）。"}, # 同
		{"dim": "效率", "sentence": SENT_EFF_2},                    # 变了
		{"dim": "鲁棒性", "sentence": "没有触发 failure（A 版）。"}, # 同
		{"dim": "可读性", "sentence": SENT_READ_2},                 # 变了
	]


func _diff_ab() -> Dictionary:
	return RunDiffScript.new().diff(_run_a(), _run_b())


func _config_entry(changes: Array, eid: String, key: String) -> Dictionary:
	for c in changes:
		if str((c as Dictionary).get("entityId", "")) == eid and str((c as Dictionary).get("key", "")) == key:
			return c
	return {}


## T4 set_param 差异逐条列出（参数名/旧值/新值）。
func _t04_run_diff_config() -> void:
	var d := _diff_ab()
	if not _check(bool(d.get("ok", false)) and str(d.get("runA", "")) == "rA-001" \
			and str(d.get("runB", "")) == "rB-002",
			"T4a diff 两份 run JSON 成功，runId 各就各位"):
		return
	var changes: Array = d["config_changes"]
	var ok := changes.size() == 4
	for c in changes:
		ok = ok and (c as Dictionary).has("from") and (c as Dictionary).has("to")
	_check(ok, "T4b 配置差恰好 4 处（每处带 from/to）：%s" % str(changes.size()))

	var e1 := _config_entry(changes, "board#1", "task_text")
	var e2 := _config_entry(changes, BELT, "batch_size")
	var e3 := _config_entry(changes, GATE, "schema_fields")
	var e4 := _config_entry(changes, BELT, "@batch_out")
	var e5 := _config_entry(changes, BELT, "@samples")
	_check(str(e1.get("from", "")) == TASK_V2 and str(e1.get("to", "")) == TASK_V1,
		"T4c task_text 差异：终值取最后一次写入（从 TASK_V2 到 TASK_V1），旧值新值逐条给出")
	_check(_veq(e2.get("from"), 8) and _veq(e2.get("to"), 12),
		"T4d batch_size 差异：从 8 到 12")
	_check(_veq(e3.get("from"), 3) and e3.get("to") == null,
		"T4e schema_fields 只在 A 写过：from=3、to=null（B 侧未出现）")
	_check(_veq(e4.get("from"), 4) and _veq(e4.get("to"), 9.0) and e5.is_empty(),
		"T4f @batch_out 从 4 到 9.0 被列出；@samples 4≈4.0 一类数值相等不列（int/float 同价）")


## T5 结果差：末步 world 摘要对比（端口终值 + 实体增删）。
func _t05_run_diff_results() -> void:
	var d := _diff_ab()
	var changes: Array = d["result_changes"]
	var port_data_in := {}
	var port_gate := {}
	var port_batch := {}
	var added := false
	for r in changes:
		var rd: Dictionary = r
		if str(rd.get("kind", "")) == "port_value":
			if str(rd.get("entityId", "")) == GATE and str(rd.get("portId", "")) == "data_in":
				port_data_in = rd
			elif str(rd.get("entityId", "")) == GATE and str(rd.get("portId", "")) == "gate":
				port_gate = rd
			elif str(rd.get("entityId", "")) == BELT and str(rd.get("portId", "")) == "batch_out":
				port_batch = rd
		if str(rd.get("kind", "")) == "entity_added" and str(rd.get("entityId", "")) == BUTTON:
			added = true
	_check(changes.size() == 4 and not port_data_in.is_empty() and not port_gate.is_empty() \
			and not port_batch.is_empty() and added,
		"T5a 结果差恰好 4 处：batch_out/data_in/gate 端口终值 + button#1 新增实体")
	_check(_veq(port_data_in.get("from"), 4.0) and _veq(port_data_in.get("to"), 9.0)
			and bool(port_gate.get("from")) == false and bool(port_gate.get("to")) == true,
		"T5b 端口终值从旧到新：data_in 4.0→9.0、gate false→true（布尔差不与数字混淆）")


## T6 评分差：五句中变化的维度被点名。
func _t06_score_changes() -> void:
	var d := _diff_ab()
	var changes: Array = d["score_changes"]
	var ok := changes.size() == 2
	var dims := []
	for s in changes:
		dims.append(str((s as Dictionary).get("dim", "")))
	ok = ok and dims.has("效率") and dims.has("可读性") and not dims.has("正确性")
	var eff := {}
	for s in changes:
		if str((s as Dictionary).get("dim", "")) == "效率":
			eff = s
	ok = ok and str(eff.get("from", "")) == SENT_EFF_1 and str(eff.get("to", "")) == SENT_EFF_2
	_check(ok, "T6 评分差只点名变化的维度（效率、可读性），句子从旧到新全文给出；未变维度不出场")


## T7 totals 步数与 ops。
func _t07_totals() -> void:
	var d := _diff_ab()
	var totals: Dictionary = d["totals"]
	var steps_t: Dictionary = totals["steps"]
	var ops_t: Dictionary = totals["ops"]
	# A：8 步（6 次 set_param×20 + 1 次 run×20 + score 0 = 140 ops）
	# B：7 步（5 次 set_param×20，其中一次失败也计价 + 1 次 run×20 = 120 ops）
	_check(int(steps_t["a"]) == 8 and int(steps_t["b"]) == 7 and int(steps_t["delta"]) == -1 \
			and int(ops_t["a"]) == 140 and int(ops_t["b"]) == 120 and int(ops_t["delta"]) == -20,
		"T7 totals 数字正确：步数 8→7（Δ-1）、ops 140→120（Δ-20）")


## T8 format_text 中文差异句。
func _t08_format_text() -> void:
	var text: String = RunDiffScript.new().format_text(_diff_ab())
	print(text)
	_check(text.contains("参数 board#1:task_text 从 %s 改成 %s" % [TASK_V2, TASK_V1])
			and text.contains("端口 %s:data_in 从 4.0 变到 9.0" % GATE)
			and text.contains("维度「效率」的句子变了")
			and text.contains("实体 %s 是新出现的" % BUTTON)
			and text.contains("步数 8 → 7") and text.contains("ops 140 → 120"),
		"T8 format_text 输出中文差异句：参数从…改成…、端口从…变到…、维度点名、合计数字")
	var same := RunDiffScript.new().format_text(RunDiffScript.new().diff(_run_a(), _run_a()))
	_check(same.contains("没有差异"), "T8b 两次相同 run 的 format_text 明说无差异，不编话")


## T9 坏槽位：文件损坏 load 结构化失败不崩、世界原样不动。
func _t09_corrupt_slot() -> void:
	var st := _fresh_kernel()
	var store = DeviceStoreScript.new()
	DirAccess.make_dir_recursive_absolute("user://saves")
	var path := "user://saves/%s.json" % SLOT_CORRUPT
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string("{ 这不是 JSON [[[")
	f.close()

	var snap_before := st.logical_snapshot()
	var bad: Dictionary = store.load(st, SLOT_CORRUPT)
	_check(not bool(bad.get("ok", true)) and str(bad.get("code", "")) == "corrupt_slot"
			and _deq(st.logical_snapshot(), snap_before),
		"T9a 坏槽位 load 结构化失败（corrupt_slot）不崩，且世界原样未动（校验先行、不清场）")

	var missing: Dictionary = store.load(st, "persistence_demo_不存在的槽位")
	var bad_name: Dictionary = store.load(st, "../evil")
	_check(str(missing.get("code", "")) == "no_such_slot" and str(bad_name.get("code", "")) == "bad_slot_name",
		"T9b 缺槽位报 no_such_slot；非法槽位名（路径穿越）报 bad_slot_name")

	var crashed := false
	var slots: Array = []
	slots = store.list_slots() # 坏档在列表里也不炸
	var corrupt_entry: Dictionary = {}
	for entry in slots:
		if str((entry as Dictionary).get("slot", "")) == SLOT_CORRUPT:
			corrupt_entry = entry
	_check(not crashed and bool(corrupt_entry.get("valid", true)) == false,
		"T9c list_slots 遇坏档不崩，以 valid:false 列出（UI 才能引导删除）")
	_check(bool(store.delete_slot(SLOT_CORRUPT).get("ok", false)),
		"T9d 坏档也能被 delete_slot 清走")


# ---------- 收尾 ----------

## T10 同资产两实例、绑定指向 #2、两实例参数分叉：读档逐实例复原。
## （写口径与内核一致：未绑定实例不可写——存档时 #1 的参数是改绑前写进去的，
## 读档得靠临时改绑重放，再拨回存档的绑定表。）
func _t10_two_instances_diverged() -> void:
	var st := _fresh_kernel()
	var store = DeviceStoreScript.new()
	_delete_if_exists(store, SLOT_A)
	st.place(ASSET_BELT, [0, 0, 0])          # #1 自动绑
	st.set_param(BELT, "batch_size", 15)      # 绑在 #1 时改参
	st.place(ASSET_BELT, [1, 0, 0])           # #2（绑定已有，不自动绑）
	st.bind(ASSET_BELT, ASSET_BELT + "#2")    # 显式改绑到 #2
	st.set_param(ASSET_BELT + "#2", "batch_size", 16)
	var snap_before := st.logical_snapshot()

	var loaded: Dictionary = store.load(st, SLOT_A) if bool(store.save(st, SLOT_A).get("ok", false)) else {}
	if not _check(bool(loaded.get("ok", false)) and int(loaded.get("entities", 0)) == 2,
			"T10a 两实例装置存取成功（2 实体）"):
		return
	var snap_after := st.logical_snapshot()
	_check(_deq(_strip_for_compare(snap_before), _strip_for_compare(snap_after)),
		"T10b 读档后 snapshot 与存档时逐字段一致（#1=15、#2=16、绑定指向 #2）")
	_check(_veq((snap_after["entities"] as Dictionary)[BELT]["params"]["batch_size"], 15)
			and _veq((snap_after["entities"] as Dictionary)[ASSET_BELT + "#2"]["params"]["batch_size"], 16)
			and str((snap_after["bindings"] as Dictionary)[ASSET_BELT]) == ASSET_BELT + "#2",
		"T10c 逐字段断言：两个实例各自的参数与绑定表指向全部复原")


func _cleanup() -> void:
	var store = DeviceStoreScript.new()
	for slot in [SLOT_A, SLOT_B, SLOT_CORRUPT]:
		_delete_if_exists(store, slot)
