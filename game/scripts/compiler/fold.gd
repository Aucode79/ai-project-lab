extends RefCounted

## 方块编译器 · 折叠/展开（docs/10-契约/方块体系.md §6.3 折叠不变量）。
##
## fold/unfold 是头等操作，但**只动"折叠组"标记，绝不动连接与参数**：
## 同一连接图不同折叠层次编译出的 Python 必须完全相同——这条由
## 测试显式断言（run_compiler_tests.gd 的折叠不变量用例）。
## 重排不做自动布局（§6.4），fold 同样不做任何布局计算。


## 把 member_ids 折叠进 group_id（一级装配）。幂等：重复 fold 同组只是
## 合并成员集合。返回新图，不改入参。
static func fold(graph: Dictionary, group_id: String, member_ids: Array = []) -> Dictionary:
	var g: Dictionary = graph.duplicate(true)
	var groups: Array = g.get("fold_groups", [])
	var found := false
	for grp in groups:
		if String(grp.get("id", "")) == group_id:
			found = true
			var members: Array = grp.get("members", [])
			for m in member_ids:
				if not members.has(m):
					members.append(m)
			members.sort()
			grp["members"] = members
	if not found:
		var fresh: Array = []
		for m in member_ids:
			fresh.append(m)
		fresh.sort()
		groups.append({"id": group_id, "members": fresh})
	g["fold_groups"] = groups
	_mark_entities(g, member_ids, group_id)
	return g


## 展开 group_id：成员回到未分组，组本身移除。返回新图，不改入参。
static func unfold(graph: Dictionary, group_id: String) -> Dictionary:
	var g: Dictionary = graph.duplicate(true)
	var groups: Array = g.get("fold_groups", [])
	var kept: Array = []
	var removed_members: Array = []
	for grp in groups:
		if String(grp.get("id", "")) == group_id:
			for m in grp.get("members", []):
				if not removed_members.has(m):
					removed_members.append(m)
		else:
			kept.append(grp)
	g["fold_groups"] = kept
	_mark_entities(g, removed_members, "")
	return g


## 只改实体的 fold_group 视图标记；连接与参数一概不碰。
static func _mark_entities(g: Dictionary, member_ids: Array, group_id: String) -> void:
	for e in g.get("entities", []):
		if e is Dictionary and member_ids.has(String(e.get("id", ""))):
			if group_id == "":
				e.erase("fold_group")
			else:
				e["fold_group"] = group_id
