extends RefCounted

## 思考的模拟内核（L4 · docs/10-契约/mini-codex.md §一 #5 思考机）。
##
## **这是确定性规则模拟，不是 LLM**：demo 阶段没有接真模型，思考机的行为
## 来源是本文件的关键词规则；同一提示词永远得到同一计划（可判定、可复跑）。
##
## 接口形状（prompt → plan）为将来接真模型预留：
##   think(prompt: String) -> {"prompt": String,
##                             "steps": [{"name": String, "tool": String}],
##                             "tokens": int}
## 将来换真模型（spec §9.1.1 L4 → mini-codex §七 6 的三级内核）时，保持同一
## 接口另写一个实现替换本文件即可，调用方（l4_flow.gd / 测试）不动。
##
## 规则：
##   * 提示词含「先检查 / 检查 / 校验」→ 计划**最前**插入校验步
##   * 含「两遍 / 重复」→ 用循环步替代单次执行步
##   * 含「搜索 / 查找」→ 插入一步用「搜」工具
##   * 都不含 → 默认三步计划：读 → 做 → 写
##   * 无论怎么变，计划总以「写出结果」收尾
##   * 模拟 token 数 = 基础 + 每步加成 + 提示词长度（与提示词长度正相关）
##
## 工具取值与工具带（tool_belt.gd）四把一一对应：read / write / run / search。

const TOOL_READ := "read"
const TOOL_WRITE := "write"
const TOOL_RUN := "run"
const TOOL_SEARCH := "search"

const KEYWORDS_CHECK := ["先检查", "检查", "校验"]
const KEYWORDS_LOOP := ["两遍", "重复"]
const KEYWORDS_SEARCH := ["搜索", "查找"]

## 步名关键词（check_pass 与测试据此识别校验步 / 循环步）。
const STEP_NAME_VERIFY := "校验"
const STEP_NAME_LOOP := "循环"

const TOKEN_BASE := 12
const TOKEN_PER_STEP := 6


## 一次"模型调用"：提示词进，计划与模拟 token 数出。纯函数，无场景依赖。
static func think(prompt: String) -> Dictionary:
	var steps: Array = []
	if _has_any(prompt, KEYWORDS_CHECK):
		steps.append({"name": "校验输入格式", "tool": TOOL_RUN})
	steps.append({"name": "读入材料", "tool": TOOL_READ})
	if _has_any(prompt, KEYWORDS_SEARCH):
		steps.append({"name": "搜索相关内容", "tool": TOOL_SEARCH})
	if _has_any(prompt, KEYWORDS_LOOP):
		steps.append({"name": "循环执行两遍", "tool": TOOL_RUN})
	else:
		steps.append({"name": "完成任务", "tool": TOOL_RUN})
	steps.append({"name": "写出结果", "tool": TOOL_WRITE})
	return {
		"prompt": prompt,
		"steps": steps,
		"tokens": token_count(prompt, steps),
	}


## 模拟 token 数：与步数、提示词长度都正相关（规则模拟，非真实计量）。
static func token_count(prompt: String, steps: Array) -> int:
	return TOKEN_BASE + TOKEN_PER_STEP * steps.size() + prompt.length()


## 计划签名（JSON 级比较用）：只取 name/tool 对，确定性序列化。
static func plan_signature(steps: Array) -> String:
	var pairs: Array = []
	for s in steps:
		if s is Dictionary:
			pairs.append({"name": str(s.get("name", "")), "tool": str(s.get("tool", ""))})
	return JSON.stringify(pairs)


## 计划里是否有名字含 keyword 的步骤（如 "校验" / "循环"）。
static func has_step_named(steps: Array, keyword: String) -> bool:
	for s in steps:
		if s is Dictionary and str(s.get("name", "")).contains(keyword):
			return true
	return false


static func tool_sequence(steps: Array) -> Array:
	var tools: Array = []
	for s in steps:
		if s is Dictionary:
			tools.append(str(s.get("tool", "")))
	return tools


static func _has_any(text: String, keywords: Array) -> bool:
	for k in keywords:
		if text.contains(str(k)):
			return true
	return false
