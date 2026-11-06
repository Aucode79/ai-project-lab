extends SceneTree

## MCP 桥测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/mcp/run_mcp_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##   1  world.place 走完整 TCP 行协议：响应 ok、步记录多一步 actor=codex、
##      ops=20（写价）、action 带工具名与参数；首条请求自动开 explore run
##   2  world.read（读）经桥：ops=1（读价），result 带结构化负载，priced_by=godot
##   3  record_external 回写一条 fs.read：步记录多一步 actor=codex、
##      tool=fs.read、ops 由 sidecar 计价带入（1）、phase=observe
##   4  未知工具 / 非 JSON 行：结构化 error（unknown_tool / bad_request），
##      且这两类协议错误不进步记录
##   5  project.godot 的 autoload 注册：McpBridge 在 WorldTools 之后
##
## 桥实例选择：-s 模式下 autoload 的 _ready 不监听（core 里对 ScriptRunner
## 有守卫，避免退出阶段抢端口），所以这里常规路径是自建注入式内核实例，
## 走与游戏运行时完全相同的协议路；若 autoload 恰在监听则直接复用。

const ASSET_BELT := "conc_batch_belt"

var _passed := 0
var _failed := 0
var _own_bridge: McpBridgeCore = null
var _garbage: Array[Node] = []


func _initialize() -> void:
	var bridge := _get_bridge()
	if bridge == null:
		print("FAIL: 拿不到监听中的 McpBridge（autoload 缺失且自建失败）")
		_failed += 1
	else:
		_t1_place_over_tcp(bridge)
		_t2_inspect_read_priced(bridge)
		_t3_record_external(bridge)
		_t4_protocol_errors(bridge)
	_t5_autoload_registered()
	_cleanup()
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ---------- 基础设施 ----------

func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


## 优先用引擎加载的 McpBridge autoload；-s 下没有则自建注入式实例。
func _get_bridge() -> McpBridgeCore:
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null and loop.root != null:
		var found := loop.root.get_node_or_null("McpBridge")
		if found is McpBridgeCore:
			if (found as McpBridgeCore).is_listening():
				return found
	# 兜底：自建一套（注入独立内核，不碰共享单例）
	var tools := WorldToolsCore.new()
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	_own_bridge = McpBridgeCore.new()
	_own_bridge.own_tools = tools
	_garbage.append_array([tools, st, rc, cm, _own_bridge])
	var ret: Dictionary = _own_bridge.listen(McpBridgeCore.DEFAULT_PORT)
	if not bool(ret["ok"]):
		print("自建桥监听失败：%s" % str(ret))
		return null
	return _own_bridge


func _register_assets(bridge: McpBridgeCore) -> void:
	# 全新进程里共享 autoload 是空的；重复注册（极端并行场景）忽略即可
	bridge.state().register_asset(ASSET_BELT, WorldStateCore.KIND_PARAMETRIC,
		{"batch_size": 8}, [
			{"id": "samples_in", "kind": "ANALOG", "dir": "in"},
			{"id": "batch_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])


## 一条完整的 TCP 行协议往返：连接 → 发一行 JSON → 泵桥 → 收一行 JSON。
func _roundtrip(bridge: McpBridgeCore, line: String, timeout_ms := 5000) -> Dictionary:
	var client := StreamPeerTCP.new()
	var err := client.connect_to_host("127.0.0.1", bridge.port)
	if err != OK:
		return {"ok": false, "error": {"code": "connect_failed", "message": str(err)}}
	var deadline := Time.get_ticks_msec() + timeout_ms
	var connected := false
	var buf := PackedByteArray()
	while Time.get_ticks_msec() < deadline:
		client.poll()
		bridge.pump()
		if not connected:
			if client.get_status() == StreamPeerTCP.STATUS_CONNECTED:
				connected = true
				client.set_no_delay(true)
				client.put_data((line + "\n").to_utf8_buffer())
			elif client.get_status() == StreamPeerTCP.STATUS_ERROR:
				return {"ok": false, "error": {"code": "connect_failed", "message": "连接被拒"}}
		else:
			var avail := client.get_available_bytes()
			if avail > 0:
				# get_data 在 StreamPeerTCP 上不可靠（只回 2 个零字节），用 get_partial_data
				var res: Array = client.get_partial_data(avail)
				buf.append_array(res[1])
			var nl := buf.find(10)
			if nl >= 0:
				var resp: Variant = JSON.parse_string(buf.slice(0, nl).get_string_from_utf8())
				client.disconnect_from_host()
				if resp is Dictionary:
					return resp
				return {"ok": false, "error": {"code": "bad_response", "message": "响应不是 JSON"}}
		OS.delay_msec(5)
	return {"ok": false, "error": {"code": "timeout", "message": "等响应超时"}}


func _steps_of(bridge: McpBridgeCore) -> Array:
	# recorder 未开 run 时 _doc 为空（get_steps 会踩空键），等价于 0 步
	if bridge.recorder().state_name() != "recording":
		return []
	return bridge.recorder().get_steps()


func _cleanup() -> void:
	if _own_bridge != null and is_instance_valid(_own_bridge):
		_own_bridge.stop()
	for n in _garbage:
		if n != null and is_instance_valid(n):
			n.free()
	_garbage.clear()


# ---------- 测试 ----------

func _t1_place_over_tcp(bridge: McpBridgeCore) -> void:
	_register_assets(bridge)
	var was_idle := bridge.recorder().state_name() == "idle"
	var steps_before := _steps_of(bridge).size()
	var req := JSON.stringify({"id": 101, "tool": "world.place",
		"args": {"assetId": ASSET_BELT, "pos": [2, 0, 1]}})
	var resp := _roundtrip(bridge, req)
	var steps := _steps_of(bridge)
	var ok := bool(resp.get("ok", false)) and int(resp.get("id", -1)) == 101
	ok = ok and (steps.size() == steps_before + 1)
	var step: Dictionary = steps[steps.size() - 1] if steps.size() > 0 else {}
	ok = ok and str(step.get("actor", "")) == "codex"
	ok = ok and str(step.get("phase", "")) == "build"
	ok = ok and int(step.get("ops", -1)) == 20 # 写价（spec §7.2：写 20 读 1）
	ok = ok and str(step.get("action", {}).get("tool", "")) == "world.place"
	ok = ok and (step["action"]["args"] as Dictionary).has("assetId")
	ok = ok and int(resp.get("ops", -1)) == 20 and int(resp.get("step", -1)) == int(step.get("i", -1))
	ok = ok and str((resp.get("usage", {}) as Dictionary).get("priced_by", "")) == "godot"
	ok = ok and was_idle and bridge.recorder().state_name() == "recording" # 首条请求自动开 explore run
	_check(ok, "T1 world.place 经 TCP：响应 ok/id/step/ops=20、步记录 actor=codex phase=build、自动开 run")


func _t2_inspect_read_priced(bridge: McpBridgeCore) -> void:
	var steps_before := _steps_of(bridge).size()
	# world.read（读价）：result 里带 ref/value 结构化负载（inspect 的 result 为空
	# 是 WorldToolsCore 既有行为，不在本测试的改动面内）
	var req := JSON.stringify({"id": "s2", "tool": "world.read",
		"args": {"ref": ASSET_BELT + "#1"}})
	var resp := _roundtrip(bridge, req)
	var steps := _steps_of(bridge)
	var step: Dictionary = steps[steps.size() - 1] if steps.size() > 0 else {}
	var ok := bool(resp.get("ok", false)) and str(resp.get("id", "")) == "s2"
	ok = ok and steps.size() == steps_before + 1
	ok = ok and int(step.get("ops", -1)) == 1 # 读价
	ok = ok and str(step.get("actor", "")) == "codex" and str(step.get("phase", "")) == "observe"
	ok = ok and int(resp.get("ops", -1)) == 1
	ok = ok and str((resp.get("usage", {}) as Dictionary).get("mode", "")) == "read"
	ok = ok and str((resp.get("result", {}) as Dictionary).get("entityId", "")) == ASSET_BELT + "#1"
	_check(ok, "T2 world.read 经桥：ops=1（读价）、usage.mode=read、result 结构化带回")


func _t3_record_external(bridge: McpBridgeCore) -> void:
	var steps_before := _steps_of(bridge).size()
	var req := JSON.stringify({"id": 7, "tool": "record_external", "args": {
		"tool": "fs.read",
		"args": {"path": "notes/a.txt"},
		"ok": true,
		"result": {"bytes": 12},
		"ops": 1,
		"costMs": 0.4,
	}})
	var resp := _roundtrip(bridge, req)
	var steps := _steps_of(bridge)
	var step: Dictionary = steps[steps.size() - 1] if steps.size() > 0 else {}
	var ok := bool(resp.get("ok", false)) and int(resp.get("id", -1)) == 7
	ok = ok and steps.size() == steps_before + 1
	ok = ok and str(step.get("actor", "")) == "codex"
	ok = ok and str(step.get("action", {}).get("tool", "")) == "fs.read"
	ok = ok and str((step["action"]["args"] as Dictionary).get("path", "")) == "notes/a.txt"
	ok = ok and int(step.get("ops", -1)) == 1 and str(step.get("phase", "")) == "observe"
	ok = ok and bool((step["output"] as Dictionary).get("ok", false))
	_check(ok, "T3 record_external fs.read：进步记录 actor=codex、tool=fs.read、ops=1（sidecar 计价）、phase=observe")


func _t4_protocol_errors(bridge: McpBridgeCore) -> void:
	var steps_before := _steps_of(bridge).size()
	var r1 := _roundtrip(bridge, JSON.stringify({"id": 8, "tool": "studio.bake", "args": {}}))
	var r2 := _roundtrip(bridge, JSON.stringify({"id": 9, "tool": "fs.read", "args": {}}))
	var r3 := _roundtrip(bridge, "{not json at all")
	var steps_after := _steps_of(bridge).size()
	var ok := not bool(r1.get("ok", true)) and str(r1.get("error", {}).get("code", "")) == "unknown_tool"
	ok = ok and not bool(r2.get("ok", true)) and str(r2.get("error", {}).get("code", "")) == "unknown_tool"
	ok = ok and not bool(r3.get("ok", true)) and str(r3.get("error", {}).get("code", "")) == "bad_request"
	ok = ok and steps_after == steps_before # 协议级错误不冒充世界步
	_check(ok, "T4 studio.bake/fs.read 直发桥与坏 JSON 行：结构化 unknown_tool/bad_request，且不进步记录")


func _t5_autoload_registered() -> void:
	var text := FileAccess.get_file_as_string("res://project.godot")
	# 手工比顺序：WorldState -> CostModel -> StepRecorder -> WorldTools -> McpBridge
	var lines := {
		"WorldState": 'WorldState="*res://scripts/autoload/world_state.gd"',
		"CostModel": 'CostModel="*res://scripts/autoload/cost_model.gd"',
		"StepRecorder": 'StepRecorder="*res://scripts/autoload/step_recorder.gd"',
		"WorldTools": 'WorldTools="*res://scripts/autoload/world_tools.gd"',
		"McpBridge": 'McpBridge="*res://scripts/autoload/mcp_bridge.gd"',
	}
	var positions: Array = []
	var ok := text.contains("[autoload]")
	for nm in ["WorldState", "CostModel", "StepRecorder", "WorldTools", "McpBridge"]:
		var pos := text.find(lines[nm])
		ok = ok and pos >= 0
		positions.append(pos)
	for k in range(positions.size() - 1):
		ok = ok and positions[k] < positions[k + 1]
	_check(ok, "T5 project.godot 注册 McpBridge autoload 且顺序在 WorldTools 之后（共 5 个 autoload）")
