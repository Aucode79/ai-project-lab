class_name ScorerService
extends RefCounted

## 「另一实例」评分入口（交互方案 §七：评分要用另一个 codex 实例——至少
## 另一次调用 + 另一套提示词，不能是刚替学员做过的那个自己判自己）。
##
## demo 阶段的"另一实例"由本包扮演：
##   * 独立入口：score() 只吃冻结的 run JSON 与 task_goal（goals.gd），
##     不接触、不 import 被评任务的执行代码（levels/、core/、compiler/）；
##   * 独立模板表：sentence_templates.gd（评分侧专用，执行侧零共享）；
##   * 独立通道预留：llm_bridge.gd——sidecar 接入后同一入口换 LLM 通道，
##     LLM 不可用 / 超时 / 形状不对时回退规则评分（rule_v1），调用方无感。
##
## 用法：
##   var out := ScorerService.new().score(run_json, ScorerGoals.goal_for("L1"))
##   out.sentences / out.evidence / out.scorer / out.llm
## 本文件不写任何文件；落进步记录由集成侧做。

const Scorer := preload("res://scripts/scoring/five_dim_scorer.gd")
const Bridge := preload("res://scripts/scoring/llm_bridge.gd")


## 评分主入口：先试 LLM 通道，不可用（v1 一律）则回退规则评分。
func score(run: Dictionary, task_goal: Dictionary) -> Dictionary:
	var bridge := Bridge.new()
	if bridge.is_available():
		var llm_out: Dictionary = bridge.score_with_llm(run, task_goal)
		if bool(llm_out.get("ok", false)) and _shape_ok(llm_out.get("result", {})):
			var res: Dictionary = llm_out["result"]
			res["llm"] = {"channel": "llm", "fallback": false}
			return res
		return _rule(run, task_goal, str(llm_out.get("code", "llm_error")))
	return _rule(run, task_goal, Bridge.CODE_NOT_IMPLEMENTED)


func _rule(run: Dictionary, task_goal: Dictionary, reason: String) -> Dictionary:
	var out: Dictionary = Scorer.new().score(run, task_goal)
	out["llm"] = {"channel": Scorer.SCORER_ID, "fallback": true, "reason": reason}
	return out


## LLM 结果必须与规则评分同形状才放行，否则回退。
func _shape_ok(res: Dictionary) -> bool:
	if not res is Dictionary or res.is_empty():
		return false
	var sentences: Array = res.get("sentences", [])
	if sentences.size() != 5:
		return false
	for item in sentences:
		var d: Dictionary = item
		if str(d.get("dim", "")) == "" or str(d.get("text", "")) == "":
			return false
	if typeof(res.get("evidence", null)) != TYPE_DICTIONARY:
		return false
	return str(res.get("scorer", "")) != ""
