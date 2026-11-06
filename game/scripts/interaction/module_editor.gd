extends PanelContainer

## Edits the same module document compiled and executed by lab_service.
## 端口表与类型判定复用 machine_view（Godot 侧唯一真源）；参数用具名字段编辑。
signal saved(program: Dictionary)
signal closed
const STYLE := preload("res://scripts/asset_lib/asset_style.gd")
const MachineView := preload("res://scripts/lessons/machine_view.gd")
var program: Dictionary
var revision := 0
var current := "main"
var tools_catalog: Array = []
var history: Array[String] = []
var graph: GraphEdit
var module_select: OptionButton
var operation: OptionButton
var status: Label
var interface_edit: LineEdit
var input_ports := {}
var output_ports := {}
var building := false
var selected: Array[String] = []
var counter := 0
var detail: TextEdit
var source_port: OptionButton
var target_port: OptionButton
var recorded_events: Array = []

func _ready() -> void:
	theme = STYLE.ui_theme()
	var backdrop := StyleBoxFlat.new()
	backdrop.bg_color = Color("18343d")
	add_theme_stylebox_override("panel", backdrop)
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var column := VBoxContainer.new()
	add_child(column)
	var toolbar := HBoxContainer.new()
	column.add_child(toolbar)
	_button(toolbar, "← 返回上层", func():
		if not history.is_empty():
			current = history.pop_back()
			rebuild())
	module_select = OptionButton.new()
	toolbar.add_child(module_select)
	module_select.item_selected.connect(func(i: int): enter(module_select.get_item_text(i)))
	_button(toolbar, "保存", save_program)
	_button(toolbar, "查看生成代码", show_code)
	_button(toolbar, "复制当前定义", duplicate_module)
	_button(toolbar, "封装选中节点", extract_selection)
	_button(toolbar, "关闭", func(): closed.emit(); queue_free())
	var row := HBoxContainer.new()
	column.add_child(row)
	operation = OptionButton.new()
	for op in MachineView.PORTS: operation.add_item(op)
	row.add_child(operation)
	_button(row, "添加节点", add_node)
	_button(row, "新建模块", new_module)
	var label := Label.new()
	label.text = "模块输入接口（JSON 数组）"
	row.add_child(label)
	interface_edit = LineEdit.new()
	interface_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(interface_edit)
	_button(row, "更新接口", func():
		var value: Variant = JSON.parse_string(interface_edit.text)
		if value is Array:
			program.modules[current].inputs = value
			rebuild())
	status = Label.new()
	status.text = "橙线 = 控制顺序；蓝线 = 数据。拖动端口连线，从已连接的输入口拖出断线。内部定义由所有调用共享。"
	column.add_child(status)
	var connections := HBoxContainer.new()
	column.add_child(connections)
	source_port = OptionButton.new()
	source_port.custom_minimum_size.x = 235
	connections.add_child(source_port)
	target_port = OptionButton.new()
	target_port.custom_minimum_size.x = 235
	connections.add_child(target_port)
	_button(connections, "连接端口", func(): edit_connection(false))
	_button(connections, "断开端口", func(): edit_connection(true))
	_button(connections, "查看端口运行数据", inspect_connection)
	graph = GraphEdit.new()
	var graph_backdrop := StyleBoxFlat.new()
	graph_backdrop.bg_color = Color("213b43")
	graph.add_theme_stylebox_override("panel", graph_backdrop)
	graph.size_flags_vertical = Control.SIZE_EXPAND_FILL
	graph.right_disconnects = true
	graph.connection_request.connect(connect_ports)
	graph.disconnection_request.connect(disconnect_ports)
	graph.node_selected.connect(func(n: Node):
		if not selected.has(str(n.name)): selected.append(str(n.name))
		inspect_node(str(n.name)))
	graph.node_deselected.connect(func(n: Node): selected.erase(str(n.name)))
	graph.delete_nodes_request.connect(delete_nodes)
	column.add_child(graph)
	detail = TextEdit.new()
	detail.custom_minimum_size.y = 105
	detail.editable = false
	column.add_child(detail)
	rebuild()

func _button(parent: Node, text: String, action: Callable) -> void:
	var b := Button.new()
	b.text = text
	b.pressed.connect(action)
	parent.add_child(b)

func request(path: String, payload: Dictionary) -> Dictionary:
	var http := HTTPRequest.new()
	add_child(http)
	var err := http.request("http://127.0.0.1:7332" + path, ["Content-Type: application/json"], HTTPClient.METHOD_POST, JSON.stringify(payload))
	if err != OK:
		http.queue_free()
		return {"ok": false, "error": "连接服务失败"}
	var reply: Array = await http.request_completed
	http.queue_free()
	var parsed: Variant = JSON.parse_string((reply[3] as PackedByteArray).get_string_from_utf8())
	return parsed if parsed is Dictionary else {"ok": false, "error": "响应格式错误"}

func enter(id: String) -> void:
	if not program.modules.has(id): return
	history.append(current)
	current = id
	rebuild()

func pins(n: Dictionary) -> Array:
	return MachineView.pins(n, program.modules)

func outputs(n: Dictionary) -> Array:
	return MachineView.outputs(n)

func rebuild() -> void:
	building = true
	graph.clear_connections()
	for child in graph.get_children():
		if child is GraphNode:
			graph.remove_child(child)
			child.queue_free()
	selected.clear()
	input_ports.clear()
	output_ports.clear()
	module_select.clear()
	for mid in program.modules:
		module_select.add_item(mid)
		if mid == current: module_select.select(module_select.item_count - 1)
	if not program.modules.has(current):
		current = str(program.get("entry", program.modules.keys()[0] if not program.modules.is_empty() else "main"))
		if not program.modules.has(current):
			building = false
			return
	interface_edit.text = JSON.stringify(program.modules[current].inputs)
	var index := 0
	for n in program.modules[current].nodes:
		var box := GraphNode.new()
		box.name = n.id
		box.title = n.get("label", n.id) + " · " + n.op
		box.custom_minimum_size.x = 225
		var pos: Array = program.get("layout", {}).get(current + "/" + n.id, [60.0 + float(index % 4) * 300, 70.0 + float(index / 4) * 325])
		box.position_offset = Vector2(pos[0], pos[1])
		var ins: Array = ([] if n.op in MachineView.PURE else ["exec"]) + pins(n)
		var outs: Array = outputs(n)
		input_ports[n.id] = ins
		output_ports[n.id] = outs
		for i in maxi(ins.size(), outs.size()):
			var row := Label.new()
			row.text = (str(ins[i]) if i < ins.size() else "") + "   →   " + (str(outs[i]) if i < outs.size() else "")
			box.add_child(row)
			var it := 0 if i < ins.size() and ins[i] == "exec" else 1
			var ot := 1 if i >= outs.size() or outs[i] == "value" else 0
			box.set_slot(i, i < ins.size(), it, Color("e6a353") if it == 0 else Color("36b2ce"), i < outs.size(), ot, Color("e6a353") if ot == 0 else Color("36b2ce"))
		if n.op in ["call", "trycall"]:
			var target := OptionButton.new()
			for mid in program.modules:
				target.add_item(mid)
				if mid == n.get("module", ""): target.select(target.item_count - 1)
			target.item_selected.connect(func(i: int): n.module = target.get_item_text(i); rebuild.call_deferred())
			box.add_child(target)
			_button(box, "进入共享定义 ↗", func(): enter(n.get("module", "")))
		var title_edit := LineEdit.new()
		title_edit.text = n.get("label", n.id)
		title_edit.placeholder_text = "节点名称"
		title_edit.text_changed.connect(func(value: String): n.label = value)
		box.add_child(title_edit)
		_param_fields(box, n)
		if n.op not in MachineView.PURE:
			_button(box, "设为模块入口" + (" ✓" if program.modules[current].entry == n.id else ""), func():
				program.modules[current].entry = n.id
				rebuild.call_deferred())
		graph.add_child(box)
		box.position_offset_changed.connect(func():
			if not building:
				program.layout[current + "/" + n.id] = [box.position_offset.x, box.position_offset.y])
		index += 1
	for edge in program.modules[current].edges:
		var a: PackedStringArray = edge.from.split(".")
		var b: PackedStringArray = edge.to.split(".")
		if a.size() != 2 or b.size() != 2: continue
		if not output_ports.has(a[0]) or not input_ports.has(b[0]): continue
		var ai: int = output_ports[a[0]].find(a[1])
		var bi: int = input_ports[b[0]].find(b[1])
		if ai >= 0 and bi >= 0: graph.connect_node(a[0], ai, b[0], bi)
	source_port.clear()
	target_port.clear()
	for id in output_ports:
		for pin in output_ports[id]: source_port.add_item(id + "." + pin)
	for id in input_ports:
		for pin in input_ports[id]: target_port.add_item(id + "." + pin)
	building = false

func connect_ports(a: StringName, ai: int, b: StringName, bi: int) -> void:
	if not output_ports.has(str(a)) or not input_ports.has(str(b)): return
	var from_pin: String = output_ports[str(a)][ai]
	var to_pin: String = input_ports[str(b)][bi]
	if not MachineView.ports_compatible(from_pin, to_pin):
		status.text = "连线被拒绝：控制端口与数据端口不能混接"
		return
	var edge := {"from": str(a) + "." + from_pin, "to": str(b) + "." + to_pin}
	if not program.modules[current].edges.has(edge): program.modules[current].edges.append(edge)
	graph.connect_node(a, ai, b, bi)
	status.text = "已连线；保存后下一次运行生效"

func disconnect_ports(a: StringName, ai: int, b: StringName, bi: int) -> void:
	program.modules[current].edges.erase({"from": str(a) + "." + str(output_ports[str(a)][ai]), "to": str(b) + "." + str(input_ports[str(b)][bi])})
	graph.disconnect_node(a, ai, b, bi)
	status.text = "已断开；保存后下一次运行生效"

func delete_nodes(ids: Array[StringName]) -> void:
	var module: Dictionary = program.modules[current]
	module.nodes = module.nodes.filter(func(n): return not ids.has(StringName(n.id)))
	module.edges = module.edges.filter(func(e): return not ids.has(StringName(e.from.get_slice(".", 0))) and not ids.has(StringName(e.to.get_slice(".", 0))))
	rebuild()

func fresh(prefix: String) -> String:
	counter += 1
	return prefix + "_" + str(Time.get_ticks_msec()) + "_" + str(counter)

func add_node() -> void:
	var op := operation.get_item_text(operation.selected)
	var n := {"id": fresh("n"), "op": op, "params": {}}
	if op in ["call", "trycall"]: n.module = current
	if op == "const": n.params = {"value": 0}
	if op == "input": n.params = {"name": "value"}
	if op in ["list", "object", "tools"]: n.params = {"fields": ["a", "b"]}
	if op == "get": n.params = {"key": "value"}
	if op == "tool": n.params = {"name": "fs.read"}
	program.modules[current].nodes.append(n)
	rebuild()

## 结构化参数编辑：常用操作给具名字段，未覆盖的键回退 JSON 行。
func _param_fields(box: GraphNode, n: Dictionary) -> void:
	match n.op:
		"const": _field_json(box, n, "value", "常量值（JSON）")
		"input": _field_text(box, n, "name", "接口名")
		"tool": _field_tools(box, n)
		"get": _field_text(box, n, "key", "字段名")
		"message": _field_enum(box, n, "role", "消息角色", ["user", "assistant", "system", "tool"])
		"list", "object", "tools": _field_csv(box, n, "fields", "字段列表（逗号分隔）")
		_:
			if n.get("params", {}).is_empty(): return
			var params_line := LineEdit.new()
			params_line.text = JSON.stringify(n.params)
			params_line.tooltip_text = "其余参数 JSON"
			params_line.text_submitted.connect(func(value: String):
				var parsed: Variant = JSON.parse_string(value)
				if parsed is Dictionary: n.params = parsed; rebuild.call_deferred()
				else: status.text = "参数必须是 JSON 对象")
			box.add_child(params_line)

func _labeled(parent: Node, caption: String) -> void:
	var label := Label.new()
	label.text = caption
	label.add_theme_font_size_override("font_size", 13)
	parent.add_child(label)

func _field_text(box: GraphNode, n: Dictionary, key: String, caption: String) -> void:
	_labeled(box, caption)
	var field := LineEdit.new()
	field.text = str(n.get("params", {}).get(key, ""))
	field.text_submitted.connect(func(value: String):
		n.params[key] = value
		status.text = "参数已更新：" + key)
	box.add_child(field)

func _field_json(box: GraphNode, n: Dictionary, key: String, caption: String) -> void:
	_labeled(box, caption)
	var field := LineEdit.new()
	field.text = JSON.stringify(n.get("params", {}).get(key, null))
	field.text_submitted.connect(func(value: String):
		var parsed: Variant = JSON.parse_string(value)
		if parsed == null and value.strip_edges() != "null":
			status.text = caption + " 需要是合法 JSON 值"
			return
		n.params[key] = parsed
		status.text = "参数已更新：" + key)
	box.add_child(field)

func _field_csv(box: GraphNode, n: Dictionary, key: String, caption: String) -> void:
	_labeled(box, caption)
	var field := LineEdit.new()
	field.text = ",".join(PackedStringArray(n.get("params", {}).get(key, [])))
	field.text_submitted.connect(func(value: String):
		var fields := value.split(",", false)
		for i in fields.size(): fields[i] = fields[i].strip_edges()
		n.params[key] = fields
		rebuild.call_deferred())
	box.add_child(field)

func _field_enum(box: GraphNode, n: Dictionary, key: String, caption: String, options: Array) -> void:
	_labeled(box, caption)
	var field := OptionButton.new()
	for option in options: field.add_item(option)
	var current_value := str(n.get("params", {}).get(key, options[0]))
	field.select(options.find(current_value) if options.has(current_value) else 0)
	field.item_selected.connect(func(i: int): n.params[key] = options[i])
	box.add_child(field)

func _field_tools(box: GraphNode, n: Dictionary) -> void:
	_labeled(box, "工具绑定")
	if tools_catalog.is_empty():
		var field := LineEdit.new()
		field.text = str(n.get("params", {}).get("name", ""))
		field.text_submitted.connect(func(value: String):
			n.params["name"] = value
			status.text = "工具绑定已更新：" + value)
		box.add_child(field)
		return
	var field := OptionButton.new()
	var current_value := str(n.get("params", {}).get("name", ""))
	for tool in tools_catalog: field.add_item(str(tool))
	if tools_catalog.has(current_value): field.select(tools_catalog.find(current_value))
	field.item_selected.connect(func(i: int):
		n.params["name"] = tools_catalog[i]
		status.text = "工具绑定已更新：" + str(tools_catalog[i]))
	box.add_child(field)

func new_module() -> void:
	var id := fresh("module")
	program.modules[id] = {"inputs": ["value"], "entry": "result", "nodes": [
		{"id": "argument", "op": "input", "params": {"name": "value"}}, {"id": "result", "op": "return"}],
		"edges": [{"from": "argument.value", "to": "result.value"}]}
	enter(id)

func duplicate_module() -> void:
	var id := fresh(current)
	program.modules[id] = program.modules[current].duplicate(true)
	# A self-call in a copied definition must refer to the copy, not the old definition.
	for n in program.modules[id].nodes:
		if n.get("module", "") == current: n.module = id
	enter(id)

func extract_selection() -> void:
	if selected.is_empty(): status.text = "先选择要封装的节点"; return
	var m: Dictionary = program.modules[current]
	var internal: Array = []
	var incoming: Array = []
	var outgoing: Array = []
	for e in m.edges:
		var a := selected.has(e.from.get_slice(".", 0))
		var b := selected.has(e.to.get_slice(".", 0))
		if a and b: internal.append(e.duplicate())
		elif b: incoming.append(e.duplicate())
		elif a: outgoing.append(e.duplicate())
	var ctrl_in: Array = incoming.filter(func(e): return e.to.ends_with(".exec"))
	var ctrl_out: Array = outgoing.filter(func(e): return e.to.ends_with(".exec"))
	var values: Array = outgoing.filter(func(e): return not e.to.ends_with(".exec"))
	if ctrl_in.size() > 1 or ctrl_out.size() != 1:
		status.text = "封装需要单个控制入口、单个控制出口；可先整理分支汇合"
		return
	var empty_id := fresh("empty")
	var return_id := fresh("result")
	var result_source := str(values[0].from) if not values.is_empty() else empty_id + ".value"
	for e in values:
		if e.from != result_source: status.text = "多个返回值请先用 object 节点组合"; return
	var id := fresh("module")
	var call_id := fresh("call")
	var new_nodes: Array = m.nodes.filter(func(n): return selected.has(n.id)).duplicate(true)
	var new_edges: Array = m.edges.filter(func(e): return not selected.has(e.from.get_slice(".", 0)) and not selected.has(e.to.get_slice(".", 0)))
	var args: Array = []
	for e in incoming:
		if e.to.ends_with(".exec"):
			new_edges.append({"from": e.from, "to": call_id + ".exec"})
		else:
			var arg_id := fresh("arg")
			args.append(arg_id)
			new_nodes.append({"id": arg_id, "op": "input", "params": {"name": arg_id}})
			internal.append({"from": arg_id + ".value", "to": e.to})
			new_edges.append({"from": e.from, "to": call_id + "." + arg_id})
	if values.is_empty(): new_nodes.append({"id": empty_id, "op": "const", "params": {"value": null}})
	new_nodes.append({"id": return_id, "op": "return"})
	internal.append({"from": result_source, "to": return_id + ".value"})
	internal.append({"from": ctrl_out[0].from, "to": return_id + ".exec"})
	for e in outgoing: new_edges.append({"from": call_id + (".next" if e.to.ends_with(".exec") else ".value"), "to": e.to})
	var entry: String = ctrl_in[0].to.get_slice(".", 0) if not ctrl_in.is_empty() else m.entry
	if not selected.has(entry): status.text = "选择中缺少控制入口"; return
	program.modules[id] = {"inputs": args, "entry": entry, "nodes": new_nodes, "edges": internal}
	m.nodes = m.nodes.filter(func(n): return not selected.has(n.id))
	m.nodes.append({"id": call_id, "op": "call", "module": id, "label": id})
	m.edges = new_edges
	if selected.has(m.entry): m.entry = call_id
	rebuild()

func save_program() -> void:
	var result := await request("/program", {"program": program, "revision": revision})
	if result.get("ok", false):
		revision = result.revision
		status.text = "已保存；下一次运行生效" if result.validation.ok else "草稿已保存；请修复：" + JSON.stringify(result.validation.errors)
		saved.emit(program)
	else: status.text = JSON.stringify(result)

func show_code() -> void:
	var result := await request("/compile", {"program": program})
	detail.text = result.get("python", "") if result.get("ok", false) else JSON.stringify(result.get("errors", []), "  ")
	detail.custom_minimum_size.y = 260

func show_event(event: Dictionary) -> void:
	recorded_events.append(event)
	if event.get("moduleId", "") != current: return
	var node_id := str(event.get("nodeId", ""))
	var box := graph.get_node_or_null(NodePath(node_id)) as GraphNode
	if box != null:
		box.modulate = Color("f4d891") if event.kind == "node" else Color.WHITE
		detail.text = "真实调用 " + str(event.get("callId", "")) + " · " + current + "/" + node_id + "\n" + JSON.stringify(event, "  ")

func edit_connection(remove: bool) -> void:
	if source_port.selected < 0 or target_port.selected < 0: return
	var a := source_port.get_item_text(source_port.selected).split(".")
	var b := target_port.get_item_text(target_port.selected).split(".")
	if (a[1] == "value") != (b[1] != "exec"):
		status.text = "控制端口与数据端口不能混接"
		return
	var ai: int = output_ports[a[0]].find(a[1])
	var bi: int = input_ports[b[0]].find(b[1])
	if remove: disconnect_ports(a[0], ai, b[0], bi)
	else: connect_ports(a[0], ai, b[0], bi)

func inspect_node(id: String) -> void:
	detail.custom_minimum_size.y = 260
	var matches := recorded_events.filter(func(e): return e.get("moduleId") == current and e.get("nodeId") == id)
	detail.text = "节点 " + current + "/" + id + " · 按 callId 区分递归调用\n" + JSON.stringify(matches.slice(maxi(0, matches.size() - 12)), "  ")
	if matches.is_empty(): detail.text += "\n当前记录中没有执行此节点。纯数据节点在消费者执行时求值。"

func inspect_connection() -> void:
	detail.custom_minimum_size.y = 260
	if source_port.selected < 0 or target_port.selected < 0: return
	var a := source_port.get_item_text(source_port.selected)
	var b := target_port.get_item_text(target_port.selected)
	var values: Array = []
	for e in recorded_events:
		if e.get("moduleId") != current: continue
		if e.get("nodeId") == b.get_slice(".", 0) and e.get("kind") == "node":
			var pin := b.get_slice(".", 1)
			if e.get("inputs", {}).has(pin): values.append({"callId": e.callId, "value": e.inputs[pin], "seq": e.seq})
	detail.text = a + " → " + b + "\n"
	if not program.modules[current].edges.has({"from": a, "to": b}): detail.text += "当前草稿未连接这两个端口。\n"
	detail.text += JSON.stringify(values.slice(maxi(0, values.size() - 12)), "  ")
