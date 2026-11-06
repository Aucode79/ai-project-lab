extends RefCounted

## 桥客户端：与 McpBridge（autoload，行 JSON TCP 协议）对话。
## 协议全文见 sidecar/PROTOCOL.md；连接与读取的做法照抄
## game/tests/mcp/run_mcp_tests.gd 的 _roundtrip：
##   * 只连回环 127.0.0.1:7310（被占桥自退 7395，客户端连 bridge.port）
##   * 一行请求一行响应：{"id": n, "tool": "world.*", "args": {...}}\n，
##     id 由本客户端递增，桥原样带回
##   * 读取用 get_partial_data——get_data 在 StreamPeerTCP 上实测不可靠
##     （只回 2 个零字节），不要换回去
##   * 等待期间要泵桥才能收到响应：游戏运行时 autoload McpBridge 在
##     _process 里自泵，可不注入 pump；headless -s 测试用自建桥实例时
##     注入 Callable(bridge, "pump")
##
## 连接长期复用（协议 §1）；call_tool 发现连接不在时按记忆的 host:port 重连。

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT := 7310
const DEFAULT_TIMEOUT_MS := 5000
const POLL_INTERVAL_MS := 5

var host := DEFAULT_HOST
var port := 0
var timeout_ms := DEFAULT_TIMEOUT_MS
## 等待期泵桥（见类头注释；游戏运行时可不注入）。
var pump: Callable = Callable()

var _peer: StreamPeerTCP = null
var _next_id := 0


# ---------- 连接 ----------

func connect_to_bridge(want_host := DEFAULT_HOST, want_port := 0) -> Dictionary:
	host = want_host
	if want_port > 0:
		port = want_port
	if port <= 0:
		return _err("no_port", "桥端口未指定（默认 %d）" % DEFAULT_PORT)
	close()
	_peer = StreamPeerTCP.new()
	var err := _peer.connect_to_host(host, port)
	if err != OK:
		return _err("connect_failed", "connect_to_host(%s:%d) 返回 %s" % [host, port, str(err)])
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		_pump()
		var status := _peer.get_status()
		if status == StreamPeerTCP.STATUS_CONNECTED:
			_peer.set_no_delay(true)
			return {"ok": true, "host": host, "port": port}
		if status == StreamPeerTCP.STATUS_NONE or status == StreamPeerTCP.STATUS_ERROR:
			return _err("connect_failed", "连接 %s:%d 被拒（桥没在监听？）" % [host, port])
		OS.delay_msec(POLL_INTERVAL_MS)
	return _err("timeout", "等连接 %s:%d 超时（%d ms）" % [host, port, timeout_ms])


## 连接是否就绪（不叫 is_connected：那是 Object 内置方法名，会遮蔽冲突）。
func has_connection() -> bool:
	return _peer != null and _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED


func close() -> void:
	if _peer != null:
		_peer.disconnect_from_host()
		_peer = null


# ---------- 请求 ----------

## 发一条 world.* 请求并同步等待该行的响应（自旋轮询，非阻塞泵桥）。
## 返回桥的响应 Dictionary；客户端自身错误（连不上/超时/坏响应）返回
## {ok: false, error: {code, message}}，与桥的错误形状一致。
func call_tool(tool: String, args: Dictionary = {}) -> Dictionary:
	if not has_connection():
		var conn := connect_to_bridge()
		if not bool(conn.get("ok", false)):
			return conn
	_next_id += 1
	var line := JSON.stringify({"id": _next_id, "tool": tool, "args": args})
	var put_err := _peer.put_data((line + "\n").to_utf8_buffer())
	if put_err != OK:
		return _err("send_failed", "发送 %s 失败：%s" % [tool, str(put_err)])
	var buf := PackedByteArray()
	var deadline := Time.get_ticks_msec() + timeout_ms
	while Time.get_ticks_msec() < deadline:
		_peer.poll()
		_pump()
		if _peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
			var avail := _peer.get_available_bytes()
			if avail > 0:
				var res: Array = _peer.get_partial_data(avail)
				if res.size() >= 2:
					buf.append_array(res[1])
		var nl := buf.find(10) # b"\n"
		if nl >= 0:
			var parsed: Variant = JSON.parse_string(buf.slice(0, nl).get_string_from_utf8())
			if parsed is Dictionary:
				return parsed
			return _err("bad_response", "响应行不是 JSON 对象：%s"
				% buf.slice(0, nl).get_string_from_utf8().substr(0, 120))
		if _peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
			return _err("connection_lost", "等 %s 响应时连接断开" % tool)
		OS.delay_msec(POLL_INTERVAL_MS)
	return _err("timeout", "等 %s 响应超时（%d ms）" % [tool, timeout_ms])


# ---------- 内部 ----------

func _pump() -> void:
	if pump.is_valid():
		pump.call()


func _err(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}
