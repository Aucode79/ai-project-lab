extends RefCounted

## 四层展开阅读器：功能 → 流程 → 语句 → 真实源码行（或显式缺口）。
##
## 它是**生产模块**，不属于任何测试场景：工作台与真实沙盒都用它渲染同一个目录。
## 状态只在这里维护（当前对象、层级、选中的流程与语句），渲染是纯函数式的——
## 调用方拿 text() 显示，按键交给 handle_key()，返回 true 表示状态变了、需要重画。
##
## 三类第四层都在这一个渲染器里处理，不假装统一：
##   external —— 本机 smolagents 行（带整文件哈希校验）
##   repo     —— 本仓实现行（与映射同一次提交，只比逐行文本）
##   缺口     —— anchor 为 null 且带 reason，界面写明「尚未实现」

const Map := preload("res://scripts/interaction/unfolding_map.gd")
const Link := preload("res://scripts/interaction/execution_link.gd")

const STAGE_FUNCTION := "function"
const STAGE_PROCESS := "process"
const STAGE_STATEMENT := "statement"

var object_id := ""
## 可选：运行观察联动。没有它时只说「静态可达」，不假装有执行证据。
var link = null
var stage := STAGE_FUNCTION
var process_id := ""
var statement_id := ""


func reset(id: String) -> void:
	object_id = id
	stage = STAGE_FUNCTION
	process_id = ""
	statement_id = ""


func has_entry() -> bool:
	return not Map.object_entry(object_id).is_empty()


## 按键：数字选层、B 逐层返回、Tab 在已映射对象之间轮换。
## 返回 true 表示状态已变（调用方负责重画与回到顶部）。
func handle_key(keycode: int) -> bool:
	if keycode == KEY_TAB:
		var ids: Array = Map.objects()
		if ids.is_empty():
			return false
		var next := 0
		if object_id in ids:
			next = (ids.find(object_id) + 1) % ids.size()
		reset(String(ids[next]))
		return true
	if keycode == KEY_B:
		if stage == STAGE_STATEMENT:
			statement_id = ""
			stage = STAGE_PROCESS
			return true
		if stage == STAGE_PROCESS:
			process_id = ""
			stage = STAGE_FUNCTION
			return true
		return false
	var digit := keycode - KEY_1
	if digit < 0 or digit > 8:
		return false
	return select_choice(digit)

## The mouse list has no nine-key limit; every real statement can be opened.
func choices() -> Array:
	var entry := Map.object_entry(object_id)
	if entry.is_empty(): return []
	if stage == STAGE_FUNCTION: return entry["processes"]
	if stage == STAGE_PROCESS:
		var result := []
		for statement in Map.statements_of_process(object_id, process_id):
			result.append({"title": statement.get("text", "") if Map.is_mapped(statement) else statement.get("reason", "尚未实现")})
		return result
	return []

func select_choice(index: int) -> bool:
	var entry := Map.object_entry(object_id)
	if entry.is_empty() or index < 0: return false
	if stage == STAGE_FUNCTION:
		var processes: Array = entry["processes"]
		if index >= processes.size(): return false
		process_id = processes[index]["id"]
		stage = STAGE_PROCESS
		return true
	if stage == STAGE_PROCESS:
		var statements := Map.statements_of_process(object_id, process_id)
		if index >= statements.size(): return false
		statement_id = statements[index]["id"]
		stage = STAGE_STATEMENT
		return true
	return false


func text() -> String:
	var entry: Dictionary = Map.object_entry(object_id)
	if entry.is_empty():
		return ""
	var level1: Dictionary = entry["level1"]
	var out := "第 1 层 · 功能：%s %s\n%s\n\n" % [level1["title"], level1["en"], level1["summary"]]
	var source: Dictionary = level1.get("source", {})
	if String(source.get("path", "")) == "":
		out += "第 4 层：尚未实现 —— 这一件还没有真实实现可指（见下方声明）。\n\n"
	else:
		out += "真实源码：%s 第 %d–%d 行（%s）\n\n" % [
			source["path"], source["lines"][0], source["lines"][1],
			"本仓实现" if String(source.get("root", "")) == "repo" else "本机 smolagents，锚点带哈希校验"]
	if stage == STAGE_FUNCTION:
		out += "第 2 层 · 流程（按数字键展开）：\n"
		var processes: Array = entry["processes"]
		for i in processes.size():
			out += "  %d) %s\n" % [i + 1, processes[i]["title"]]
		out += "\n每个流程都能继续展开到具体语句，再落到真实代码行。\nB 返回上一层，Tab 换对象，Esc 关闭。"
		return out
	if stage == STAGE_PROCESS:
		var title := process_id
		for process in entry["processes"]:
			if process["id"] == process_id:
				title = process["title"]
		out += "第 2 层 · 流程：%s\n\n第 3 层 · 逻辑语句（按数字键看真实源码）：\n" % title
		var statements: Array = Map.statements_of_process(object_id, process_id)
		for i in statements.size():
			if Map.is_mapped(statements[i]):
				out += "  %d) %s:%d  %s%s\n" % [i + 1, statements[i]["anchor"]["path"],
					statements[i]["anchor"]["line"], statements[i]["text"],
					_observation_suffix(String(statements[i]["id"]))]
			else:
				out += "  %d) （未实现）%s\n" % [i + 1, statements[i].get("reason", "")]
		out += "\nB 返回流程列表，Esc 关闭。"
		return out
	var statement := _selected_statement(entry)
	if statement.is_empty():
		return out
	if not Map.is_mapped(statement):
		out += "第 3 层 · 语句（未实现）：%s\n\n声明：%s\n\n" % [
			statement["id"], statement.get("reason", "")]
		out += "这一件还没有第 4 层。等实现接上以后再补锚点，不先写假代码行。\nB 返回语句列表，Esc 关闭。"
		return out
	var anchor: Dictionary = statement["anchor"]
	out += "第 3 层 · 语句：%s（流程 %s）\n第 4 层 · 真实源码 %s:%d\n%s\n" % [
		statement["text"], statement["process"], anchor["path"], anchor["line"],
		_observation_line(String(statement["id"]))]
	# 一行可能同时属于多个对象（共用入口），全部列出，不假装只有一个主人。
	var owners: Array = Map.owners_of(anchor["path"], anchor["line"])
	out += "反向定位（本行认领者 %d 个）：\n" % owners.size()
	for owner in owners:
		out += "  · %s / 流程 %s / 语句 %s\n" % [
			owner.get("level1_title", "?"), owner.get("process_id", "?"), owner.get("statement_id", "?")]
	out += "\n"
	out += source_window(String(anchor["path"]), int(anchor["line"]), 6,
		String(anchor.get("root", "external")))
	out += "\nB 返回语句列表，Esc 关闭。"
	return out


## 运行观察：只有真有事件落到这行才显示次数；否则明确写「静态可达」。
func _observation_line(statement_id: String) -> String:
	if link == null:
		return "运行观察：无（当前只有静态可达证据，没有事件源接入）\n"
	var seen: int = link.observed(object_id, statement_id)
	if seen <= 0:
		return "运行观察：0 次（静态可达，尚无事件落到这行）\n"
	return "运行观察：%d 次（来自记录事件）\n" % seen


func _observation_suffix(statement_id: String) -> String:
	if link == null:
		return ""
	var seen: int = link.observed(object_id, statement_id)
	return "" if seen <= 0 else "   ← 已观察到 %d 次" % seen


func _selected_statement(entry: Dictionary) -> Dictionary:
	for candidate in entry["statements"]:
		if candidate["id"] == statement_id:
			return candidate
	return {}


## 真实源码窗口：目标行用 ▶ 标出，行号即文件行号。
func source_window(rel_path: String, line_number: int, radius: int, root := "external") -> String:
	var path := Map.absolute_path(rel_path, root)
	if not FileAccess.file_exists(path):
		return "（源码不可读：%s）\n" % path
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var first: int = maxi(1, line_number - radius)
	var last: int = mini(lines.size(), line_number + radius)
	var out := ""
	for n in range(first, last + 1):
		var marker := "▶" if n == line_number else " "
		# 外部仓库可能是 CRLF；去掉行尾 \r，否则渲染成双倍行距。
		out += "%s %4d  %s\n" % [marker, n, String(lines[n - 1]).strip_edges(false, true)]
	return out
