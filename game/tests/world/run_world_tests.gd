extends SceneTree

## 世界侧内核测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/world/run_world_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##   1  place→connect→set_param→run 全链路产出合法 run 记录 JSON（schema 字段齐全、steps>=4）
##   2  落盘即冻结：end_run 只写一次、冻结后 record_step 被拒、文件内容不变
##   3  同一份记录加载两次，重放后 world.read 结论一致（逻辑稳定不变量，spec §7.3）
##   4  snapshot 只取状态层，不含物理内部量
##   5  ops 计数正确且写贵读廉（写 20 读 1），外部代码可读
##   6  未知工具名 / 错误参数 → 结构化 failure，不崩溃
##   7  绑定表：同资产两实例按 #1/#2 区分，未绑定实例操作被拒
##   8  物理桥：接触事件上报一次生效、重复上报被拒、事件进步记录
##   9  trace / watch 可观测性订阅
##  10  export_netlist 输出连接图文本
##  11  world.diff 检出两步之间的状态差异
##  12  project.godot 的 autoload 注册段（名字与顺序）
##  13  无 autoload 环境下 WorldToolsCore 兜底实例可用（godot -s 模式）

const ASSET_BELT := "conc_batch_belt"
const ASSET_GATE := "conc_tool_slot_gate"
const ASSET_BUTTON := "base_button"
const ASSET_DEBRIS := "fx_debris"

const STEP_KEYS := ["action", "actor", "causes", "caption", "costMs", "formula", "i", "input",
	"ops", "output", "phase", "t", "tokens", "world"]
const RUN_KEYS := ["engineHash", "episode", "kind", "runId", "rulesetVersion", "seed", "startedAt"]
const TOP_KEYS := ["failures", "run", "schemaVersion", "steps"]
const SNAP_KEYS := ["bindings", "edges", "entities", "schema", "t", "tick"]
const ENTITY_KEYS := ["assetId", "entityId", "exists", "index", "kind", "params", "ports", "pos", "signals"]

var _passed := 0
var _failed := 0
var _garbage: Array[Node] = []


func _initialize() -> void:
	_t01_schema_and_pipeline()
	_t02_frozen_after_end_run()
	_t03_replay_logic_stable()
	_t04_snapshot_state_layer_only()
	_t05_ops_pricing()
	_t06_structured_failures()
	_t07_bindings_two_instances()
	_t08_physics_bridge()
	_t09_trace_watch()
	_t10_netlist()
	_t11_diff()
	_t12_autoload_registered()
	_t13_fallback_without_autoload()
	_cleanup_garbage()
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ---------- 基础设施 ----------

func _make_assets(st: WorldStateCore) -> void:
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
	st.register_asset(ASSET_DEBRIS, WorldStateCore.KIND_DECO, {}, [])


## 独立一套内核实例（不碰共享/autoload），测试互不污染。
func _fresh(begin: bool) -> Dictionary:
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	var tools := WorldToolsCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	_make_assets(st)
	_garbage.append(st)
	_garbage.append(rc)
	_garbage.append(cm)
	_garbage.append(tools)
	if begin:
		var b := rc.begin_run(StepRecorderCore.KIND_TASK, 49, 12345)
		assert(bool(b["ok"]), "begin_run 必须成功")
	return {"st": st, "rc": rc, "cm": cm, "tools": tools}


## place→place→connect→set_param→run→read 全链路。
func _pipeline(tools: WorldToolsCore) -> Array:
	var out: Array = []
	out.append(tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [2, 0, 1]}))
	out.append(tools.call_tool("world.place", {"assetId": ASSET_GATE, "pos": [4, 0, 1]}))
	out.append(tools.call_tool("world.connect", {"from": ASSET_BELT + "#1:batch_out", "to": ASSET_GATE + "#1:data_in"}))
	out.append(tools.call_tool("world.set_param", {"entityId": ASSET_BELT + "#1", "key": "@batch_out", "value": 4}))
	out.append(tools.call_tool("world.run", {"duration": 1.0}))
	out.append(tools.call_tool("world.read", {"ref": ASSET_GATE + "#1:data_in"}))
	return out


## 重放器：世界初始化（资产注册）在工具序列之外（spec §4.5：绑定表同理），
## 所以重放前先声明同样的资产，再按 steps[].action 逐条重放 world.* 工具。
func _replay(doc: Dictionary) -> WorldToolsCore:
	var kit := _fresh(false)
	var steps: Array = doc["steps"]
	for step in steps:
		var action: Dictionary = step["action"]
		if not str(action.get("tool", "")).begins_with("world."):
			continue
		(kit["tools"] as WorldToolsCore).call_tool(str(action["tool"]), action.get("args", {}))
	return kit["tools"]


func _cleanup_garbage() -> void:
	for n in _garbage:
		if n != null and is_instance_valid(n):
			n.free()
	_garbage.clear()


func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


func _keys_eq(d: Dictionary, want: Array) -> bool:
	var got: Array = d.keys()
	got.sort()
	var w := want.duplicate()
	w.sort()
	return got == w


## 测试产物清理（DirAccess.remove 是实例方法，不能直接当静态调）
func _remove_file(res_path: String) -> void:
	var d := DirAccess.open("res://")
	if d != null:
		d.remove(res_path.replace("res://", ""))


func _deep_eq(a: Variant, b: Variant) -> bool:
	var ta := typeof(a)
	var tb := typeof(b)
	if ta != tb:
		if (ta == TYPE_INT or ta == TYPE_FLOAT) and (tb == TYPE_INT or tb == TYPE_FLOAT):
			return float(a) == float(b)
		return false
	if ta == TYPE_DICTIONARY:
		var da: Dictionary = a
		var db: Dictionary = b
		if da.size() != db.size():
			return false
		for k in da:
			if not db.has(k) or not _deep_eq(da[k], db[k]):
				return false
		return true
	if ta == TYPE_ARRAY:
		var aa: Array = a
		var ab: Array = b
		if aa.size() != ab.size():
			return false
		for i in aa.size():
			if not _deep_eq(aa[i], ab[i]):
				return false
		return true
	return a == b


# ---------- 测试 ----------

func _t01_schema_and_pipeline() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var results := _pipeline(tools)
	var ok_all := true
	for r in results:
		ok_all = ok_all and bool(r["ok"])
	var end: Dictionary = (kit["rc"] as StepRecorderCore).end_run()
	if not _check(ok_all and bool(end["ok"]), "T1 全链路 6 个工具全部成功且 run 落盘"):
		return
	var path := str(end["path"])
	var doc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var ok := _keys_eq(doc, TOP_KEYS) and int(doc["schemaVersion"]) == 6
	ok = ok and _keys_eq(doc["run"], RUN_KEYS) and int((doc["run"] as Dictionary)["episode"]) == 49
	ok = ok and (doc["steps"] as Array).size() >= 4
	ok = ok and doc["failures"] is Array
	var steps: Array = doc["steps"]
	for s in steps:
		if not _keys_eq(s, STEP_KEYS):
			ok = false
			break
	ok = ok and int(steps[0]["i"]) == 0 and (steps[0]["causes"] as Array).is_empty()
	for k in range(1, steps.size()):
		var causes: Array = steps[k]["causes"]
		# JSON round-trip 后数字变 float：[0.0] == [0] 在 GDScript 里是 false，必须按数值比
		if causes.size() != 1 or float(causes[0]) != float(k - 1):
			ok = false
	ok = ok and str((steps[0] as Dictionary)["action"]["tool"]) == "world.place"
	ok = ok and (steps[0]["action"]["args"] as Dictionary).has("assetId")
	ok = ok and (steps[5]["world"]["entities"] as Dictionary).has(ASSET_BELT + "#1")
	ok = ok and ((steps[5]["world"] as Dictionary)["highlight"] is Array)
	ok = ok and float(steps[5]["world"]["entities"][ASSET_GATE + "#1"]["ports"]["data_in"]["value"]) == 4.0
	_check(ok, "T1 run 记录 schema v6 字段一一对上、steps>=4、传播结果 4.0")
	# 冻结文本与文件一致（供 T2 复用的前提）
	_check((kit["rc"] as StepRecorderCore).frozen_text() == FileAccess.get_file_as_string(path),
		"T1 内存冻结文本 == 落盘文件内容")
	_remove_file(path)


func _t02_frozen_after_end_run() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var rc: StepRecorderCore = kit["rc"]
	_pipeline(tools)
	var rid1 := rc.run_id()
	var end1: Dictionary = rc.end_run()
	var path := str(end1["path"])
	var bytes_before := FileAccess.get_file_as_string(path)
	var end2: Dictionary = rc.end_run()
	var after_repeat := FileAccess.get_file_as_string(path)
	var step_i := rc.record_step({"t": 0.0, "action": {"tool": "world.place", "args": {}}})
	var ok := bool(end1["ok"]) and not bool(end2["ok"]) and str(end2.get("code", "")) == "already_frozen"
	ok = ok and step_i == -1 and bytes_before == after_repeat
	ok = ok and rc.state_name() == "frozen"
	# 冻结后允许开新 run（新 runId、新文件），旧文件不受影响
	var begin2: Dictionary = rc.begin_run(StepRecorderCore.KIND_EXPLORE, -1, 7)
	ok = ok and bool(begin2["ok"]) and str(begin2["runId"]) != rid1
	ok = ok and bytes_before == FileAccess.get_file_as_string(path)
	_check(ok, "T2 落盘即冻结：二次 end_run 被拒、record_step 返 -1、文件只写一次、可开新 run")
	_remove_file(path)


func _t03_replay_logic_stable() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	_pipeline(tools)
	var end: Dictionary = (kit["rc"] as StepRecorderCore).end_run()
	var path := str(end["path"])
	# 同一文件读两次，parse 结果 deep 相等
	var text1 := FileAccess.get_file_as_string(path)
	var doc_a: Dictionary = JSON.parse_string(text1)
	var doc_b: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	var stable_file := _deep_eq(doc_a, doc_b)
	# 两次独立重放，read 同一 portRef，结论一致，且与原记录最后一步的世界一致
	var ref := ASSET_GATE + "#1:data_in"
	var read_a: Dictionary = (_replay(doc_a) as WorldToolsCore).call_tool("world.read", {"ref": ref})
	var read_b: Dictionary = (_replay(doc_b) as WorldToolsCore).call_tool("world.read", {"ref": ref})
	var last_steps: Array = doc_a["steps"]
	var recorded: Variant = last_steps[last_steps.size() - 1]["world"]["entities"][ASSET_GATE + "#1"]["ports"]["data_in"]["value"]
	var ok := stable_file and bool(read_a["ok"]) and bool(read_b["ok"])
	ok = ok and _deep_eq(read_a["result"]["value"], read_b["result"]["value"])
	ok = ok and _deep_eq(read_a["result"]["value"], recorded)
	_check(ok, "T3 同一份记录加载两次、重放两次，world.read 结论一致（== %s）" % str(recorded))
	_remove_file(path)


func _t04_snapshot_state_layer_only() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var st: WorldStateCore = kit["st"]
	_pipeline(tools)
	tools.call_tool("world.watch", {"ref": ASSET_BELT + "#1:batch_out"})
	var snap: Dictionary = tools.call_tool("world.snapshot", {})["result"]["snapshot"]
	var text := JSON.stringify(snap)
	var ok := _keys_eq(snap, SNAP_KEYS)
	for eid in snap["entities"]:
		if not _keys_eq(snap["entities"][eid], ENTITY_KEYS):
			ok = false
	# 物理内部量一个都不许出现；订阅表也不是世界状态
	for forbidden in ["velocity", "impulse", "force", "angular", "transform", "mass", "watchers", "collision"]:
		if text.to_lower().contains(forbidden):
			ok = false
	_check(ok, "T4 snapshot 只取状态层：键集精确、无任何物理内部量、不含订阅表")


func _t05_ops_pricing() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var cm: CostModelCore = kit["cm"]
	tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [1, 0, 1]})
	var after_write := cm.total_ops
	tools.call_tool("world.read", {"ref": ASSET_BELT + "#1:batch_out"})
	var after_read := cm.total_ops
	tools.call_tool("world.set_param", {"entityId": ASSET_BELT + "#1", "key": "batch_size", "value": 16})
	var after_write2 := cm.total_ops
	tools.call_tool("world.step", {})
	var after_exec := cm.total_ops
	var steps: Array = (kit["rc"] as StepRecorderCore).get_steps()
	var step_ops: Array = []
	for s in steps:
		step_ops.append(int(s["ops"]))
	# 单价外部可读（学员代码读的就是这两个常量/方法）
	var pricing := CostModelCore.WRITE_OPS == 20 and CostModelCore.READ_OPS == 1 \
		and cm.price_of(CostModelCore.MODE_WRITE) == 20 and cm.price_of(CostModelCore.MODE_READ) == 1
	var ok := pricing and after_write == 20 and after_read == 21 and after_write2 == 41 and after_exec == 61
	ok = ok and step_ops == [20, 1, 20, 20]
	_check(ok, "T5 ops：写 20 读 1、run/step 同为 20、total_ops 外部可读、每步 ops 进记录")


func _t06_structured_failures() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var r1: Dictionary = tools.call_tool("world.nope", {"x": 1})
	var r2: Dictionary = tools.call_tool("world.place", {})
	var r3: Dictionary = tools.call_tool("world.place", {"assetId": "missing_asset", "pos": [0, 0, 0]})
	var r4: Dictionary = tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": "not_array"})
	var r5: Dictionary = tools.call_tool("world.set_param", {"entityId": "ghost#1", "key": "k", "value": 1})
	var rc: StepRecorderCore = kit["rc"]
	var failures: Array = rc.get_doc()["failures"]
	var codes: Array = []
	for f in failures:
		codes.append(str(f["code"]))
	var ok := not bool(r1["ok"]) and str(r1["error"]["code"]) == "unknown_tool" and str(r1["error"]["message"]) != ""
	ok = ok and not r2["ok"] and str(r2["error"]["code"]) == "bad_args"
	ok = ok and not r3["ok"] and str(r3["error"]["code"]) == "unknown_asset"
	ok = ok and not r4["ok"] and str(r4["error"]["code"]) == "bad_args"
	ok = ok and not r5["ok"] and str(r5["error"]["code"]) == "unknown_entity"
	ok = ok and codes.has("unknown_tool") and codes.has("bad_args") and codes.has("unknown_asset")
	for f in failures:
		ok = ok and _keys_eq(f, ["code", "diagnosis", "failId", "stepRef"])
	# 没崩的证据：失败之后还能正常干活
	var alive: Dictionary = tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [9, 9, 9]})
	ok = ok and bool(alive["ok"])
	_check(ok, "T6 未知工具/缺参/错类型/未知实体/未知资产 -> 结构化 error + failures 条目，且进程存活")


func _t07_bindings_two_instances() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var st: WorldStateCore = kit["st"]
	tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [2, 0, 1]})
	var p2: Dictionary = tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [3, 0, 1]})
	var second := str(p2["result"]["entityId"])
	tools.call_tool("world.place", {"assetId": ASSET_GATE, "pos": [4, 0, 1]})
	var set_first: Dictionary = tools.call_tool("world.set_param", {"entityId": ASSET_BELT + "#1", "key": "batch_size", "value": 4})
	var set_second: Dictionary = tools.call_tool("world.set_param", {"entityId": second, "key": "batch_size", "value": 4})
	# 两端端口都存在，但源实例未被绑定表选中 -> 拒绝操作
	var conn_second: Dictionary = tools.call_tool("world.connect", {"from": second + ":batch_out", "to": ASSET_GATE + "#1:data_in"})
	var ok := second == ASSET_BELT + "#2" and str(st.logical_snapshot()["bindings"][ASSET_BELT]) == ASSET_BELT + "#1"
	ok = ok and bool(set_first["ok"])
	ok = ok and not bool(set_second["ok"]) and str(set_second["error"]["code"]) == "entity_not_bound"
	ok = ok and not bool(conn_second["ok"]) and str(conn_second["error"]["code"]) == "entity_not_bound"
	# 显式改绑到 #2 后，#2 可操作、#1 被拒
	var rebind: Dictionary = st.bind(ASSET_BELT, second)
	var set_second2: Dictionary = tools.call_tool("world.set_param", {"entityId": second, "key": "batch_size", "value": 6})
	var set_first2: Dictionary = tools.call_tool("world.set_param", {"entityId": ASSET_BELT + "#1", "key": "batch_size", "value": 6})
	ok = ok and bool(rebind["ok"]) and bool(set_second2["ok"]) and not bool(set_first2["ok"])
	# highlight 只跟绑定表走：observe 指向资产模板，解析出的是被绑定的实例
	st.set_observes([{"observeId": "o1", "targetRef": ASSET_BELT, "kind": "value", "expect": "batch_out > 0"}])
	ok = ok and st.resolve_highlight() == [second]
	_check(ok, "T7 绑定表：#1/#2 区分、未绑定实例 set_param/connect 被拒、改绑后翻转、highlight 跟绑定走")


func _t08_physics_bridge() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var st: WorldStateCore = kit["st"]
	tools.call_tool("world.place", {"assetId": ASSET_BUTTON, "pos": [1, 0, 0]})
	tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [2, 0, 0]})
	var bridge := PhysicsBridge.new(st)
	var r1: Dictionary = bridge.report_contact(ASSET_BUTTON + "#1", Vector3i(1, 0, 0))
	var r2: Dictionary = bridge.report_contact(ASSET_BUTTON + "#1", Vector3i(1, 0, 0))
	var touched := st.read_ref(ASSET_BUTTON + "#1:touched")
	var bridge_belt: Dictionary = bridge.report_contact(ASSET_BELT + "#1", Vector3i(2, 0, 0))
	var belt := st.read_ref(ASSET_BELT + "#1")
	# 事件进步记录：走 WorldToolsCore 的同一条记录通道
	var ev: Dictionary = tools.report_physics_event({"type": "contact", "entityId": ASSET_BUTTON + "#1", "cell": [1, 0, 3]})
	var steps: Array = (kit["rc"] as StepRecorderCore).get_steps()
	var last_step: Dictionary = steps[steps.size() - 1]
	var ok := bool(r1["ok"]) and not bool(r2["ok"]) and str(r2.get("code", "")) == "duplicate_event"
	ok = ok and bool(touched["ok"]) and bool(touched["value"]) # 有 touched 端口 -> 端口被置 true
	ok = ok and bool(bridge_belt["ok"]) and bool((belt["signals"] as Dictionary).get("contact", false)) # 无端口 -> signals
	ok = ok and bool(ev["ok"]) and str(last_step["phase"]) == "event" and str(last_step["actor"]) == "physics"
	ok = ok and str(last_step["action"]["tool"]) == "physics.contact"
	ok = ok and int(last_step["ops"]) == 0
	_check(ok, "T8 物理桥：接触上报一次生效（touched 端口 / signals）、重复上报被拒、事件进步记录(phase=event, actor=physics, ops=0)")


func _t09_trace_watch() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	var st: WorldStateCore = kit["st"]
	tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [2, 0, 1]})
	var w: Dictionary = tools.call_tool("world.watch", {"ref": ASSET_BELT + "#1:batch_out"})
	tools.call_tool("world.set_param", {"entityId": ASSET_BELT + "#1", "key": "@batch_out", "value": 4})
	tools.call_tool("world.run", {"duration": 1.0})
	var tr: Dictionary = tools.call_tool("world.trace", {"ref": ASSET_BELT + "#1:batch_out"})
	var history: Array = tr["result"]["history"]
	var ok := bool(w["ok"]) and str(w["result"]["watchId"]) == "w1" and float(w["result"]["current"]["value"]) == 0.0
	ok = ok and history.size() >= 3
	ok = ok and _deep_eq(history[0]["value"], 0.0) and _deep_eq(history[history.size() - 1]["value"], 4.0)
	var ts := 0.0
	for h in history:
		ok = ok and float(h["t"]) >= ts
		ts = float(h["t"])
	ok = ok and float(st.world_t()) > 0.0 and st.watchers().has("w1")
	_check(ok, "T9 watch 订阅拿 watchId 与初值、trace 给出值序列（0.0 -> 4.0，t 单调），订阅不进快照")


func _t10_netlist() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	_pipeline(tools)
	var r: Dictionary = tools.call_tool("world.export_netlist", {})
	var text: String = r["result"]["text"]
	var ok := bool(r["ok"]) and int(r["result"]["entities"]) == 2 and int(r["result"]["edges"]) == 1
	ok = ok and text.contains("ENTITY " + ASSET_BELT + "#1 parametric @ (2,0,1)")
	ok = ok and text.contains("PORT batch_out ANALOG out = 4")
	ok = ok and text.contains("CONN %s:batch_out -> %s:data_in" % [ASSET_BELT + "#1", ASSET_GATE + "#1"])
	_check(ok, "T10 export_netlist：实体/端口/连线逐行输出，端口类型明写（ANALOG out）")


func _t11_diff() -> void:
	var kit := _fresh(true)
	var tools: WorldToolsCore = kit["tools"]
	_pipeline(tools)
	var r: Dictionary = tools.call_tool("world.diff", {"fromStep": 0, "toStep": 3})
	var d: Dictionary = r["result"]["diff"]
	var ok := bool(r["ok"]) and int(r["result"]["fromStep"]) == 0 and int(r["result"]["toStep"]) == 3
	ok = ok and (d["added"] as Array).has(ASSET_GATE + "#1") # step0 只有 belt，step3 已有 gate
	ok = ok and (d["changed"] as Dictionary).has(ASSET_BELT + "#1") # set_param 改了端口值
	var ports_diff: Dictionary = d["changed"][ASSET_BELT + "#1"]["ports"]
	ok = ok and str(ports_diff["from"]["batch_out"]["value"]) == "0.0" and str(ports_diff["to"]["batch_out"]["value"]) == "4.0"
	var bad: Dictionary = tools.call_tool("world.diff", {"fromStep": 5, "toStep": 1})
	ok = ok and not bool(bad["ok"]) and str(bad["error"]["code"]) == "bad_args"
	_check(ok, "T11 world.diff：added/changed 检出 0->3 步差异（batch_out 0.0->4.0），非法区间结构化拒绝")


func _t12_autoload_registered() -> void:
	var text := FileAccess.get_file_as_string("res://project.godot")
	var lines := {
		"WorldState": 'WorldState="*res://scripts/autoload/world_state.gd"',
		"CostModel": 'CostModel="*res://scripts/autoload/cost_model.gd"',
		"StepRecorder": 'StepRecorder="*res://scripts/autoload/step_recorder.gd"',
		"WorldTools": 'WorldTools="*res://scripts/autoload/world_tools.gd"',
	}
	var positions: Array = []
	var ok := text.contains("[autoload]")
	for nm in ["WorldState", "CostModel", "StepRecorder", "WorldTools"]:
		var pos := text.find(lines[nm])
		ok = ok and pos >= 0
		positions.append(pos)
	for k in range(positions.size() - 1):
		ok = ok and positions[k] < positions[k + 1]
	_check(ok, "T12 project.godot 注册四个 autoload 且顺序 WorldState->CostModel->StepRecorder->WorldTools")


func _t13_fallback_without_autoload() -> void:
	# godot -s 模式下引擎不一定加载 autoload；WorldToolsCore 必须能兜底自建依赖。
	var loop := Engine.get_main_loop() as SceneTree
	var has_autoload := false
	if loop != null and loop.root != null:
		has_autoload = loop.root.get_node_or_null("WorldState") != null
	var tools := WorldToolsCore.new()
	_garbage.append(tools)
	var st := tools.state()
	if not has_autoload:
		# 只有兜底实例归测试清理；autoload 节点归引擎管，不能 free
		_garbage.append(st)
		_garbage.append(tools.recorder())
		_garbage.append(tools.cost())
	st.register_asset(ASSET_BELT, WorldStateCore.KIND_PARAMETRIC, {"batch_size": 8}, [])
	var r: Dictionary = tools.call_tool("world.place", {"assetId": ASSET_BELT, "pos": [0, 0, 0]})
	var read: Dictionary = tools.call_tool("world.read", {"ref": ASSET_BELT + "#1"})
	var ok := st is WorldStateCore and bool(r["ok"]) and bool(read["ok"])
	ok = ok and tools.state() == st # 依赖稳定复用同一实例
	if has_autoload:
		ok = ok and st == loop.root.get_node_or_null("WorldState")
	_check(ok, "T13 无注入环境：WorldToolsCore 解析到 autoload（有则用之），否则兜底实例，调用链完整可用")
