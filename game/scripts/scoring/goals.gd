class_name ScorerGoals
extends RefCounted

## 五关 task_goal 定义（评分输入的"目标侧"，five_dim_scorer 消费）。
##
## 提炼口径：
##   L1 从 l1_flow.gd 的 check_pass 判定逻辑提炼（任务被下过、其后 codex 执行、
##      跑足两遍）——只读语义不 import 不调用（交互方案 §七：不能自己判自己）。
##   L2–L5 已按各关 flow 落地后的实测 run 校准（2026-09-14，五关端到端测试）：
##      资产 id 取各关 setup_world 注册、stage_install 实际 world.place 的 id；
##      动作模式对照各关 check_pass 语义（L2 读经扫描器写经机械臂的先后链、
##      L3 写→读值因果的先后链、L4 两次 think 的提示词不同、L5 拒绝→重试→
##      通过→完成的闭环）；baseline_ops/baseline_steps 一律取实测值（见各关注释）。
##
## 键义（five_dim_scorer 逐条消费）：
##   level_id / title / episode / summary   关卡标识与过关检查一句话
##   required_phases    必经 phase（出现即算，不要求连续，按列出顺序应为先后）；
##                      不含 score——评分器在 score 步落账前运行，评分步不是被评对象
##   required_assets    install 必装组件（world.place 的 assetId）
##   required_patterns  期望动作模式 [{id, tool, actor?, paramKey?, after?,
##                      value_differs_from?, desc}]；after=必须排在所引模式之后，
##                      value_differs_from=set_param 的 value 须与所引模式不同，
##                      desc=给学员看的中文描述
##   forbidden_tools    本关禁止使用的工具
##   expect_runs        期望 world.run 遍数（含改参后重跑）
##   baseline_ops       ops 基线（效率维对照，实测校准）
##   baseline_steps     步数基线（参考值，实测校准）
##   task_param_key     任务描述写在哪个参数上（默认 task_text）
##   task_must_mention  任务描述应说清的关键短语（字面匹配；文案定型后再填）
##   validation_tools   哪些工具算校验步（expect_validation 时用）
##   expect_validation  是否期望执行前有校验步
##   expect_retry_close 失败后是否期望重试闭环（预留键：rule_v1 的鲁棒维无条件检测重试闭环，暂不消费此键；LLM 评分接入后生效）

const LEVEL_IDS := ["L1", "L2", "L3", "L4", "L5"]


static func goal_for(level_id: String) -> Dictionary:
	match level_id:
		"L1":
			return _l1()
		"L2":
			return _l2()
		"L3":
			return _l3()
		"L4":
			return _l4()
		"L5":
			return _l5()
	return {}


static func all_goals() -> Array:
	var out: Array = []
	for id in LEVEL_IDS:
		out.append(goal_for(str(id)))
	return out


## goal 键合法性检查：返回问题清单（空数组 = 合法）。
static func validate(goal: Dictionary) -> Array:
	var problems: Array = []
	if str(goal.get("level_id", "")) == "":
		problems.append("level_id 为空")
	for key in ["title", "summary"]:
		if str(goal.get(key, "")) == "":
			problems.append(key + " 为空")
	var phases: Array = goal.get("required_phases", [])
	if phases.is_empty():
		problems.append("required_phases 为空")
	for ph in phases:
		if str(ph) == "":
			problems.append("required_phases 含空串")
	var assets: Array = goal.get("required_assets", [])
	if assets.is_empty():
		problems.append("required_assets 为空")
	for aid in assets:
		if str(aid) == "":
			problems.append("required_assets 含空串")
	var patterns: Array = goal.get("required_patterns", [])
	if patterns.is_empty():
		problems.append("required_patterns 为空")
	var seen_ids := {}
	for p in patterns:
		var pat: Dictionary = p
		var pid := str(pat.get("id", ""))
		if pid == "":
			problems.append("pattern 缺 id")
			continue
		if seen_ids.has(pid):
			problems.append("pattern id 重复：" + pid)
		seen_ids[pid] = true
		if str(pat.get("tool", "")) == "":
			problems.append("pattern " + pid + " 缺 tool")
		if str(pat.get("desc", "")) == "":
			problems.append("pattern " + pid + " 缺 desc")
		for ref_key in ["after", "value_differs_from"]:
			if pat.has(ref_key):
				var rid := str(pat[ref_key])
				if rid == pid or not seen_ids.has(rid):
					problems.append("pattern " + pid + " 的 " + ref_key + " 引用了未在它之前定义的 " + rid)
	for num_key in ["expect_runs", "baseline_ops", "baseline_steps"]:
		if typeof(goal.get(num_key, null)) != TYPE_INT:
			problems.append(num_key + " 应为 int")
	for bool_key in ["expect_validation", "expect_retry_close"]:
		if typeof(goal.get(bool_key, null)) != TYPE_BOOL:
			problems.append(bool_key + " 应为 bool")
	for arr_key in ["forbidden_tools", "task_must_mention", "validation_tools"]:
		if typeof(goal.get(arr_key, null)) != TYPE_ARRAY:
			problems.append(arr_key + " 应为 Array")
	return problems


# ---------- L1：它是谁、接什么活（E49） ----------
# check_pass 语义：set_param(task_text) 之后有 codex 的 world.run，且改参后
# 再跑一遍（tune）；实测基线 16 步 / 220 ops（runs/e49，端到端测试实测）。

static func _l1() -> Dictionary:
	return {
		"level_id": "L1",
		"title": "它是谁、接什么活",
		"episode": 49,
		"summary": "给 codex 下一条任务，并看到它接下",
		"required_phases": ["video", "install", "run"],
		"required_assets": ["conc_task_board", "conc_nameplate"],
		"required_patterns": [
			{
				"id": "set_task",
				"tool": "world.set_param",
				"actor": "player",
				"paramKey": "task_text",
				"desc": "学员给 codex 下任务（把任务写到任务牌 task_text）",
			},
			{
				"id": "accept",
				"tool": "world.set_param",
				"actor": "codex",
				"paramKey": "@task_out",
				"after": "set_task",
				"desc": "codex 接活（task_out 翻到 1）",
			},
			{
				"id": "run_task",
				"tool": "world.run",
				"actor": "codex",
				"after": "accept",
				"desc": "codex 执行任务（world.run）",
			},
		],
		"forbidden_tools": [],
		"expect_runs": 2,
		"baseline_ops": 220,
		"baseline_steps": 16,
		"task_param_key": "task_text",
		"task_must_mention": [],
		"validation_tools": [],
		"expect_validation": false,
		"expect_retry_close": false,
	}


# ---------- L2：它怎么读、怎么写（E51） ----------
# check_pass 语义：扫描器成功读 report.txt、机械臂成功写 out.txt、上锁格从未
# 读成功。goal 的动作模式表达"先读后写"的先后链（读经扫描器、写经机械臂）。
# 实测基线 22 步 / 202 ops（runs/e51：video+install+两轮任务+评分）；
# 任务面 = 扫描器的 target_file（学员下任务即指定扫描目标）。

static func _l2() -> Dictionary:
	return {
		"level_id": "L2",
		"title": "它怎么读、怎么写",
		"episode": 51,
		"summary": "看到它读出指定文件、写出指定格子",
		"required_phases": ["video", "install", "run"],
		"required_assets": ["l2_file_cabinet", "l2_scanner", "l2_arm"],
		"required_patterns": [
			{
				"id": "read_src",
				"tool": "fs.read",
				"desc": "读出指定文件（扫描器扫过文件柜的格子，carrier=scanner）",
			},
			{
				"id": "write_dst",
				"tool": "fs.write",
				"after": "read_src",
				"desc": "把结果写进指定格子（机械臂放入文件柜，carrier=arm）",
			},
		],
		"forbidden_tools": [],
		"expect_runs": 2,
		"baseline_ops": 202,
		"baseline_steps": 22,
		"task_param_key": "target_file",
		"task_must_mention": [],
		"validation_tools": [],
		"expect_validation": false,
		"expect_retry_close": false,
	}


# ---------- L3：它记得住什么（E50） ----------
# check_pass 语义：memory.write（任务 1）与其后 value 相等的 memory.read（任务 2），
# out 格被写为 read 值×2，tune 段有 context.trim。rule_v1 的模式只能表达先后链
# 与"值不同"约束，写读值相等由 check_pass 判定；goal 用 读→存→取回→写 out
# 四段先后链承载这条因果（存/取回两步带 key=last_result 即值的同一性锚点）。
# 实测基线 28 步 / 303 ops（runs/e50：两任务 + 容量裁剪 + 评分）。
# 任务面说明：L3 的任务文本在 level.task 步里，rule_v1 只认 set_param 形任务面，
# 暂以 files（上下文装了什么）近似——LLM 通道接入后按 level.task 判。

static func _l3() -> Dictionary:
	return {
		"level_id": "L3",
		"title": "它记得住什么",
		"episode": 50,
		"summary": "看到它把上一次的结果带进这一次",
		"required_phases": ["video", "install", "run"],
		"required_assets": ["conc_context_container", "conc_memory_cabinet"],
		"required_patterns": [
			{
				"id": "read_src",
				"tool": "world.read",
				"actor": "codex",
				"desc": "codex 读 report.txt（读取走工具面，命中内容进上下文）",
			},
			{
				"id": "save_result",
				"tool": "memory.write",
				"paramKey": "last_result",
				"after": "read_src",
				"desc": "第一次的结果写进记忆柜抽屉 1（memory.write，key=last_result）",
			},
			{
				"id": "reuse_result",
				"tool": "memory.read",
				"paramKey": "last_result",
				"after": "save_result",
				"desc": "下一次开柜取回上一次的结果（memory.read 同 key，值因果由 check_pass 判）",
			},
			{
				"id": "write_out",
				"tool": "world.set_param",
				"actor": "codex",
				"paramKey": "@out",
				"after": "reuse_result",
				"desc": "取回的前值乘 2 写到 out 格（写→读→写闭环收口）",
			},
		],
		"forbidden_tools": [],
		"expect_runs": 3,
		"baseline_ops": 303,
		"baseline_steps": 28,
		"task_param_key": "files",
		"task_must_mention": [],
		"validation_tools": [],
		"expect_validation": false,
		"expect_retry_close": false,
	}


# ---------- L4：它怎么想、怎么决定（E40） ----------
# check_pass 语义：两次 model.think 的计划序列不同（第二次含校验步+循环步）、
# 两张提示词原文都在记录里、两次 token 数不同。goal 用 提示A→思考A→提示B
# （value 与 A 不同）→思考B 的先后链承载"改提示、计划随之变化"；计划序列
# 本身的差异由 check_pass 判。实测基线 36 步 / 580 ops（runs/e40：两轮思考
# + 计划逐步执行 + 评分）。任务面 = 思考机的 prompt（提示词就是这关的任务）。

static func _l4() -> Dictionary:
	return {
		"level_id": "L4",
		"title": "它怎么想、怎么决定",
		"episode": 40,
		"summary": "改它的提示，计划随之变化",
		"required_phases": ["video", "install", "run", "tune"],
		"required_assets": ["conc_thinker", "conc_plan_board", "conc_tool_belt"],
		"required_patterns": [
			{
				"id": "prompt_a",
				"tool": "world.set_param",
				"actor": "player",
				"paramKey": "prompt",
				"desc": "第一次提示词喂进思考机",
			},
			{
				"id": "think_a",
				"tool": "model.think",
				"actor": "codex",
				"after": "prompt_a",
				"desc": "第一次思考出计划并执行",
			},
			{
				"id": "prompt_b",
				"tool": "world.set_param",
				"actor": "player",
				"paramKey": "prompt",
				"after": "think_a",
				"value_differs_from": "prompt_a",
				"desc": "改提示词（内容与第一次不同）",
			},
			{
				"id": "think_b",
				"tool": "model.think",
				"actor": "codex",
				"after": "prompt_b",
				"desc": "第二次思考：计划随提示词变化（序列差异由 check_pass 判）",
			},
		],
		"forbidden_tools": [],
		"expect_runs": 2,
		"baseline_ops": 580,
		"baseline_steps": 36,
		"task_param_key": "prompt",
		"task_must_mention": [],
		"validation_tools": [],
		"expect_validation": false,
		"expect_retry_close": false,
	}


# ---------- L5：它怎么跑完、怎么不错（E60） ----------
# check_pass 语义：校验拒绝步 → 旁路重试步 → 第二轮通过步 → 完成步的顺序链
# （tune 重跑后仍成立），重试计数不超上限。goal 用 喂坏输入→校验→重试→
# 再校验→显式出口 五段先后链承载这条闭环；计数与上限的一致性由 check_pass 判。
# 十四件全装（本关四件实体 + L1–L4 十件占位）是本关"终点"语义，全部列入
# 必装。实测基线 73 步 / 1226 ops（runs/e60：两条坏输入链 + 两次导出 + 评分）。

static func _l5() -> Dictionary:
	return {
		"level_id": "L5",
		"title": "它怎么跑完、怎么不错",
		"episode": 60,
		"summary": "给它一个坏输入，它自己校验、重试、跑完",
		"required_phases": ["video", "install", "run"],
		"required_assets": [
			"conc_loop_gallery", "conc_runner", "conc_verify_gate", "conc_bypass",
			"stub_task_board", "stub_nameplate", "stub_planner_board",
			"stub_context_container", "stub_model_core", "stub_memory_cabinet",
			"stub_tool_belt", "stub_file_cabinet", "stub_arm_head", "stub_scanner_head",
		],
		"required_patterns": [
			{
				"id": "feed_input",
				"tool": "world.set_param",
				"actor": "player",
				"paramKey": "task_text",
				"desc": "喂一个坏输入任务（payload 缺必需字段）",
			},
			{
				"id": "verify_reject",
				"tool": "codex.verify",
				"after": "feed_input",
				"desc": "先过校验门：坏输入被拒（c10.3:1 字段缺失）",
			},
			{
				"id": "bypass_retry",
				"tool": "world.set_param",
				"actor": "codex",
				"paramKey": "retry_count",
				"after": "verify_reject",
				"desc": "被拒不裸崩：旁路记录重试",
			},
			{
				"id": "verify_pass",
				"tool": "codex.verify",
				"after": "bypass_retry",
				"desc": "修正输入后第二轮过校验门",
			},
			{
				"id": "close_done",
				"tool": "world.set_param",
				"actor": "codex",
				"paramKey": "@done",
				"after": "verify_pass",
				"desc": "回廊显式出口：跑完并写出结果（拒绝→重试闭环收口）",
			},
		],
		"forbidden_tools": [],
		"expect_runs": 4,
		"baseline_ops": 1226,
		"baseline_steps": 73,
		"task_param_key": "task_text",
		"task_must_mention": [],
		"validation_tools": ["codex.verify"],
		"expect_validation": true,
		"expect_retry_close": true,
	}
