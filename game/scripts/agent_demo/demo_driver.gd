extends RefCounted

## 代做驱动器（docs/10-契约/交互方案.md §六 / docs/10-契约/mini-codex.md §四）。
##
## 「让它做」时 codex 经 MCP 桥真实操作世界：把学员会做的那串操作
## （place → set_param → run → read）逐条发 world.*，每步之间停留
## slow_step_seconds（默认 0.6 秒，mini-codex §2.3），每步发 step_presented
## 信号——可视层（任务牌"正在"灯、工具头指示）订阅它，接线由场景任务完成，
## 本类只发信号、不碰任何场景节点。
##
## 代操作边界三条（mini-codex §四）在代码里的落点：
##   (a) 慢速可视——每步后 await _tick(slow_step_seconds)，时钟可注入（测试
##       假推进不真 sleep）；
##   (b) 学员随时接管——request_pause() 在下一步前生效；take_over() 立即停
##       （正在等的那一步走完），返回 {completed_steps, remaining_steps}
##       供学员续做；
##   (c) 代做不参与判定——本类完全不碰 recorder：world.* 经桥转发，步记录
##       由桥自动开的 explore run 承载（mcp_bridge_core._ensure_run），
##       判定只属于学员自己的 task run。运行结果的 was_judged 恒为 false，
##       是这条边界的断言依据。学员 task run 进行中（recorder recording 态）
##       时入口直接拒绝（l1_flow.run_agent_demo 返回 student_run_in_progress），
##       代做步进不了任何进行中的判定 run。
##
## steps 形状：[{tool: String, args: Dictionary, caption: String?}]；
## args 需要引用前序响应时（如 place 带回的 entityId）用 args_fn:
## Callable(responses: Array) -> Dictionary，发送时求值。
##
## headless 可测：bridge 可注入 mock（只要求 call_tool(tool, args) -> Dictionary），
## clock 可注入假时钟（只要求 tick(seconds: float)）。

const DEFAULT_SLOW_STEP_SECONDS := 0.6
## 暂停期间的轮询间隔（真实时钟下每 50ms 看一眼 resume/take_over）
const PAUSE_POLL_SECONDS := 0.05

## 每步一发（发送该步请求之前）：可视层据此点亮"正在"灯、移动工具头。
signal step_presented(index: int, total: int, tool: String, args: Dictionary, caption: String)
## 一次代做结束（完成 / 被接管 / 失败）时发，载荷即 run() 返回值。
signal run_finished(result: Dictionary)

## 桥客户端（scripts/agent_demo/bridge_client.gd 或测试 mock），
## 只要求有 call_tool(tool, args) -> Dictionary。
var bridge = null
## 每步停留秒数（默认 0.6，参数化）。
var slow_step_seconds := DEFAULT_SLOW_STEP_SECONDS
## 注入时钟：func(seconds: float)。不注入则用引擎真实计时器。
var clock: Callable = Callable()

var _pause_requested := false
var _taken_over := false
var _cursor := 0
var _plan: Array = []


# ---------- 主循环 ----------

## 把 steps 逐条经桥发出。每步：发 step_presented → call_tool → 停留
## slow_step_seconds。下一步前检查暂停与接管。失败即停（世界没配上时
## 后续步只会连环失败，慢速可视也没意义）。
func run(steps: Array) -> Dictionary:
	_pause_requested = false
	_taken_over = false
	_cursor = 0
	_plan = steps
	var responses: Array = []
	var error: Dictionary = {}
	for i in steps.size():
		if _taken_over:
			break
		while _pause_requested and not _taken_over:
			await _tick(PAUSE_POLL_SECONDS)
		if _taken_over:
			break
		var action: Dictionary = steps[i] if steps[i] is Dictionary else {}
		var tool := str(action.get("tool", ""))
		var args := resolve_args(action, responses)
		var caption := str(action.get("caption", ""))
		step_presented.emit(i, steps.size(), tool, args, caption)
		var resp: Dictionary = _send(tool, args, i)
		responses.append(resp)
		_cursor = i + 1
		if not bool(resp.get("ok", false)):
			error = resp.get("error", {})
			break
		await _tick(slow_step_seconds)
	var result := {
		"ok": error.is_empty(),
		"completed": error.is_empty() and not _taken_over and _cursor >= steps.size(),
		"taken_over": _taken_over,
		"completed_steps": _cursor,
		"remaining_steps": _plan.slice(_cursor),
		"responses": responses,
		"steps_total": steps.size(),
		"slow_step_seconds": slow_step_seconds,
		"was_judged": false, # 代做运行不参与判定（mini-codex §四）
	}
	if not error.is_empty():
		result["error"] = error
	run_finished.emit(result)
	return result


## 求一步的参数：args_fn（可引用前序响应）优先，静态 args 次之。
static func resolve_args(action: Dictionary, responses: Array) -> Dictionary:
	if action.has("args_fn"):
		var fn: Callable = action["args_fn"]
		var built: Variant = fn.call(responses)
		return built if built is Dictionary else {}
	var raw: Variant = action.get("args", {})
	return raw if raw is Dictionary else {}


# ---------- 暂停与接管 ----------

## 请求暂停：下一步前生效（正在执行的这一步走完）。
func request_pause() -> void:
	_pause_requested = true


## 从暂停继续。
func resume() -> void:
	_pause_requested = false


func is_paused() -> bool:
	return _pause_requested


## 接管：立即置停标志（正在等待/发送的当前步走完，下一步不再发）。
## 返回交接信息：{completed_steps, remaining_steps}——remaining_steps 是
## 还没发出的原始步骤（含 args_fn），供学员续做或重放。
func take_over() -> Dictionary:
	_taken_over = true
	_pause_requested = false
	return handoff()


## 当前交接快照（不置停标志，纯查询）。
func handoff() -> Dictionary:
	return {"completed_steps": _cursor, "remaining_steps": _plan.slice(_cursor)}


# ---------- 内部 ----------

func _send(tool: String, args: Dictionary, i: int) -> Dictionary:
	if bridge == null:
		return {"ok": false, "error": {"code": "no_bridge",
			"message": "桥客户端未注入（第 %d 步无处发送）" % i}}
	if tool == "":
		return {"ok": false, "error": {"code": "bad_step",
			"message": "第 %d 步缺少 tool 字段" % i}}
	return bridge.call_tool(tool, args)


## 停留一拍：注入时钟优先（测试假推进），否则用引擎真实计时器。
func _tick(seconds: float) -> void:
	if clock.is_valid():
		await clock.call(seconds)
		return
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null:
		await loop.create_timer(seconds).timeout
	else:
		OS.delay_msec(int(seconds * 1000.0))
