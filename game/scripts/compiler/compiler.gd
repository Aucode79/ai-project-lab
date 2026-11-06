extends RefCounted

## 方块编译器 · 门面（正式交付物，docs/10-契约/方块体系.md §6.2 / 原 spec §9 新增清单）。
##
## compile(graph_dict) -> {ok: bool, python: String, errors: Array, warnings: Array, ir_hash: String}
##
## errors 阻断产码；warnings（如 MULTI_DATA_IN_EDGE）不阻断，仅供拼装 UI 提示。
##
## 契约：
## - 输入：连接图 + 参数 + 装配层次（Dictionary，JSON 形状）。
## - 不读位置与朝向：图在入口处规范化（丢弃坐标），同逻辑不同摆法
##   输出字节级相同。
## - 编译期校验一次返回**全部**错误（拼装即时反馈的数据源），每条
##   {code, entity_id, port_ref, message}；有错时不产码。codegen 层错误
##   （如 FANOUT_ITEM_NAME_COLLISION）并入同一 errors 数组，同样阻断产码。
## - 确定性：同一连接图 → 相同 ir_hash 与相同 python（可哈希对比）；
##   折叠层次不影响两者（折叠不变量，§6.3）。
##
## 用法（无 class_name，统一 preload）：
##   const COMPILER := preload("res://scripts/compiler/compiler.gd")
##   var r := COMPILER.compile(graph_dict)

const GM := preload("res://scripts/compiler/graph_model.gd")
const IRB := preload("res://scripts/compiler/ir.gd")
const VAL := preload("res://scripts/compiler/validate.gd")
const CPG := preload("res://scripts/compiler/codegen_python.gd")


## 主入口：连接图 Dictionary → 编译结果。
static func compile(graph_dict: Dictionary) -> Dictionary:
	if graph_dict.get("formatVersion", "") == "module/1":
		return preload("res://scripts/compiler/module_program.gd").compile(graph_dict)
	var graph = GM.parse(graph_dict)
	if graph == null:
		return {
			"ok": false,
			"python": "",
			"errors": [{"code": "PARSE_ERROR", "entity_id": "", "port_ref": "", "message": "图字典无法解析"}],
			"warnings": [],
			"ir_hash": "",
		}
	var warnings := VAL.warnings(graph)
	var errors := VAL.validate(graph)
	if not errors.is_empty():
		return {"ok": false, "python": "", "errors": errors, "warnings": warnings, "ir_hash": ""}
	var ir := IRB.build(graph)
	# codegen 层硬错误（如 FANOUT_ITEM_NAME_COLLISION）与 validate 错误同走
	# errors：generate 返回 {python, errors}，有错同样阻断产码。
	var gen: Dictionary = CPG.generate(graph, ir)
	if not (gen["errors"] as Array).is_empty():
		return {"ok": false, "python": "", "errors": gen["errors"], "warnings": warnings, "ir_hash": ""}
	return {"ok": true, "python": gen["python"], "errors": [], "warnings": warnings, "ir_hash": IRB.sha256_hex(ir.canonical_text())}


## 从 JSON 文本编译（等价于 parse 后 compile）。
static func compile_json(graph_json: String) -> Dictionary:
	var parsed: Variant = JSON.parse_string(graph_json)
	if parsed is Dictionary:
		return compile(parsed)
	return {
		"ok": false,
		"python": "",
		"errors": [{"code": "PARSE_ERROR", "entity_id": "", "port_ref": "", "message": "JSON 解析失败"}],
		"warnings": [],
		"ir_hash": "",
	}
