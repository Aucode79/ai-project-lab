extends RefCounted

## concepts.yaml 的最小读取器（求助系统 L2 诊断的数据源入口）。
## 只解析本仓库 concepts.yaml 实际用到的子集——
##   concepts: 列表里每条记录（spec 2026-09-13 §4.2）的
##     conceptId / label / fail（[{failId, condition 条件, symptom 可观测表现}]）
## **不是通用 YAML 解析器**：本文件结构是受控的（顶层块映射 + 两层缩进的
## 块序列 + 单行引号标量 + 空表 `[]`），按这个子集写；文件结构变化时改这里。
##
## concepts.yaml 在仓库根（game 工程外一层），路径由 default_path() 解析。
## 不用 class_name（同 fail_counter.gd 的注释）。

const FALLBACK_RES_PATH := "res://concepts.yaml"


## 仓库根的 concepts.yaml：从 res://（=game/）向上一层。
## 找不到时兜底 res://concepts.yaml（若日后把 yaml 拷进工程）。
static func default_path() -> String:
	var game_root := ProjectSettings.globalize_path("res://")
	var p := (game_root + "/../concepts.yaml").simplify_path()
	if FileAccess.file_exists(p):
		return p
	return FALLBACK_RES_PATH


## 解析整份 concepts 块。返回 { conceptId: {label: String, fail: Array} }，
## fail 条目形如 {failId, condition, symptom}；文件缺失/无法解析返回空表。
func load_concepts(path := "") -> Dictionary:
	if path == "":
		path = default_path()
	var out := {}
	if not FileAccess.file_exists(path):
		push_warning("concept_reader: 找不到 concepts.yaml：%s" % path)
		return out
	var in_concepts := false
	var mode := "field"            # field（概念字段层）| fail（fail 条目层）
	var current: Dictionary = {}   # 正在收的 concept 记录（引用进 out，后续字段就地写入）
	var current_fail: Dictionary = {}   # 正在收的 fail 条目（引用进 current["fail"]）
	for raw in FileAccess.get_file_as_string(path).split("\n"):
		var stripped := raw.strip_edges()
		if stripped == "" or stripped.begins_with("#"):
			continue
		var indent := _indent_of(raw)
		if indent == 0:
			# 顶层键：只有 concepts: 块要收；planned_assets 等其余块跳过
			in_concepts = (stripped == "concepts:")
			mode = "field"
			continue
		if not in_concepts:
			continue

		# fail 条目层：indent 6 的 "- failId: x" 开新条目，indent 8 收 condition/symptom
		if mode == "fail" and indent >= 6:
			if indent == 6 and stripped.begins_with("- "):
				var item_kv := _parse_kv(stripped.substr(2))
				if item_kv["key"] == "failId":
					current_fail = {"failId": item_kv["value"], "condition": "", "symptom": ""}
					(current["fail"] as Array).append(current_fail)
			elif indent == 8 and not current_fail.is_empty():
				var sub_kv := _parse_kv(stripped)
				if sub_kv["key"] == "condition" or sub_kv["key"] == "symptom":
					current_fail[sub_kv["key"]] = sub_kv["value"]
			continue

		# 概念字段层（或刚从 fail 层掉回来——本行按字段重新处理）
		mode = "field"
		if indent == 2 and stripped.begins_with("- "):
			var kv := _parse_kv(stripped.substr(2))
			if kv["key"] == "conceptId":
				current = {"conceptId": kv["value"], "label": "", "fail": []}
				out[kv["value"]] = current
		elif indent == 4 and not current.is_empty():
			var kv := _parse_kv(stripped)
			match kv["key"]:
				"label":
					current["label"] = kv["value"]
				"fail":
					# fail: [] 是空表（陈列概念用 contrast 替代，无 fail 条目）
					mode = "fail" if kv["value"] != "[]" else "field"
	return out


# ---------- 内部 ----------

static func _indent_of(line: String) -> int:
	var n := 0
	while n < line.length() and line[n] == " ":
		n += 1
	return n


## 取第一个 ": " 切 key/value（failId 值 "c10.1:1" 自带冒号但后面无空格，安全）。
## 裸键行（"fail:" / "knob:"，无值）没有 ": "：键去掉行尾冒号、值为空。
static func _parse_kv(s: String) -> Dictionary:
	var idx := s.find(": ")
	if idx < 0:
		return {"key": s.strip_edges().trim_suffix(":"), "value": ""}
	return {
		"key": s.substr(0, idx).strip_edges(),
		"value": _unquote(s.substr(idx + 2).strip_edges()),
	}


static func _unquote(v: String) -> String:
	if v.length() >= 2 and v.begins_with("\"") and v.ends_with("\""):
		return v.substr(1, v.length() - 2)
	if v.length() >= 2 and v.begins_with("'") and v.ends_with("'"):
		return v.substr(1, v.length() - 2)
	return v
