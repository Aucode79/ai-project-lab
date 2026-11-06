extends SceneTree

## 代做与接管测试（docs/10-契约/交互方案.md §六 / docs/10-契约/mini-codex.md §四）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game -s res://tests/agent_demo/run_agent_demo_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准）：
##  1  代做全流程（mock 桥）：收到 [world.place×2, world.connect, world.set_param(task_text),
##     world.run, world.read] 七步序列（含报身份）、set_param/connect/read 动态绑定 place 响应的
##     实体号（connect 同 stage_install：identity_out -> task_in）、connect 写计价 20、
##     每步停留 slow_step_seconds（注入时钟假推进，不真 sleep）、was_judged=false
##  2  慢速可视：step_presented 每步一发、次数=步数、载荷带 index/total/已求值 args
##  3  随时接管：第 3 步（connect）后 take_over → remaining 非空（set_param+run+read
##     四步）、不再有后续请求、take_over 返回的交接与 run 返回一致
##  4  request_pause 下一步前生效、resume 后继续：序列照常走完，暂停期只多一次轮询
##  5  不参与判定（注入内核实测）：学员 task run 判定通过后经真桥代做——
##     代做落 explore run、学员冻结文件与重推判定不变、与无代做对照一致
##  6  任务牌两键：「我来」/「让它做」3D 按钮块在位、mode_selected(me/agent)
##     两信号、非法模式拒绝；四态显示零回归
##  7  slow_step_seconds 参数化：0.6→总停留 4.2s，0.1→0.7s（总时长变短）
##  8  真桥冒烟：本地 McpBridgeCore（注入内核，手动 listen）+ BridgeClient
##     真 TCP——完整 7 步（含 connect 与报身份）、id/step 回带、ops 计价 写20×5/演20/读1、
##     idle 自动开 explore
##  9  recording 护栏（mini-codex §四(c)）：学员 task run 进行中（recorder recording
##     态）run_agent_demo 被拒（code=student_run_in_progress、message 带指引）、桥零请求、
##     学员 run 步数不变；end_run 冻结后再调成功
##
## mock 桥记下每条发出的请求不真连 TCP（1/2/3/4/7）；真桥路径（5/8）是
## run_mcp_tests 同款做法：自建 McpBridgeCore 手动 listen 后用 BridgeClient 连。

const DemoDriverScript := preload("res://scripts/agent_demo/demo_driver.gd")
const BridgeClientScript := preload("res://scripts/agent_demo/bridge_client.gd")
const TaskBoardScene := preload("res://scenes/levels/l1/components/task_board.tscn")
const TaskBoardScript := preload("res://scenes/levels/l1/components/task_board.gd")
const L1FlowScript := preload("res://scripts/levels/l1/l1_flow.gd")

var _passed := 0
var _failed := 0
var _garbage: Array[Node] = []


func _initialize() -> void:
	_run_all.call_deferred()


func _run_all() -> void:
	await _t01_demo_full_flow_mock()
	await _t02_step_presented_per_step()
	await _t03_take_over()
	await _t04_pause_resume()
	await _t05_judgment_invariant_real_kernel()
	_t06_mode_selected_signals()
	await _t07_slow_step_parameterized()
	await _t08_real_bridge_smoke()
	await _t09_recording_guard()
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


func _cleanup() -> void:
	for n in _garbage:
		if n != null and is_instance_valid(n):
			n.free()
	_garbage.clear()


## 注入式独立内核 + 挂好 tools 的 L1Flow（不进场景树，headless 直驱）。
func _new_flow_with_kernel() -> Dictionary:
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	var tools := WorldToolsCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	_garbage.append_array([st, rc, cm, tools])
	var flow: Node = L1FlowScript.new()
	flow.tools = tools
	_garbage.append(flow)
	return {"flow": flow, "tools": tools, "recorder": rc}


## 步记录 runId 按秒取整（r{unix秒}-{各自序号}）：同一秒内两个内核都从 001
## 起编号会撞 e49 文件名，end_run 拒绝覆盖、第二个 run 冻结失败。T5 要连跑两套
## 内核，各自 drive_full 前先等秒界，保证 begin_run 落在不同秒。
func _await_fresh_second() -> void:
	var t0 := int(Time.get_unix_time_from_system())
	while int(Time.get_unix_time_from_system()) == t0:
		await create_timer(0.02).timeout


## mock 桥 + 假时钟 + 驱动器一套（flow 为全新内核，任务牌未装 → 完整七步序列）。
func _mock_demo(task_text := L1FlowScript.TASK_TEXT_1, slow := 0.6) -> Dictionary:
	var bag := _new_flow_with_kernel()
	var mock := MockBridge.new()
	var fake := FakeClock.new()
	var driver := DemoDriverScript.new()
	driver.bridge = mock
	driver.clock = Callable(fake, "tick")
	driver.slow_step_seconds = slow
	return {"bag": bag, "mock": mock, "fake": fake, "driver": driver,
		"steps": bag.flow.demo_steps(task_text)}


## 自建真桥（注入内核）+ BridgeClient，连好待用。失败时返回 {"ok": false}。
func _real_bridge(tools: WorldToolsCore) -> Dictionary:
	var bridge := McpBridgeCore.new()
	bridge.own_tools = tools
	_garbage.append(bridge)
	var listen_ret: Dictionary = bridge.listen(McpBridgeCore.DEFAULT_PORT)
	if not bool(listen_ret.get("ok", false)):
		return {"ok": false, "detail": listen_ret}
	var client = BridgeClientScript.new()
	client.pump = Callable(bridge, "pump") # 自建桥不在树上，要手动泵
	var conn: Dictionary = client.connect_to_bridge("127.0.0.1", bridge.port)
	if not bool(conn.get("ok", false)):
		bridge.stop()
		return {"ok": false, "detail": conn}
	return {"ok": true, "bridge": bridge, "client": client}


## mock 桥：记下每条请求（含 ops 计价），不真连 TCP；place 按资产计数发实体号、
## place/connect 都按写 20 计价（与内核同构；演 20 只在真桥 T8 断言）。
class MockBridge:
	extends RefCounted
	var requests: Array = []
	var _counts := {}

	func call_tool(tool: String, args: Dictionary) -> Dictionary:
		var step_no := requests.size()
		var write := tool == "world.place" or tool == "world.connect"
		var ops := 20 if write else 1
		var result: Dictionary = {"mock": true}
		if tool == "world.place":
			var asset := str(args.get("assetId", ""))
			var n := int(_counts.get(asset, 0)) + 1
			_counts[asset] = n
			result = {"entityId": "%s#%d" % [asset, n], "bound": true}
		requests.append({"tool": tool, "args": args.duplicate(true), "ops": ops})
		return {"id": step_no + 1, "ok": true, "result": result,
			"step": step_no, "ops": ops,
			"usage": {"ops": ops, "mode": "write" if write else "read", "priced_by": "godot"}}


## 假时钟：累计等待不真 sleep；on_call(sec, 第几次) 可注入暂停/接管动作。
class FakeClock:
	extends RefCounted
	var waits: Array = []
	var total := 0.0
	var on_call: Callable = Callable()

	func tick(seconds: float) -> void:
		waits.append(seconds)
		total += seconds
		if on_call.is_valid():
			on_call.call(seconds, waits.size())


# ---------- 测试 ----------

func _t01_demo_full_flow_mock() -> void:
	var kit := _mock_demo()
	var result: Dictionary = await kit.driver.run(kit.steps)
	var seq: Array = []
	for r in kit.mock.requests:
		seq.append(str(r["tool"]))
	var ok := seq == ["world.place", "world.place", "world.connect", "world.set_param", "world.set_param", "world.run", "world.read"]
	var conn_args: Dictionary = kit.mock.requests[2]["args"] if kit.mock.requests.size() > 2 else {}
	ok = ok and str(conn_args.get("from", "")) == "conc_nameplate#1:identity_out" # 连线同 stage_install：identity_out -> task_in
	ok = ok and str(conn_args.get("to", "")) == "conc_task_board#1:task_in"
	ok = ok and int(kit.mock.requests[2].get("ops", -1)) == 20 # connect 写计价 20
	var set_args: Dictionary = kit.mock.requests[3]["args"] if kit.mock.requests.size() > 3 else {}
	ok = ok and str(set_args.get("key", "")) == "task_text"
	ok = ok and str(set_args.get("value", "")) == L1FlowScript.TASK_TEXT_1
	ok = ok and str(set_args.get("entityId", "")) == "conc_task_board#1" # 动态绑定第 1 步 place 的实体号
	var ident_args: Dictionary = kit.mock.requests[4]["args"] if kit.mock.requests.size() > 4 else {}
	ok = ok and str(ident_args.get("key", "")) == "@identity_out" and float(ident_args.get("value", 0.0)) == 1.0
	ok = ok and str(ident_args.get("entityId", "")) == "conc_nameplate#1"
	ok = ok and str((kit.mock.requests[6]["args"] as Dictionary).get("ref", "")) == "conc_task_board#1:task_in"
	ok = ok and bool(result.get("ok", false)) and bool(result.get("completed", false))
	ok = ok and not bool(result.get("taken_over", true))
	ok = ok and result.get("was_judged", true) == false
	ok = ok and int(result.get("completed_steps", -1)) == 7
	ok = ok and (result.get("remaining_steps", [1]) as Array).is_empty()
	ok = ok and (result.get("responses", []) as Array).size() == 7
	ok = ok and kit.fake.waits.size() == 7 and is_equal_approx(kit.fake.total, 4.2) # 7 步 × 0.6
	_check(ok, "T1 代做全流程（mock 桥）：序列 place×2→connect(identity_out->task_in)→set_param(task_text)→set_param(@identity_out=1)→run→read、实体号动态绑定、connect 写计价 20、每步停留 0.6s（假时钟）、was_judged=false")


func _t02_step_presented_per_step() -> void:
	var kit := _mock_demo()
	var seen: Array = []
	kit.driver.step_presented.connect(func(index, total, tool, args, caption):
		seen.append({"index": index, "total": total, "tool": tool, "args": args, "caption": caption}))
	await kit.driver.run(kit.steps)
	var want := ["world.place", "world.place", "world.connect", "world.set_param", "world.set_param", "world.run", "world.read"]
	var ok := seen.size() == 7 # 次数=步数
	for i in range(seen.size() if seen.size() == 7 else 0):
		ok = ok and int(seen[i]["index"]) == i and int(seen[i]["total"]) == 7
		ok = ok and str(seen[i]["tool"]) == want[i]
		ok = ok and str(seen[i]["caption"]) != ""
	ok = ok and seen.size() == 7 and str((seen[2]["args"] as Dictionary).get("from", "")) == "conc_nameplate#1:identity_out" # args 已求值
	ok = ok and str((seen[2]["args"] as Dictionary).get("to", "")) == "conc_task_board#1:task_in"
	ok = ok and str((seen[3]["args"] as Dictionary).get("entityId", "")) == "conc_task_board#1"
	ok = ok and str((seen[3]["args"] as Dictionary).get("key", "")) == "task_text"
	_check(ok, "T2 慢速可视：step_presented 每步一发（次数=步数=7），载荷带 index/total/tool/已求值 args/中文说明")


func _t03_take_over() -> void:
	var kit := _mock_demo()
	var presented: Array = []
	kit.driver.step_presented.connect(func(index, total, tool, args, caption): presented.append(index))
	# GDScript lambda 按值捕获局部变量，交接结果经一元素数组带出
	var handoff_box := [{}]
	kit.fake.on_call = func(sec, n):
		if n == 3: # 第 3 步（connect）的停留期间按停
			handoff_box[0] = kit.driver.take_over()
	var result: Dictionary = await kit.driver.run(kit.steps)
	var ok := bool(kit.mock.requests.size() == 3) # 不再有后续请求
	ok = ok and bool(result.get("taken_over", false)) and not bool(result.get("completed", true))
	ok = ok and int(result.get("completed_steps", -1)) == 3
	var remaining: Array = result.get("remaining_steps", [])
	ok = ok and remaining.size() == 4
	ok = ok and remaining.size() == 4 and str(remaining[0]["tool"]) == "world.set_param" \
		and str(remaining[1]["tool"]) == "world.set_param" and str(remaining[2]["tool"]) == "world.run" and str(remaining[3]["tool"]) == "world.read"
	ok = ok and presented == [0, 1, 2]
	var handoff: Dictionary = handoff_box[0]
	ok = ok and int(handoff.get("completed_steps", -1)) == 3
	ok = ok and (handoff.get("remaining_steps", []) as Array).size() == 4
	_check(ok, "T3 随时接管：第 3 步（connect）后 take_over → remaining 非空（set_param×2+run+read 四步待续）、无后续请求、交接信息与 run 结果一致")


func _t04_pause_resume() -> void:
	var kit := _mock_demo()
	kit.fake.on_call = func(sec, n):
		if n == 2:
			kit.driver.request_pause() # 第 2 步停留后请求暂停
		elif n == 3:
			kit.driver.resume() # 暂停轮询一拍后继续
	var result: Dictionary = await kit.driver.run(kit.steps)
	var seq: Array = []
	for r in kit.mock.requests:
		seq.append(str(r["tool"]))
	var ok := bool(result.get("completed", false)) and seq.size() == 7
	ok = ok and seq[2] == "world.connect" # 暂停没吃掉任何一步，序列照序走完
	var expect := [0.6, 0.6, DemoDriverScript.PAUSE_POLL_SECONDS, 0.6, 0.6, 0.6, 0.6, 0.6]
	ok = ok and kit.fake.waits.size() == expect.size()
	if kit.fake.waits.size() == expect.size():
		for i in expect.size():
			ok = ok and is_equal_approx(float(kit.fake.waits[i]), float(expect[i]))
	_check(ok, "T4 request_pause 下一步前生效、resume 后继续：7 步照序完成，暂停期只多一次 0.05s 轮询等待")


func _t05_judgment_invariant_real_kernel() -> void:
	# 学员先跑完整流程并判定（注入内核，headless 真跑，非 mock）
	var bag := _new_flow_with_kernel()
	await _await_fresh_second()
	var verdict_before: Dictionary = await bag.flow.drive_full()
	var ok := bool(verdict_before.get("pass", false))
	var frozen_path := str(verdict_before.get("path", ""))
	var frozen_before := FileAccess.get_file_as_string(frozen_path)
	ok = ok and frozen_before != ""
	# 代做：真桥（注入同一内核）+ BridgeClient 真 TCP；任务牌已装 → 代做只走任务段
	var rig := _real_bridge(bag.tools)
	ok = ok and bool(rig.get("ok", false))
	if ok:
		var demo: Dictionary = await bag.flow.run_agent_demo(rig.client, L1FlowScript.TASK_TEXT_2, 0.02)
		ok = ok and bool(demo.get("ok", false)) and bool(demo.get("completed", false))
		ok = ok and demo.get("was_judged", true) == false
		# 代做落进桥自动开的 explore run，绝不是学员的 task run
		var rc: StepRecorderCore = bag.recorder
		ok = ok and rc.state_name() == "recording"
		var run_doc: Dictionary = rc.get_doc()["run"]
		ok = ok and str(run_doc.get("kind", "")) == "explore"
		ok = ok and str(run_doc.get("runId", "")) != str(verdict_before.get("runId", ""))
		var demo_tools: Array = []
		for s in rc.get_doc().get("steps", []):
			demo_tools.append(str((s as Dictionary).get("action", {}).get("tool", "")))
		ok = ok and demo_tools == ["world.set_param", "world.set_param", "world.run", "world.read"]
		# 判定不变：学员 task run 的冻结文件一字未改，从它重推的判定与代做前一致
		ok = ok and FileAccess.get_file_as_string(frozen_path) == frozen_before
		var reparsed: Variant = JSON.parse_string(frozen_before)
		if reparsed is Dictionary:
			var traj: Array = TaskBoardScript.state_trajectory(
				(reparsed as Dictionary).get("steps", []), str(bag.flow.board_eid))
			ok = ok and traj.has(TaskBoardScript.STATE_DONE)
			ok = ok and str(traj[traj.size() - 1]) == TaskBoardScript.STATE_DONE
		else:
			ok = false
		rig.client.close()
		rig.bridge.stop()
	# 对照：另一套无代做内核跑同样的学员流程——task run 步数与判定一致（代做没往 task run 塞步）
	var ctrl := _new_flow_with_kernel()
	await _await_fresh_second()
	var verdict_ctrl: Dictionary = await ctrl.flow.drive_full()
	ok = ok and bool(verdict_ctrl.get("pass", false))
	ok = ok and int(verdict_ctrl.get("steps", -1)) == int(verdict_before.get("steps", -2))
	ok = ok and str(verdict_ctrl.get("firstText", "")) == str(verdict_before.get("firstText", ""))
	ok = ok and str(verdict_ctrl.get("secondText", "")) == str(verdict_before.get("secondText", ""))
	_check(ok, "T5 不参与判定（注入内核实测）：代做经真桥落 explore run、学员 task run 冻结文件与重推判定不变、与无代做对照组一致")


func _t06_mode_selected_signals() -> void:
	var tb := TaskBoardScene.instantiate()
	root.add_child(tb)
	var got: Array = []
	tb.mode_selected.connect(func(mode): got.append(str(mode)))
	var ok := tb.has_node("MeButton") and tb.has_node("AgentButton")
	ok = ok and tb.has_node("MeButton/Caption") and str(tb.get_node("MeButton/Caption").text) == "我来"
	ok = ok and tb.has_node("AgentButton/Caption") and str(tb.get_node("AgentButton/Caption").text) == "让它做"
	ok = ok and tb.get_mode_button(TaskBoardScript.MODE_ME) != null
	ok = ok and str(tb.get_mode_button(TaskBoardScript.MODE_AGENT).get_meta("mode", "")) == "agent"
	ok = ok and bool(tb.press_mode_button(TaskBoardScript.MODE_ME)) and got == ["me"]
	ok = ok and bool(tb.press_mode_button(TaskBoardScript.MODE_AGENT)) and got == ["me", "agent"]
	ok = ok and not tb.press_mode_button("bogus") and got.size() == 2 # 非法模式拒绝
	# 四态零回归：既有显示路径不受两键影响
	tb.set_task_text("四态回归检查")
	tb.set_state_visual(TaskBoardScript.STATE_DONE)
	ok = ok and tb.get_task_text() == "四态回归检查"
	ok = ok and str(tb.get_node("StateCaption").text) == "完成"
	tb.set_state_visual(TaskBoardScript.STATE_ERROR)
	ok = ok and str(tb.get_node("StateCaption").text) == "出错"
	tb.free()
	_check(ok, "T6 任务牌两键：「我来」/「让它做」3D 按钮块在位（带 caption 与 mode 元数据）、mode_selected(me/agent) 两信号、非法模式拒绝、四态显示零回归")


func _t07_slow_step_parameterized() -> void:
	var slow_kit := _mock_demo(L1FlowScript.TASK_TEXT_1, 0.6)
	await slow_kit.driver.run(slow_kit.steps)
	var fast_kit := _mock_demo(L1FlowScript.TASK_TEXT_1, 0.1)
	await fast_kit.driver.run(fast_kit.steps)
	var ok := bool(slow_kit.fake.waits.size() == 7 and fast_kit.fake.waits.size() == 7)
	ok = ok and is_equal_approx(slow_kit.fake.total, 4.2) and is_equal_approx(fast_kit.fake.total, 0.7)
	ok = ok and fast_kit.fake.total < slow_kit.fake.total # 总时长变短
	_check(ok, "T7 slow_step_seconds 参数化生效：0.6→总停留 4.2s、0.1→0.7s（同 7 步，总时长随之变短）")


func _t08_real_bridge_smoke() -> void:
	var bag := _new_flow_with_kernel()
	bag.flow.setup_world() # 只建世界（资产注册），任务牌未装 → 代做走完整七步
	var rig := _real_bridge(bag.tools)
	var ok := bool(rig.get("ok", false))
	if ok:
		var demo: Dictionary = await bag.flow.run_agent_demo(rig.client, L1FlowScript.TASK_TEXT_1, 0.02)
		ok = ok and bool(demo.get("completed", false)) and bool(demo.get("ok", false))
		ok = ok and int(demo.get("completed_steps", -1)) == 7
		# idle 状态下首条请求自动开 explore run（代做运行不参与判定）
		var rc: StepRecorderCore = bag.recorder
		ok = ok and rc.state_name() == "recording"
		ok = ok and str((rc.get_doc()["run"] as Dictionary).get("kind", "")) == "explore"
		# 协议级：id 回带、step 落账、ops 计价 写20×5/演20/读1、priced_by=godot
		var responses: Array = demo.get("responses", [])
		ok = ok and responses.size() == 7
		var ops_seq: Array = []
		for i in range(responses.size() if responses.size() == 7 else 0):
			var resp: Dictionary = responses[i]
			ok = ok and bool(resp.get("ok", false)) and int(resp.get("id", -1)) == i + 1
			ok = ok and int(resp.get("step", -1)) == i # 桥端步号从 0 连续递增
			ok = ok and str((resp.get("usage", {}) as Dictionary).get("priced_by", "")) == "godot"
			ops_seq.append(int(resp.get("ops", -1)))
		ok = ok and ops_seq == [20, 20, 20, 20, 20, 20, 1] # place×2+connect+set_param×2 写20、run 演20、read 读1
		# 世界真的动了：代做的任务牌实体在状态层里，连线也真的建上了
		ok = ok and bag.tools.state().has_entity("conc_task_board#1")
		var board_ins: Array = bag.tools.state().edges_for("conc_task_board#1").get("in", [])
		ok = ok and board_ins.size() == 1 and str((board_ins[0] as Dictionary).get("to", "")) == "conc_task_board#1:task_in"
		# 报身份步在真桥路径没静默失效：read 回 1.0，run 后 task_in 真到 1.0（锁进仓库，防回归）
		var last_resp: Dictionary = responses[responses.size() - 1] if responses.size() == 7 else {}
		ok = ok and float((last_resp.get("result", {}) as Dictionary).get("value", -1.0)) == 1.0
		var snap: Dictionary = bag.tools.state().logical_snapshot()
		var snap_board: Dictionary = (snap.get("entities", {}) as Dictionary).get("conc_task_board#1", {})
		var snap_ports: Dictionary = snap_board.get("ports", {})
		ok = ok and float((snap_ports.get("task_in", {}) as Dictionary).get("value", 0.0)) == 1.0
		rig.client.close()
		rig.bridge.stop()
	_check(ok, "T8 真桥冒烟：本地 McpBridgeCore 手动 listen + BridgeClient 真 TCP，run_agent_demo 完整 7 步（含 connect 与报身份）、id/step 回带、ops 计价 写20×4/演20/读1、idle 自动开 explore run、世界真变了（连线已建）")


func _t09_recording_guard() -> void:
	await _await_fresh_second() # 冻结文件按秒编号，避开与前序内核的 run 撞名
	var bag := _new_flow_with_kernel()
	bag.flow.setup_world()
	bag.flow.begin() # 学员 task run 开跑：kind=task，recorder 进 recording 态
	bag.flow.stage_video() # 学员已走过一两步（幕布亮起），run 里不是空的
	var rc: StepRecorderCore = bag.recorder
	var steps_before := rc.get_steps().size()
	var mock := MockBridge.new()
	# 学员 task run 进行中「让它做」→ 入口直接拒绝（mini-codex §四(c)）
	var rejected: Dictionary = await bag.flow.run_agent_demo(mock, L1FlowScript.TASK_TEXT_1, 0.02)
	var ok := not bool(rejected.get("ok", true))
	ok = ok and str(rejected.get("code", "")) == "student_run_in_progress"
	ok = ok and str(rejected.get("message", "")).contains("finish_run") # message 带指引
	ok = ok and rejected.get("was_judged", true) == false
	ok = ok and mock.requests.is_empty() # 一条请求都没发出去
	ok = ok and rc.state_name() == "recording" and rc.get_steps().size() == steps_before # 学员 run 一步未动
	# end_run 冻结学员 run 后再「让它做」→ 正常跑完（fresh 七步，connect 与报身份在内）
	bag.flow.finish_run()
	ok = ok and rc.state_name() == "frozen"
	var demo: Dictionary = await bag.flow.run_agent_demo(mock, L1FlowScript.TASK_TEXT_1, 0.02)
	ok = ok and bool(demo.get("ok", false)) and bool(demo.get("completed", false))
	ok = ok and int(demo.get("completed_steps", -1)) == 7
	ok = ok and demo.get("was_judged", true) == false
	var seq: Array = []
	for r in mock.requests:
		seq.append(str(r["tool"]))
	ok = ok and seq[2] == "world.connect" and seq.size() == 7
	_check(ok, "T9 recording 护栏（§四(c)）：学员 task run 进行中 run_agent_demo 被拒（code=student_run_in_progress、message 带指引）、桥零请求、学员 run 步数不变；end_run 冻结后再调成功（7 步含 connect 与报身份）")
	# 本测试冻结的 e49 文件即时清掉：它是套件最后一步，紧随其后的 L1 回归若在
	# 同一秒 begin_run 会拿到同名 runId（两个内核各自从 001 编号），end_run
	# 拒绝覆盖 → L1 的 T3 连环失败（护栏测试不该给别的套件埋文件名雷）。
	DirAccess.remove_absolute(rc.out_path())
