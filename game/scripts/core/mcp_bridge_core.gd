class_name McpBridgeCore
extends Node

## MCP 桥内核（autoload 薄壳：autoload/mcp_bridge.gd）。
##
## spec §7.2 / §8.4 落位裁决：MCP 客户端在 sidecar（Python 侧），Godot 不碰 MCP。
## 本节点只做一件事：在 127.0.0.1:7310 上听一个**行分隔 JSON** 的 TCP 小协议，
## 把 world.* 工具调用交给 WorldTools，把 sidecar 本地执行的 fs.* / run.*
## 回写进步记录——世界（步记录）是唯一权威。
##
## 协议（全文见 sidecar/PROTOCOL.md）：
##   请求：{"id": <任意>, "tool": "world.place", "args": {...}}\n
##   响应：{"id": <同值>, "ok": true, "result": {...}, "step": i, "ops": n,
##          "usage": {"ops": n, "mode": "write|read|exec", "priced_by": "godot"}}\n
##         {"id": <同值>, "ok": false, "error": {"code": ..., "message": ...}}\n
##   record_external 端点（sidecar 本地执行 fs.*/run.* 后回写）：
##   请求 args：{"tool": "fs.read", "args": {...}, "ok": true,
##              "result": <摘要>, "ops": 1, "costMs": 0.5}
##
## 约定：
##   * world.* 经 WorldToolsCore.call_tool 走，actor 固定 "codex"（spec §6：
##     内置 agent 与世界共用同一套工具面，它的每次操作都进步记录）
##   * ops 由 Godot 侧 CostModel 计价后随 result 带回（sidecar 不重复计价）
##   * record_external 的 ops 由 sidecar 计价（同口径：写 20 读 1 exec 20），
##     世界只做记录
##   * 桥收到请求时若没有进行中的 run，自动 begin_run(kind=explore)——
##     agent 的代做运行不参与判定（docs/10-契约/mini-codex.md §四）
##   * 只监听回环；studio.* 制作工具不在本桥的工具面内，永不转发
##
## 读数据用 get_partial_data（非阻塞语义正确）；get_data 在
## StreamPeerTCP 上行为不可靠（实测只回 2 个零字节），不要换回去。

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 7310
## 默认口被占（比如另一台 headless 实例在跑）时的备用口
const FALLBACK_PORT := 7395

const ACTOR_CODEX := "codex"

const ENDPOINT_RECORD_EXTERNAL := "record_external"

## world.* 工具面（与 WorldToolsCore 的 12 个一一对应；studio.* 不在内）
const WORLD_TOOLS := [
	"world.place", "world.connect", "world.set_param", "world.run", "world.step",
	"world.inspect", "world.snapshot", "world.read", "world.trace", "world.watch",
	"world.diff", "world.export_netlist",
]

## record_external 的 phase 映射（fs/run 不碰世界状态层，按动作性质归类）
const _EXTERNAL_PHASE := {
	"fs.read": "observe", "fs.list": "observe",
	"fs.write": "build",
	"run.python": "run", "run.tests": "run",
}

## 测试 / 独立实例注入的 WorldTools 内核（不碰共享单例）
var own_tools: WorldToolsCore = null

var host := DEFAULT_HOST
var port := 0

var _server := TCPServer.new()
var _conns: Array[_Conn] = []
var _listening := false


## 一条已接受的连接。buf 不能塞进 Dictionary（Variant 装箱会让
## PackedByteArray 的原地追加丢失），必须是对象属性。
class _Conn:
	extends RefCounted
	var peer: StreamPeerTCP
	var buf := PackedByteArray()


func _ready() -> void:
	# `godot -s`（ScriptRunner 测试）模式下 _ready 要到退出阶段才触发，
	# 此时再抢端口只会和测试自建的桥实例打架：桥的监听交给游戏运行时，
	# 测试同步驱动自己的 McpBridgeCore 实例（tests/mcp/run_mcp_tests.gd）。
	if _is_script_runner():
		return
	listen(DEFAULT_PORT)


func _is_script_runner() -> bool:
	for a in OS.get_cmdline_args():
		if a == "-s" or a == "--script":
			return true
	return false


func _process(_delta: float) -> void:
	pump()


func _exit_tree() -> void:
	stop()


# ---------- 生命周期 ----------

## 开始监听。默认口被占则退到 FALLBACK_PORT；两个都不行就带错误码返回
## （不抛、不退进程：桥挂了世界照跑，只是 sidecar 连不上）。
func listen(want_port := DEFAULT_PORT) -> Dictionary:
	if _listening:
		return {"ok": false, "code": "already_listening", "message": "桥已在监听：%s:%d" % [host, port]}
	for p in [want_port, FALLBACK_PORT]:
		if p == FALLBACK_PORT and want_port == FALLBACK_PORT:
			continue
		var err := _server.listen(p, host)
		if err == OK:
			_listening = true
			port = p
			return {"ok": true, "host": host, "port": p}
	return {"ok": false, "code": "listen_failed",
		"message": "监听 %s 失败：端口 %d/%d 可能被占用" % [host, want_port, FALLBACK_PORT]}


func stop() -> void:
	for c in _conns:
		if c.peer != null and is_instance_valid(c.peer):
			c.peer.disconnect_from_host()
	_conns.clear()
	if _listening:
		_server.stop()
		_listening = false
	port = 0


func is_listening() -> bool:
	return _listening


## 单次轮询：收连接、读行、分发、回写。_process 每帧调；测试也可直接同步调用，
## 这样 -s 脚本模式下不依赖引擎帧循环也能驱动协议。
func pump() -> void:
	if not _listening:
		return
	while _server.is_connection_available():
		var conn := _Conn.new()
		conn.peer = _server.take_connection()
		_conns.append(conn)
	var alive: Array[_Conn] = []
	for c in _conns:
		var peer := c.peer
		if peer == null or not is_instance_valid(peer):
			continue
		var status := peer.get_status()
		if status != StreamPeerTCP.STATUS_CONNECTED:
			# CONNECTING 留观；NONE / ERROR 是死连接，丢弃
			if status == StreamPeerTCP.STATUS_CONNECTING:
				alive.append(c)
			continue
		peer.poll()
		var avail := peer.get_available_bytes()
		if avail > 0:
			var res: Array = peer.get_partial_data(avail)
			# 出错时返回 [errcode] 单元素数组，读不出数据就等下一轮
			if res.size() >= 2:
				var chunk: PackedByteArray = res[1]
				if chunk.size() > 0:
					c.buf.append_array(chunk)
					_drain_lines(c)
		alive.append(c)
	_conns = alive


# ---------- 请求分发 ----------

## 协议入口（纯逻辑，测试直调；pump 从网络到达同一条路）。
## 返回完整响应 Dictionary（序列化时补换行）。
func handle_request(request: Dictionary) -> Dictionary:
	if not request.has("tool"):
		return _err(request.get("id", null), "bad_request", "请求缺少 tool 字段")
	var tool := str(request["tool"])
	var raw_args: Variant = request.get("args", {})
	var args: Dictionary = raw_args if raw_args is Dictionary else {}
	if tool == ENDPOINT_RECORD_EXTERNAL:
		return _handle_record_external(request.get("id", null), args)
	if not WORLD_TOOLS.has(tool):
		return _err(request.get("id", null), "unknown_tool",
			"未知工具名：%s（桥只转发 world.* 12 个工具与 record_external）" % tool)
	_ensure_run()
	var ret: Dictionary = tools().call_tool(tool, args, {"actor": ACTOR_CODEX})
	if not bool(ret.get("ok", false)):
		var e: Dictionary = ret.get("error", {})
		return _err(request.get("id", null), str(e.get("code", "tool_failed")),
			str(e.get("message", "工具执行失败")), ret.get("step", -1))
	var step_i := int(ret.get("step", -1))
	var ops := _ops_of_step(step_i)
	return {
		"id": request.get("id", null),
		"ok": true,
		"result": ret.get("result", {}),
		"step": step_i,
		"ops": ops,
		"usage": {"ops": ops, "mode": _mode_of_tool(tool), "priced_by": "godot"},
	}


## sidecar 本地执行 fs.*/run.* 后回写一条：世界把这条也进步记录（唯一权威）。
func _handle_record_external(id: Variant, args: Dictionary) -> Dictionary:
	var tool := str(args.get("tool", ""))
	if not _EXTERNAL_PHASE.has(tool):
		return _err(id, "bad_request",
			"record_external 只收 fs.*/run.* 的回写，得到：%s" % tool)
	var raw_inner: Variant = args.get("args", {})
	var inner: Dictionary = raw_inner if raw_inner is Dictionary else {}
	_ensure_run()
	var t0 := Time.get_ticks_usec()
	var i := recorder().record_step({
		"t": state().world_t(),
		"phase": _EXTERNAL_PHASE[tool],
		"actor": ACTOR_CODEX,
		"input": {},
		"action": {"tool": tool, "args": inner.duplicate(true)},
		"output": {"ok": bool(args.get("ok", false)), "result": args.get("result", {})},
		"tokens": int(args.get("tokens", 0)),
		"ops": int(args.get("ops", 0)),
		"costMs": float(args.get("costMs", (Time.get_ticks_usec() - t0) / 1000.0)),
		"world": state().state_digest(),
		"caption": str(args.get("caption", "")),
		"formula": "",
	})
	if i < 0:
		return _err(id, "not_recording", "步记录不在 recording 状态，回写被拒")
	return {"id": id, "ok": true, "result": {"recorded": true, "step": i},
		"step": i, "ops": int(args.get("ops", 0)),
		"usage": {"ops": int(args.get("ops", 0)), "priced_by": "sidecar"}}


# ---------- 依赖解析（与 WorldToolsCore 同款：注入优先，autoload 次之，兜底自建） ----------

func tools() -> WorldToolsCore:
	if own_tools != null:
		return own_tools
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null and loop.root != null:
		var found := loop.root.get_node_or_null("WorldTools")
		if found is WorldToolsCore:
			return found
	return WorldToolsCore.new()


func state() -> WorldStateCore:
	return tools().state()


func recorder() -> StepRecorderCore:
	return tools().recorder()


## 桥收到第一条请求时若没有进行中的 run，自动开一个 explore run。
## agent 的代做运行不参与判定（docs/10-契约/mini-codex.md §四），判定只属于学员的 task run。
func _ensure_run() -> void:
	var rc := recorder()
	if rc.state_name() != "recording":
		rc.begin_run(StepRecorderCore.KIND_EXPLORE, -1, 0)


# ---------- 内部 ----------

func _ops_of_step(step_i: int) -> int:
	if step_i < 0:
		return 0
	var steps := recorder().get_steps()
	if step_i >= steps.size():
		return 0
	return int(steps[step_i]["ops"])


func _mode_of_tool(tool_name: String) -> String:
	match tool_name:
		"world.place", "world.connect", "world.set_param":
			return CostModelCore.MODE_WRITE
		"world.run", "world.step":
			return CostModelCore.MODE_EXEC
		_:
			return CostModelCore.MODE_READ


func _err(id: Variant, code: String, message: String, step: Variant = null) -> Dictionary:
	var resp := {"id": id, "ok": false, "error": {"code": code, "message": message}}
	if step != null and int(step) >= 0:
		resp["step"] = int(step)
	return resp


func _drain_lines(conn: _Conn) -> void:
	var peer := conn.peer
	var buf := conn.buf
	while true:
		var nl := buf.find(10) # b"\n"
		if nl < 0:
			break
		var line := buf.slice(0, nl).get_string_from_utf8().strip_edges()
		buf = buf.slice(nl + 1) if buf.size() > nl + 1 else PackedByteArray()
		conn.buf = buf
		if line.is_empty():
			continue
		var resp := _handle_line(line)
		peer.put_data((JSON.stringify(resp) + "\n").to_utf8_buffer())


func _handle_line(line: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(line)
	if parsed == null or not (parsed is Dictionary):
		return _err(null, "bad_request", "行不是合法 JSON 对象")
	return handle_request(parsed as Dictionary)
