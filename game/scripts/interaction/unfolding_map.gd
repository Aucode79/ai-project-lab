extends RefCounted

## 四层展开映射的**接口**：读 unfolding_data.gd 的数据，负责校验、漂移检测与反向定位。
##
## 数据只记录真实存在的行号与整行文本；行文本按 strip_edges 比较，避免抄写空白差异。
## 覆盖数由数据推导，不写死；没有锚点的语句显式留空并计入 unmapped，不算已覆盖。
## 外部源码不在本仓库内，因此每条记录同时保存整文件 sha256：文件一变即报 drift，
## 不允许「行号看起来对得上」就宣称仍然有效。
##
## 路径口径：引擎是 Windows 可执行文件（tools/godot/*_win64_console.exe），
## 读不到 WSL 的 /mnt/d 形式；默认用 Windows 形式，其他环境用 SMOLAGENTS_ROOT 覆盖。

const Data := preload("res://scripts/interaction/unfolding_data.gd")

const DEFAULT_SOURCE_ROOT := "D:/smolagents"


static func source_root() -> String:
	var override := OS.get_environment("SMOLAGENTS_ROOT")
	return override if override != "" else DEFAULT_SOURCE_ROOT


static func objects() -> Array:
	return Data.OBJECTS.keys()


static func object_entry(id: String) -> Dictionary:
	return Data.OBJECTS.get(id, {})


static func file_hashes() -> Dictionary:
	return Data.FILES


## 锚点解析：外部源码（smolagents）走 SMOLAGENTS_ROOT，本仓实现走 res://。
static func absolute_path(rel_path: String, root := "external") -> String:
	if root == "repo":
		return "res://" + rel_path
	return source_root().path_join(rel_path)


## 锚点是否已落实：有路径、有正行号、且不是显式声明的未实现。
static func is_mapped(statement: Dictionary) -> bool:
	var anchor: Variant = statement.get("anchor")
	if not (anchor is Dictionary):
		return false
	var dict: Dictionary = anchor
	return String(dict.get("path", "")) != "" and int(dict.get("line", -1)) > 0


## 显式声明的未实现语句（带原因），不能默默缺失。
static func unmapped_declarations() -> Array:
	var out: Array = []
	for object_id in Data.OBJECTS:
		for statement in Data.OBJECTS[object_id]["statements"]:
			if not is_mapped(statement):
				out.append({
					"object_id": object_id,
					"statement_id": statement["id"],
					"reason": String(statement.get("reason", "")),
				})
	return out


static func file_hash(rel_path: String) -> String:
	var path := absolute_path(rel_path)
	if not FileAccess.file_exists(path):
		return ""
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(FileAccess.get_file_as_bytes(path))
	return context.finish().hex_encode()


## 记录哈希与当前文件不一致时返回原因；一致返回空数组。
static func detect_drift(rel_path: String, expected: String) -> Array:
	var actual := file_hash(rel_path)
	if actual == "":
		return ["missing file: %s" % rel_path]
	if actual != expected:
		return ["hash drift: %s recorded=%s actual=%s" % [rel_path, expected, actual]]
	return []


## 逐条回读真实文件：核对行文本与整文件哈希。checked 是真正读过的文件数。
##
## 外部源码额外比对整文件 sha256（那部分不在本仓版本控制里，行号可能悄悄漂移）；
## 本仓实现（root == "repo"）只比行文本——它和这份映射同一次提交，漂移会立刻表现为文本不符。
## 显式声明未实现的语句（anchor 为 null）不计入 mismatch，也不冒充已落实。
static func verify() -> Dictionary:
	var missing: Array = []
	var drifted: Array = []
	var mismatched: Array = []
	var checked := 0
	var lines_cache := {}
	for rel_path in Data.FILES:
		var path := absolute_path(rel_path)
		if not FileAccess.file_exists(path):
			missing.append(rel_path)
			continue
		checked += 1
		drifted.append_array(detect_drift(rel_path, Data.FILES[rel_path]))
		lines_cache[rel_path] = FileAccess.get_file_as_string(path).split("\n")
	for object_id in Data.OBJECTS:
		for statement in Data.OBJECTS[object_id]["statements"]:
			if not is_mapped(statement):
				continue
			var anchor: Dictionary = statement["anchor"]
			var rel_path := String(anchor["path"])
			var root := String(anchor.get("root", "external"))
			if not lines_cache.has(rel_path):
				var abs_path := absolute_path(rel_path, root)
				if not FileAccess.file_exists(abs_path):
					missing.append(rel_path)
					continue
				checked += 1
				lines_cache[rel_path] = FileAccess.get_file_as_string(abs_path).split("\n")
			var lines: Array = lines_cache[rel_path]
			var line_number: int = anchor.get("line", -1)
			var actual := ""
			if line_number >= 1 and line_number <= lines.size():
				actual = String(lines[line_number - 1]).strip_edges()
			if actual != statement["text"]:
				mismatched.append({
					"path": rel_path, "line": line_number,
					"expected": statement["text"], "actual": actual,
				})
	return {
		"ok": missing.is_empty() and drifted.is_empty() and mismatched.is_empty(),
		"checked": checked,
		"missing_paths": missing,
		"drifted_paths": drifted,
		"mismatched": mismatched,
	}


## 反向定位（全部认领者）：真实源码行 → 可能属于多个对象/流程/语句。
## 同一行被两个对象共用是正常的（例如 run() 入口既属任务信箱也属跑圈台），
## 所以这里返回数组而不是单值；阅读器要把所有认领者都显示出来。
static func owners_of(rel_path: String, line_number: int) -> Array:
	var out: Array = []
	for object_id in Data.OBJECTS:
		for statement in Data.OBJECTS[object_id]["statements"]:
			if not is_mapped(statement):
				continue
			var anchor: Dictionary = statement["anchor"]
			if String(anchor.get("path", "")) == rel_path and int(anchor.get("line", -1)) == line_number:
				out.append({
					"object_id": object_id,
					"process_id": statement["process"],
					"statement_id": statement["id"],
					"level1_title": Data.OBJECTS[object_id]["level1"]["title"],
				})
	return out


## 反向定位（主认领者）：只返回第一个，判空方便。多认领者用 owners_of()。
static func reverse(rel_path: String, line_number: int) -> Dictionary:
	var owners := owners_of(rel_path, line_number)
	return owners[0] if not owners.is_empty() else {}


## 覆盖数由数据推导：没有锚点的语句计入 unmapped，不算已落实。
static func coverage() -> Dictionary:
	var out := {}
	for object_id in Data.OBJECTS:
		var total := 0
		var mapped := 0
		var unmapped: Array = []
		for statement in Data.OBJECTS[object_id]["statements"]:
			total += 1
			if is_mapped(statement):
				mapped += 1
			else:
				unmapped.append(statement["id"])
		out[object_id] = {"mapped": mapped, "total": total, "unmapped_ids": unmapped}
	return out


## 某对象按流程分组的语句（供阅读器逐层展开）。
static func statements_of_process(object_id: String, process_id: String) -> Array:
	var out: Array = []
	var entry: Dictionary = object_entry(object_id)
	for statement in entry.get("statements", []):
		if statement["process"] == process_id:
			out.append(statement)
	return out


## 某文件当前被哪些对象引用（多对多关系：一个文件可支撑多个对象）。
static func objects_touching(rel_path: String) -> Array:
	var out: Array = []
	for object_id in Data.OBJECTS:
		for statement in Data.OBJECTS[object_id]["statements"]:
			if not is_mapped(statement):
				continue
			var anchor: Dictionary = statement["anchor"]
			if String(anchor.get("path", "")) == rel_path and not out.has(object_id):
				out.append(object_id)
	return out
