extends SceneTree

# 逐件状态总表：从数据生成，不手写，避免与代码漂移。
# $G --headless --path game -s res://tests/bright_loop/report_component_status.gd
const Specimens := preload("res://tests/bright_loop/bright_specimens.gd")
const Map := preload("res://scripts/interaction/unfolding_map.gd")
const Workbench := preload("res://scripts/interaction/bright_workbench.gd")


func _initialize() -> void:
	var in_scene := {}
	for id in Workbench.SPECIMEN_IDS:
		in_scene[id] = true
	var coverage: Dictionary = Map.coverage()
	var rows: Array = []
	var totals := {"mapped": 0, "total": 0, "external": 0, "repo": 0, "gap": 0, "events": 0}
	for index in Specimens.MACHINES.size():
		var machine: Dictionary = Specimens.MACHINES[index]
		var id := String(machine.id)
		var row: Dictionary = coverage.get(id, {"mapped": 0, "total": 0})
		var files := {}
		var external := 0
		var repo := 0
		var gap := 0
		var events := 0
		var entry: Dictionary = Map.object_entry(id)
		for statement in entry.get("statements", []):
			if not Map.is_mapped(statement):
				gap += 1
				continue
			var root := String(statement["anchor"].get("root", "external"))
			files[String(statement["anchor"]["path"])] = true
			if root == "repo":
				repo += 1
			else:
				external += 1
			events += (statement.get("events", []) as Array).size()
		totals["mapped"] += int(row["mapped"])
		totals["total"] += int(row["total"])
		totals["external"] += external
		totals["repo"] += repo
		totals["gap"] += gap
		totals["events"] += events
		rows.append({
			"id": id, "zh": machine.zh, "en": machine.en, "cat": machine.cat,
			"boxes": machine.boxes.size(),
			"scene": in_scene.has(id),
			"label": machine.has("label_lines"),
			"mapped": int(row["mapped"]), "total": int(row["total"]),
			"external": external, "repo": repo, "gap": gap,
			"files": files.keys().size(), "events": events,
		})
	print("| 对象 | 类别 | 盒体 | 字砖 | 场景 | 四层：已落实/声明 | 外部 | 本仓 | 缺口 | 事件键 |")
	print("|---|---|---|---|---|---|---|---|---|---|")
	for row in rows:
		print("| %s %s | %s | %d | %s | %s | %d/%d | %d | %d | %d | %d |" % [
			row["zh"], row["en"], row["cat"], row["boxes"],
			"有" if row["label"] else "无", "在" if row["scene"] else "不在",
			row["mapped"], row["total"], row["external"], row["repo"], row["gap"], row["events"]])
	print("| **合计** | 26 件 | — | — | — | **%d/%d** | %d | %d | %d | %d |" % [
		totals["mapped"], totals["total"], totals["external"], totals["repo"],
		totals["gap"], totals["events"]])
	print("OBJECTS: %d | in-scene: %d | with-gap: %d" % [rows.size(), in_scene.size(),
		rows.filter(func(r): return int(r["gap"]) > 0).size()])
	quit(0)
