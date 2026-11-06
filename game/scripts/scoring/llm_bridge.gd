class_name ScorerLLMBridge
extends RefCounted

## LLM 评分通道（预留接口）。v1 不接真模型：score_with_llm 一律报
## NOT_IMPLEMENTED（GDScript 无异常机制，用 {ok:false, code} 契约模拟"抛错"），
## 调用方（ScorerService）收到后回退规则评分 rule_v1。
##
## 将来接 sidecar 的调用形状（MCP 客户端在 Python 侧，Godot 不碰 MCP——spec §7.2）：
##
##   POST http://127.0.0.1:<sidecar_port>/v1/score      （Godot 侧用 HTTPRequest）
##   请求体：
##     {
##       "run": <完整 run JSON（schema v6，原样透传）>,
##       "goal": <task_goal（goals.gd 形状）>,
##       "prompt": ScorerLLMBridge.prompt_template(),   # 另一套提示词（评分侧独立）
##       "ruleset_version": "world-kernel/1"
##     }
##   响应体：与规则评分同形状
##     { "sentences": [{dim, text} × 5],
##       "evidence":  {dim: [stepRef…]},
##       "scorer":    "llm_<model>" }
##   缓存键含规则集版本与提示词摘要（spec §7.3：LLM 响应缓存的口径——
##   理由是成本，不是复现）。
##   超时 / 非 200 / 解析失败 / 形状不对：同样回退规则评分，调用方无感。
##   接入时把 is_available() 改为探测 sidecar 健康检查即可，回退路径不动。

const CODE_NOT_IMPLEMENTED := "NOT_IMPLEMENTED"


## v1：sidecar 未接入，评分走规则通道（rule_v1）。
func is_available() -> bool:
	return false


## v1 一律报 NOT_IMPLEMENTED；接上 sidecar 后改为真调用（形状见类注释）。
func score_with_llm(run: Dictionary, task_goal: Dictionary) -> Dictionary:
	push_error("[ScorerLLMBridge] LLM 评分通道未接入：score_with_llm 报 NOT_IMPLEMENTED，调用方应回退规则评分（rule_v1）")
	return {
		"ok": false,
		"code": CODE_NOT_IMPLEMENTED,
		"message": "sidecar 未接入：demo 阶段由规则评分器扮演『另一实例』；接口与调用形状见 llm_bridge.gd 类注释",
		"result": {},
	}


## 另一套提示词（与执行侧零共享）：将来原样发给 sidecar 的 system prompt 骨架。
func prompt_template() -> Dictionary:
	return {
		"role": "你是独立评分实例，只输出五维诊断语句：不给分数、不与他人比较、不评聪明",
		"dims": ["正确性", "结构", "效率", "鲁棒性", "可读性"],
		"rules": [
			"每句必须绑定至少一个 stepRef 作为证据；拿不出证据就说『这一版看不出问题』，不编话",
			"每句要指出下一步改哪里，落在诊断上（如『你在第 7 步把校验放在解析之前…』）",
			"效率只读步记录的 ops 字段，不自己估",
			"判定只依据这份 run JSON 与 task_goal，不重跑世界",
		],
		"output_shape": {
			"sentences": "[{dim, text} x 5]",
			"evidence": "{dim: [stepRef...]}",
			"scorer": "llm_<model>",
		},
	}
