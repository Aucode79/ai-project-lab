extends SceneTree

var passed := 0
var failed := 0

class DelayedL1:
	extends "res://scripts/levels/l1/l1_scene.gd"
	var ground_ready := false
	func _world_ready() -> bool:
		return ground_ready

func _initialize() -> void:
	run.call_deferred()

func check(ok: bool, title: String) -> void:
	if ok: passed += 1
	else:
		failed += 1
		print("FAIL: ", title)

func run() -> void:
	# A late terrain callback must not release an object already held by the user.
	var delayed := DelayedL1.new()
	root.add_child(delayed)
	await process_frame
	var block := delayed.get_node("Workstation/LooseBlock1") as RigidBody3D
	var hub = delayed.get_interaction_hub()
	hub.drag.begin_drag(block, "drag_block#1", block.global_position)
	delayed.ground_ready = true
	for tick in 4: await process_frame
	check(block.freeze, "late terrain readiness preserves the held block freeze")
	hub.drag.cancel_drag()
	delayed.free()
	await process_frame
	for number in range(2, 6):
		var scene: Node3D = load("res://scenes/levels/l%d/l%d.tscn" % [number, number]).instantiate()
		root.add_child(scene)
		for method in scene.get_method_list():
			if str(method.name).begins_with("install_") and method.args.is_empty(): scene.call(method.name)
		await process_frame
		await physics_frame
		check(scene._orbit_cam != null and scene._orbit_cam.has_method("zoom_by"), "L%d has an interactive orbit camera" % number)
		var bad: Array[String] = []
		scan(scene, Transform3D.IDENTITY, bad)
		check(bad.is_empty(), "L%d component rotations are quarter turns: %s" % [number, bad])
		scene.free()
		await process_frame
	print("LESSON VIEW TOTAL: %d passed, %d failed" % [passed, failed])
	quit(1 if failed else 0)

func scan(node: Node, parent: Transform3D, bad: Array[String]) -> void:
	var xf: Transform3D = parent * node.transform if node is Node3D else parent
	if node is MeshInstance3D:
		var angles := xf.basis.get_euler()
		for axis in 3:
			if absf(angles[axis] / (PI / 2) - roundf(angles[axis] / (PI / 2))) > 0.001:
				bad.append(str(node.name))
				break
	for child in node.get_children(): scan(child, xf, bad)
