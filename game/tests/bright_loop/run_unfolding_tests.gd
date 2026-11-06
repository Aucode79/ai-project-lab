extends SceneTree

# Four-level unfolding contract: function -> process -> statement -> real source line.
# Anchors are checked against the actual files on disk; nothing passes by construction.
const MAP := "res://scripts/interaction/unfolding_map.gd"
const REQUIRED_OBJECTS := ["agent_loop_table", "agent_memory_rack", "agent_model_well",
	"agent_execution_table", "agent_task_dock", "agent_answer_dock", "agent_budget_rail",
	"agent_tool_rack", "agent_observation_tray", "agent_state_cabinet", "agent_plan_steps",
	"agent_argument_gate", "code_assign", "code_call", "code_branch", "code_loop",
	"code_define", "code_read", "code_guard", "code_return", "agent_message_table",
	"agent_parallel_bridge", "studio_text_tile", "studio_flow_strip", "studio_session_walker",
	"studio_lesson_screen"]
var passed := 0
var failed := 0
var skipped := 0

func _initialize() -> void:
	check(FileAccess.file_exists(MAP), "unfolding map exists")
	if not FileAccess.file_exists(MAP):
		finish()
		return
	var map = load(MAP)
	check(map != null, "unfolding map parses")
	if map == null:
		finish()
		return
	var root: String = map.source_root()
	# Every mapped file must be readable before any anchor claim is checked.
	var missing: Array = []
	for rel_path in map.file_hashes():
		if not FileAccess.file_exists(map.absolute_path(rel_path)):
			missing.append(rel_path)
	if not missing.is_empty():
		skipped += 1
		print("SKIP: external sources not present under %s: %s" % [root, str(missing)])
		finish()
		return
	var lines_of := {}
	for rel_path in map.file_hashes():
		lines_of[rel_path] = FileAccess.get_file_as_string(map.absolute_path(rel_path)).split("\n")
	check(map.objects().size() == 26, "the whole 26-object catalogue is present in the map")
	for object_id in REQUIRED_OBJECTS:
		check(object_id in map.objects(), "approved specimen is mapped: %s" % object_id)
	for object_id in map.objects():
		var entry: Dictionary = map.object_entry(object_id)
		check(entry.has("level1") and entry["level1"].has("title") and entry["level1"].has("summary"), "%s states level 1" % object_id)
		# 少量流程是允许的（回音盘就是「捕获 / 回填」两面）；已经完全没有实现的设施
		# 只能有 1 个「尚未实现」流程，但它必须在 coverage 里显式留缺口。
		var gap_count := 0
		for statement in entry.get("statements", []):
			if not map.is_mapped(statement):
				gap_count += 1
		var minimum_processes := 1 if gap_count > 0 else 2
		check(entry.get("processes", []).size() >= minimum_processes, "%s splits into real processes" % object_id)
		check(entry.get("statements", []).size() >= 1, "%s declares its statements" % object_id)
		var declared := {}
		for process in entry["processes"]:
			declared[process["id"]] = true
		var owned_lines := {}
		for statement in entry["statements"]:
			check(declared.has(statement["process"]), "%s statement %s belongs to a declared process" % [object_id, statement["id"]])
			if not map.is_mapped(statement):
				check(String(statement.get("reason", "")) != "", "%s unmapped statement %s carries a reason" % [object_id, statement["id"]])
				check(statement["anchor"] == null, "%s unmapped statement has no anchor" % object_id)
				continue
			var anchor: Dictionary = statement["anchor"]
			var rel_path := String(anchor["path"])
			var anchor_root := String(anchor.get("root", "external"))
			if anchor_root != "repo":
				check(map.file_hashes().has(rel_path), "%s anchor points at a hashed external file" % object_id)
			var line_number: int = anchor["line"]
			if not lines_of.has(rel_path):
				lines_of[rel_path] = FileAccess.get_file_as_string(map.absolute_path(rel_path, anchor_root)).split("\n")
			var file_lines: Array = lines_of[rel_path]
			check(line_number >= 1 and line_number <= file_lines.size(), "%s anchor line in range: %s:%d" % [object_id, rel_path, line_number])
			if line_number >= 1 and line_number <= file_lines.size():
				var actual: String = String(file_lines[line_number - 1]).strip_edges()
				check(actual == statement["text"], "%s:%d text matches source: %s" % [rel_path, line_number, actual])
			# 同一对象内一行只认领一次；跨对象共用是允许的（真实代码就是一行的多重身份）。
			var owned_key := "%s:%d" % [rel_path, line_number]
			check(not owned_lines.has(owned_key), "%s owns %s once" % [object_id, owned_key])
			owned_lines[owned_key] = true
			var owners: Array = map.owners_of(rel_path, line_number)
			var matched := false
			for owner in owners:
				matched = matched or (owner.get("object_id", "") == object_id and owner.get("statement_id", "") == statement["id"])
			check(matched, "%s:%d reverse lists this statement among its owners" % [rel_path, line_number])
			check(map.reverse(rel_path, line_number).get("object_id", "") != "", "%s:%d has a primary owner" % [rel_path, line_number])
	# 共用行必须真实存在：run() 入口同时属于任务信箱、跑圈台与体力尺。
	var shared: Array = map.owners_of("src/smolagents/agents.py", 468)
	var shared_objects: Array = []
	for owner in shared:
		shared_objects.append(owner["object_id"])
	check(shared.size() >= 2, "a shared source line has multiple owners: %s" % str(shared_objects))
	check(shared_objects.has("agent_task_dock") and shared_objects.has("agent_loop_table"), "shared line names both objects")
	# 一个对象可以跨文件（体力尺：agents.py 的步数 + executor 的操作数/墙钟）。
	var budget_files := {}
	for statement in map.object_entry("agent_budget_rail")["statements"]:
		budget_files[String(statement["anchor"]["path"])] = true
	check(budget_files.size() >= 2, "an object may span multiple source files: %s" % str(budget_files.keys()))
	# The loop object must own its收尾 paths, not delegate them to nowhere.
	var loop_texts := []
	for statement in map.object_entry("agent_loop_table")["statements"]:
		loop_texts.append(statement["text"])
	for required in ["finally:", "except AgentError as e:", "self.step_number += 1",
			"self.memory.steps.append(action_step)", "self._handle_max_steps_reached(task)"]:
		var owned := false
		for text in loop_texts:
			owned = owned or String(text).contains(required)
		check(owned, "loop object owns the statement: %s" % required)
	# Multi-file linkage: one object per file is not enough; files may serve several objects.
	check(map.objects_touching("src/smolagents/agents.py").size() >= 1, "file-to-object link is queryable")
	# Drift detection: recorded hashes must equal the files actually on disk.
	var verify: Dictionary = map.verify()
	check(verify["checked"] >= 4, "verify read every mapped file: %d" % verify["checked"])
	check(verify["mismatched"].is_empty(), "no anchor text mismatches: %s" % str(verify["mismatched"]))
	check(verify["drifted_paths"].is_empty(), "recorded hashes match the worktree: %s" % str(verify["drifted_paths"]))
	check(verify["missing_paths"].is_empty(), "no missing source files: %s" % str(verify["missing_paths"]))
	# Coverage numbers are derived from data, and unmapped entries stay visible.
	var coverage: Dictionary = map.coverage()
	var total_statements := 0
	for object_id in coverage:
		var row: Dictionary = coverage[object_id]
		check(row["mapped"] == row["total"] or not row["unmapped_ids"].is_empty(), "%s either fully mapped or openly declares gaps" % object_id)
		check(row["mapped"] <= row["total"], "%s mapped never exceeds total" % object_id)
		total_statements += int(row["total"])
	check(total_statements >= 280, "twenty objects map a substantial statement set: %d" % total_statements)
	# 未实现声明必须带原因，且数量与 coverage 的 unmapped 一致。
	var declarations: Array = map.unmapped_declarations()
	check(declarations.size() == 2, "exactly the two unimplemented facilities declare a gap: %d" % declarations.size())
	for declaration in declarations:
		check(String(declaration["reason"]).length() >= 10, "gap %s explains why" % declaration["statement_id"])
		check(String(declaration["object_id"]).begins_with("studio_"), "gap belongs to a facility: %s" % declaration["object_id"])
	var declared_total := 0
	for object_id in coverage:
		declared_total += (coverage[object_id]["unmapped_ids"] as Array).size()
	check(declared_total == declarations.size(), "coverage unmapped count matches the declared gaps")
	# A synthetic drifted hash must be reported, not silently accepted.
	var drifted: Array = map.detect_drift("src/smolagents/agents.py", "sha256-not-the-real-hash")
	check(not drifted.is_empty(), "hash mismatch is detected as drift")
	finish()

func check(condition: bool, label: String) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		print("FAIL: " + label)

func finish() -> void:
	print("UNFOLDING TOTAL: %d passed, %d failed, %d skipped" % [passed, failed, skipped])
	quit(0 if failed == 0 else 1)
