extends SceneTree

const Workbench := preload("res://scripts/interaction/bright_workbench.gd")
var failed := 0
var passed := 0

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, message: String) -> void:
	if ok:
		passed += 1
	else:
		failed += 1
		print("FAIL: " + message)

func run() -> void:
	var stage := Workbench.new()
	root.add_child(stage)
	await physics_frame
	await physics_frame
	check(stage.hub.run.is_inside_tree(), "run controller is owned and freed with the hub")
	var predictor = stage.hub.predictor
	predictor.setup()
	var captured: int = predictor.capture_statics_from(stage, Vector3(9, 0, 18), 1000.0)
	check(captured >= 27, "prediction contains floor and frozen components")
	var item := stage.items[0]
	stage.hub.drag.begin_drag(item, str(item.name), item.global_position)
	var ghost: MeshInstance3D = stage.hub.drag._ghost
	check(ghost.get_aabb().size.is_equal_approx(stage.hub.drag._bounds.size), "ghost preserves full nested component silhouette bounds")
	stage.hub.drag.validator = func(_pose): return false
	stage.hub.drag._finish_drop()
	var label := stage.labels[0]
	var before: Vector3 = label.global_position
	item.position.x += 1.0
	await physics_frame
	await process_frame
	check(is_equal_approx(label.global_position.x - before.x, 1.0), "name tile follows moved component")
	var last := stage.items[-1]
	var query := PhysicsRayQueryParameters3D.create(last.global_position + Vector3(0, 10, 0), last.global_position - Vector3(0, 20, 0))
	query.exclude = [last.get_rid()]
	var hit := stage.get_world_3d().direct_space_state.intersect_ray(query)
	check(not hit.is_empty(), "last row has a real floor beneath it")
	stage._show_page(0)
	await physics_frame
	var glyph: MeshInstance3D = label.get_child(0)
	var screen := stage.camera.unproject_position(glyph.global_position)
	check(stage.hub._pick_body(screen) == item, "clicking a name tile resolves to its moving component")
	# Exercise every assembly through the real settle/commit path, including the 9 m screen.
	for body in stage.items:
		stage.hub.drag.validator = Callable()
		var initial: Transform3D = body.global_transform
		var count_before: int = stage.hub.drag.land_report_count()
		stage.hub.predictor.clear_statics()
		stage.hub.predictor.capture_statics_from(stage, body.global_position, 24, body)
		stage.hub.drag.begin_drag(body, str(body.name), body.global_position + Vector3(0, 0.5, -1))
		for tick in 36: await physics_frame
		stage.hub.drag._last_hand_ms = Time.get_ticks_msec() - 600
		stage.hub.drag.release()
		for tick in 300:
			await physics_frame
			if stage.hub.drag.state() == stage.hub.drag.DragState.IDLE: break
		check(body.freeze and stage.hub.drag.land_report_count() == count_before + 1, "%s real physical relocation accepted" % body.name)
		body.global_transform = initial
	# Saved layouts round-trip without serializing code or pretending to run an agent.
	var path := "user://test_component_layout.json"
	check(stage.save_layout(path), "layout saves")
	var saved: Vector3 = item.position
	item.position.x += 2
	check(stage.load_layout(path) and item.position.is_equal_approx(saved), "layout restores exact assembly position")
	DirAccess.remove_absolute(path)
	var reader = stage.reader
	var widest := 0
	for object_id in stage.Map.objects():
		var entry: Dictionary = stage.Map.object_entry(object_id)
		for process in entry.processes:
			var count: int = stage.Map.statements_of_process(object_id, process.id).size()
			if count > widest:
				widest = count
				reader.reset(object_id)
				reader.process_id = process.id
				reader.stage = reader.STAGE_PROCESS
	check(reader.select_choice(widest - 1), "mouse navigation reaches the last statement beyond numeric shortcuts")
	stage.free()
	await process_frame
	print("WORKBENCH FINISH TOTAL: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)
