extends SceneTree

## 世界 ↔ 编译器集成测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/integration/run_integration_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 装置（带环 + 分岔，机械臂语义命名，6 实体 12 连接）：
##   agent_core(entry) → arm_sensor(think, max_turns=3) → route_gate(decide)
##     ├─ then：arm_actuator(step) → stop_gate(guard)
##     └─ else：stop_gate(guard)
##   stop_gate.retry → arm_sensor.ctl（校验回环）
##   stop_gate.done(exit) → mission_report(sink)
##
## 覆盖：
## 1  用 WorldTools 真实 place/connect/set_param 搭装置（全 ok，6 实体 12 连接）
## 2  world_to_graph 建图：形状对齐 graph_model 白名单；位置/朝向不进图
## 3  导出编译 ok：带环 + 分岔控制结构；set_param 的 max_turns=3 穿透进产物
## 4  导出 Python 写临时文件，wsl python3 真跑 exit=0
## 5  位置无关：同装置两种摆法导出逐字节相同（世界侧也成立）
## 6  netlist 实体覆盖与导出 python 一致
## 7  world.export_python 工具面：结构化返回 + 计价读 1 ops + 进步记录

const BRIDGE := preload("res://scripts/integration/world_to_graph.gd")

const A_CORE := "agent_core"
const A_SENSOR := "arm_sensor"
const A_GATE := "route_gate"
const A_ACT := "arm_actuator"
const A_STOP := "stop_gate"
const A_REPORT := "mission_report"

const ENTITY_KEYS := ["id", "kind", "params", "ports", "fold_group"]
const PORT_KEYS := ["dir", "kind", "name", "required", "type"]

var _pass := 0
var _fail := 0
var _garbage: Array[Node] = []


func _initialize() -> void:
	print("== 世界↔编译器集成测试 ==")
	_t01_build_device()
	_t02_graph_shape()
	_t03_compile_and_params()
	_t04_executable()
	_t05_position_independent()
	_t06_netlist_coverage()
	_t07_tool_export()
	_cleanup_garbage()
	print("")
	print("结果：PASS %d / FAIL %d" % [_pass, _fail])
	quit(1 if _fail > 0 else 0)


func _cleanup_garbage() -> void:
	for n in _garbage:
		if n != null and is_instance_valid(n):
			n.free()
	_garbage.clear()


func _check(name: String, cond: bool, note := "") -> void:
	if cond:
		_pass += 1
		print("PASS ", name)
	else:
		_fail += 1
		print("FAIL ", name, "" if note == "" else "  —— %s" % note)


# ---------------------------------------------------------------- 装置搭建

## 独立一套内核实例（不碰共享/autoload），测试互不污染。
func _fresh() -> Dictionary:
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	var tools := WorldToolsCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	_register_assets(st)
	_garbage.append(st)
	_garbage.append(rc)
	_garbage.append(cm)
	_garbage.append(tools)
	assert(bool(rc.begin_run(StepRecorderCore.KIND_TASK, 3, 20260914)["ok"]), "begin_run 必须成功")
	return {"st": st, "rc": rc, "cm": cm, "tools": tools}


## 资产声明即编译器投影约定（world_to_graph.gd 头注释）：保留参数
## block=编译器方块 kind；端口 id 命中控制词汇表（ctl/next/then/else/loop/done）
## 映射为控制端口，其余（in/out/state/payload）映射为数据端口。
func _register_assets(st: WorldStateCore) -> void:
	st.register_asset(A_CORE, WorldStateCore.KIND_PARAMETRIC, {"block": "entry"}, [
		{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		{"id": "next", "kind": "BOOL", "dir": "out"},
	])
	st.register_asset(A_SENSOR, WorldStateCore.KIND_PARAMETRIC, {"block": "think", "max_turns": 4}, [
		{"id": "in", "kind": "ANALOG", "dir": "in"},
		{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		{"id": "ctl", "kind": "BOOL", "dir": "in"},
		{"id": "next", "kind": "BOOL", "dir": "out"},
	])
	st.register_asset(A_GATE, WorldStateCore.KIND_PARAMETRIC, {"block": "decide"}, [
		{"id": "state", "kind": "ANALOG", "dir": "in"},
		{"id": "ctl", "kind": "BOOL", "dir": "in"},
		{"id": "then", "kind": "BOOL", "dir": "out"},
		{"id": "else", "kind": "BOOL", "dir": "out"},
	])
	st.register_asset(A_ACT, WorldStateCore.KIND_PARAMETRIC, {"block": "step"}, [
		{"id": "in", "kind": "ANALOG", "dir": "in"},
		{"id": "out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		{"id": "ctl", "kind": "BOOL", "dir": "in"},
		{"id": "next", "kind": "BOOL", "dir": "out"},
	])
	st.register_asset(A_STOP, WorldStateCore.KIND_PARAMETRIC, {"block": "guard"}, [
		{"id": "payload", "kind": "ANALOG", "dir": "in"},
		{"id": "ctl", "kind": "BOOL", "dir": "in"},
		{"id": "loop", "kind": "BOOL", "dir": "out"},
		{"id": "done", "kind": "BOOL", "dir": "out"},
	])
	st.register_asset(A_REPORT, WorldStateCore.KIND_PARAMETRIC, {"block": "sink"}, [
		{"id": "in", "kind": "ANALOG", "dir": "in"},
		{"id": "ctl", "kind": "BOOL", "dir": "in"},
	])


## 用真实 WorldTools 调用搭装置；dx 只影响 pos（编译不读 pos，位置无关用）。
func _build_device(env: Dictionary, dx: int) -> Dictionary:
	var tools: WorldToolsCore = env["tools"]
	var ids := {}
	var placements: Array = [
		[A_CORE, 0, 0, 0], [A_SENSOR, 1, 0, 0], [A_GATE, 2, 0, 0],
		[A_ACT, 3, 1, 0], [A_STOP, 3, -1, 0], [A_REPORT, 4, 0, 0],
	]
	for p in placements:
		var r: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE, {
			"assetId": p[0],
			"pos": [int(p[1]) + dx, int(p[2]) - dx, int(p[3]) + dx * 2],
		})
		if not bool(r["ok"]):
			return {"ok": false, "where": "place %s" % p[0], "ret": r}
		ids[p[0]] = r["result"]["entityId"]
	var wiring: Array = [
		# 控制：上电→读→分岔；（then）执行→校验；（else）校验；校验回环 + 出口
		["%s:next" % ids[A_CORE], "%s:ctl" % ids[A_SENSOR]],
		["%s:next" % ids[A_SENSOR], "%s:ctl" % ids[A_GATE]],
		["%s:then" % ids[A_GATE], "%s:ctl" % ids[A_ACT]],
		["%s:next" % ids[A_ACT], "%s:ctl" % ids[A_STOP]],
		["%s:else" % ids[A_GATE], "%s:ctl" % ids[A_STOP]],
		["%s:loop" % ids[A_STOP], "%s:ctl" % ids[A_SENSOR]],
		["%s:done" % ids[A_STOP], "%s:ctl" % ids[A_REPORT]],
		# 数据
		["%s:out" % ids[A_CORE], "%s:in" % ids[A_SENSOR]],
		["%s:out" % ids[A_SENSOR], "%s:state" % ids[A_GATE]],
		["%s:out" % ids[A_SENSOR], "%s:in" % ids[A_ACT]],
		["%s:out" % ids[A_SENSOR], "%s:payload" % ids[A_STOP]],
		["%s:out" % ids[A_SENSOR], "%s:in" % ids[A_REPORT]],
	]
	for w in wiring:
		var r2: Dictionary = tools.call_tool(WorldToolsCore.TOOL_CONNECT, {"from": w[0], "to": w[1]})
		if not bool(r2["ok"]):
			return {"ok": false, "where": "connect %s" % str(w), "ret": r2}
	var r3: Dictionary = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM, {
		"entityId": ids[A_SENSOR], "key": "max_turns", "value": 3,
	})
	if not bool(r3["ok"]):
		return {"ok": false, "where": "set_param", "ret": r3}
	return {"ok": true, "ids": ids}


# ---------------------------------------------------------------- 用例

func _t01_build_device() -> void:
	var env := _fresh()
	var b: Dictionary = _build_device(env, 0)
	_check("装置搭建：place/connect/set_param 全 ok", bool(b["ok"]),
		"%s %s" % [str(b.get("where", "")), str(b.get("ret", ""))])
	var snap: Dictionary = env["st"].logical_snapshot()
	_check("装置搭建：6 实体 12 连接（7 控制 + 5 数据）",
		(snap["entities"] as Dictionary).size() == 6 and (snap["edges"] as Array).size() == 12)


func _t02_graph_shape() -> void:
	var env := _fresh()
	_build_device(env, 0)
	var graph: Dictionary = BRIDGE.build_graph(env["st"])
	var shape_ok := true
	for key in graph.keys():
		if not ["name", "entities", "connections", "fold_groups"].has(key):
			shape_ok = false
	var kinds: Array = []
	var no_geometry := true
	for e in graph["entities"]:
		var ed: Dictionary = e
		for key in ed.keys():
			if not ENTITY_KEYS.has(key):
				shape_ok = false
		if ed.has("position") or ed.has("rotation_y"):
			no_geometry = false
		kinds.append(String(ed["kind"]))
		for p in ed["ports"]:
			var pd: Dictionary = p
			for key in pd.keys():
				if not PORT_KEYS.has(key):
					shape_ok = false
	kinds.sort()
	_check("建图：形状对齐 graph_model 白名单（实体/端口键集合）", shape_ok, str(graph.keys()))
	_check("建图：位置/朝向/端口仿真值不进图", no_geometry and not graph.has("position"))
	_check("建图：block 保留参数映射方块 kind（6 实体 12 连接，折叠组空）",
		str(kinds) == str(["decide", "entry", "guard", "sink", "step", "think"])
		and (graph["entities"] as Array).size() == 6
		and (graph["connections"] as Array).size() == 12
		and (graph["fold_groups"] as Array).is_empty(), str(kinds))


func _t03_compile_and_params() -> void:
	var env := _fresh()
	_build_device(env, 0)
	var r: Dictionary = BRIDGE.export_python(env["st"])
	_check("导出：编译 ok 且产物非空", bool(r["ok"]) and String(r["python"]) != "", str(r["errors"]))
	var py: String = String(r["python"])
	_check("导出：带环 + 分岔控制结构", py.contains("while True:") and py.contains("if route_") and py.contains("break"))
	_check("导出：set_param 的 max_turns=3 穿透进产物", py.contains("max_turns=3"))
	_check("导出：无告警（每端口单数据入边）", (r["warnings"] as Array).is_empty(), str(r["warnings"]))


func _t04_executable() -> void:
	var env := _fresh()
	_build_device(env, 0)
	var r: Dictionary = BRIDGE.export_python(env["st"])
	if not bool(r["ok"]):
		_check("wsl 执行：导出 ok", false, str(r["errors"]))
		return
	var res := _exec_wsl_python(String(r["python"]), "world_device.py")
	if int(res[0]) == -1:
		return  # NOTE 已打印：wsl 不可用，跳过外部执行
	_check("wsl python3 执行世界装置产物 exit=0", int(res[0]) == 0, "exit=%d" % int(res[0]))
	for ln in res[1]:
		print("  [world_device] ", ln)


func _t05_position_independent() -> void:
	var a := _fresh()
	_build_device(a, 0)
	var b := _fresh()
	_build_device(b, 137)
	var ra: Dictionary = BRIDGE.export_python(a["st"])
	var rb: Dictionary = BRIDGE.export_python(b["st"])
	_check("位置无关：同装置两种摆法导出逐字节相同",
		bool(ra["ok"]) and bool(rb["ok"]) and String(ra["python"]) == String(rb["python"]) and String(ra["python"]) != "")
	_check("位置无关：ir_hash 相同", String(ra["ir_hash"]) == String(rb["ir_hash"]) and String(ra["ir_hash"]) != "")


func _t06_netlist_coverage() -> void:
	var env := _fresh()
	_build_device(env, 0)
	var net_ids: Array = []
	for ln in env["st"].netlist_text().split("\n"):
		if String(ln).begins_with("ENTITY "):
			net_ids.append(String(ln).split(" ")[1])
	net_ids.sort()
	var graph: Dictionary = BRIDGE.build_graph(env["st"])
	var graph_ids: Array = []
	for e in graph["entities"]:
		graph_ids.append(String((e as Dictionary)["id"]))
	graph_ids.sort()
	var r: Dictionary = BRIDGE.export_python(env["st"])
	var py: String = String(r["python"])
	var fn_hit := true
	for eid in graph_ids:
		if not py.contains("def step_%s(" % _py_ident(String(eid))):
			fn_hit = false
	_check("netlist 与导出实体覆盖一致（实体集合相等）", str(net_ids) == str(graph_ids),
		"%s vs %s" % [str(net_ids), str(graph_ids)])
	_check("每个实体都有对应 step_* 函数（覆盖 %d/%d）" % [graph_ids.size(), graph_ids.size()],
		py.count("def step_") == graph_ids.size() and fn_hit)


func _t07_tool_export() -> void:
	var env := _fresh()
	_build_device(env, 0)
	var cm: CostModelCore = env["cm"]
	var ops_before := cm.total_ops
	var r: Dictionary = (env["tools"] as WorldToolsCore).export_python()
	_check("world.export_python：结构化返回 ok 且带产物",
		bool(r.get("ok", false)) and str((r.get("result", {}) as Dictionary).get("python", "")).contains("def step_"))
	_check("world.export_python：计价读 1 ops", cm.total_ops - ops_before == 1,
		"delta=%d" % (cm.total_ops - ops_before))
	var steps: Array = env["rc"].get_steps()
	var last: Dictionary = steps[steps.size() - 1]
	_check("world.export_python：进步记录 action=world.export_python",
		str((last["action"] as Dictionary).get("tool", "")) == "world.export_python"
		and int(r.get("step", -1)) == int(last["i"]))


# ---------------------------------------------------------------- 基础设施

## 把产物写到 user://integration_out/（不弄脏仓库）并用 wsl python3 真跑。
## 返回 [exit_code, 输出行数组]；wsl 不可用返回 [-1, []]（打 NOTE，不判失败）。
func _exec_wsl_python(py_source: String, fname: String) -> Array:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://integration_out"))
	var path := ProjectSettings.globalize_path("user://integration_out/%s" % fname)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		_check("wsl 执行准备（写入 %s）" % fname, false, str(FileAccess.get_open_error()))
		return [-1, []]
	f.store_string(py_source)
	f.close()
	var probe: Array = []
	if OS.execute("wsl", ["--status"], probe) != 0:
		print("NOTE wsl 不可用，跳过外部执行（产物已生成：%s，验收用 wsl python3 手跑）" % path)
		return [-1, []]
	var wsl_path := _to_wsl_path(path)
	var output: Array = []
	var code := OS.execute("wsl", ["-e", "bash", "-lc", "python3 '%s'" % wsl_path], output)
	var lines: Array = []
	for o in output:
		for ln in String(o).split("\n"):
			if ln.strip_edges() != "":
				lines.append(ln.strip_edges())
	return [code, lines]


func _to_wsl_path(win_path: String) -> String:
	var p := win_path.replace("\\", "/")
	var idx := p.find(":")
	if idx < 0:
		return p
	return "/mnt/%s%s" % [p.substr(0, idx).to_lower(), p.substr(idx + 1)]


## 与 codegen_python.gd 的 py_ident 同算法（测试侧副本，用于覆盖核对）。
func _py_ident(eid: String) -> String:
	var out: String = eid.to_snake_case()
	var safe := ""
	for ch in out:
		var ok := (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch == "_"
		safe += ch if ok else "_"
	if safe == "" or (safe[0] >= "0" and safe[0] <= "9"):
		safe = "e_" + safe
	return safe
