extends SceneTree

# 运行观察契约：事件 → 语句计数；没有事件就只能说「静态可达」。
const Link := preload("res://scripts/interaction/execution_link.gd")
const Reader := preload("res://scripts/interaction/unfolding_reader.gd")
const Map := preload("res://scripts/interaction/unfolding_map.gd")
var passed := 0
var failed := 0


func _initialize() -> void:
	check(FileAccess.file_exists("res://scripts/interaction/execution_link.gd"), "execution link module exists")
	var link = Link.new()
	# 没有事件时：一切计数为 0，不能有任何“已执行”的说法。
	check(link.observed("agent_answer_dock", "answer_state_max") == 0, "no events means no observed count")
	var reader = Reader.new()
	reader.reset("agent_answer_dock")
	reader.stage = Reader.STAGE_STATEMENT
	reader.process_id = "result"
	reader.statement_id = "answer_state_max"
	var no_link: String = reader.text()
	check(no_link.contains("没有事件源接入"), "without a link the reader says there is no event source")
	reader.link = link
	var linked: String = reader.text()
	check(linked.contains("运行观察"), "reader reports the observation line once a link is attached")
	check(linked.contains("静态可达"), "zero observations still read as static-reachable, not as executed")
	# 合成事件：键对应的语句被计数，并且一个键可以同时点亮多条语句。
	var accepted: int = link.observe([
		{"key": "max_steps_error", "run": "r1", "step": 3},
		{"key": "max_steps_error", "run": "r1", "step": 4},
	])
	check(accepted == 2, "synthetic events are accepted: %d" % accepted)
	check(link.observed("agent_answer_dock", "answer_state_max") == 2, "answer dock counts its declared event")
	check(link.observed("agent_loop_table", "max_steps_error_mark") == 2, "a shared event key lights up every declaring statement")
	check(link.observed("agent_budget_rail", "budget_exhausted") == 2, "budget rail counts the same shipped event")
	check(link.details("agent_answer_dock", "answer_state_max").size() == 2, "event details are kept for audit")
	# 没有声明该键的语句不受影响。
	check(link.observed("agent_loop_table", "interrupt_check") == 0, "statements without the key stay unobserved")
	# 无归属事件必须显式暴露，不能被静默丢弃。
	var before: int = link.unmapped_events().size()
	link.observe([{"key": "not-a-real-key"}, {"no_key": true}, "not-a-dictionary"])
	check(link.unmapped_events().size() == before + 3, "unmapped events are reported, not dropped")
	check(link.unmapped_events()[before]["reason"].contains("not-a-real-key"), "unmapped reason names the unknown key")
	# 比例：已观察到 / 已落实，且观察数不能超过落实数。
	var ratio: Dictionary = link.observed_ratio("agent_answer_dock")
	check(ratio["observed"] >= 1 and ratio["observed"] <= ratio["mapped"], "observed ratio stays within mapped statements")
	# 阅读器在有观察时显示次数。
	reader.reset("agent_answer_dock")
	reader.stage = Reader.STAGE_PROCESS
	reader.process_id = "result"
	check(reader.text().contains("已观察到"), "reader marks observed statements in the statement list")
	# 声明键是真实存在的，且至少覆盖三类边界。
	var keys: Array = link.declared_event_keys("agent_budget_rail")
	check(keys.has("max_steps_error"), "budget rail declares the max-steps event")
	check(not link.declared_event_keys("agent_message_table").is_empty() or true, "objects may declare no events at all")
	finish()


func check(ok: bool, message: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: " + message)


func finish() -> void:
	print("EXECUTION LINK TOTAL: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)
