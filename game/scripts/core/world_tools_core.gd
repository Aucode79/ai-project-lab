class_name WorldToolsCore
extends Node

## 世界工具面内核（autoload 薄壳：autoload/world_tools.gd）。
##
## spec §7.2 的世界工具 + 可观测性工具，共 12 个：
##   写（机械臂）：world.place / world.connect / world.set_param
##   演：        world.run / world.step
##   读（扫描器）：world.inspect / world.snapshot / world.read / world.trace
##               / world.watch / world.diff / world.export_netlist
##
## 约定：
##   * 每个工具调用都进步记录，action 含工具名与完整参数（spec §6）
##   * 返回值结构化：{ok: true, result, step} 或 {ok: false, error: {code, message}}
##   * 失败也进步记录、也写 failures——错误是过程的一部分，不是进程崩溃
##   * ops 按 CostModel 定价（写 20 读 1），计数进步记录且能被外部代码读到
##   * snapshot 只取状态层；trace / watch 是订阅，不是世界状态
##
## 依赖解析：注入优先（own_*，测试与重放器用），其次 autoload 单例
## （/root/WorldState 等，名字与 project.godot 注册顺序一致），最后进程内兜底实例
## （`godot -s` 测试模式下引擎不加载 autoload，兜底保证同一份内核代码可跑）。

const TOOL_PLACE := "world.place"
const TOOL_CONNECT := "world.connect"
const TOOL_SET_PARAM := "world.set_param"
const TOOL_RUN := "world.run"
const TOOL_INSPECT := "world.inspect"
const TOOL_SNAPSHOT := "world.snapshot"
const TOOL_READ := "world.read"
const TOOL_TRACE := "world.trace"
const TOOL_WATCH := "world.watch"
const TOOL_STEP := "world.step"
const TOOL_DIFF := "world.diff"
const TOOL_EXPORT_NETLIST := "world.export_netlist"
## 导出 Python 不是 §7.2 的 12 工具之一，是 spec §11 方块编译器交付物的
## 工具面入口（12 工具注册表不动，只加方法）。
const TOOL_EXPORT_PYTHON := "world.export_python"

const BRIDGE := preload("res://scripts/integration/world_to_graph.gd")

const PHASE_BUILD := "build"
const PHASE_RUN := "run"
const PHASE_OBSERVE := "observe"
const PHASE_EVENT := "event"

const ACTOR_AGENT := "agent"
const ACTOR_PHYSICS := "physics"

## 测试 / 重放器注入的独立实例（不碰共享单例）
var own_state: WorldStateCore = null
var own_recorder: StepRecorderCore = null
var own_cost: CostModelCore = null

var _tools: Dictionary = {}
var _shared_state: WorldStateCore = null
var _shared_recorder: StepRecorderCore = null
var _shared_cost: CostModelCore = null

## 参数规格：值是类型；"@xxx" 前缀表示"只查存在、不限类型"（value 接受任意标量）。
const _ARG_SPEC := {
	TOOL_PLACE: {"assetId": TYPE_STRING, "pos": TYPE_ARRAY},
	TOOL_CONNECT: {"from": TYPE_STRING, "to": TYPE_STRING},
	TOOL_SET_PARAM: {"entityId": TYPE_STRING, "key": TYPE_STRING, "@value": TYPE_NIL},
	TOOL_RUN: {},
	TOOL_INSPECT: {"entityId": TYPE_STRING},
	TOOL_SNAPSHOT: {},
	TOOL_READ: {"ref": TYPE_STRING},
	TOOL_TRACE: {"ref": TYPE_STRING},
	TOOL_WATCH: {"ref": TYPE_STRING},
	TOOL_STEP: {},
	TOOL_DIFF: {},
	TOOL_EXPORT_NETLIST: {},
}


func _init() -> void:
	_tools = {
		TOOL_PLACE: {"mode": CostModelCore.MODE_WRITE, "phase": PHASE_BUILD, "fn": Callable(self, "_tool_place")},
		TOOL_CONNECT: {"mode": CostModelCore.MODE_WRITE, "phase": PHASE_BUILD, "fn": Callable(self, "_tool_connect")},
		TOOL_SET_PARAM: {"mode": CostModelCore.MODE_WRITE, "phase": PHASE_BUILD, "fn": Callable(self, "_tool_set_param")},
		TOOL_RUN: {"mode": CostModelCore.MODE_EXEC, "phase": PHASE_RUN, "fn": Callable(self, "_tool_run")},
		TOOL_STEP: {"mode": CostModelCore.MODE_EXEC, "phase": PHASE_RUN, "fn": Callable(self, "_tool_step")},
		TOOL_INSPECT: {"mode": CostModelCore.MODE_READ, "phase": PHASE_OBSERVE, "fn": Callable(self, "_tool_inspect")},
		TOOL_SNAPSHOT: {"mode": CostModelCore.MODE_READ, "phase": PHASE_OBSERVE, "fn": Callable(self, "_tool_snapshot")},
		TOOL_READ: {"mode": CostModelCore.MODE_READ, "phase": PHASE_OBSERVE, "fn": Callable(self, "_tool_read")},
		TOOL_TRACE: {"mode": CostModelCore.MODE_READ, "phase": PHASE_OBSERVE, "fn": Callable(self, "_tool_trace")},
		TOOL_WATCH: {"mode": CostModelCore.MODE_READ, "phase": PHASE_OBSERVE, "fn": Callable(self, "_tool_watch")},
		TOOL_DIFF: {"mode": CostModelCore.MODE_READ, "phase": PHASE_OBSERVE, "fn": Callable(self, "_tool_diff")},
		TOOL_EXPORT_NETLIST: {"mode": CostModelCore.MODE_READ, "phase": PHASE_OBSERVE, "fn": Callable(self, "_tool_export_netlist")},
	}


# ---------- 依赖解析 ----------

func state() -> WorldStateCore:
	if own_state != null:
		return own_state
	if _shared_state == null:
		var found := _find_autoload("WorldState")
		_shared_state = found if found is WorldStateCore else WorldStateCore.new()
	return _shared_state


func recorder() -> StepRecorderCore:
	if own_recorder != null:
		return own_recorder
	if _shared_recorder == null:
		var found := _find_autoload("StepRecorder")
		_shared_recorder = found if found is StepRecorderCore else StepRecorderCore.new()
	return _shared_recorder


func cost() -> CostModelCore:
	if own_cost != null:
		return own_cost
	if _shared_cost == null:
		var found := _find_autoload("CostModel")
		_shared_cost = found if found is CostModelCore else CostModelCore.new()
	return _shared_cost


func _find_autoload(autoload_name: String) -> Node:
	var loop := Engine.get_main_loop() as SceneTree
	if loop == null or loop.root == null:
		return null
	# 用相对名从 root 找子节点；绝对路径在 `-s` 这类非活动场景树模式下会报错
	return loop.root.get_node_or_null(autoload_name)


# ---------- 调用主路径 ----------

## 统一入口。opts 可传 actor / tokens / caption / formula / causes（进步记录的旁路字段）。
func call_tool(tool_name: String, args: Dictionary = {}, opts: Dictionary = {}) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var entry: Dictionary = _tools.get(tool_name, {})
	if entry.is_empty():
		return _fail(tool_name, args, opts, t0, PHASE_OBSERVE, "unknown_tool",
			"未知工具名：%s（不在 world.* 工具面内）" % tool_name)
	var phase := str(entry["phase"])
	var arg_err := _check_args(tool_name, args)
	if arg_err != "":
		return _fail(tool_name, args, opts, t0, phase, "bad_args", arg_err)
	var ret: Dictionary = (entry["fn"] as Callable).call(args)
	if not bool(ret.get("ok", false)):
		return _fail(tool_name, args, opts, t0, phase,
			str(ret.get("code", "tool_failed")), str(ret.get("message", "工具执行失败")))
	return _succeed(tool_name, args, opts, t0, phase, str(entry["mode"]), ret)


## 物理→逻辑事件走同一条记录通道（phase=event，actor=physics，ops=0：
## 物理事件是世界的自然行为，不是学员或 agent 的计价动作）。
func report_physics_event(event: Dictionary, opts: Dictionary = {}) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var ret := state().apply_physics_event(event)
	var cost_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var output := {"ok": bool(ret.get("ok", false))}
	if output["ok"]:
		output["result"] = {"applied": ret.get("applied", "")}
	else:
		output["error"] = {"code": str(ret.get("code", "")), "message": str(ret.get("message", ""))}
	var i := recorder().record_step({
		"t": state().world_t(),
		"phase": PHASE_EVENT,
		"actor": str(opts.get("actor", ACTOR_PHYSICS)),
		"input": {},
		"action": {"tool": "physics." + str(event.get("type", "event")), "args": event.duplicate(true)},
		"output": output,
		"tokens": int(opts.get("tokens", 0)),
		"ops": 0,
		"costMs": cost_ms,
		"world": state().state_digest(),
		"caption": str(opts.get("caption", "")),
		"formula": str(opts.get("formula", "")),
	})
	if not output["ok"]:
		recorder().record_failure(i, "physics:" + str(event.get("type", "event")),
			str(ret.get("code", "")), str(ret.get("message", "")))
	output["step"] = i
	return output


func tool_names() -> Array:
	return _tools.keys()


# ---------- 内部：收尾记账 ----------

func _succeed(tool_name: String, args: Dictionary, opts: Dictionary, t0: int, phase: String, mode: String, ret: Dictionary) -> Dictionary:
	var ops := cost().charge(mode)
	var cost_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var output := {"ok": true, "result": ret.get("result", {})}
	var i := recorder().record_step({
		"t": state().world_t(),
		"phase": phase,
		"actor": str(opts.get("actor", ACTOR_AGENT)),
		"input": ret.get("input", {}),
		"action": {"tool": tool_name, "args": args.duplicate(true)},
		"output": {"ok": true, "result": (output["result"] as Dictionary).duplicate(true)},
		"tokens": int(opts.get("tokens", 0)),
		"ops": ops,
		"costMs": cost_ms,
		"world": state().state_digest(),
		"caption": str(opts.get("caption", "")),
		"formula": str(opts.get("formula", "")),
	})
	# 工具内部的次生失败（如 run 发现 ANALOG 接了 BOOL）也要进 failures
	for f in ret.get("failures", []):
		recorder().record_failure(i, "tool:" + tool_name,
			str(f.get("code", "")), str(f.get("message", "")))
	output["step"] = i
	return output


func _fail(tool_name: String, args: Dictionary, opts: Dictionary, t0: int, phase: String, code: String, message: String) -> Dictionary:
	var cost_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var ops := cost().charge_failed()
	var output := {"ok": false, "error": {"code": code, "message": message}}
	var i := recorder().record_step({
		"t": state().world_t(),
		"phase": phase,
		"actor": str(opts.get("actor", ACTOR_AGENT)),
		"input": {},
		"action": {"tool": tool_name, "args": args.duplicate(true)},
		"output": output.duplicate(true),
		"tokens": int(opts.get("tokens", 0)),
		"ops": ops,
		"costMs": cost_ms,
		"world": state().state_digest(),
		"caption": str(opts.get("caption", "")),
		"formula": str(opts.get("formula", "")),
	})
	if i >= 0:
		recorder().record_failure(i, "tool:" + tool_name, code, message)
	output["step"] = i
	return output


func _check_args(tool_name: String, args: Dictionary) -> String:
	var spec: Dictionary = _ARG_SPEC.get(tool_name, {})
	for key in spec:
		var name := str(key)
		var bare: String = name.substr(1) if name.begins_with("@") else name
		if not args.has(bare):
			return "缺少必填参数：%s" % bare
		if name.begins_with("@"):
			continue
		var want: int = spec[key]
		var got := typeof(args[bare])
		if want == TYPE_STRING and got != TYPE_STRING:
			return "参数 %s 必须是字符串，得到 %s" % [bare, type_string(got)]
		if want == TYPE_ARRAY and got != TYPE_ARRAY:
			return "参数 %s 必须是数组（如 [x, y, z]），得到 %s" % [bare, type_string(got)]
	return ""


# ---------- 工具实现 ----------

func _tool_place(args: Dictionary) -> Dictionary:
	var ret := state().place(str(args["assetId"]), args["pos"])
	if bool(ret.get("ok", false)):
		return {"ok": true, "result": {"entityId": ret["entityId"], "bound": bool(ret.get("bound", false))}}
	return ret


func _tool_connect(args: Dictionary) -> Dictionary:
	var ret := state().connect_ports(str(args["from"]), str(args["to"]))
	if bool(ret.get("ok", false)):
		return {"ok": true, "result": {"from": str(args["from"]), "to": str(args["to"])}}
	return ret


func _tool_set_param(args: Dictionary) -> Dictionary:
	var ret := state().set_param(str(args["entityId"]), str(args["key"]), args["value"])
	if bool(ret.get("ok", false)):
		return {"ok": true, "result": {
			"entityId": args["entityId"],
			"key": args["key"],
			"oldValue": ret.get("oldValue"),
		}, "input": {
			"entityId": args["entityId"],
			"key": args["key"],
			"oldValue": ret.get("oldValue"),
		}}
	return ret


func _tool_run(args: Dictionary) -> Dictionary:
	var duration := 1.0
	if args.has("duration"):
		var v: Variant = args["duration"]
		if not (v is int or v is float):
			return {"ok": false, "code": "bad_args", "message": "duration 必须是数字（秒），得到 %s" % type_string(typeof(v))}
		duration = float(v)
	var st := state()
	st.advance(duration)
	var errs := st.propagate()
	var result := {"t": st.world_t(), "tick": st.tick(), "typeErrors": errs}
	if errs.is_empty():
		return {"ok": true, "result": result}
	return {"ok": true, "result": result, "failures": errs}


func _tool_step(_args: Dictionary) -> Dictionary:
	var st := state()
	st.step_once()
	var errs := st.propagate()
	var result := {"t": st.world_t(), "tick": st.tick(), "typeErrors": errs}
	if errs.is_empty():
		return {"ok": true, "result": result}
	return {"ok": true, "result": result, "failures": errs}


func _tool_inspect(args: Dictionary) -> Dictionary:
	return state().inspect_entity(str(args["entityId"]))


func _tool_snapshot(_args: Dictionary) -> Dictionary:
	return {"ok": true, "result": {"snapshot": state().logical_snapshot()}}


func _tool_read(args: Dictionary) -> Dictionary:
	var ret := state().read_ref(str(args["ref"]))
	if bool(ret.get("ok", false)):
		return {"ok": true, "result": ret}
	return ret


func _tool_trace(args: Dictionary) -> Dictionary:
	var ref := str(args["ref"])
	if not ref.contains(":"):
		return {"ok": false, "code": "bad_args", "message": "trace 需要 portRef（{entityId}:{portId}），得到：%s" % ref}
	var eid := ref.substr(0, ref.find(":"))
	var pid := ref.substr(eid.length() + 1)
	var history: Array = []
	for step in recorder().get_steps():
		var entities: Dictionary = step["world"]["entities"]
		if entities.has(eid) and (entities[eid] as Dictionary)["ports"].has(pid):
			history.append({
				"i": step["i"],
				"t": step["t"],
				"value": entities[eid]["ports"][pid]["value"],
			})
	return {"ok": true, "result": {"ref": ref, "history": history}}


func _tool_watch(args: Dictionary) -> Dictionary:
	var ref := str(args["ref"])
	var current := state().read_ref(ref)
	var wid := state().add_watch(ref)
	return {"ok": true, "result": {"watchId": wid, "ref": ref, "current": current}}


func _tool_diff(args: Dictionary) -> Dictionary:
	var steps := recorder().get_steps()
	if steps.size() < 2:
		return {"ok": false, "code": "no_steps", "message": "至少要有两步才能 diff（当前 %d 步）" % steps.size()}
	var to_i := steps.size() - 1
	var from_i := to_i - 1
	if args.has("fromStep"):
		from_i = int(args["fromStep"])
	if args.has("toStep"):
		to_i = int(args["toStep"])
	if from_i < 0 or to_i <= from_i or to_i >= steps.size():
		return {"ok": false, "code": "bad_args",
			"message": "需要 0 <= fromStep < toStep < %d，得到 from=%d to=%d" % [steps.size(), from_i, to_i]}
	var a: Dictionary = steps[from_i]["world"]["entities"]
	var b: Dictionary = steps[to_i]["world"]["entities"]
	var d := WorldStateCore.diff_entities(a, b)
	return {"ok": true, "result": {"fromStep": from_i, "toStep": to_i, "diff": d}}


func _tool_export_netlist(_args: Dictionary) -> Dictionary:
	var text := state().netlist_text()
	var snapshot := state().logical_snapshot()
	return {"ok": true, "result": {
		"text": text,
		"entities": (snapshot["entities"] as Dictionary).size(),
		"edges": (snapshot["edges"] as Array).size(),
	}}


# ---------- 导出 Python（world.export_python：12 工具之外的新增交付物） ----------

## 把世界里拼好的装置一键导出为可搬运 Python（spec §11 方块编译器交付物）。
## 经 integration/world_to_graph.gd 桥投影成编译器图再 compile：只读连接与
## 参数，位置/朝向不进图（契约 §6.2）。计价按读（1 ops，与 export_netlist 同档）；
## 成功/失败都进步记录，失败不收费并写 failures。
func export_python() -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var r: Dictionary = BRIDGE.export_python(state())
	if bool(r.get("ok", false)):
		return _succeed(TOOL_EXPORT_PYTHON, {}, {}, t0, PHASE_OBSERVE, CostModelCore.MODE_READ, {
			"ok": true,
			"result": {
				"python": String(r.get("python", "")),
				"ir_hash": String(r.get("ir_hash", "")),
				"warnings": r.get("warnings", []),
			},
		})
	var messages: Array[String] = []
	for e in (r.get("errors", []) as Array):
		messages.append(str(e) if not (e is Dictionary) else String((e as Dictionary).get("message", "")))
	return _fail(TOOL_EXPORT_PYTHON, {}, {}, t0, PHASE_OBSERVE, "compile_failed",
		"世界装置编译失败：%s" % "；".join(PackedStringArray(messages)))
