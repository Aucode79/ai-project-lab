extends Node

## 五关流程驱动器的共用骨架：工具内核解析、集号/种子、开始与收尾、逐级步记录。
## 各关 lN_flow.gd `extends "res://scripts/levels/flow_base.gd"`，只留本关的阶段内容。
## 背后由来见 docs/30-决策/2026-09-15-场景与流程层去重重构.md。
##
## 为什么 stage_* / drive_full 不在这里：GDScript 覆写要求签名精确一致，而各关
## stage_run/stage_tune 带本关默认参数（l1 一条任务文本、l5 三条），scene 与测试
## 都按这些签名调用——做成虚函数必须改关卡的公开签名，得不偿失。各关自留一份。

const ScorerServiceScript := preload("res://scripts/scoring/scorer_service.gd")
const ScorerGoalsScript := preload("res://scripts/scoring/goals.gd")

var tools: WorldToolsCore = null
var view = null
var _world_set_up := false

## 本关集号（步记录用）与默认随机种子（begin 用）；子类在 _init 里覆盖。
var episode := 0
var default_seed := 0


func _ready() -> void:
	if tools == null:
		tools = _resolve_tools()


## 解析本关用的工具内核：优先取场景树里的共享 WorldTools（窗口模式），
## 否则新建独立内核（headless 测试）。
func _resolve_tools() -> WorldToolsCore:
	var loop := Engine.get_main_loop() as SceneTree
	if loop != null and loop.root != null:
		var found := loop.root.get_node_or_null("WorldTools")
		if found is WorldToolsCore:
			return found
	return WorldToolsCore.new()


## 开始一次 task run（集号与种子来自子类 _init；显式传种子可覆盖）。
func begin(seed_value := 0) -> Dictionary:
	return tools.recorder().begin_run(StepRecorderCore.KIND_TASK, episode,
		seed_value if seed_value != 0 else default_seed)


func finish_run(out_root := StepRecorderCore.RUN_OUT_ROOT) -> Dictionary:
	return tools.recorder().end_run(out_root)


## 记录一条关卡级步（l2 覆写为自定义世界摘要）。
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
		"world": tools.state().state_digest(),
		"caption": caption,
	})
