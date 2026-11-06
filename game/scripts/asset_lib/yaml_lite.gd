extends RefCounted

## 极简 YAML 子集解析器——只服务 assets/**/asset.yaml（本仓库机器生成的固定
## 格式），不追求通用。与 compiler 模块同约定：不用 class_name，消费方一律
## preload（见 tests/assets/run_asset_tests.gd）。
##
## 支持的语法刚好覆盖 asset.yaml 的写法：
##   - 两级映射（顶层 + defaults 嵌套）
##   - 块序列："- k: v" 起头的映射项，后续行缩进 +2 对齐；"- 标量" 项
##   - 内联列表 [a, b]（含空 []）
##   - 标量：int / float / true / false / null / 字符串（裸串与双引号串）
##   - 整行注释（# 开头）与空行
## 不支持的写法直接报错返回空——修 asset.yaml，不迁就解析器。


static func parse_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("yaml_lite: 无法打开 %s" % path)
		return {}
	var text := f.get_as_text()
	f.close()
	return parse(text)


static func parse(text: String) -> Dictionary:
	var lines := _tokenize(text)
	if lines.is_empty():
		push_error("yaml_lite: 没有可解析的行")
		return {}
	var result := _parse_node(lines, 0, int(lines[0]["indent"]))
	var value: Variant = result["value"]
	if not (value is Dictionary):
		push_error("yaml_lite: 顶层必须是映射")
		return {}
	if int(result["next"]) != lines.size():
		push_error("yaml_lite: 第 %d 行起无法归位（缩进不对齐？）" % int(result["next"]))
		return {}
	return value


# ---------- 内部 ----------

static func _tokenize(text: String) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw in text.split("\n"):
		var line := str(raw)
		var content := line.strip_edges()
		if content == "" or content.begins_with("#"):
			continue
		var indent := line.length() - line.lstrip(" \t").length()
		out.append({"indent": indent, "text": content})
	return out


static func _parse_node(lines: Array[Dictionary], i: int, indent: int) -> Dictionary:
	if str(lines[i]["text"]).begins_with("- "):
		return _parse_seq(lines, i, indent)
	return _parse_map(lines, i, indent)


static func _parse_map(lines: Array[Dictionary], i: int, indent: int) -> Dictionary:
	var dict := {}
	var next := i
	while next < lines.size():
		var ln: Dictionary = lines[next]
		if int(ln["indent"]) != indent or str(ln["text"]).begins_with("- "):
			break
		var colon := str(ln["text"]).find(":")
		if colon < 1:
			push_error("yaml_lite: 非法映射行 %r" % str(ln["text"]))
			return {"value": {}, "next": lines.size()}
		var key := str(ln["text"]).substr(0, colon).strip_edges()
		var rest := str(ln["text"]).substr(colon + 1).strip_edges()
		next += 1
		if rest != "":
			dict[key] = _parse_scalar(rest)
			continue
		if next < lines.size() and int(lines[next]["indent"]) > indent:
			var sub := _parse_node(lines, next, int(lines[next]["indent"]))
			dict[key] = sub["value"]
			next = int(sub["next"])
		elif next < lines.size() and int(lines[next]["indent"]) == indent \
				and str(lines[next]["text"]).begins_with("- "):
			var sub2 := _parse_seq(lines, next, indent)
			dict[key] = sub2["value"]
			next = int(sub2["next"])
		else:
			dict[key] = null
	return {"value": dict, "next": next}


static func _parse_seq(lines: Array[Dictionary], i: int, indent: int) -> Dictionary:
	var arr: Array = []
	var next := i
	while next < lines.size():
		var ln: Dictionary = lines[next]
		var text := str(ln["text"])
		if int(ln["indent"]) != indent or not text.begins_with("- "):
			break
		var item := text.substr(2).strip_edges()
		next += 1
		if item.begins_with("- "):
			push_error("yaml_lite: 不支持嵌套序列项 %r" % item)
			return {"value": arr, "next": lines.size()}
		elif item.find(":") > 0:
			# 映射项：把 "- k: v" 折成缩进 +2 的首行，与后续同缩进行合成映射
			var sub_lines: Array[Dictionary] = [{"indent": indent + 2, "text": item}]
			while next < lines.size() and int(lines[next]["indent"]) == indent + 2 \
					and not str(lines[next]["text"]).begins_with("- "):
				sub_lines.append(lines[next])
				next += 1
			var sub := _parse_map(sub_lines, 0, indent + 2)
			arr.append(sub["value"])
		else:
			arr.append(_parse_scalar(item))
	return {"value": arr, "next": next}


static func _parse_scalar(raw: String) -> Variant:
	var s := raw.strip_edges()
	if s.begins_with("[") and s.ends_with("]"):
		var inner := s.substr(1, s.length() - 2).strip_edges()
		var out: Array = []
		if inner == "":
			return out
		for part in inner.split(","):
			out.append(_parse_scalar(str(part)))
		return out
	if s.length() >= 2 and s.begins_with("\"") and s.ends_with("\""):
		return s.substr(1, s.length() - 2)
	if s == "true":
		return true
	if s == "false":
		return false
	if s == "null" or s == "~":
		return null
	var int_re := RegEx.create_from_string("^-?\\d+$")
	if int_re.search(s) != null:
		return int(s)
	var float_re := RegEx.create_from_string("^-?\\d+\\.\\d+$")
	if float_re.search(s) != null:
		return float(s)
	return s
