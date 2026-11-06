extends "res://scripts/levels/flow_base.gd"

## L4 流程驱动器（照抄 l1_flow.gd 施工模式）：把一关的闭环
##   看视频(占位) → 装组件(三件) → 跑一遍(提示词 A) → 改提示词(B) → 评分 → 过关检查
## 在 headless 可判定、窗口模式可看两种方式下跑通。
##
## 主题（spec §9.1.1 L4）："它怎么想、怎么决定"——装 思考机/计划板/工具带，
## 配 E40 占位视频；过关检查 = **改它的提示，能看到计划随之变化**。
##
## 分工：
##   * 本脚本只做"逻辑 + 步记录"：世界操作全走 WorldTools 的 12 工具面
##     （autoload 或注入内核，注入优先——测试与演示互不污染）；
##   * 思考本身走 mini_brain.gd（确定性规则模拟，不是 LLM；接口 prompt→plan
##     为将来接真模型预留），每次"模型调用"以 actor=codex 的 model.think 步
##     落进同一条步记录通道；
##   * 可视（view，可空）：指向 l4_scene.gd 的场景实例，装组件、小车移动、
##     指针推进、工具发光都是纯显示，headless 无 view 也能跑完整闭环。
##
## 硬规则（mini-codex §2.1）：组件状态由步记录派生（派生函数在各组件 .gd），
## 本类不另做状态机——_refresh_visuals() 每次都从 recorder 的 steps 重算。

const MiniBrain := preload("res://scripts/levels/l4/mini_brain.gd")

## 「另一实例」评分入口（scoring/ 包，与执行侧零共享）。显式 preload 不走
## 全局类名缓存——headless -s 模式不重扫 class cache（评分侧测试同款做法）。
const LevelAssets := preload("res://scripts/levels/level_assets.gd")
const ThinkerScript := preload("res://scenes/levels/l4/components/thinker.gd")
const PlanBoardScript := preload("res://scenes/levels/l4/components/plan_board.gd")
const ToolBeltScript := preload("res://scenes/levels/l4/components/tool_belt.gd")

const ASSET_THINKER := "conc_thinker"
const ASSET_PLAN := "conc_plan_board"
const ASSET_BELT := "conc_tool_belt"
const ASSET_SCREEN := LevelAssets.ASSET_SCREEN
const ASSET_CODEX := LevelAssets.ASSET_CODEX
## 两张纸条：B 比 A 多出 校验步 + 循环步 + 搜工具，token 数也不同。
const PROMPT_A := "数出错误并写出结果"
const PROMPT_B := "先检查格式，再数两遍错误，最后搜索相关词"

const SEED_L4 := 20260914
const EPISODE_L4 := 40

## 注入优先；为空时在 _ready 解析 autoload（窗口模式），再兜底自建。
## 可视场景（l4_scene.gd），可空。
var thinker_eid := ""
var plan_eid := ""
var belt_eid := ""
var screen_eid := ""
var codex_eid := ""

func _init() -> void:
	episode = EPISODE_L4
	default_seed = SEED_L4
# ---------- 世界初始化（工具序列之外，spec §4.5） ----------

func setup_world() -> Dictionary:
	if _world_set_up:
		return {"ok": true, "entityId": codex_eid}
	var st := tools.state()
	st.register_asset(ASSET_THINKER, WorldStateCore.KIND_PARAMETRIC,
		{"prompt": ""}, [
			{"id": "prompt_in", "kind": "ANALOG", "dir": "in"},
			{"id": "tokens_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_PLAN, WorldStateCore.KIND_PARAMETRIC,
		{"plan_text": "[]"}, [
			{"id": "plan_in", "kind": "ANALOG", "dir": "in"},
			{"id": "step_out", "kind": "ANALOG", "dir": "out", "value": 0.0},
		])
	st.register_asset(ASSET_BELT, WorldStateCore.KIND_PARAMETRIC,
		{"selected_tool": ""}, [
			{"id": "tool_in", "kind": "ANALOG", "dir": "in"},
		])
	st.register_asset(ASSET_SCREEN, WorldStateCore.KIND_EXHIBIT,
		{"content": "L4 · E40 占位视频"}, [])
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
		view.get_player_screen().play()
	_record_level_step("video",
		{"tool": "level.stage", "args": {"stage": "video", "episode": EPISODE_L4, "content": "placeholder"}},
		"幕布亮起：L4 · E40 占位视频（占位内容，不引真视频）")
	return place


## 阶段二：装上 思考机 / 计划板 / 工具带 三件（world.place + 连线）。
func stage_install() -> Dictionary:
	var t: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_THINKER, "pos": [-3, 0, -1]},
		{"actor": "player", "caption": "装上思考机（conc_thinker）：一侧进纸条，一侧吐 token"})
	var p: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_PLAN, "pos": [2, 0, -2]},
		{"actor": "player", "caption": "装上计划板（conc_plan_board）：排程板，当前步骤有指针"})
	var b: Dictionary = tools.call_tool(WorldToolsCore.TOOL_PLACE,
		{"assetId": ASSET_BELT, "pos": [0, 0, -4]},
		{"actor": "player", "caption": "装上工具带（conc_tool_belt）：墙上四把工具，被选中那把发光"})
	thinker_eid = str(t.get("result", {}).get("entityId", ""))
	plan_eid = str(p.get("result", {}).get("entityId", ""))
	belt_eid = str(b.get("result", {}).get("entityId", ""))
	var c: Dictionary = tools.call_tool(WorldToolsCore.TOOL_CONNECT,
		{"from": thinker_eid + ":tokens_out", "to": plan_eid + ":plan_in"},
		{"actor": "player", "caption": "连线：思考机 tokens_out -> 计划板 plan_in"})
	if view != null:
		view.install_thinker()
		view.install_plan_board()
		view.install_tool_belt()
		_refresh_visuals()
	_record_level_step("install",
		{"tool": "level.stage", "args": {
			"stage": "install",
			"components": [ASSET_THINKER, ASSET_PLAN, ASSET_BELT],
			"ports": ["prompt_in", "tokens_out", "plan_in", "step_out", "tool_in"],
		}},
		"三件组件装上：思考机 + 计划板 + 工具带，绑定表就位")
	return {"thinker": t, "plan": p, "belt": b, "connect": c}


## 阶段三（run）/ 阶段四（tune）共用一条"思考→计划→执行"管线：
##   ① 学员把提示词喂进思考机（提示词原文进步记录）
##   ② mini_brain 一次"模型调用"：出计划 + 模拟 token 数（model.think 步，tokens=实数）
##   ③ 计划上板（plan_text = 计划 JSON）
##   ④ 逐步执行：工具带选中该步工具（哪步亮哪把），计划板指针推进（@step_out）
##   ⑤ world.run 收尾
## tune 与 run 的差别只有：换了提示词、phase 标 tune——**计划随提示词变化**正是过关检查。
func _drive_think_run(phase: String, prompt: String) -> Dictionary:
	var out: Dictionary = {}
	out["set_prompt"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": thinker_eid, "key": "prompt", "value": prompt},
		{"actor": "player", "caption": "给思考机换纸条：" + prompt})
	if view != null:
		view.get_thinker().set_prompt(prompt)
		await view.codex_goto(view.thinker_front_pos())

	# 一次模型调用（确定性规则模拟，非 LLM；接口 prompt→plan 预留接真模型）
	var plan: Dictionary = MiniBrain.think(prompt)
	out["set_tokens"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": thinker_eid, "key": "@tokens_out", "value": float(plan["tokens"])},
		{"actor": "codex", "caption": "思考机吐出 %d 个 token" % int(plan["tokens"])})
	_record_think_step(phase, prompt, plan)
	if view != null:
		view.get_thinker().emit_tokens(int(plan["tokens"]))
		_refresh_visuals()

	# 计划上板
	var steps: Array = plan["steps"]
	out["set_plan"] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
		{"entityId": plan_eid, "key": "plan_text", "value": JSON.stringify(steps)},
		{"actor": "codex", "caption": "计划上板：%d 步（来自提示词「%s」）" % [steps.size(), prompt]})
	if view != null:
		view.get_plan_board().set_plan(steps)
		view.get_tool_belt().select_tool("")
		_refresh_visuals()

	# 逐步执行：工具带随步骤亮对应工具，计划板指针推进
	for i in steps.size():
		var st: Dictionary = steps[i]
		out["pick_%d" % i] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
			{"entityId": belt_eid, "key": "selected_tool", "value": str(st["tool"])},
			{"actor": "codex", "caption": "第 %d 步「%s」：工具带选中「%s」" % [i + 1, st["name"], st["tool"]]})
		out["step_%d" % i] = tools.call_tool(WorldToolsCore.TOOL_SET_PARAM,
			{"entityId": plan_eid, "key": "@step_out", "value": float(i)},
			{"actor": "codex", "caption": "计划板指针推进到第 %d 步" % (i + 1)})
		if view != null:
			view.get_plan_board().set_current_step(i)
			view.get_tool_belt().select_tool(str(st["tool"]))
			_refresh_visuals()
	out["run"] = tools.call_tool(WorldToolsCore.TOOL_RUN,
		{"duration": 1.0},
		{"actor": "codex", "caption": "按计划跑完一遍（%d 步）" % steps.size()})
	if view != null:
		_refresh_visuals()
	_record_level_step(phase,
		{"tool": "level.stage", "args": {"stage": phase, "prompt": prompt,
			"plan": MiniBrain.plan_signature(steps), "tokens": int(plan["tokens"])}},
		"提示词「%s」→ 计划 %d 步 / %d token：%s" % [prompt, steps.size(), int(plan["tokens"]), MiniBrain.plan_signature(steps)])
	return out


## 阶段三：提示词 A（默认三步：读→做→写）。
func stage_run(prompt := PROMPT_A) -> Dictionary:
	return await _drive_think_run("run", prompt)


## 阶段四：**改提示词**为 B——计划 B 明显不同（多出校验步与循环步、token 数不同），
## 计划板内容更新，指针重走。
func stage_tune(prompt := PROMPT_B) -> Dictionary:
	return await _drive_think_run("tune", prompt)


## 阶段五：评分——交给「另一实例」ScorerService（scoring/ 包，与执行侧零共享）：
## 输入是冻结前的 run 文档 + 本关 task_goal（goals.gd 纯数据，不从本类取状态）；
## LLM 通道不可用时自动回退规则评分（rule_v1）。五句与 evidence 落进 score 步的
## output（args.dimensions 保持旧形状兼容：[{dim, sentence}×5]）。
func stage_score() -> Dictionary:
	var rc := tools.recorder()
	var verdict: Dictionary = ScorerServiceScript.new().score(rc.get_doc(), ScorerGoalsScript.goal_for("L4"))
	var dims: Array = []
	for s in verdict.get("sentences", []):
		var d: Dictionary = s
		dims.append({"dim": str(d.get("dim", "")), "sentence": str(d.get("text", ""))})
	var ops_total := 0
	var tokens_total := 0
	for s in rc.get_steps():
		ops_total += int((s as Dictionary).get("ops", 0))
		tokens_total += int((s as Dictionary).get("tokens", 0))
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
		"tokens": tokens_total,
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


# ---------- 过关检查（读冻结的 run JSON，不重跑世界） ----------

## 判定"改它的提示，能看到计划随之变化"（spec §9.1.1 L4）：
##   ① 两次 run 的计划步骤序列不同（JSON 级比较）
##   ② 第二次计划含校验步与循环步
##   ③ 两张提示词原文都在步记录里（set_param 的 args.value）
##   ④ 两次模拟 token 数不同
func check_pass() -> Dictionary:
	var rc := tools.recorder()
	if rc.state_name() != "frozen":
		return {"pass": false, "reason": "not_frozen", "runId": rc.run_id()}
	var doc: Dictionary = JSON.parse_string(rc.frozen_text())
	var steps: Array = doc.get("steps", [])
	var prompts: Array = []
	var thinks: Array = []
	for s in steps:
		var step: Dictionary = s
		var action: Dictionary = step.get("action", {})
		var tool := str(action.get("tool", ""))
		if tool == WorldToolsCore.TOOL_SET_PARAM:
			var args: Dictionary = action.get("args", {})
			if str(args.get("entityId", "")) == thinker_eid and str(args.get("key", "")) == "prompt":
				prompts.append(str(args.get("value", "")))
		elif tool == "model.think":
			var output: Dictionary = step.get("output", {})
			thinks.append({
				"prompt": str(action.get("args", {}).get("prompt", "")),
				"plan": output.get("plan", []),
				"tokens": int(step.get("tokens", 0)),
			})
	var two := thinks.size() >= 2
	var sig_a := MiniBrain.plan_signature(thinks[0]["plan"]) if two else ""
	var sig_b := MiniBrain.plan_signature(thinks[1]["plan"]) if two else ""
	var seq_differs := two and sig_a != sig_b
	var second_b := two and str(thinks[1]["prompt"]) == PROMPT_B
	var has_verify_loop := second_b and MiniBrain.has_step_named(thinks[1]["plan"], MiniBrain.STEP_NAME_VERIFY) \
		and MiniBrain.has_step_named(thinks[1]["plan"], MiniBrain.STEP_NAME_LOOP)
	var prompts_in_record := prompts.has(PROMPT_A) and prompts.has(PROMPT_B)
	var tokens_differ := two and int(thinks[0]["tokens"]) != int(thinks[1]["tokens"])
	return {
		"pass": seq_differs and has_verify_loop and prompts_in_record and tokens_differ,
		"planSeqDiffers": seq_differs,
		"secondHasVerifyAndLoop": has_verify_loop,
		"promptsInRecord": prompts_in_record,
		"tokensDiffer": tokens_differ,
		"prompts": prompts,
		"sigA": sig_a,
		"sigB": sig_b,
		"tokensA": int(thinks[0]["tokens"]) if two else -1,
		"tokensB": int(thinks[1]["tokens"]) if two else -1,
		"stepsA": (thinks[0]["plan"] as Array).size() if two else -1,
		"stepsB": (thinks[1]["plan"] as Array).size() if two else -1,
		"runId": rc.run_id(),
		"path": rc.out_path(),
		"steps": steps.size(),
	}


# ---------- 内部 ----------

## 思考机的一次"模型调用"步（actor=codex，tokens=模拟 token 数，
## action=model.think；与工具步走同一条记录通道）。
func _record_think_step(phase: String, prompt: String, plan: Dictionary) -> int:
	var t0 := Time.get_ticks_usec()
	var steps: Array = plan["steps"]
	return tools.recorder().record_step({
		"t": tools.state().world_t(),
		"phase": phase,
		"actor": "codex",
		"input": {"prompt": prompt},
		"action": {"tool": "model.think", "args": {"prompt": prompt}},
		"output": {"ok": true, "plan": steps.duplicate(true), "tokens": int(plan["tokens"])},
		"tokens": int(plan["tokens"]),
		"ops": 0,
		"costMs": (Time.get_ticks_usec() - t0) / 1000.0,
		"world": tools.state().state_digest(),
		"caption": "思考机一次模型调用：纸条进「%s」→ 计划 %d 步 / %d token 出" % [prompt, steps.size(), int(plan["tokens"])],
	})


## 关卡自身的阶段步（video/install/score 这些 kernel 没有的 phase），
## 与工具步走同一条记录通道（参照 l1_flow 的做法）。
## output 参数默认 {"ok": true}；score 步把评分器的五句与证据放进来。
## 状态灯永远从步记录重算（mini-codex §2.1：不另做状态机）。
func _refresh_visuals() -> void:
	if view == null:
		return
	var steps := tools.recorder().get_steps()
	var thinker = view.get_thinker()
	if thinker != null:
		thinker.set_state_visual(ThinkerScript.derive_state_from_steps(steps, thinker_eid))
	var board = view.get_plan_board()
	if board != null:
		board.set_state_visual(PlanBoardScript.derive_state_from_steps(steps, plan_eid))
	var belt = view.get_tool_belt()
	if belt != null:
		belt.set_state_visual(ToolBeltScript.derive_state_from_steps(steps, belt_eid))
