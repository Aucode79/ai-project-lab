extends RefCounted

## 运行观察联动：把**记录到的事件**对应到已锚定的语句上。
##
## 这一层的存在意义是**区分两件事**：
##   静态可达 —— 代码行在源码里存在且锚点校验通过（四层展开已经做到）
##   已观察到 —— 真有事件记录落到这一行（只有这里返回的计数能这么说）
##
## 所以本模块**不产生事件**：它只吃外部喂进来的事件（StepRecorder 的步骤、
## 沙盒里的运行记录、测试里的合成事件），按语句声明的 `events` 键计数。
## 没有事件时不猜、不推断——计数就是 0，阅读器会写「尚无运行观察（静态可达）」。
##
## 事件形状：字典，至少带 "key"（字符串）；可选 "run"、"step" 等原样保留在明细里。

const Map := preload("res://scripts/interaction/unfolding_map.gd")

var _counts := {}       # "object_id/statement_id" -> 次数
var _details := {}      # 同上 -> 事件明细数组
var _unmapped := []     # 没有对应语句的事件（要显式暴露，不能悄悄丢）


## 喂一批事件，返回本次被接受的条数。可重复调用（累加）。
func observe(events: Array) -> int:
	var accepted := 0
	for event in events:
		if not (event is Dictionary):
			_unmapped.append({"event": event, "reason": "事件不是字典"})
			continue
		var key := String((event as Dictionary).get("key", ""))
		if key == "":
			_unmapped.append({"event": event, "reason": "事件没有 key"})
			continue
		var owners := _statements_for_event(key)
		if owners.is_empty():
			_unmapped.append({"event": event, "reason": "没有语句声明这个事件键：%s" % key})
			continue
		accepted += 1
		for owner in owners:
			var slot := "%s/%s" % [owner["object_id"], owner["statement_id"]]
			_counts[slot] = int(_counts.get(slot, 0)) + 1
			if not _details.has(slot):
				_details[slot] = []
			(_details[slot] as Array).append(event)
	return accepted


## 某条语句被观察到几次。没有就是 0——**不代表没执行，只代表没有事件落到它**。
func observed(object_id: String, statement_id: String) -> int:
	return int(_counts.get("%s/%s" % [object_id, statement_id], 0))


func details(object_id: String, statement_id: String) -> Array:
	return _details.get("%s/%s" % [object_id, statement_id], [])


## 某个对象被观察到的语句数 / 已落实语句数。
func observed_ratio(object_id: String) -> Dictionary:
	var entry: Dictionary = Map.object_entry(object_id)
	var mapped := 0
	var seen := 0
	for statement in entry.get("statements", []):
		if not Map.is_mapped(statement):
			continue
		mapped += 1
		if observed(object_id, String(statement["id"])) > 0:
			seen += 1
	return {"observed": seen, "mapped": mapped}


## 没有归属的事件：必须显式报告，不能因为「统计里看不见」就当没发生。
func unmapped_events() -> Array:
	return _unmapped


## 语句声明的事件键 → 认领它的语句（一个键可能被多条语句声明）。
func _statements_for_event(key: String) -> Array:
	var out: Array = []
	for object_id in Map.objects():
		var entry: Dictionary = Map.object_entry(object_id)
		for statement in entry.get("statements", []):
			var keys: Array = statement.get("events", [])
			if key in keys:
				out.append({"object_id": object_id, "statement_id": statement["id"]})
	return out


## 该对象声明了哪些事件键（供文档与自检：声明了键才有被观察的可能）。
func declared_event_keys(object_id: String) -> Array:
	var out: Array = []
	var entry: Dictionary = Map.object_entry(object_id)
	for statement in entry.get("statements", []):
		for key in statement.get("events", []):
			if not out.has(key):
				out.append(key)
	return out
