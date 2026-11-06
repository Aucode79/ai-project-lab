extends RefCounted

## 三维整机下钻的面包屑栈与目标解析（纯函数，无场景依赖）。
## 栈元素为 {mid, label}；path_label 用「 › 」连接各段，同一模块在路径里
## 重复出现时该段加「第 N 层」后缀，读作同一模块的第 N 次嵌套（首现不加）。

## 入栈：返回新数组，不改入参。
static func push(stack: Array, mid: String, label: String) -> Array:
	var next := stack.duplicate(true)
	next.append({"mid": mid, "label": label})
	return next


## 回退到第 index 段（保留 [0..index]）；index 越界按钳制处理，负数清空。
static func pop_to(stack: Array, index: int) -> Array:
	var next := []
	for i in stack.size():
		if i <= index: next.append(stack[i])
	return next


## 面包屑全文，如 "main › agent"；同名模块第 2 次起显示 "agent 第 2 层"。
static func path_label(stack: Array) -> String:
	var counts := {}
	var parts: Array = []
	for segment in stack:
		var mid := str(segment.get("mid", ""))
		var label := str(segment.get("label", mid))
		counts[mid] = int(counts.get(mid, 0)) + 1
		if int(counts[mid]) > 1: label += " 第 " + str(counts[mid]) + " 层"
		parts.append(label)
	return " › ".join(parts)


## 下钻目标解析：modules 里有该 id 才可下钻，返回 {ok, module}。
static func drill_target(program: Dictionary, mid: String) -> Dictionary:
	var module: Dictionary = program.get("modules", {}).get(mid, {})
	return {"ok": not module.is_empty(), "module": module}
