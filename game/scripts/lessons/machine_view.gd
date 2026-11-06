extends RefCounted

## 可执行整机的共享三维构建器（Fractal Foundry 式立方体语言）。
## 同一份代码服务三处：Agent Lab 场景、headless 测试、视频 glTF 导出。
## 布局是确定性的：控制流定列（入口在左，沿连线向右），纯数据节点排同列上带，
## 超过四行折成副列；调用节点画成三层叠板——「模块里还有模块」的自相似提示。
## 所有摆位落在 0.25 m 网格（AGENTS.md 铁律 2），布局不读节点 label。

const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
const Cable := preload("res://scripts/lessons/machine_cable.gd")

const PURE := ["input", "const", "tool", "tools", "get", "eq", "lt", "gt", "le", "ge", "ne",
	"add", "sub", "mul", "div", "floordiv", "mod", "pow", "neg", "not",
	"and", "or", "select", "builtin", "format", "list", "listcomp", "dictcomp", "object", "phi", "generator", "generator_input"]
## 与 module_compiler.py 的 PORTS 同形；这里是 Godot 侧唯一的端口表真源，
## module_editor 的针脚显示也从这里取。
const PORTS := {"input": [], "const": [], "tool": [], "tools": [], "list": [], "object": [],
	"get": ["value"], "eq": ["a", "b"], "lt": ["a", "b"], "gt": ["a", "b"],
	"le": ["a", "b"], "ge": ["a", "b"], "ne": ["a", "b"],
	"add": ["a", "b"], "sub": ["a", "b"], "mul": ["a", "b"],
	"div": ["a", "b"], "floordiv": ["a", "b"], "mod": ["a", "b"], "pow": ["a", "b"],
	"and": ["a", "b"], "or": ["a", "b"], "select": ["condition", "then", "else"],
	"neg": ["value"], "not": ["value"], "builtin": ["value"], "format": ["value"],
	"phi": ["initial", "updated"], "for": ["items"],
	"model": ["messages", "tools"], "dispatch": ["action", "tools"], "append": ["items", "value"],
	"message": ["value"], "branch": ["condition"], "return": ["value"], "raise": ["value"],
	"statement": [], "setitem": ["@target"], "file": ["path"], "nop": [], "call": [], "trycall": [],
	"generator": [], "listcomp": [], "dictcomp": [], "generator_input": []}

const EXEC_COLOR := Color("e6a353")
const DATA_COLOR := Color("36b2ce")
const EXEC_WIRE_COLOR := Color("b85a31")
const DATA_WIRE_COLOR := Color("087b91")
const BODY_COLOR := Color("dbe8df")
const CALL_COLOR := Color("568991")
const TOOL_FS_COLOR := Color("e8be73")
const TOOL_WORLD_COLOR := Color("7ba7ad")
const TOOL_MARKS := {"world.snapshot": 1, "world.inspect": 2, "world.move": 3,
	"world.pickup": 4, "world.drop": 5, "fs.list": 6, "fs.read": 7, "fs.write": 8}
const OP_CAPS := {"model": Color("9261c5"), "dispatch": Color("ef743b"), "message": Color("24b9cf"),
	"append": Color("4279d4"), "branch": Color("f2c43d"), "return": Color("68ab5d"),
	"raise": Color("db6268"), "nop": Color("8f9998")}

const X_STEP := 3.0
const SUB_STEP := 1.75
const Z_STEP := 1.75
const ROW_WRAP := 4
const WIRE_Y := 1.0
const DATA_WIRE_Y := 1.25
const WIRE_LANE := 0.25
const WIRE_THICK := 0.25
const PUCK := 0.25


static func pins(n: Dictionary, definitions := {}) -> Array:
	if n.op == "file":
		return ["path", "content"] if str(n.get("params", {}).get("operation", "")) == "write" else ["path"]
	if n.op == "for":
		if str(n.get("module", "")) != "":
			return definitions.get(n.get("module", ""), {}).get("inputs", [])
		return n.get("params", {}).get("visualInputs", ["items"])
	if n.op == "branch" and str(n.get("module", "")) != "":
		return definitions.get(n.get("module", ""), {}).get("inputs", [])
	if n.op in ["call", "trycall", "statement", "setitem"] or (n.op == "return" and n.get("module", "") != ""):
		var module_inputs: Array = definitions.get(n.get("module", ""), {}).get("inputs", [])
		return module_inputs + ["@target"] if n.op == "setitem" or \
			(n.op == "statement" and str(n.get("params", {}).get("inplaceOp", "")) != "") else module_inputs
	if n.op in ["list", "object", "tools", "generator", "listcomp", "dictcomp"]:
		return n.get("params", {}).get("fields", [])
	return PORTS.get(n.op, [])


static func outputs(n: Dictionary) -> Array:
	if n.op in PURE or n.op in ["return", "raise"]:
		return ["value"]
	if n.op == "branch":
		return ["then", "else", "value"]
	if n.op == "for":
		return ["each", "done", "value"]
	if n.op == "break":
		return ["exit"]
	return ["next", "value"]


## 确定性布局：返回 {nodeId: Vector3}（机器局部坐标，y=0 为底面）。
## 控制列用自入口的广度优先深度；循环回边自然拉出长回程线，不做层级松弛。
static func layout(module: Dictionary, definitions := {}, overrides: Dictionary = {}) -> Dictionary:
	var nodes: Array = module.get("nodes", [])
	var by_id := {}
	for n in nodes:
		by_id[n.id] = n
	var consumers := {}
	for e in module.get("edges", []):
		var src: String = str(e.get("from", "")).get_slice(".", 0)
		var dst: String = str(e.get("to", "")).get_slice(".", 0)
		if not by_id.has(src) or not by_id.has(dst): continue
		consumers[src] = consumers.get(src, []) + [dst]
	var col := {}
	for n in nodes:
		col[n.id] = 999
	var entry: String = module.get("entry", "")
	if by_id.has(entry): col[entry] = 0
	var queue: Array = [entry] if by_id.has(entry) else []
	while not queue.is_empty():
		var id: String = queue.pop_front()
		for e in module.get("edges", []):
			if not str(e.get("to", "")).ends_with(".exec"): continue
			if str(e.get("from", "")).get_slice(".", 0) != id: continue
			var dst: String = str(e.get("to", "")).get_slice(".", 0)
			if col.get(dst, 999) == 999:
				col[dst] = col[id] + 1
				queue.append(dst)
	var spread := 0
	for v in col.values():
		if v < 999: spread = maxi(spread, v)
	for n in nodes:
		if col[n.id] == 999 and n.op not in PURE:
			spread += 1
			col[n.id] = spread
	# 纯数据节点列 = 消费者列的最小值；纯子图无环（编译器拒绝），有环以轮数封顶。
	for round in nodes.size() + 1:
		var changed := false
		for n in nodes:
			if n.op not in PURE or col[n.id] != 999: continue
			var target := 999
			for dst in consumers.get(n.id, []):
				if by_id[dst].op in PURE and col[dst] < 999:
					target = mini(target, col[dst])
				elif by_id[dst].op not in PURE:
					target = mini(target, col[dst])
			if target < 999:
				col[n.id] = target
				changed = true
		if not changed: break
	for n in nodes:
		if col[n.id] == 999:
			spread += 1
			col[n.id] = spread
	# 分列分带：同列里纯节点在上带（超四行折副列），效果节点在下带。
	var bands := {}
	for n in nodes:
		var key := str(col[n.id])
		if not bands.has(key): bands[key] = {"pure": [], "effect": []}
		bands[key]["pure" if n.op in PURE else "effect"].append(n.id)
	var positions := {}
	var x := 0.0
	var cols: Array = bands.keys().map(func(k): return int(k))
	cols.sort()
	for key in cols:
		var band: Dictionary = bands[str(key)]
		var pure: Array = band["pure"]
		var effect: Array = band["effect"]
		pure.sort()
		effect.sort()
		var subcols := maxi(1, ceili(float(pure.size()) / ROW_WRAP))
		for i in pure.size():
			positions[pure[i]] = Vector3(
				x + float(i / ROW_WRAP) * SUB_STEP, 0.0, -Z_STEP - float(i % ROW_WRAP) * Z_STEP)
		for i in effect.size():
			positions[effect[i]] = Vector3(x, 0.0, float(i) * Z_STEP)
		x += X_STEP + float(subcols - 1) * SUB_STEP
	for id in overrides:
		if positions.has(id) and overrides[id] is Array and overrides[id].size() == 3:
			positions[id] = Vector3(float(overrides[id][0]), float(overrides[id][1]), float(overrides[id][2]))
	return positions


static func kind(n: Dictionary) -> String:
	if n.op in ["for", "generator", "listcomp", "dictcomp"]: return "loop"
	if n.op == "phi": return "state"
	if n.op == "setitem": return "state"
	if n.op == "file": return "file"
	if n.op == "branch" and str(n.get("visualKind", "")) == "while": return "loop"
	if n.op == "break": return "break"
	if n.op == "continue": return "continue"
	if n.op == "select": return "router"
	if n.op == "branch": return "router"
	if n.op in ["call", "trycall"]: return "call"
	if n.op == "statement": return "statement"
	if n.op == "tool": return "tool"
	if n.op == "tools": return "collection"
	if n.op in ["input", "generator_input"]: return "input"
	if n.op == "return": return "return"
	if n.op in PURE: return "pure"
	return "op"


static func extents(n: Dictionary) -> Vector3:
	var custom: Variant = n.get("params", {}).get("visualExtent", [])
	if custom is Array and custom.size() == 3:
		return Vector3(float(custom[0]), float(custom[1]), float(custom[2]))
	if n.op in ["call", "trycall", "statement", "setitem", "return"] and str(n.get("module", "")) != "":
		return Vector3(2.0, 0.75, 1.5)
	match kind(n):
		"call": return Vector3(1.5, 0.75, 1.0)
		"statement": return Vector3(2.0, 0.75, 1.25)
		"state": return Vector3(1.25, 0.5, 0.75)
		"file": return Vector3(1.5, 0.75, 1.0)
		"tool": return Vector3(0.75, 0.5, 0.75)
		"collection": return Vector3(1.75, 0.5, 1.0)
		"input", "pure": return Vector3(1.25, 0.5, 0.75)
		"return": return Vector3(1.25, 0.75, 0.75)
	return Vector3(1.25, 0.75, 1.0)


## 三维端口直接拖线用的类型判定：控制口只进 exec，数据口只进数据针。
static func ports_compatible(from_pin: String, to_pin: String) -> bool:
	if from_pin in ["next", "then", "else", "each", "done", "exit"]: return to_pin == "exec"
	return from_pin == "value" and to_pin != "exec"


## 组装整机：返回 positions / nodes / ports / labels / wires；
## with_ports 控制是否生成可拾取端口块；关系通道始终按图边绘制。with_labels 控制是否生成节点名贴地字砖
## （组件设计 spec §2.3：世界内文字只走字砖、不新增悬浮标签；glTF 导出关闭，文字由映射重建）。
static func build(parent: Node3D, program: Dictionary, mid: String, with_ports := true,
		with_labels := true, with_source_text := false, defer_wires := false) -> Dictionary:
	var defs: Dictionary = program.get("modules", {})
	var module: Dictionary = defs.get(mid, {})
	var layout_overrides: Dictionary = program.get("machineLayout", {}).get(mid, {}).get("positions", {})
	var out := {"positions": layout(module, defs, layout_overrides), "nodes": {}, "ports": {}, "labels": {}, "wires": []}
	for n in module.get("nodes", []):
		var class_visual: Dictionary = program.get("machineLayout", {}).get(
			str(n.get("module", "")), {}).get("classVisual", {})
		_build_node(parent, n, out["positions"].get(n.id, Vector3.ZERO), defs, out,
			with_ports, with_labels, with_source_text, class_visual)
	if str(module.get("scopeKind", "")) == "resource":
		_build_resource_scope(parent, module, out["positions"])
	if not defer_wires: build_wires(parent, module, out)
	return out

static func _build_resource_scope(parent: Node3D, module: Dictionary, positions: Dictionary) -> void:
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for node in module.get("nodes", []):
		var p: Vector3 = positions.get(str(node.id), Vector3.ZERO)
		var e: Vector3 = extents(node)
		low.x = minf(low.x, p.x - e.x * 0.5)
		low.y = minf(low.y, p.z - e.z * 0.5)
		high.x = maxf(high.x, p.x + e.x * 0.5)
		high.y = maxf(high.y, p.z + e.z * 0.5)
	_build_scope_outline(parent, Vector3((low.x + high.x) * 0.5, 0.125, (low.y + high.y) * 0.5), high - low + Vector2(0.5, 0.5))

static func _build_scope_outline(parent: Node3D, center: Vector3, size: Vector2) -> void:
	var color := Color("a46c48")
	for side in [-1.0, 1.0]:
		_slab(parent, Vector3(size.x, 0.125, 0.125), Vector3(center.x, center.y, center.z + side * size.y * 0.5), color)
		_slab(parent, Vector3(0.125, 0.125, size.y), Vector3(center.x + side * size.x * 0.5, center.y, center.z), color)

static func build_wires(parent: Node3D, module: Dictionary, out: Dictionary) -> void:
	# Summary components may be scaled after the blocks are built. Move the hidden
	# port anchors with their holders before laying down the relation channels.
	for key in out["ports"].keys():
		var node_id := str(key).get_slice(".", 0)
		if not out["nodes"].has(node_id): continue
		var holder: Node3D = out["nodes"][node_id]
		var port: Dictionary = out["ports"][key]
		var position: Vector3 = port["position"]
		var offset := position - holder.position
		port["position"] = holder.position + Vector3(
			offset.x * holder.scale.x, offset.y * holder.scale.y, offset.z * holder.scale.z)
		var surface_offset: Vector3 = port["surface_position"] - holder.position
		port["surface_position"] = holder.position + Vector3(
			surface_offset.x * holder.scale.x, surface_offset.y * holder.scale.y,
			surface_offset.z * holder.scale.z)
		out["ports"][key] = port
	var lanes := _assign_lanes(module, out)
	var edges: Array = module.get("edges", [])
	var compact_python: bool = str(module.get("kind", "")) == "expression" or str(module.get("language", "")) == "python"
	for i in edges.size():
		var lane: float = lanes.get(i, WIRE_Y)
		_build_wire(parent, edges[i], out, lane - 0.25 if compact_python else lane)


static func _slab(parent: Node3D, size: Vector3, offset: Vector3, color: Color) -> MeshInstance3D:
	var mesh := MeshInstance3D.new()
	mesh.mesh = Surface.mesh(size)
	mesh.material_override = Style.matte(color)
	mesh.position = offset
	parent.add_child(mesh)
	return mesh


static func _build_node(parent: Node3D, n: Dictionary, pos: Vector3, defs: Dictionary,
		out: Dictionary, with_ports: bool, with_labels: bool, with_source_text: bool,
		class_visual: Dictionary) -> void:
	var holder := Node3D.new()
	holder.name = "N_" + n.id
	holder.position = pos
	parent.add_child(holder)
	var ext := extents(n)
	match kind(n):
		"loop":
			_build_factory_shell(holder, ext, Color("c6a663"))
			_build_module_preview(holder, str(n.get("module", "")), defs, ext)
			_build_loop_tray(holder, ext)
		"state":
			if n.op == "setitem":
				_build_factory_shell(holder, ext, DATA_COLOR)
				_build_module_preview(holder, str(n.get("module", "")), defs, ext)
			else:
				_slab(holder, Vector3(ext.x, 0.25, ext.z), Vector3(0, 0.125, 0), Color("809392"))
				for side in [-1.0, 1.0]:
					_slab(holder, Vector3(0.125, 0.25, ext.z),
						Vector3(side * (ext.x / 2.0 - 0.0625), 0.375, 0), CALL_COLOR)
				_slab(holder, Vector3(0.5, 0.25, 0.5), Vector3(0, 0.375, 0), DATA_COLOR)
		"router":
			_build_module_preview(holder, str(n.get("module", "")), defs, ext)
			_build_router(holder, ext)
		"break":
			_build_exit_chute(holder, ext)
		"continue":
			_build_loop_return(holder, ext)
		"statement":
			_build_factory_shell(holder, ext, Color("8aa3a1"))
			_build_module_preview(holder, str(n.get("module", "")), defs, ext)
		"call":
			if class_visual.is_empty():
				_build_factory_shell(holder, ext, CALL_COLOR)
			else:
				_build_class_workbench(holder, ext, class_visual)
			_build_module_preview(holder, str(n.get("module", "")), defs, ext)
			if n.op == "trycall":
				_ring(holder, ext, Style.ERROR)
		"tool":
			var tool_name := str(n.get("params", {}).get("name", ""))
			var is_world: bool = tool_name.begins_with("world.")
			_slab(holder, ext, Vector3(0, ext.y / 2, 0),
				TOOL_WORLD_COLOR if is_world else TOOL_FS_COLOR)
			if is_world:
				# world.* 顶加小天线（细柱+顶块），读作"感知世界状态"。
				_slab(holder, Vector3(0.25, 0.25, 0.25), Vector3(0.25, 0.625, -0.25), TOOL_WORLD_COLOR)
				_slab(holder, Vector3(0.25, 0.25, 0.25), Vector3(0.25, 0.875, -0.25), DATA_COLOR)
			else:
				# fs.* 前缘加纸盘低板，读作"吃进文件"。
				_slab(holder, Vector3(ext.x, 0.25, 0.25),
					Vector3(0, 0.125, ext.z / 2 + 0.125), Style.PAPER)
			for i in int(TOOL_MARKS.get(tool_name, 0)):
				var x := -0.3 + float(i % 4) * 0.2
				var z := 0.1 + float(i / 4) * 0.2
				_slab(holder, Vector3(0.125, 0.125, 0.125), Vector3(x, ext.y + 0.0625, z), DATA_COLOR)
		"file":
			_slab(holder, ext, Vector3(0, ext.y / 2, 0), Style.PAPER)
			_slab(holder, Vector3(ext.x - 0.5, 0.25, 0.25),
				Vector3(0, ext.y + 0.125, ext.z / 2 + 0.125),
				DATA_COLOR if str(n.get("params", {}).get("operation", "")) == "read" else TOOL_FS_COLOR)
			if str(n.get("params", {}).get("operation", "")) == "write":
				_slab(holder, Vector3(0.25, 0.25, 0.25), Vector3(ext.x / 2 - 0.25, ext.y + 0.25, 0), EXEC_COLOR)
		"collection":
			_slab(holder, ext, Vector3(0, ext.y / 2, 0), Color("c9d8cd"))
			var fields: Array = pins(n, defs)
			for i in mini(fields.size(), 8):
				_slab(holder, Vector3(PUCK, PUCK, PUCK),
					Vector3(-ext.x / 2 + 0.375 + 0.2 * i, ext.y + 0.125, 0), TOOL_FS_COLOR)
		"input":
			_slab(holder, ext, Vector3(0, ext.y / 2, 0), Color("e5dcc3"))
			# 前缘薄坡板：两级台阶向外递降的进料台。
			_slab(holder, Vector3(ext.x - 0.5, 0.25, 0.25),
				Vector3(0, 0.125, ext.z / 2 + 0.125), Color("e5dcc3"))
			_slab(holder, Vector3(ext.x - 0.5, 0.125, 0.25),
				Vector3(0, 0.0625, ext.z / 2 + 0.375), Color("e5dcc3"))
			var input_params: Dictionary = n.get("params", {})
			if input_params.has("previewValue"):
				var input_name := str(input_params.get("name", ""))
				if input_name != "":
					_add_surface_text(holder, input_name, ext.x - 0.1,
						Vector3(0, ext.y * 0.5, ext.z / 2 + 0.025), 36, Vector3.ZERO)
				var preview_value: Variant = input_params["previewValue"]
				var values: Array = preview_value if preview_value is Array else [preview_value]
				var visible_values := mini(values.size(), 8)
				var chip_step := minf(0.4, (ext.x - 0.25) / maxf(1.0, float(visible_values)))
				for i in visible_values:
					var x := (float(i) - float(visible_values - 1) / 2.0) * chip_step
					var chip := _slab(holder, Vector3(0.25, 0.125, 0.25),
						Vector3(x, ext.y + 0.0625, 0), TOOL_FS_COLOR)
					chip.name = "InputValue_%d" % i
					var value_text := "null" if values[i] == null else str(values[i])
					_add_surface_text(holder, value_text, 0.25,
						Vector3(x, ext.y + 0.14, 0), 48)
		"return":
			if str(n.get("module", "")) != "":
				_build_factory_shell(holder, ext, OP_CAPS["return"])
				_build_module_preview(holder, str(n.module), defs, ext)
			else:
				_slab(holder, ext, Vector3(0, ext.y / 2, 0), BODY_COLOR)
				_slab(holder, Vector3(0.5, 0.25, 0.5), Vector3(0, ext.y + 0.125, 0), OP_CAPS["return"])
				# 矮出料唇板：前缘薄板，读作出料口。
				_slab(holder, Vector3(ext.x - 0.5, 0.125, 0.25),
					Vector3(0, 0.0625, ext.z / 2 + 0.125), BODY_COLOR)
		"pure":
			_slab(holder, ext, Vector3(0, ext.y / 2, 0), Color("cfd9dc"))
			if n.op == "const":
				var value: Variant = n.get("params", {}).get("value", 0)
				var count := clampi(int(value), 0, 9) if value is int or value is float else 0
				for i in count:
					var x := float(i % 3 - 1) * 0.25
					var z := float(i / 3 - 1) * 0.25
					_slab(holder, Vector3(PUCK, 0.125, PUCK), Vector3(x, ext.y + 0.0625, z), DATA_COLOR)
			elif n.op in ["add", "sub", "mul"]:
				var center := Vector3(0, ext.y + 0.125, 0)
				var color := DATA_COLOR
				if n.op == "sub": color = EXEC_COLOR
				elif n.op == "mul": color = CALL_COLOR
				var bar := _slab(holder, Vector3(0.75, 0.25, 0.25), center, color)
				if n.op == "add":
					_slab(holder, Vector3(0.25, 0.25, 0.75), center, color)
				elif n.op == "mul":
					bar.rotation.y = PI / 4
					var crossing := _slab(holder, Vector3(0.75, 0.25, 0.25), center, color)
					crossing.rotation.y = -PI / 4
			elif n.op == "eq":
				_slab(holder, Vector3(0.75, 0.125, 0.2), Vector3(0, ext.y + 0.1, -0.1), EXEC_COLOR)
				_slab(holder, Vector3(0.75, 0.125, 0.2), Vector3(0, ext.y + 0.1, 0.2), EXEC_COLOR)
			elif n.op == "builtin":
				_slab(holder, Vector3(0.75, 0.25, 0.5), Vector3(0, ext.y + 0.125, 0), CALL_COLOR)
				_slab(holder, Vector3(0.25, 0.125, 0.75), Vector3(0, ext.y + 0.3125, 0), DATA_COLOR)
			elif n.op in ["list", "object"]:
				for side in [-1.0, 1.0]:
					_slab(holder, Vector3(0.125, 0.25, 0.75),
						Vector3(side * 0.375, ext.y + 0.125, 0), CALL_COLOR)
				_slab(holder, Vector3(0.875, 0.125, 0.25), Vector3(0, ext.y + 0.0625, 0), DATA_COLOR)
		_:
			_slab(holder, ext, Vector3(0, ext.y / 2, 0), BODY_COLOR)
			if OP_CAPS.has(n.op):
				_slab(holder, Vector3(0.5, 0.25, 0.5), Vector3(0, ext.y + 0.125, 0), OP_CAPS[n.op])
	out["nodes"][n.id] = holder
	out["labels"][n.id] = str(n.get("label", n.id))
	if with_source_text:
		if n.has("sourceText") and str(n.sourceText) != "":
			_add_source_text(holder, str(n.get("sourceText", "")), ext)
		elif n.op == "const":
			var global_name := str(n.get("params", {}).get("globalName", ""))
			if global_name != "":
				_add_surface_text(holder, global_name, ext.x - 0.1,
					Vector3(0, ext.y * 0.4, ext.z / 2.0 + 0.025), 40, Vector3.ZERO)
	_build_ports(holder, n, ext, defs, out, with_ports)


static func _build_loop_tray(holder: Node3D, ext: Vector3) -> void:
	var tray_color := Color("c6a663")
	_slab(holder, Vector3(ext.x - 0.75, 0.125, 0.25),
		Vector3(0, 0.25, ext.z / 2.0 - 0.375), tray_color)
	for i in 3:
		var x := (float(i) - 1.0) * 0.5
		_slab(holder, Vector3(0.25, 0.2, 0.25),
			Vector3(x, 0.4, ext.z / 2.0 - 0.375), Color("e3ce93"))


static func _build_router(holder: Node3D, ext: Vector3) -> void:
	_slab(holder, Vector3(ext.x, 0.25, ext.z), Vector3(0, 0.125, 0), Color("809392"))
	var center := _slab(holder, Vector3(0.75, 0.25, 0.75),
		Vector3(0, ext.y * 0.68, 0), Color("e0bd4e"))
	center.rotation.y = PI / 4.0
	for side in [-1.0, 1.0]:
		var lane := _slab(holder, Vector3(0.25, 0.125, maxf(0.5, ext.z * 0.34)),
			Vector3(0, ext.y * 0.68, side * ext.z * 0.31), EXEC_COLOR if side < 0 else DATA_COLOR)
		lane.name = "Route_Then" if side < 0 else "Route_Else"


static func _build_exit_chute(holder: Node3D, ext: Vector3) -> void:
	_slab(holder, ext, Vector3(0, ext.y / 2.0, 0), Color("cfd9dc"))
	var chute := _slab(holder, Vector3(0.75, 0.125, 0.25),
		Vector3(0, ext.y + 0.0625, ext.z / 2.0 + 0.2), EXEC_COLOR)
	chute.rotation.x = deg_to_rad(-18.0)
	_slab(holder, Vector3(0.25, 0.125, 0.25),
		Vector3(0, ext.y + 0.125, ext.z / 2.0 + 0.5), EXEC_COLOR)


static func _build_loop_return(holder: Node3D, ext: Vector3) -> void:
	_slab(holder, ext, Vector3(0, ext.y / 2.0, 0), Color("cfd9dc"))
	var lane_z := ext.z / 2.0 + 0.2
	_slab(holder, Vector3(ext.x, 0.125, 0.125), Vector3(0, ext.y + 0.0625, lane_z), Color("c6a663"))
	_slab(holder, Vector3(0.125, 0.125, 0.5), Vector3(ext.x / 2.0 - 0.1, ext.y + 0.0625, lane_z - 0.2), Color("c6a663"))
	_slab(holder, Vector3(0.125, 0.125, 0.5), Vector3(-ext.x / 2.0 + 0.1, ext.y + 0.0625, lane_z - 0.2), Color("c6a663"))


static func _add_source_text(holder: Node3D, text: String, ext: Vector3) -> void:
	if text.is_empty(): return
	_add_surface_text(holder, text, ext.x - 0.2,
		Vector3(0, ext.y * 0.4, ext.z / 2.0 + 0.025), 48, Vector3.ZERO)


static func _add_surface_text(parent: Node3D, text: String, max_width: float,
		at: Vector3, font_size: int, rotation := Vector3(-PI / 2.0, 0, 0)) -> void:
	var label := Label3D.new()
	label.name = "SourceText"
	label.text = text
	label.position = at
	label.rotation = rotation
	label.font_size = font_size
	label.pixel_size = clampf(max_width / maxf(1.0, float(text.length()) * float(font_size) * 0.58), 0.001, 0.004)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.modulate = Color("24383b")
	label.outline_size = 2
	label.shaded = false
	parent.add_child(label)


## 函数模块做成开顶子工厂：外壳留出视线，实际子图缩排在工作台内。
## 端口仍位于外壳两侧，内构只读，不产生第二份可编辑程序。
static func _build_factory_shell(parent: Node3D, ext: Vector3, accent: Color) -> void:
	_slab(parent, Vector3(ext.x, 0.25, ext.z), Vector3(0, 0.125, 0), Color("8fa9a5"))
	_slab(parent, Vector3(ext.x - 0.5, 0.125, ext.z - 0.5),
		Vector3(0, 0.3125, 0), Color("c9d8cd"))
	_slab(parent, Vector3(ext.x * 0.4, 0.0625, ext.z * 0.4),
		Vector3(0, 0.40625, 0), Color("526b6c"))
	# 矮边框只标出盒子的边界，不挡住缩小后的机器；机器轮廓应先于外壳被看见。
	var rail_y := 0.375
	var rail_color := Color("9bb2ae")
	for x in [-ext.x / 2 + 0.125, ext.x / 2 - 0.125]:
		for z in [-ext.z / 2 + 0.125, ext.z / 2 - 0.125]:
			_slab(parent, Vector3(0.125, 0.25, 0.125), Vector3(x, rail_y, z), rail_color)
	_slab(parent, Vector3(0.375, 0.125, 0.125), Vector3(0, 0.5, ext.z / 2 - 0.125), accent)


## Class factories and methods share one table shape; each call node owns its own field slots.
static func _build_class_workbench(parent: Node3D, ext: Vector3, visual: Dictionary) -> void:
	var role := str(visual.get("role", ""))
	var accent := Color("8c73a1") if role == "factory" else Color("628d98")
	_build_factory_shell(parent, ext, accent)
	_slab(parent, Vector3(ext.x - 0.75, 0.125, 0.25),
		Vector3(0, 0.5, ext.z / 2 - 0.375), Color("667e7c"))
	var fields: Array = visual.get("fields", [])
	var columns := mini(4, maxi(1, fields.size()))
	for i in fields.size():
		var column := i % columns
		var row := i / columns
		var x := (float(column) - float(mini(fields.size(), 4) - 1) * 0.5) * 0.25
		var z := ext.z / 2 - 0.375 - float(row) * 0.25
		_slab(parent, Vector3(0.125, 0.125, 0.125), Vector3(x, 0.625, z), DATA_COLOR)
	if role == "method":
		_slab(parent, Vector3(0.25, 0.125, 0.25),
			Vector3(ext.x / 2 - 0.5, 0.625, ext.z / 2 - 0.375), EXEC_COLOR)


## 把被调用模块的真实节点和关系压进外壳内；钻入时仍显示完整模块图。
static func _build_module_preview(parent: Node3D, module_id: String, defs: Dictionary, ext: Vector3) -> void:
	var module: Dictionary = defs.get(module_id, {})
	var nodes: Array = module.get("nodes", [])
	if nodes.is_empty(): return
	# A compact 3D inset: preserve the real graph, but keep it visibly smaller than its containing module.
	var thumbnail := Node3D.new()
	thumbnail.name = "SubfactoryThumbnail"
	thumbnail.position = Vector3(0, 0.36, 0)
	thumbnail.scale = Vector3.ONE * 0.3
	parent.add_child(thumbnail)
	var positions := layout(module, defs)
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for node in nodes:
		var p: Vector3 = positions.get(str(node.id), Vector3.ZERO)
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.z)
		max_z = maxf(max_z, p.z)
	var room_x := ext.x - 0.75
	var room_z := ext.z - 0.75
	var span_x := maxf(1.0, max_x - min_x)
	var span_z := maxf(1.0, max_z - min_z)
	var sx := room_x / span_x
	var sz := room_z / span_z
	var centers := {}
	var cell := clampf(minf(room_x, room_z) / 1.8, 0.4, 0.6)
	for node in nodes:
		var p: Vector3 = positions.get(str(node.id), Vector3.ZERO)
		var center := Vector3((p.x - (min_x + max_x) / 2.0) * sx, 0.5,
			(p.z - (min_z + max_z) / 2.0) * sz)
		centers[str(node.id)] = center
	for edge in module.get("edges", []):
		var from_id := str(edge.get("from", "")).get_slice(".", 0)
		var to_id := str(edge.get("to", "")).get_slice(".", 0)
		if not centers.has(from_id) or not centers.has(to_id): continue
		var color := EXEC_COLOR if str(edge.get("to", "")).ends_with(".exec") else DATA_COLOR
		_preview_channel(thumbnail, centers[from_id], centers[to_id], color)
	for node in nodes:
		_build_preview_station(thumbnail, node, centers[str(node.id)], cell)
	if str(module.get("scopeKind", "")) == "resource":
		_build_scope_outline(thumbnail, Vector3(0, 0.5, 0), Vector2(room_x, room_z))


static func _preview_channel(parent: Node3D, a: Vector3, b: Vector3, color: Color) -> void:
	var mid_x := (a.x + b.x) / 2.0
	var corner_a := Vector3(mid_x, 0.375, a.z)
	var corner_b := Vector3(mid_x, 0.375, b.z)
	var start := Vector3(a.x, 0.375, a.z)
	var finish := Vector3(b.x, 0.375, b.z)
	_preview_segment(parent, start, corner_a, color)
	_preview_segment(parent, corner_a, corner_b, color)
	_preview_segment(parent, corner_b, finish, color)
	# 传送带上的料块让连线读成物流；青色为数据，珊瑚色为执行信号。
	var cargo := _slab(parent, Vector3(0.2, 0.2, 0.2),
		Vector3(mid_x, 0.5, (a.z + b.z) / 2.0), color)
	cargo.name = "PreviewCargo"


static func _preview_segment(parent: Node3D, a: Vector3, b: Vector3, color: Color) -> void:
	var delta := b - a
	if absf(delta.x) + absf(delta.z) < 0.04: return
	var size := Vector3(maxf(absf(delta.x), 0.25), 0.125, 0.25) if absf(delta.x) >= absf(delta.z) \
		else Vector3(0.25, 0.125, maxf(absf(delta.z), 0.25))
	_slab(parent, size, (a + b) / 2.0, Color("526b6c"))
	var stripe := Vector3(size.x, 0.05, 0.1) if size.x > size.z else Vector3(0.1, 0.05, size.z)
	_slab(parent, stripe, (a + b) / 2.0 + Vector3(0, 0.0875, 0), color)


static func _build_preview_station(parent: Node3D, node: Dictionary, center: Vector3, cell: float) -> void:
	var op := str(node.get("op", ""))
	var body_color := Color("b9d2c8")
	if op in ["input", "return"]: body_color = Color("d9c99f")
	elif op in ["call", "trycall", "statement"]: body_color = Color("d8a17b")
	elif op == "tool": body_color = Color("9bb9c2")
	_slab(parent, Vector3(cell * 1.15, 0.375, cell * 1.15), center + Vector3(0, 0.0625, 0), body_color)
	var cap_color := DATA_COLOR
	if op in ["branch", "raise"]: cap_color = EXEC_COLOR
	elif op in ["call", "trycall", "statement", "tool"]: cap_color = CALL_COLOR
	elif op == "const": cap_color = TOOL_FS_COLOR
	var cap := _slab(parent, Vector3(cell * 0.65, 0.125, cell * 0.65),
		center + Vector3(0, 0.3125, 0), cap_color)
	if op == "mul":
		_slab(parent, Vector3(cell * 0.65, 0.125, 0.1), center + Vector3(0, 0.3125, 0), cap_color)
		_slab(parent, Vector3(0.1, 0.125, cell * 0.65), center + Vector3(0, 0.3125, 0), cap_color)
	elif op == "add":
		_slab(parent, Vector3(cell * 0.65, 0.125, 0.1), center + Vector3(0, 0.3125, 0), cap_color)
		_slab(parent, Vector3(0.1, 0.125, cell * 0.65), center + Vector3(0, 0.3125, 0), cap_color)
	elif op in ["input", "tool"]:
		_slab(parent, Vector3(cell * 0.75, 0.125, 0.25),
			center + Vector3(0, -0.0625, cell * 0.7), body_color)
	elif op == "return":
		_slab(parent, Vector3(cell * 0.75, 0.125, 0.25),
			center + Vector3(0, -0.0625, -cell * 0.7), body_color)


## trycall 边框圈：底板四周一圈异色薄板，侧向中段留出端口槽（端口块与走线从中通过）。
static func _ring(parent: Node3D, ext: Vector3, color: Color) -> void:
	var front: float = ext.z / 2 + 0.125
	var side: float = ext.x / 2 + 0.125
	_slab(parent, Vector3(ext.x + 0.5, 0.25, 0.25), Vector3(0, 0.125, front), color)
	_slab(parent, Vector3(ext.x + 0.5, 0.25, 0.25), Vector3(0, 0.125, -front), color)
	var seg_len: float = ext.z / 2 - 0.25
	if seg_len < 0.1: return
	var seg_center: float = 0.25 + seg_len / 2
	for x in [-side, side]:
		for z in [seg_center, -seg_center]:
			_slab(parent, Vector3(0.25, 0.25, seg_len), Vector3(x, 0.125, z), color)


static func _build_ports(holder: Node3D, n: Dictionary, ext: Vector3, defs: Dictionary,
		out: Dictionary, show_ports: bool) -> void:
	var in_pins: Array = pins(n, defs)
	if n.op not in PURE: in_pins = ["exec"] + in_pins
	for i in in_pins.size():
		var pin: String = in_pins[i]
		# exec 在最上，数据针按声明顺序向下排，间距 0.25。
		var y := ext.y + 0.125 - PUCK * i
		_puck(holder, n.id, pin, "in", "control" if pin == "exec" else "data",
			Vector3(-ext.x / 2 - PUCK / 2, y, 0), EXEC_COLOR if pin == "exec" else DATA_COLOR,
			ext, out, show_ports)
	for i in outputs(n).size():
		var pin: String = outputs(n)[i]
		var type := "control" if pin in ["next", "then", "else", "each", "done", "exit"] else "data"
		_puck(holder, n.id, pin, "out", type,
			Vector3(ext.x / 2 + PUCK / 2, ext.y + 0.125 - PUCK * i, 0),
			EXEC_COLOR if type == "control" else DATA_COLOR, ext, out, show_ports)


static func _puck(holder: Node3D, node_id: String, pin: String, dir: String, type: String,
		offset: Vector3, color: Color, ext: Vector3, out: Dictionary, show_port: bool) -> void:
	if show_port:
		var puck := _slab(holder, Vector3(PUCK, PUCK, PUCK), offset, color)
		puck.name = "P_" + node_id + "_" + pin
		var body := StaticBody3D.new()
		body.set_meta("port", {"node": node_id, "pin": pin, "dir": dir, "type": type})
		var collision := CollisionShape3D.new()
		var shape := BoxShape3D.new()
		shape.size = Vector3(PUCK + 0.15, PUCK + 0.15, PUCK + 0.15)
		collision.shape = shape
		body.add_child(collision)
		puck.add_child(body)
	var surface_offset := offset
	var side := signf(offset.x)
	surface_offset.x = side * maxf(0.0, ext.x / 2.0 - 0.04)
	surface_offset.y = clampf(offset.y, 0.04, ext.y - 0.04)
	surface_offset.z = clampf(offset.z, -ext.z / 2.0 + 0.04, ext.z / 2.0 - 0.04)
	out["ports"][node_id + "." + pin] = {
		"position": holder.position + offset,
		"surface_position": holder.position + surface_offset,
		"dir": dir, "type": type}


## 兼容旧调用的四点路径；整机连线与拖线预览使用 channel_path。
static func wire_path(a: Vector3, b: Vector3, lane: float = WIRE_Y) -> Array:
	return [a, Vector3(a.x, lane, a.z), Vector3(b.x, lane, b.z), b]


## 连接通道走直角段，避免把 x/z 对角位移拉成整片板。
static func channel_path(a: Vector3, b: Vector3, lane: float = WIRE_Y) -> Array:
	return [a, Vector3(a.x, lane, a.z), Vector3(b.x, lane, a.z),
		Vector3(b.x, lane, b.z), b]


## 车道分配：控制线基高 WIRE_Y、数据线 DATA_WIRE_Y；不重叠的连线复用高度。
## 水平段跨过中间节点脚印时外移一档，目标车道已被先前分配（x 区间重叠）
## 占用则继续外移——确定性，不做通用寻路。
static func _assign_lanes(module: Dictionary, out: Dictionary) -> Dictionary:
	var edges: Array = module.get("edges", [])
	var ports: Dictionary = out["ports"]
	var order := []
	for i in edges.size():
		order.append(i)
	order.sort_custom(func(x, y): return _edge_sort_key(edges[x]) < _edge_sort_key(edges[y]))
	var taken: Array = []
	var lanes := {}
	for idx in order:
		var edge: Dictionary = edges[idx]
		var key_from := str(edge.get("from", ""))
		var key_to := str(edge.get("to", ""))
		if not ports.has(key_from) or not ports.has(key_to): continue
		var a: Vector3 = ports[key_from]["position"]
		var b: Vector3 = ports[key_to]["position"]
		var line_type := "control" if key_to.ends_with(".exec") else "data"
		var lane: float = WIRE_Y if line_type == "control" else DATA_WIRE_Y
		if _crosses_nodes(a, b, key_from, key_to, out["positions"], module):
			lane += WIRE_LANE
		var lo_x: float = minf(a.x, b.x)
		var hi_x: float = maxf(a.x, b.x)
		var lo_z: float = minf(a.z, b.z)
		var hi_z: float = maxf(a.z, b.z)
		while _lane_taken(taken, lane, lo_x, hi_x, lo_z, hi_z):
			lane += WIRE_LANE
		taken.append({"y": lane, "lo": lo_x, "hi": hi_x, "zlo": lo_z, "zhi": hi_z})
		lanes[idx] = lane
	return lanes


static func _edge_sort_key(e: Dictionary) -> String:
	return str(e.get("from", "")) + ">" + str(e.get("to", ""))


static func _lane_taken(taken: Array, lane: float, lo: float, hi: float,
		zlo: float, zhi: float) -> bool:
	for t in taken:
		if absf(t.y - lane) < 0.001 and hi + WIRE_THICK > t.lo \
				and lo - WIRE_THICK < t.hi and zhi + WIRE_THICK > t.zlo \
				and zlo - WIRE_THICK < t.zhi:
			return true
	return false


## 水平段避让判定：与中间节点脚印（extents 近似 AABB，外扩半线厚）相交才算穿过。
static func _crosses_nodes(a: Vector3, b: Vector3, key_from: String, key_to: String,
		positions: Dictionary, module: Dictionary) -> bool:
	var skip := {str(key_from).get_slice(".", 0): true, str(key_to).get_slice(".", 0): true}
	var lo_x: float = minf(a.x, b.x) - WIRE_THICK / 2
	var hi_x: float = maxf(a.x, b.x) + WIRE_THICK / 2
	var lo_z: float = minf(a.z, b.z) - WIRE_THICK / 2
	var hi_z: float = maxf(a.z, b.z) + WIRE_THICK / 2
	for n in module.get("nodes", []):
		var id := str(n.id)
		if skip.has(id) or not positions.has(id): continue
		var p: Vector3 = positions[id]
		var ext := extents(n)
		if hi_x > p.x - ext.x / 2 and lo_x < p.x + ext.x / 2 \
				and hi_z > p.z - ext.z / 2 and lo_z < p.z + ext.z / 2:
			return true
	return false


static func _build_wire(parent: Node3D, edge: Dictionary, out: Dictionary, lane: float) -> void:
	var ports: Dictionary = out["ports"]
	var key_from := str(edge.get("from", ""))
	var key_to := str(edge.get("to", ""))
	if not ports.has(key_from) or not ports.has(key_to): return
	var from_port: Dictionary = ports[key_from]
	var to_port: Dictionary = ports[key_to]
	var path := channel_path(from_port["position"], to_port["position"], lane)
	var color := EXEC_WIRE_COLOR if key_to.ends_with(".exec") else DATA_WIRE_COLOR
	var holder := Node3D.new()
	holder.name = "W_" + key_from + "__" + key_to
	parent.add_child(holder)
	Cable.build_wire(holder, path, color, from_port["surface_position"], to_port["surface_position"])
	out["wires"].append({"from": key_from, "to": key_to, "node": holder, "path": path})
