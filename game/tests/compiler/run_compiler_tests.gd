extends SceneTree

## 方块编译器测试（SceneTree 脚本）。
##
## 运行：
##   "$GODOT" --headless --path game -s res://tests/compiler/run_compiler_tests.gd
## 退出码非 0 即失败；逐条 print PASS/FAIL。
##
## 覆盖：
## - 五种拓扑各一个 fixture（直线/分岔/带环/扇出/汇聚）→ 编译 ok、
##   输出含对应控制结构关键字
## - 合法递推：loop fixture 加环内数据回边（update.out→forward.in）→
##   编译 ok、无 IMPLICIT_DEPENDENCY_CYCLE、wsl python3 真跑退出码 0
## - 多路数据入边：非 join 实体同一入端口多条边 → MULTI_DATA_IN_EDGE
##   告警（不阻断产码）+ sources 聚合实参 + sink 输出非空
## - 扇出×sources 撞名：臂首的数据来源实体改名 item（py_ident 与扇出
##   支路槽 v_item 同键）→ FANOUT_ITEM_NAME_COLLISION 硬错误（不产码）；
##   改成非 item 名后同图编译 ok（对照）
## - 折叠不变量：带环+分岔混合图折叠成一级装配再编译，输出与未折叠
##   **逐字节相同**（显式断言，非口头声明）
## - 位置无关：同图改坐标/朝向并打乱实体数组顺序后编译，输出逐字节相同
## - 连接乱序：同图打乱 connections 数组后编译，输出逐字节相同
## - 五条错误各一个 fixture → 各自错误码命中；组合 fixture 一次返回全部
## - 确定性：同图编译两次 ir_hash 与 python 相同；JSON 往返后仍相同
## - 可执行证明：混合 fixture 输出写入 out/sample_agent.py，
##   wsl python3 真跑（退出码 0）

const COMPILER := preload("res://scripts/compiler/compiler.gd")
const CPG := preload("res://scripts/compiler/codegen_python.gd")
const FOLD := preload("res://scripts/compiler/fold.gd")
const GM := preload("res://scripts/compiler/graph_model.gd")
const VAL := preload("res://scripts/compiler/validate.gd")

var _pass := 0
var _fail := 0


func _initialize() -> void:
	print("== 方块编译器测试 ==")
	_test_linear()
	_test_branch()
	_test_loop()
	_test_loop_recursion()
	_test_fanout()
	_test_join()
	_test_mixed()
	_test_multi_data_in_edge()
	_test_fanout_sources()
	_test_fanout_item_collision()
	_test_fold_invariant()
	_test_position_independent()
	_test_connection_order_independent()
	_test_errors()
	_test_determinism()
	_test_json_roundtrip()
	_test_sample_executable()
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


# ---------------------------------------------------------------- fixtures

func _ent(id: String, kind: String, params := {}, ports := [], pos_x := 0.0, pos_y := 0.0, rot := 0.0) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"params": params,
		"ports": ports,
		"position": {"x": pos_x, "y": pos_y},
		"rotation_y": rot,
	}


func _p(pname: String, dir: String, kind := "data", type := "any", required := false) -> Dictionary:
	return {"name": pname, "dir": dir, "kind": kind, "type": type, "required": required}


func _c(from_ref: String, to_ref: String) -> Dictionary:
	return {"from": from_ref, "to": to_ref}


func _io_ports() -> Array:
	return [
		_p("in", "in", "data", "json"),
		_p("out", "out", "data", "json"),
		_p("ctl", "in", "control", "seq"),
		_p("next", "out", "control", "seq"),
	]


## 直线型：采集→清洗→变换→汇报
func _linear_fixture() -> Dictionary:
	return {
		"name": "linear_pipeline",
		"entities": [
			_ent("entry", "entry", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("clean", "step", {}, _io_ports()),
			_ent("transform", "step", {}, _io_ports()),
			_ent("report", "sink", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("entry.next", "clean.ctl"),
			_c("clean.next", "transform.ctl"),
			_c("transform.next", "report.ctl"),
			_c("entry.out", "clean.in"),
			_c("clean.out", "transform.in"),
			_c("transform.out", "report.in"),
		],
	}


## 分岔型（三分路）：schema 校验的通过 / 重试 / 拒绝
func _branch_fixture(moved := false) -> Dictionary:
	var ents := [
		_ent("entry", "entry", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")], 0, 0),
		_ent("decide", "decide", {}, [
			_p("state", "in", "data", "json"), _p("ctl", "in", "control", "seq"),
			_p("pass", "out", "control", "then"),
			_p("retry", "out", "control", "elif"),
			_p("reject", "out", "control", "else"),
		], 10, 0),
		_ent("accept", "step", {}, _io_ports(), 20, -5),
		_ent("retry_step", "step", {}, _io_ports(), 20, 0),
		_ent("reject_step", "step", {}, _io_ports(), 20, 5),
		_ent("sink", "sink", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")], 30, 0),
	]
	if moved:
		# 换摆法：坐标/朝向全变 + 实体数组倒序——编译结果必须不变
		var shuffled: Array = []
		for i in range(ents.size() - 1, -1, -1):
			var e: Dictionary = ents[i].duplicate(true)
			e["position"] = {"x": 900.0 + float(i) * 37.0, "y": -400.0 - float(i) * 11.0}
			e["rotation_y"] = 90.0 * float(i)
			shuffled.append(e)
		ents = shuffled
	return {
		"name": "schema_gate",
		"entities": ents,
		"connections": [
			_c("entry.next", "decide.ctl"),
			_c("decide.pass", "accept.ctl"),
			_c("decide.retry", "retry_step.ctl"),
			_c("decide.reject", "reject_step.ctl"),
			_c("accept.next", "sink.ctl"),
			_c("retry_step.next", "sink.ctl"),
			_c("reject_step.next", "sink.ctl"),
			_c("entry.out", "decide.state"),
			_c("accept.out", "sink.in"),
			_c("retry_step.out", "sink.in"),
			_c("reject_step.out", "sink.in"),
		],
	}


## 带环型：前向→损失→反向→更新→检查，检查不满足则回环。
## back_edge=true 时加一条环内数据回边（update.out→forward.in）——
## 数据环整体落在显式控制环内，属合法递推（不应报 IMPLICIT_DEPENDENCY_CYCLE）。
func _loop_fixture(with_exit := true, back_edge := false) -> Dictionary:
	var conns: Array = [
		_c("entry.next", "forward.ctl"),
		_c("forward.next", "loss.ctl"),
		_c("loss.next", "backward.ctl"),
		_c("backward.next", "update.ctl"),
		_c("update.next", "check.ctl"),
		_c("check.loop", "forward.ctl"),
		_c("entry.out", "forward.in"),
		_c("forward.out", "loss.in"),
		_c("loss.out", "backward.in"),
		_c("backward.out", "update.in"),
		_c("update.out", "check.payload"),
	]
	if back_edge:
		conns.append(_c("update.out", "forward.in"))
	if with_exit:
		conns.append(_c("check.done", "out.ctl"))
	return {
		"name": "train_loop_recursion" if back_edge else "train_loop",
		"entities": [
			_ent("entry", "entry", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("forward", "step", {}, _io_ports()),
			_ent("loss", "step", {}, _io_ports()),
			_ent("backward", "step", {}, _io_ports()),
			_ent("update", "step", {}, _io_ports()),
			_ent("check", "guard", {}, [
				_p("payload", "in", "data", "json"), _p("ctl", "in", "control", "seq"),
				_p("loop", "out", "control", "seq"),
				_p("done", "out", "control", "exit"),
			]),
			_ent("out", "sink", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
		],
		"connections": conns,
	}


## 扇出型 + 汇聚：扫描/写入两路并行，join 归一
func _fanout_fixture() -> Dictionary:
	return {
		"name": "parallel_tools",
		"entities": [
			_ent("entry", "entry", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("split", "split", {"ways": {"value": 2, "type": "int", "min": 1, "max": 16}}, [
				_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq"),
				_p("scan_p", "out", "control", "parallel"),
				_p("write_p", "out", "control", "parallel"),
			]),
			_ent("scan", "step", {}, _io_ports()),
			_ent("write", "step", {}, _io_ports()),
			_ent("join", "join", {}, [
				_p("in1", "in", "data", "json"), _p("in2", "in", "data", "json"),
				_p("ctl", "in", "control", "seq"), _p("next", "out", "control", "seq"),
			]),
			_ent("out", "sink", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("entry.next", "split.ctl"),
			_c("split.scan_p", "scan.ctl"),
			_c("split.write_p", "write.ctl"),
			_c("scan.next", "join.ctl"),
			_c("write.next", "join.ctl"),
			_c("join.next", "out.ctl"),
			_c("entry.out", "split.in"),
			_c("scan.out", "join.in1"),
			_c("write.out", "join.in2"),
		],
	}


## 扇出×sources：扇出臂首实体 scan 的同一入端口 in 接两条数据入边
## （entry.out 与 scan_a.out）——臂首命中 sources 签名，pool.map 的单实参
## item 不能直塞（会被错绑进 sources 解包，支路值与多路来源全丢）。
func _fanout_sources_fixture() -> Dictionary:
	return {
		"name": "parallel_sources",
		"entities": [
			_ent("entry", "entry", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("scan_a", "source", {"tag": "alpha"}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("split", "split", {"ways": {"value": 2, "type": "int", "min": 1, "max": 16}}, [
				_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq"),
				_p("scan_p", "out", "control", "parallel"),
				_p("write_p", "out", "control", "parallel"),
			]),
			_ent("scan", "step", {}, _io_ports()),
			_ent("write", "step", {}, _io_ports()),
			_ent("join", "join", {}, [
				_p("in1", "in", "data", "json"), _p("in2", "in", "data", "json"),
				_p("ctl", "in", "control", "seq"), _p("next", "out", "control", "seq"),
			]),
			_ent("out", "sink", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("entry.next", "split.ctl"),
			_c("scan_a.next", "split.ctl"),
			_c("split.scan_p", "scan.ctl"),
			_c("split.write_p", "write.ctl"),
			_c("scan.next", "join.ctl"),
			_c("write.next", "join.ctl"),
			_c("join.next", "out.ctl"),
			_c("entry.out", "split.in"),
			_c("entry.out", "scan.in"),
			_c("scan_a.out", "scan.in"),
			_c("scan.out", "join.in1"),
			_c("write.out", "join.in2"),
		],
	}


## 扇出×sources 撞名：把 _fanout_sources_fixture 的臂首数据来源实体
## scan_a 改名为 new_name——"item" 时其 py_ident 与扇出支路槽 v_item 同键，
## sources 聚合里支路值会被静默丢弃（codegen 报 FANOUT_ITEM_NAME_COLLISION）。
func _fanout_item_collision_fixture(new_name: String) -> Dictionary:
	var g: Dictionary = _fanout_sources_fixture().duplicate(true)
	var ents: Array = []
	for e in g["entities"]:
		var d: Dictionary = e
		if String(d["id"]) == "scan_a":
			d["id"] = new_name
		ents.append(d)
	g["entities"] = ents
	var conns: Array = []
	for c in g["connections"]:
		var d: Dictionary = c
		d["from"] = String(d["from"]).replace("scan_a.", "%s." % new_name)
		d["to"] = String(d["to"]).replace("scan_a.", "%s." % new_name)
		conns.append(d)
	g["connections"] = conns
	return g


## 汇聚型：三路独立数据源归一
func _join_fixture() -> Dictionary:
	return {
		"name": "eval_merge",
		"entities": [
			_ent("src_a", "source", {"tag": "alpha"}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("src_b", "source", {"tag": "beta"}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("src_c", "source", {"tag": "gamma"}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("merge", "join", {}, [
				_p("in_a", "in", "data", "json", true), _p("in_b", "in", "data", "json", true),
				_p("in_c", "in", "data", "json", true),
				_p("ctl", "in", "control", "seq"), _p("next", "out", "control", "seq"),
			]),
			_ent("out", "sink", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("src_a.next", "merge.ctl"),
			_c("src_b.next", "merge.ctl"),
			_c("src_c.next", "merge.ctl"),
			_c("merge.next", "out.ctl"),
			_c("src_a.out", "merge.in_a"),
			_c("src_b.out", "merge.in_b"),
			_c("src_c.out", "merge.in_c"),
		],
	}


## 带环 + 分岔混合：Agent 的 think→(生成调用→解析→校验→出口 | 观察)→回环，
## 校验失败走 recover（错误恢复→重试）。
func _mixed_fixture() -> Dictionary:
	return {
		"name": "agent_retry",
		"entities": [
			_ent("entry", "entry", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("think", "think", {"max_turns": {"value": 4, "type": "int", "min": 1, "max": 64}}, _io_ports()),
			_ent("decide", "decide", {}, [
				_p("state", "in", "data", "json"), _p("ctl", "in", "control", "seq"),
				_p("act", "out", "control", "then"),
				_p("wrap", "out", "control", "else"),
			]),
			_ent("generate_call", "generate_call", {"temperature": {"value": 0.7, "type": "number", "min": 0.0, "max": 2.0}}, [
				_p("in", "in", "data", "json"), _p("out", "out", "data", "text"),
				_p("ctl", "in", "control", "seq"), _p("next", "out", "control", "seq"),
			]),
			_ent("parse", "parse", {}, [
				_p("raw", "in", "data", "text"), _p("out", "out", "data", "json"),
				_p("ctl", "in", "control", "seq"), _p("next", "out", "control", "seq"),
			]),
			_ent("validate", "validate", {"required_keys": {"value": ["tool", "args"], "type": "list"}}, [
				_p("payload", "in", "data", "json"), _p("ctl", "in", "control", "seq"),
				_p("next", "out", "control", "seq"),
			]),
			_ent("should_exit", "guard", {}, [
				_p("payload", "in", "data", "json"), _p("ctl", "in", "control", "seq"),
				_p("loop", "out", "control", "seq"),
				_p("done", "out", "control", "exit"),
			]),
			_ent("observe", "step", {}, _io_ports() + [_p("done2", "out", "control", "exit")]),
			_ent("recover", "recover", {"max_retries": {"value": 3, "type": "int", "min": 1, "max": 10}}, [
				_p("in", "in", "data", "json"),
			]),
			_ent("summarize", "summarize", {}, [
				_p("payload", "in", "data", "json"), _p("context", "in", "data", "json"),
				_p("ctl", "in", "control", "seq"),
			]),
		],
		"connections": [
			_c("entry.next", "think.ctl"),
			_c("think.next", "decide.ctl"),
			_c("decide.act", "generate_call.ctl"),
			_c("generate_call.next", "parse.ctl"),
			_c("parse.next", "validate.ctl"),
			_c("validate.next", "should_exit.ctl"),
			_c("should_exit.loop", "think.ctl"),
			_c("should_exit.done", "summarize.ctl"),
			_c("decide.wrap", "observe.ctl"),
			_c("observe.done2", "summarize.ctl"),
			_c("think.out", "decide.state"),
			_c("think.out", "generate_call.in"),
			_c("generate_call.out", "parse.raw"),
			_c("parse.out", "validate.payload"),
			_c("parse.out", "should_exit.payload"),
			_c("parse.out", "summarize.payload"),
			_c("think.out", "summarize.context"),
			_c("think.out", "observe.in"),
		],
	}


# ---------------------------------------------------------------- 拓扑用例

func _test_linear() -> void:
	var r: Dictionary = COMPILER.compile(_linear_fixture())
	_check("直线型：编译 ok", r.ok)
	var py: String = r.python
	_check("直线型：顺序调用且无循环", py.contains("step_clean(") and py.contains("step_transform(") \
		and py.rfind("step_clean(") < py.rfind("step_transform(") and py.rfind("step_transform(") < py.rfind("step_report(") \
		and not py.contains("while"), "顺序或 while 检查失败")


func _test_branch() -> void:
	var r: Dictionary = COMPILER.compile(_branch_fixture())
	_check("分岔型：编译 ok", r.ok)
	var py: String = r.python
	_check("分岔型：if/elif/else 三路", py.contains("route_decide = step_decide(") \
		and py.contains('if route_decide == "then"') \
		and py.contains('elif route_decide == "elif"') \
		and py.contains("else:"))


func _test_loop() -> void:
	var r: Dictionary = COMPILER.compile(_loop_fixture())
	_check("带环型：编译 ok", r.ok)
	var py: String = r.python
	_check("带环型：while True + 显式 break", py.contains("while True:") and py.contains("break  # 显式出口") \
		and py.rfind("step_forward(") < py.rfind("step_loss(") and py.rfind("step_loss(") < py.rfind("step_update("))


func _test_loop_recursion() -> void:
	var r: Dictionary = COMPILER.compile(_loop_fixture(true, true))
	var codes := _error_codes(r)
	_check("合法递推：环内数据回边编译 ok", r.ok, str(codes))
	_check("合法递推：无 IMPLICIT_DEPENDENCY_CYCLE", not codes.has("IMPLICIT_DEPENDENCY_CYCLE"), str(codes))
	_check("合法递推：回边端口多路入边走 sources 聚合", r.python.contains("step_forward(sources={"))
	var res := _exec_wsl_python(r.python, "train_loop_recursion.py")
	if int(res[0]) == -1:
		return  # NOTE 已打印：wsl 不可用，跳过外部执行
	_check("合法递推：wsl python3 执行产物 exit=0", int(res[0]) == 0, "exit=%d" % int(res[0]))
	for ln in res[1]:
		print("  [train_loop_recursion] ", ln)


func _test_fanout() -> void:
	var r: Dictionary = COMPILER.compile(_fanout_fixture())
	_check("扇出型：编译 ok", r.ok)
	var py: String = r.python
	_check("扇出型：并行示意（线程池 + map）", py.contains("ThreadPoolExecutor") and py.contains("_pool.map") \
		and py.contains("arms = [step_scan, step_write]"))


func _test_join() -> void:
	var r: Dictionary = COMPILER.compile(_join_fixture())
	_check("汇聚型：编译 ok", r.ok)
	var py: String = r.python
	_check("汇聚型：多路归一聚合", py.contains("def step_merge") and py.contains("多路归一") \
		and py.contains("state = step_merge([v_src_a, v_src_b, v_src_c])"))


func _test_mixed() -> void:
	var r: Dictionary = COMPILER.compile(_mixed_fixture())
	_check("混合（带环+分岔）：编译 ok", r.ok, str(r.errors))
	var py: String = r.python
	_check("混合：环内分岔 + 错误恢复重试", py.contains("while True:") \
		and py.contains('if route_decide == "then"') \
		and py.contains("step_recover(state, max_retries=3)") \
		and py.contains("continue"))


# ------------------------------------------------- 多路数据入边（warning + sources）

func _test_multi_data_in_edge() -> void:
	# 分岔 fixture 的 sink.in 接 3 条边（accept/reject_step/retry_step 各一条）：
	# 旧实现 conn_by_port 后写覆盖，sink 只拿到排序最后一条边的值（实跑打 {}）。
	var graph = GM.parse(_branch_fixture())
	var findings: Array[Dictionary] = VAL.validate_with_warnings(graph)
	var hit: Dictionary = {}
	for f in findings:
		if String(f.get("code", "")) == VAL.MULTI_DATA_IN_EDGE and String(f.get("port_ref", "")) == "sink.in":
			hit = f
			break
	_check("MULTI_DATA_IN_EDGE 命中（sink.in 多路入边）", not hit.is_empty(), str(findings))
	_check("MULTI_DATA_IN_EDGE 是 warning（severity 字段）", String(hit.get("severity", "")) == "warning", str(hit))
	var hard_codes: Array = []
	for f2 in VAL.validate(graph):
		hard_codes.append(String(f2.get("code", "")))
	_check("validate() 五条 error 语义不变：warning 不混入", not hard_codes.has(VAL.MULTI_DATA_IN_EDGE), str(hard_codes))
	var r: Dictionary = COMPILER.compile(_branch_fixture())
	_check("MULTI_DATA_IN_EDGE 不阻断产码（ok 且 python 非空）", r.ok and r.python != "", str(r.errors))
	_check("sink 实参 sources 聚合", r.python.contains("step_sink(sources={") \
		and r.python.contains('"v_accept": v_accept') and r.python.contains('"v_retry_step": v_retry_step'))
	var res := _exec_wsl_python(r.python, "schema_gate_sink.py")
	if int(res[0]) == -1:
		return  # NOTE 已打印：wsl 不可用，跳过外部执行
	_check("分岔产物：wsl python3 执行 exit=0", int(res[0]) == 0, "exit=%d" % int(res[0]))
	var sink_line := ""
	for ln in res[1]:
		if String(ln).begins_with("[sink]"):
			sink_line = String(ln).substr(String("[sink]").length()).strip_edges()
	var parsed: Variant = JSON.parse_string(sink_line)
	var has_value := false
	if parsed is Dictionary:
		for k in (parsed as Dictionary):
			if (parsed as Dictionary)[k] != null:
				has_value = true
	_check("分岔产物：sink 输出不再是空 dict（至少一支路供真值）", \
		parsed is Dictionary and not (parsed as Dictionary).is_empty() and has_value, sink_line)
	for ln in res[1]:
		print("  [schema_gate] ", ln)


## 把产物写到 user://compiler_out/（不弄脏仓库）并用 wsl python3 真跑。
## 返回 [exit_code, 输出行数组]；wsl 不可用返回 [-1, []]（打 NOTE，不判失败）。
func _exec_wsl_python(py_source: String, fname: String) -> Array:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://compiler_out"))
	var path := ProjectSettings.globalize_path("user://compiler_out/%s" % fname)
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


# ------------------------------------------------- 扇出×sources（review 缺陷修复）

func _test_fanout_sources() -> void:
	var r: Dictionary = COMPILER.compile(_fanout_sources_fixture())
	_check("扇出×sources：编译 ok", r.ok, str(r.errors))
	var hit := false
	for w in r.warnings:
		if String(w.get("code", "")) == VAL.MULTI_DATA_IN_EDGE and String(w.get("port_ref", "")) == "scan.in":
			hit = true
	_check("扇出×sources：MULTI_DATA_IN_EDGE 告警命中 scan.in", hit, str(r.warnings))
	var py: String = r.python
	_check("扇出×sources：sources 臂走包装 lambda（v_item 聚合）", \
		py.contains("_fan_scan = lambda item: step_scan(sources={") \
		and py.contains('"v_item": item') and py.contains('"v_entry": v_entry') \
		and py.contains('"v_scan_a": v_scan_a'))
	_check("扇出×sources：普通臂仍是直调（arms 混排）", py.contains("arms = [_fan_scan, step_write]"))
	var res := _exec_wsl_python(py, "fanout_sources.py")
	if int(res[0]) == -1:
		return  # NOTE 已打印：wsl 不可用，跳过外部执行
	_check("扇出×sources：wsl python3 执行产物 exit=0", int(res[0]) == 0, "exit=%d" % int(res[0]))
	var sink_line := ""
	for ln in res[1]:
		if String(ln).begins_with("[out]"):
			sink_line = String(ln).substr(String("[out]").length()).strip_edges()
	var parsed: Variant = JSON.parse_string(sink_line)
	var got_item := false
	var got_src := false
	if parsed is Dictionary:
		got_item = (parsed as Dictionary).has("v_item")
		var extra: Variant = (parsed as Dictionary).get("v_scan_a", null)
		got_src = extra is Dictionary and str((extra as Dictionary).get("scan_a", "")) == "alpha"
	_check("扇出×sources：各臂真拿到值（支路值 v_item 与多路来源 v_scan_a 都在产物里）", \
		got_item and got_src, sink_line)
	for ln in res[1]:
		print("  [parallel_sources] ", ln)


# ------------------------------------------------- 扇出×sources 撞名（should-fix）

func _test_fanout_item_collision() -> void:
	var r: Dictionary = COMPILER.compile(_fanout_item_collision_fixture("item"))
	var codes := _error_codes(r)
	_check("扇出撞名：来源实体名 item 时编译失败且不产码", not r.ok and r.python == "", str(codes))
	_check("扇出撞名：错误码 FANOUT_ITEM_NAME_COLLISION 命中", codes.has(CPG.FANOUT_ITEM_NAME_COLLISION), str(r.errors))
	var hit := {}
	for e in r.errors:
		if String(e.get("code", "")) == CPG.FANOUT_ITEM_NAME_COLLISION:
			hit = e
			break
	_check("扇出撞名：错误结构化四字段（code/entity_id/port_ref/message 均非空）", \
		not hit.is_empty() and String(hit.get("entity_id", "")) != "" \
		and String(hit.get("port_ref", "")) != "" and String(hit.get("message", "")) != "", str(hit))
	var ctrl: Dictionary = COMPILER.compile(_fanout_item_collision_fixture("item_x"))
	_check("扇出撞名对照：来源实体改名非 item 后同图编译 ok", \
		ctrl.ok and ctrl.python != "", str(_error_codes(ctrl)))


# ------------------------------------------------------ 折叠不变量 / 位置无关

func _test_fold_invariant() -> void:
	var mixed := _mixed_fixture()
	var r_plain: Dictionary = COMPILER.compile(mixed)
	var folded: Dictionary = FOLD.fold(mixed, "asm_core", [
		"think", "decide", "generate_call", "parse", "validate", "should_exit",
	])
	_check("fold 只动折叠组：连接与参数不变", str(folded["connections"]) == str(mixed["connections"]) \
		and str(folded["entities"]) != str(mixed["entities"]))
	var r_folded: Dictionary = COMPILER.compile(folded)
	_check("折叠不变量：python 逐字节相同", r_plain.ok and r_folded.ok and r_plain.python == r_folded.python and r_plain.python != "")
	_check("折叠不变量：ir_hash 相同", r_plain.ir_hash == r_folded.ir_hash and r_plain.ir_hash != "")
	var unfolded: Dictionary = FOLD.unfold(folded, "asm_core")
	var r_unfolded: Dictionary = COMPILER.compile(unfolded)
	_check("unfold 后编译仍相同", r_unfolded.ok and r_unfolded.python == r_plain.python)


func _test_position_independent() -> void:
	var r_a: Dictionary = COMPILER.compile(_branch_fixture(false))
	var r_b: Dictionary = COMPILER.compile(_branch_fixture(true))
	_check("位置无关：改坐标/朝向/数组顺序后 python 逐字节相同", r_a.ok and r_b.ok and r_a.python == r_b.python and r_a.python != "")
	_check("位置无关：ir_hash 相同", r_a.ir_hash == r_b.ir_hash and r_a.ir_hash != "")


func _test_connection_order_independent() -> void:
	# 与实体乱序测试成对：同图把 connections 数组乱序（倒序）后编译，
	# 输出必须逐字节相同——连接声明顺序不参与编译。
	var a := _branch_fixture()
	var b := _branch_fixture()
	var conns: Array = (b["connections"] as Array).duplicate()
	conns.reverse()
	b["connections"] = conns
	var r_a: Dictionary = COMPILER.compile(a)
	var r_b: Dictionary = COMPILER.compile(b)
	_check("连接乱序：connections 数组乱序后 python 逐字节相同", r_a.ok and r_b.ok and r_a.python == r_b.python and r_a.python != "")
	_check("连接乱序：ir_hash 相同", r_a.ir_hash == r_b.ir_hash and r_a.ir_hash != "")


# ---------------------------------------------------------------- 错误用例

func _error_codes(r: Dictionary) -> Array:
	var codes: Array = []
	for e in r.errors:
		codes.append(e.get("code", ""))
	return codes


func _structured(errors: Array) -> bool:
	for e in errors:
		if not (e is Dictionary):
			return false
		if String(e.get("code", "")) == "" or String(e.get("message", "")) == "":
			return false
		if String(e.get("entity_id", "")) == "" and String(e.get("port_ref", "")) == "":
			return false
	return true


func _type_mismatch_fixture() -> Dictionary:
	return {
		"name": "e_type",
		"entities": [
			_ent("emit", "step", {}, [_p("out", "out", "data", "text"), _p("next", "out", "control", "seq")]),
			_ent("consume", "step", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("emit.next", "consume.ctl"),
			_c("emit.out", "consume.in"),
		],
	}


func _required_unconnected_fixture() -> Dictionary:
	return {
		"name": "e_required",
		"entities": [
			_ent("emit", "step", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("consume", "step", {}, [_p("in", "in", "data", "json", true), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("emit.next", "consume.ctl"),
		],
	}


func _param_range_fixture() -> Dictionary:
	return {
		"name": "e_param",
		"entities": [
			_ent("emit", "step", {}, [_p("out", "out", "data", "json"), _p("next", "out", "control", "seq")]),
			_ent("hot", "think", {"max_turns": {"value": 99, "type": "int", "min": 1, "max": 64}}, _io_ports()),
			_ent("consume", "sink", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("emit.next", "hot.ctl"),
			_c("hot.next", "consume.ctl"),
			_c("emit.out", "hot.in"),
			_c("hot.out", "consume.in"),
		],
	}


func _implicit_cycle_fixture() -> Dictionary:
	return {
		"name": "e_cycle",
		"entities": [
			_ent("a", "step", {}, _io_ports()),
			_ent("b", "step", {}, _io_ports()),
		],
		"connections": [
			_c("a.next", "b.ctl"),
			_c("a.out", "b.in"),
			_c("b.out", "a.in"),
		],
	}


func _combined_errors_fixture() -> Dictionary:
	return {
		"name": "e_combined",
		"entities": [
			_ent("emit", "step", {}, [_p("out", "out", "data", "text"), _p("next", "out", "control", "seq")]),
			_ent("hot", "think", {"max_turns": {"value": 99, "type": "int", "min": 1, "max": 64}}, _io_ports()),
			_ent("consume", "step", {}, [_p("in", "in", "data", "json"), _p("ctl", "in", "control", "seq")]),
			_ent("lonely", "step", {}, [_p("in", "in", "data", "json", true), _p("ctl", "in", "control", "seq")]),
		],
		"connections": [
			_c("emit.next", "hot.ctl"),
			_c("hot.next", "consume.ctl"),
			_c("emit.out", "hot.in"),
			_c("hot.out", "consume.in"),
		],
	}


func _test_errors() -> void:
	var cases: Array = [
		["PORT_TYPE_MISMATCH", _type_mismatch_fixture()],
		["REQUIRED_PORT_UNCONNECTED", _required_unconnected_fixture()],
		["PARAM_OUT_OF_RANGE", _param_range_fixture()],
		["IMPLICIT_DEPENDENCY_CYCLE", _implicit_cycle_fixture()],
		["LOOP_MISSING_EXIT", _loop_fixture(false)],
	]
	for c in cases:
		var code: String = c[0]
		var r: Dictionary = COMPILER.compile(c[1])
		var codes := _error_codes(r)
		_check("错误码 %s 命中且不产码" % code, not r.ok and r.python == "" and codes.has(code), str(codes))
		_check("错误码 %s 结构化（code/实体或端口/message）" % code, not r.errors.is_empty() and _structured(r.errors))
	var combo: Dictionary = COMPILER.compile(_combined_errors_fixture())
	var combo_codes := _error_codes(combo)
	_check("一次编译返回全部错误（≥3 条）", not combo.ok and combo.errors.size() >= 3 \
		and combo_codes.has("PORT_TYPE_MISMATCH") and combo_codes.has("PARAM_OUT_OF_RANGE") \
		and combo_codes.has("REQUIRED_PORT_UNCONNECTED"), str(combo_codes))


# ---------------------------------------------------------------- 确定性

func _test_determinism() -> void:
	var r1: Dictionary = COMPILER.compile(_mixed_fixture())
	var r2: Dictionary = COMPILER.compile(_mixed_fixture())
	_check("确定性：同图两次编译 ir_hash 相同", r1.ok and r2.ok and r1.ir_hash == r2.ir_hash and r1.ir_hash != "")
	_check("确定性：同图两次编译 python 相同", r1.python == r2.python and r1.python != "")


func _test_json_roundtrip() -> void:
	var direct: Dictionary = COMPILER.compile(_linear_fixture())
	var roundtrip: Variant = JSON.parse_string(JSON.stringify(_linear_fixture()))
	var via_json: Dictionary = COMPILER.compile(roundtrip)
	_check("JSON 往返：Dictionary(JSON) 构建后编译相同", direct.ok and via_json.ok and direct.python == via_json.python)


# ------------------------------------------------- 可执行证明（wsl python3）

func _test_sample_executable() -> void:
	var r: Dictionary = COMPILER.compile(_mixed_fixture())
	if not r.ok:
		_check("sample_agent.py 生成", false, "混合图编译失败")
		return
	DirAccess.make_dir_recursive_absolute("res://tests/compiler/out")
	var f := FileAccess.open("res://tests/compiler/out/sample_agent.py", FileAccess.WRITE)
	if f == null:
		_check("sample_agent.py 写入", false, str(FileAccess.get_open_error()))
		return
	f.store_string(r.python)
	f.close()
	var back := FileAccess.get_file_as_string("res://tests/compiler/out/sample_agent.py")
	_check("sample_agent.py 写入且内容逐字节一致", back == r.python and back.length() > 0)
	_check("sample_agent.py 自带 main 自测", back.contains("def main() -> int:") and back.contains('if __name__ == "__main__":'))

	# wsl python3 真跑（环境不可用时降级为 NOTE，不判失败）
	var probe: Array = []
	if OS.execute("wsl", ["--status"], probe) != 0:
		print("NOTE wsl 不可用，跳过外部执行（文件已生成，验收用 wsl python3 手跑）")
		return
	var wsl_path := _to_wsl_path(ProjectSettings.globalize_path("res://tests/compiler/out/sample_agent.py"))
	var output: Array = []
	var code := OS.execute("wsl", ["-e", "bash", "-lc", "python3 %s" % wsl_path], output)
	for o in output:
		for ln in String(o).split("\n"):
			if ln.strip_edges() != "":
				print("  [sample] ", ln)
	_check("wsl python3 执行 sample_agent.py 退出码 0", code == 0, "exit=%d" % code)


func _to_wsl_path(win_path: String) -> String:
	var p := win_path.replace("\\", "/")
	var idx := p.find(":")
	if idx < 0:
		return p
	return "/mnt/%s%s" % [p.substr(0, idx).to_lower(), p.substr(idx + 1)]
