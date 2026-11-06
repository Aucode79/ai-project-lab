extends SceneTree

## machine_nav 回归：面包屑栈 push/pop_to/path_label（含同名模块「第 2 层」后缀）、
## drill_target 解析；以及 machine_view 的 build 产物在子模块视图上节点齐全、
## 每条边端口存在、wires 条目携带折线 path 且首尾等于两端端口位置。
## 纯 GDScript，不依赖后端与窗口。

const MachineNav := preload("res://scripts/lessons/machine_nav.gd")
const MachineView := preload("res://scripts/lessons/machine_view.gd")

var failed := 0

func _init() -> void:
	_run.call_deferred()

func _check(condition: bool, message: String) -> void:
	if not condition:
		failed += 1
		print("FAIL: " + message)

## 与 run_machine_view_tests._preset_root 同构的 fixture：main 调 agent，
## agent 再调 util——三层模块用来验证下钻与子模块视图组装。
func _fixture() -> Dictionary:
	return {"formatVersion": "module/1", "entry": "main", "modules": {
		"main": {"inputs": ["task"], "entry": "start", "nodes": [
			{"id": "task", "op": "input", "params": {"name": "task"}},
			{"id": "start", "op": "call", "module": "agent", "label": "Agent"},
			{"id": "done", "op": "return"}],
			"edges": [
				{"from": "task.value", "to": "start.task"},
				{"from": "start.next", "to": "done.exec"},
				{"from": "start.value", "to": "done.value"}]},
		"agent": {"inputs": ["task", "tools"], "entry": "c", "nodes": [
			{"id": "i", "op": "input", "params": {"name": "task"}},
			{"id": "c", "op": "call", "module": "util", "label": "Util"},
			{"id": "r", "op": "return"}],
			"edges": [
				{"from": "i.value", "to": "c.task"},
				{"from": "c.next", "to": "r.exec"},
				{"from": "c.value", "to": "r.value"}]},
		"util": {"inputs": ["task"], "entry": "n", "nodes": [
			{"id": "n", "op": "nop"}],
			"edges": []}}}

func _run() -> void:
	# ① 面包屑栈：push 追加且不改入参，pop_to 截断与钳制。
	var s0: Array = []
	var s1 := MachineNav.push(s0, "main", "main")
	var s2 := MachineNav.push(s1, "agent", "agent")
	_check(s0.is_empty(), "push leaves the input stack untouched")
	_check(s1.size() == 1 and s2.size() == 2, "push appends one segment per call")
	_check(str(s2[1].mid) == "agent" and str(s2[1].label) == "agent", "segment keeps mid and label")
	var back := MachineNav.pop_to(s2, 0)
	_check(back.size() == 1 and str(back[0].mid) == "main", "pop_to keeps the head segment")
	_check(MachineNav.pop_to(s2, -1).is_empty(), "pop_to below zero empties the stack")
	_check(MachineNav.pop_to(s2, 9).size() == 2, "pop_to clamps past the end")
	_check(s2.size() == 2, "pop_to leaves the input stack untouched")

	# ② path_label：连字与同名模块「第 N 层」后缀（首现不加）。
	_check(MachineNav.path_label([]) == "", "empty stack renders an empty path")
	_check(MachineNav.path_label(s2) == "main › agent", "single occurrence has no layer suffix")
	var s3 := MachineNav.push(s2, "agent", "agent")
	_check(MachineNav.path_label(s3) == "main › agent › agent 第 2 层",
		"repeated module gains the 第 2 层 suffix")
	var s4 := MachineNav.push(s3, "agent", "agent")
	_check(MachineNav.path_label(s4).ends_with("agent 第 3 层"), "third nesting counts up")

	# ③ drill_target：有则带出模块定义，无则 ok=false。
	var program := _fixture()
	var target := MachineNav.drill_target(program, "agent")
	_check(bool(target.ok) and str(target.module.get("entry", "")) == "c",
		"drill_target resolves an existing module")
	_check(not MachineNav.drill_target(program, "ghost").ok, "drill_target rejects an unknown module id")

	# ④ build("agent")：子模块视图节点齐全、每条边两端端口存在。
	var holder := Node3D.new()
	root.add_child(holder)
	var view := MachineView.build(holder, program, "agent", true, false)
	await process_frame
	var module: Dictionary = program.modules.agent
	_check(view.nodes.size() == module.nodes.size(), "submodule view builds every node")
	for n in module.nodes:
		_check(view.nodes.has(n.id), "node holder present: " + str(n.id))
	for edge in module.edges:
		_check(view.ports.has(edge.from) and view.ports.has(edge.to),
			"ports exist for edge " + str(edge.from) + " -> " + str(edge.to))
	_check(view.wires.size() == module.edges.size(), "one wire per edge")

	# ⑤ 实际通道是五点直角折线；四点 wire_path 仅供旧调用兼容。
	for w in view.wires:
		_check(w.has("path") and w.path.size() == 5, "wire carries the right-angle path: " + str(w.from))
		_check(w.path[0].distance_to(view.ports[w.from].position) < 0.001,
			"path starts at the from port: " + str(w.from))
		_check(w.path[w.path.size() - 1].distance_to(view.ports[w.to].position) < 0.001,
			"path ends at the to port: " + str(w.to))
	holder.free()
	await process_frame
	print("MACHINE NAV: ", "PASS" if failed == 0 else "FAIL", " failures=", failed)
	quit(0 if failed == 0 else 1)
