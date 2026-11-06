extends "res://scripts/levels/flow_base.gd"

## L2 流程驱动器（spec §9.1.1 第 2 关）："它怎么读、怎么写"。
## 把一关的闭环 看视频(占位) → 装组件 → 跑一遍 → 改一个参数 → 评分 → 过关检查
## 在 headless 可判定、窗口模式可看两种方式下跑通（照抄 l1_flow 的五 stage 模式）。
##
## 本关的三件组件：文件柜（一排格子每格一个文件挂三态灯）、扫描器（读的载体）、
## 机械臂（写的载体）。硬规则（mini-codex §2.2 / §2.3）：
##   * 作用域（哪格可读/可写/上锁）来自世界初始化声明（setup_world），灯只是许可；
##   * **读的动作只经扫描器、写的动作只经机械臂**——fs.read 步的 carrier=scanner、
##     fs.write 步的 carrier=arm，工具头切换记一步 world.switch_tool_head；
##   * 读不留物（柜格淡痕按参数化时长淡出）、写留物（落点一格高度标记常驻，
##     新增/修改颜色区分）；
##   * 组件四态灯由步记录派生（派生函数在各组件脚本里），本类不另做状态机。
##
## 分工（与 l1_flow 相同）：本脚本只做"逻辑 + 步记录"；可视（view，可空）指向
## l2_scene.gd 的场景实例，装组件、小车移动、痕迹与灯色都是纯显示。

const CabinetScript := preload("res://scenes/levels/l2/components/file_cabinet.gd")

## 「另一实例」评分入口（scoring/ 包，与执行侧零共享）。显式 preload 不走
## 全局类名缓存——headless -s 模式不重扫 class cache（评分侧测试同款做法）。
const LevelAssets := preload("res://scripts/levels/level_assets.gd")
const ScannerScript := preload("res://scenes/levels/l2/components/scanner.gd")
const ArmScript := preload("res://scenes/levels/l2/components/arm.gd")

const ASSET_CABINET := "l2_file_cabinet"
const ASSET_SCANNER := "l2_scanner"
const ASSET_ARM := "l2_arm"
const ASSET_CODEX := LevelAssets.ASSET_CODEX
const ASSET_SCREEN := LevelAssets.ASSET_SCREEN
const EPISODE := 51
const SEED_L2 := 20260915

const TASK_TEXT_1 := "读 report.txt，数出'错误'出现的次数，把结果写进 out.txt 格"
const TASK_TEXT_2 := "改扫 notes.md，数出'警告'出现的次数，把结果写进 config.yaml 格（替换旧内容）"

## 两次任务的执行画像：读哪个文件（经扫描器）、顺带试一次哪格上锁格、写哪个格（经机械臂）。
const RUN1 := {"read": "report.txt", "write": "out.txt", "keyword": "错误", "try_locked": "secret.txt"}
const RUN2 := {"read": "notes.md", "write": "config.yaml", "keyword": "警告", "try_locked": ""}

## L2 的三类 action（12 工具面之外的文件工具与换头步，与 kernel 步走同一条记录通道）。
const TOOL_FS_READ := "fs.read"
const TOOL_FS_WRITE := "fs.write"
const TOOL_SWITCH_HEAD := "world.switch_tool_head"
const CARRIER_SCANNER := "scanner"
const CARRIER_ARM := "arm"

## 柜格作用域声明（mini-codex §2.2：作用域来自世界初始化声明，不是文档约定）。
## permission：write=可读可写（绿且门开）、read=只读（绿）、lock=禁读（红锁）。
const CELL_FILES := [
	{"name": "report.txt", "permission": "write", "content": "第 1 行 模块A 启动正常\n第 2 行 模块B 报告 错误：超时\n第 3 行 模块B 报告 错误：重试后成功\n第 4 行 模块C 数据校验 错误：校验和不匹配\n第 5 行 模块C 自检通过"},
	{"name": "data.csv", "permission": "read", "content": "id,score\n1,96\n2,88\n3,91"},
	{"name": "notes.md", "permission": "read", "content": "# 复盘笔记\n- 上午一次 警告：磁盘余量低\n- 下午一次 警告：响应偏慢\n- 无错误"},
	{"name": "secret.txt", "permission": "lock", "content": "（内部资料，上锁）"},
	{"name": "out.txt", "permission": "write", "content": ""},
	{"name": "config.yaml", "permission": "write", "content": "theme: light\nversion: 1"},
]

## mini-codex §2.3：代做慢速可视，默认 0.6 秒/步（换头/读/写各停一拍）。
## 只在可视模式（view 非空）生效；测试与判定可调小提速。
var slow_step_seconds := 0.6

## 注入优先；为空时在 _ready 解析 autoload（窗口模式），再兜底自建。
## 可视场景（l2_scene.gd），可空。
var cabinet_eid := ""
var scanner_eid := ""
var arm_eid := ""
var codex_eid := ""
var screen_eid := ""

var _current_head := ""
func _init() -> void:
	episode = EPISODE
	default_seed = SEED_L2
# ---------- 世界初始化（工具序列之外，spec §4.5） ----------

## 资产注册（内存注册，不改 assets.yaml）+ 作用域声明 + codex 本体就位。
func setup_world() -> Dictionary:
	if _world_set_up:
		return {"ok": true, "entityId": codex_eid}
	var st := tools.state()
	st.register_asset(ASSET_CABINET, WorldStateCore.KIND_PARAMETRIC,
		{"files": CELL_FILES}, [])
	st.register_asset(ASSET_SCANNER, WorldStateCore.KIND_PARAMETRIC,
		{"target_file": "report.txt", "scan_range": 3.0, "fade_seconds": 3.0}, [
			{"id": "scan_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_ARM, WorldStateCore.KIND_PARAMETRIC,
		{"step_seconds": 0.6}, [
			{"id": "grip_busy", "kind": "BOOL", "dir": "out", "value": false},
		])
	st.register_asset(ASSET_SCREEN, WorldStateCore.KIND_EXHIBIT,
		{"content": "L2 · E51 占位视频"}, [])
	st.register_asset(ASSET_CODEX, WorldStateCore.KIND_PARAMETRIC,
		{"display_name": "mini codex"}, [
			{"id": "touched", "kind": "BOOL", "dir": "in"},
		])
	# codex 本体是世界初始化声明（不是学员的操作步，不进步记录）
	var placed: Dictionary = st.place(ASSET_CODEX, [2, 0, 4])
	codex_eid = str(placed.get("entityId", ""))
	_world_set_up = true
	return placed


# ---------- 五个阶段 ----------

## 阶段一：幕布亮起，播占位内容（步记录 phase=video）。
func stage_video() -> Dictionary:
	var place: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_SCREEN, "pos": [4, 0, -2]},
		{"actor": "level", "caption": "幕布方块就位（player_ 展示方块，占位内容）"})
	if bool(place.get("ok", false)):
		screen_eid = str(place["result"]["entityId"])
	if view != null:
		view.set_screen_title("L2 · E51 占位视频")
		view.get_player_screen().play()
	_record_level_step("video",
		{"tool": "level.stage", "args": {"stage": "video", "episode": EPISODE, "content": "L2 · E51 占位视频"}},
		"幕布亮起：L2 · E51 占位视频（占位内容，不引真视频）")
	return place


## 阶段二：装上三件组件（world.place，绑定表就位：每个资产首个实例自动绑定）。
func stage_install() -> Dictionary:
	var c: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_CABINET, "pos": [-2, 0, -1]},
		{"actor": "player", "caption": "装上文件柜（一排 6 格，每格一个文件挂三态灯）"})
	var s: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_SCANNER, "pos": [0, 0, -3]},
		{"actor": "player", "caption": "装上扫描器（一切读取的载体）"})
	var a: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_ARM, "pos": [2, 0, -3]},
		{"actor": "player", "caption": "装上机械臂（一切修改的载体）"})
	cabinet_eid = str(c.get("result", {}).get("entityId", ""))
	scanner_eid = str(s.get("result", {}).get("entityId", ""))
	arm_eid = str(a.get("result", {}).get("entityId", ""))
	if view != null:
		view.install_file_cabinet().setup_files(_cabinet_files())
		view.install_scanner()
		view.install_arm()
		_refresh_component_states()
	var scope := {}
	for entry in _cabinet_files():
		scope[str(entry.get("name", ""))] = str(entry.get("permission", ""))
	_record_level_step("install",
		{"tool": "level.stage", "args": {
			"stage": "install",
			"components": [ASSET_CABINET, ASSET_SCANNER, ASSET_ARM],
			"scope": scope,
		}},
		"三件组件装上：文件柜 + 扫描器 + 机械臂；作用域由初始化声明（report.txt 可写、secret.txt 上锁）")
	return {"cabinet": c, "scanner": s, "arm": a}


## 阶段三：跑一遍任务——扫描器读指定格 → 内容进上下文 → 机械臂把结果写进指定格。
func stage_run() -> Dictionary:
	return await _execute_task(RUN1, TASK_TEXT_1, "run")


## 阶段四：改一个参数（扫描器的目标文件）再跑一遍，看差异。
func stage_tune() -> Dictionary:
	return await _execute_task(RUN2, TASK_TEXT_2, "tune")


## 阶段五：评分——交给「另一实例」ScorerService（scoring/ 包，与执行侧零共享）：
## 输入是冻结前的 run 文档 + 本关 task_goal（goals.gd 纯数据，不从本类取状态）；
## LLM 通道不可用时自动回退规则评分（rule_v1）。五句与 evidence 落进 score 步的
## output（args.dimensions 保持旧形状兼容：[{dim, sentence}×5]）。
func stage_score() -> Dictionary:
	var rc := tools.recorder()
	var verdict: Dictionary = ScorerServiceScript.new().score(rc.get_doc(), ScorerGoalsScript.goal_for("L2"))
	var dims: Array = []
	for s in verdict.get("sentences", []):
		var d: Dictionary = s
		dims.append({"dim": str(d.get("dim", "")), "sentence": str(d.get("text", ""))})
	var ops_total := 0
	for s in rc.get_steps():
		ops_total += int((s as Dictionary).get("ops", 0))
	_record_level_step("score",
		{"tool": "level.score", "args": {"stub": false, "dimensions": dims}},
		"五维诊断已出（另一实例评分：%s，五句与证据见本步 output）" % str(verdict.get("scorer", "")),
		{
			"ok": true,
			"sentences": verdict.get("sentences", []),
			"evidence": verdict.get("evidence", {}),
			"scorer": str(verdict.get("scorer", "")),
			"llm": verdict.get("llm", {}),
		})
	return {
		"dimensions": dims,
		"sentences": verdict.get("sentences", []),
		"evidence": verdict.get("evidence", {}),
		"scorer": verdict.get("scorer", ""),
		"llm": verdict.get("llm", {}),
		"ops": ops_total,
	}


## 全流程一条龙：装→跑→改→评→落盘→判定（测试与判定用）。
func drive_full() -> Dictionary:
	setup_world()
	begin()
	await stage_video()
	await stage_install()
	await stage_run()
	await stage_tune()
	stage_score()
	finish_run()
	return check_pass()


# ---------- 任务执行（读经扫描器、写经机械臂） ----------

## 一个任务的完整走法：下任务(set_param target_file) → codex 到扫描器前换头读
## →（顺带试一次上锁格：被拒）→ world.run 在上下文里数关键词 → 到机械臂前
## 换头写进指定格。每步进步记录，phase 用传入的阶段名（run / tune）。
func _execute_task(profile: Dictionary, task_text: String, phase: String) -> Dictionary:
	var out: Dictionary = {}
	var read_path := str(profile.get("read", ""))
	var write_path := str(profile.get("write", ""))
	var keyword := str(profile.get("keyword", ""))

	# 下任务 = 告诉扫描器读哪个文件（kernel world.set_param，写步）
	out["set_target"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": scanner_eid, "key": "target_file", "value": read_path},
		{"actor": "player", "caption": "学员下任务：扫描目标文件 = %s（%s）" % [read_path, task_text]})
	var old_target := str(out["set_target"].get("result", {}).get("oldValue", ""))

	if view != null:
		await view.codex_goto(view.scanner_front_pos())
	out["switch_read"] = await _switch_head(CARRIER_SCANNER, phase)

	out["read"] = await _fs_read(read_path, phase)
	var hits := 0
	if bool(out["read"].get("ok", false)):
		# 数关键词是 codex 的"想"，放在读之后、写之前（world.run 那一步的旁白）
		hits = str(out["read"]["result"]["content"]).count(keyword)

	# 上锁格演示：扫过去没有反应（mini-codex §2.2），被拒也进步记录
	if str(profile.get("try_locked", "")) != "":
		out["read_locked"] = await _fs_read(str(profile["try_locked"]), phase)

	out["count"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "codex 在上下文里数'%s'：%d 处" % [keyword, hits]})

	if view != null:
		await view.codex_goto(view.arm_front_pos())
	out["switch_write"] = await _switch_head(CARRIER_ARM, phase)

	out["write"] = await _fs_write(write_path, "%s x%d" % [keyword, hits], phase)

	_record_level_step(phase,
		{"tool": "level.stage", "args": {
			"stage": phase,
			"taskText": task_text,
			"readTarget": read_path,
			"writeTarget": write_path,
			"oldTarget": old_target,
			"newTarget": read_path,
		}},
		"任务走完：读经扫描器、写经机械臂（%s → %s，结果落进 %s 格）" % [read_path, keyword, write_path])
	if view != null:
		_refresh_component_states()
	return out


## 工具头切换（mini-codex §2.3 开放问题 5：换头算一步——学员能看出它在读还是写）。
## phase 跟所在任务段走（run / tune），进步记录便于按段复盘。
func _switch_head(head_name: String, phase := "run") -> Dictionary:
	var head_eid := scanner_eid if head_name == CARRIER_SCANNER else arm_eid
	var t0 := Time.get_ticks_usec()
	var output := {"ok": true, "result": {"to": head_name, "carrierEntityId": head_eid}}
	var i := tools.recorder().record_step({
		"t": tools.state().world_t(),
		"phase": phase,
		"actor": "codex",
		"input": {},
		"action": {"tool": TOOL_SWITCH_HEAD, "args": {"to": head_name, "entityId": head_eid}},
		"output": output.duplicate(true),
		"tokens": 0,
		"ops": 0,
		"costMs": (Time.get_ticks_usec() - t0) / 1000.0,
		"world": _world_digest([]),
		"caption": "codex 换工具头：%s（一切%s的载体）" % [
			"扫描器" if head_name == CARRIER_SCANNER else "机械臂",
			"读取" if head_name == CARRIER_SCANNER else "修改"],
	})
	if not bool(output["ok"]):
		tools.recorder().record_failure(i, "tool:" + TOOL_SWITCH_HEAD, "switch_failed", "换头失败")
	_current_head = head_name
	if view != null:
		view.set_tool_head(head_name)
		_refresh_component_states()
		await _slow_pause()
	return output


## 一切读取只经扫描器：fs.read → 查作用域 → 成功把内容读进上下文、
## 柜格留淡痕；上锁格被拒（扫过去没有反应），失败也进步记录、不收费。
func _fs_read(path: String, phase := "run") -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var cell := _cell_of(path)
	var files := _cabinet_files()
	var perm := str((files[cell] as Dictionary).get("permission", "")) if cell >= 0 else ""
	var output := {"ok": false, "error": {"code": "", "message": ""}}
	var marks: Array = []
	var fade := _scanner_fade_seconds()
	if _current_head != CARRIER_SCANNER:
		output["error"] = {"code": "wrong_tool_head",
			"message": "读必须经扫描器（当前工具头：%s）" % ("无" if _current_head == "" else _current_head)}
	elif cell < 0:
		output["error"] = {"code": "unknown_file", "message": "柜里没有这个文件：%s" % path}
	elif perm == CabinetScript.PERM_LOCK:
		output["error"] = {"code": "locked", "message": "上锁格，扫描器扫过去没有反应：%s" % path}
	else:
		var content := str((files[cell] as Dictionary).get("content", ""))
		output = {"ok": true, "result": {
			"path": path, "cell": cell, "content": content, "bytes": content.length(),
		}}
		marks = [{"kind": "scan_fade", "cell": cell, "path": path,
			"fadeSeconds": fade, "persist": false}]
	var ops := tools.cost().charge(CostModelCore.MODE_READ) if bool(output["ok"]) else tools.cost().charge_failed()
	var i := _record_op_step(
		{"tool": TOOL_FS_READ,
			"args": {"entityId": cabinet_eid, "path": path, "cell": maxi(cell, 0)},
			"carrier": CARRIER_SCANNER, "carrierEntityId": scanner_eid},
		output, ops, t0, marks,
		"扫描器扫过柜格 %d（%s）：%s" % [maxi(cell, 0), path,
			"命中内容进入上下文" if bool(output["ok"]) else "被拒（" + str(output["error"]["code"]) + "）"], phase)
	if not bool(output["ok"]):
		tools.recorder().record_failure(i, "tool:" + TOOL_FS_READ,
			str(output["error"]["code"]), str(output["error"]["message"]))
	if view != null and bool(output["ok"]):
		view.get_file_cabinet().show_scan_mark(cell, fade)
		view.get_scanner().pulse()
		_refresh_component_states()
		await _slow_pause()
	return output


## 一切修改只经机械臂：fs.write → 查作用域（只可写格）→ 空格放入=新增、
## 有旧文=先取旧再放新（修改），落点留一格高度标记（新增/修改颜色区分）。
## 文件内容真被写进世界状态（cabinet 实体的 files 参数），本步即该修改的记录。
func _fs_write(path: String, content: String, phase := "run") -> Dictionary:
	var t0 := Time.get_ticks_usec()
	var cell := _cell_of(path)
	var files := _cabinet_files()
	var perm := str((files[cell] as Dictionary).get("permission", "")) if cell >= 0 else ""
	var output := {"ok": false, "error": {"code": "", "message": ""}}
	var marks: Array = []
	var mode := ""
	var old_content := ""
	if _current_head != CARRIER_ARM:
		output["error"] = {"code": "wrong_tool_head",
			"message": "写必须经机械臂（当前工具头：%s）" % ("无" if _current_head == "" else _current_head)}
	elif cell < 0:
		output["error"] = {"code": "unknown_file", "message": "柜里没有这个文件：%s" % path}
	elif perm != CabinetScript.PERM_WRITE:
		output["error"] = {"code": "not_writable",
			"message": "机械臂被挡回：格 %d（%s）不可写（作用域=%s）" % [cell, path, perm]}
	else:
		old_content = str((files[cell] as Dictionary).get("content", ""))
		mode = "add" if old_content == "" else "modify"
		var new_files := files.duplicate(true)
		(new_files[cell] as Dictionary)["content"] = content
		var mutated: Dictionary = tools.state().set_param(cabinet_eid, "files", new_files)
		if bool(mutated.get("ok", false)):
			output = {"ok": true, "result": {
				"path": path, "cell": cell, "mode": mode,
				"oldContent": old_content, "content": content,
			}}
			marks = [{"kind": "arm_landing", "cell": cell, "path": path, "mode": mode,
				"heightCells": 1, "persist": true}]
		else:
			output = {"ok": false, "error": {"code": str(mutated.get("code", "write_failed")),
				"message": str(mutated.get("message", "写入世界状态失败"))}}
	var ops := tools.cost().charge(CostModelCore.MODE_WRITE) if bool(output["ok"]) else tools.cost().charge_failed()
	var caption := ""
	if bool(output["ok"]):
		caption = "机械臂把结果方块%s柜格 %d（%s）%s" % [
			"放入" if mode == "add" else "替换进", cell, path,
			"" if mode == "add" else "——先取旧再放新，颜色区分"]
	else:
		caption = "机械臂被挡回：%s（%s）" % [str(output["error"]["code"]), path]
	var i := _record_op_step(
		{"tool": TOOL_FS_WRITE,
			"args": {"entityId": cabinet_eid, "path": path, "cell": maxi(cell, 0), "content": content},
			"carrier": CARRIER_ARM, "carrierEntityId": arm_eid},
		output, ops, t0, marks, caption, phase)
	if not bool(output["ok"]):
		tools.recorder().record_failure(i, "tool:" + TOOL_FS_WRITE,
			str(output["error"]["code"]), str(output["error"]["message"]))
	if view != null and bool(output["ok"]):
		view.get_file_cabinet().show_write_mark(cell, mode)
		view.get_arm().pulse()
		_refresh_component_states()
		await _slow_pause()
	return output


# ---------- 过关检查（读冻结的 run JSON，不重跑世界） ----------

## 判定"能看到它读出指定文件、写出指定格子"（spec §9.1.1 L2 行）：
##   1) 存在扫描器对 report.txt 格的成功读取步（carrier=scanner）；
##   2) 存在机械臂对 out.txt 格的成功写入步（carrier=arm）；
##   3) 上锁格（secret.txt）从未被读成功。
func check_pass() -> Dictionary:
	var rc := tools.recorder()
	if rc.state_name() != "frozen":
		return {"pass": false, "reason": "not_frozen", "runId": rc.run_id()}
	var doc: Dictionary = JSON.parse_string(rc.frozen_text())
	var steps: Array = doc.get("steps", [])
	var scanner_read := false
	var arm_write := false
	var locked_read_ok := false
	var read_steps := 0
	var write_steps := 0
	var switch_steps := 0
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		var args: Dictionary = action.get("args", {})
		var ok := bool(step.get("output", {}).get("ok", false))
		if tool == TOOL_FS_READ:
			read_steps += 1
			if ok and str(action.get("carrier", "")) == CARRIER_SCANNER and str(args.get("path", "")) == "report.txt":
				scanner_read = true
			if ok and _declared_permission(str(args.get("path", ""))) == CabinetScript.PERM_LOCK:
				locked_read_ok = true
		elif tool == TOOL_FS_WRITE:
			write_steps += 1
			if ok and str(action.get("carrier", "")) == CARRIER_ARM and str(args.get("path", "")) == "out.txt":
				arm_write = true
		elif tool == TOOL_SWITCH_HEAD:
			switch_steps += 1
	return {
		"pass": scanner_read and arm_write and not locked_read_ok,
		"scannerReadReport": scanner_read,
		"armWroteOut": arm_write,
		"lockedNeverRead": not locked_read_ok,
		"readSteps": read_steps,
		"writeSteps": write_steps,
		"switchSteps": switch_steps,
		"runId": rc.run_id(),
		"path": rc.out_path(),
		"steps": steps.size(),
	}


# ---------- 内部 ----------

## 关卡自身的阶段步与工具头/文件操作步，与 kernel 工具步走同一条记录通道。
## output 参数默认 {"ok": true}；score 步把评分器的五句与证据放进来。
func _record_level_step(phase: String, action: Dictionary, caption: String,
		output := {"ok": true}) -> int:
	var t0 := Time.get_ticks_usec()
	return tools.recorder().record_step({
		"t": tools.state().world_t(),
		"phase": phase,
		"actor": "level",
		"input": {},
		"action": action,
		"output": output,
		"tokens": 0,
		"ops": 0,
		"costMs": (Time.get_ticks_usec() - t0) / 1000.0,
		"world": _world_digest([]),
		"caption": caption,
	})


func _record_op_step(action: Dictionary, output: Dictionary, ops: int, t0: int, marks: Array, caption: String, phase := "run") -> int:
	return tools.recorder().record_step({
		"t": tools.state().world_t(),
		"phase": phase,
		"actor": "codex",
		"input": {},
		"action": action,
		"output": output.duplicate(true),
		"tokens": 0,
		"ops": ops,
		"costMs": (Time.get_ticks_usec() - t0) / 1000.0,
		"world": _world_digest(marks),
		"caption": caption,
	})


## 步记录的 world 摘要 = 内核状态摘要 + 本步产生的痕迹（mini-codex §2.3：
## 扫描淡痕与机械臂落点都进步记录，回看 JSON 即知读了哪些格、写了哪些格）。
func _world_digest(marks: Array) -> Dictionary:
	var d := tools.state().state_digest()
	d["marks"] = marks
	return d


func _cabinet_files() -> Array:
	var ret: Dictionary = tools.state().read_ref(cabinet_eid)
	if bool(ret.get("ok", false)) and ret.get("params", {}) is Dictionary:
		var params: Dictionary = ret["params"]
		if params.get("files", []) is Array:
			return params["files"]
	return []


func _cell_of(path: String) -> int:
	var files := _cabinet_files()
	for i in files.size():
		if str((files[i] as Dictionary).get("name", "")) == path:
			return i
	return -1


## 查世界初始化声明（CELL_FILES 常量）里的作用域——判定只用声明，不碰运行态。
func _declared_permission(path: String) -> String:
	for entry in CELL_FILES:
		if str((entry as Dictionary).get("name", "")) == path:
			return str(entry.get("permission", ""))
	return ""


func _scanner_fade_seconds() -> float:
	var ret: Dictionary = tools.state().read_ref(scanner_eid)
	if bool(ret.get("ok", false)) and ret.get("params", {}) is Dictionary:
		return float((ret["params"] as Dictionary).get("fade_seconds", 3.0))
	return 3.0


## 状态灯永远从步记录重算（mini-codex §2.1：不另做状态机）。
func _refresh_component_states() -> void:
	if view == null:
		return
	var steps := tools.recorder().get_steps()
	var cabinet = view.get_file_cabinet()
	if cabinet != null:
		cabinet.set_state_visual(CabinetScript.derive_state_from_steps(steps, cabinet_eid))
	var scanner = view.get_scanner()
	if scanner != null:
		scanner.set_state_visual(ScannerScript.derive_state_from_steps(steps, scanner_eid))
	var arm = view.get_arm()
	if arm != null:
		arm.set_state_visual(ArmScript.derive_state_from_steps(steps, arm_eid))


## 代做慢速可视：每步停一拍（mini-codex §2.3，默认 0.6 秒）。
func _slow_pause() -> void:
	if view == null or slow_step_seconds <= 0.0:
		return
	await view.get_tree().create_timer(slow_step_seconds).timeout
