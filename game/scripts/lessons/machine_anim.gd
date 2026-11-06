extends RefCounted

## 执行反馈动画核心（Agent Lab 工厂感升级）：数据包沿线移动、运行游标、
## 节点工作态点灯、执行事件限速回放。纯函数优先；节点操作只做生成/摆位/材质
## 切换，不用 Tween（headless 静默不跑）。事件形态见 game/runs/agent-lab/*/execution.jsonl
## （kind: enter/leave/node/value/model.start/model.result/tool.start/tool.result）。
## 走线对任意折线段数通用：一律按弧长遍历，不假设 wire_path 的点数。
## hooks 约定：{"wires": {"from->to": 折线Array}, "nodes": {"nodeId": Node3D},
##   "tools": {"toolName": nodeId}(可选), "tool_target": Vector3(可选, 默认世界台),
##   "packet_root": Node3D(可选, 包节点父级；缺省则只点灯不出包)}。
## wires 键与 MachineView.build 产物对应：key = w["from"] + "->" + w["to"]。

const View := preload("res://scripts/lessons/machine_view.gd")
const Surface := preload("res://scripts/asset_lib/block_surface.gd")
const Style := preload("res://scripts/asset_lib/asset_style.gd")
const TextTile := preload("res://scripts/asset_lib/text_tile.gd")

const EVENT_INTERVAL := 0.15
const PACKET_SPEED := 3.0
## 行进浮动幅度（m）。
const BOB := 0.05
## tool.start 金色脉冲包色（与 agent_lab 旧脉冲线同色）。
const TOOL_PULSE_COLOR := Color("f1b950")

static var _lit_materials := {}


## 事件回放状态（回放队列 + 递归调用栈 + 活跃包列表）。
static func new_state() -> Dictionary:
	return {"queue": [], "timer": 0.0, "depth": 0, "max_depth": 0, "calls": {}, "packets": []}


## 折线弧长插值取点：progress ∈ [0,1] 按总弧长比例取位置（纯函数）。
static func packet_position(path: Array, progress: float) -> Vector3:
	if path.is_empty(): return Vector3.ZERO
	if path.size() == 1: return path[0]
	var remain := clampf(progress, 0.0, 1.0) * _path_length(path)
	for i in path.size() - 1:
		var seg: Vector3 = path[i + 1] - path[i]
		var seg_len := seg.length()
		if seg_len <= 0.0: continue
		if remain <= seg_len:
			return path[i] + seg * (remain / seg_len)
		remain -= seg_len
	return path[path.size() - 1]


## 弧长整格化（FFF-276 精神）：行进里程取整到 0.25 m——正交走线上每格都是网格位，
## 包位置因此只落 0.25 网格。入参/返回值均为米。
static func packet_quantum(progress: float) -> float:
	return maxf(0.0, floorf(progress / View.PUCK + 0.5)) * View.PUCK


## 生成 0.25 小方块数据包（挂在 packet_root 下，path 为父级局部坐标）。
## 返回 {node, path, traveled, raw, length}：traveled 是整格化后的显示里程，raw 是连续里程。
static func spawn_packet(parent: Node3D, path: Array, color: Color) -> Dictionary:
	var node := MeshInstance3D.new()
	node.name = "Packet"
	node.mesh = Surface.mesh(Vector3(View.PUCK, View.PUCK, View.PUCK))
	node.material_override = Style.matte(color)
	node.position = packet_position(path, 0.0)
	parent.add_child(node)
	return {"node": node, "path": path, "traveled": 0.0, "raw": 0.0, "length": _path_length(path)}


## 推进一个 0.25 m 弧长格；到终点返回 true（节点由调用方释放）。
static func advance_packet(packet: Dictionary, delta: float, speed := PACKET_SPEED) -> bool:
	var path: Array = packet["path"]
	var length := float(packet["length"])
	if length <= 0.0:
		if not path.is_empty(): packet["node"].position = path[path.size() - 1]
		return true
	packet["raw"] = float(packet["raw"]) + speed * delta
	var traveled := minf(packet_quantum(float(packet["raw"])), length)
	packet["traveled"] = traveled
	packet["node"].position = packet_position(path, traveled / length)
	return float(packet["raw"]) >= length


## 运行游标：会走的标准方块——0.5 m 身体 + 双脚 + 前端工具头块 + 头顶身份标记小块。
static func build_cursor(parent: Node3D, color: Color) -> Node3D:
	var cursor := Node3D.new()
	cursor.name = "RunCursor"
	_cursor_part(cursor, "Body", Vector3(0.5, 0.5, 0.5), Vector3(0, 0.5, 0), color)
	_cursor_part(cursor, "FootL", Vector3(View.PUCK, View.PUCK, View.PUCK), Vector3(-View.PUCK, View.PUCK / 2, 0), color)
	_cursor_part(cursor, "FootR", Vector3(View.PUCK, View.PUCK, View.PUCK), Vector3(View.PUCK, View.PUCK / 2, 0), color)
	_cursor_part(cursor, "ToolHead", Vector3(View.PUCK, View.PUCK, View.PUCK), Vector3(0.5, 0.5, 0), View.EXEC_COLOR)
	_cursor_part(cursor, "Badge", Vector3(View.PUCK, View.PUCK, View.PUCK), Vector3(0, 0.875, 0), Style.CORE)
	parent.add_child(cursor)
	return cursor


static func _cursor_part(parent: Node3D, part_name: String, size: Vector3, offset: Vector3, color: Color) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.name = part_name
	part.mesh = Surface.mesh(size)
	part.material_override = Style.matte(color)
	part.position = offset
	parent.add_child(part)
	return part


## 沿折线走位：纯位置数学（弧长取点 + 0.05 行进浮动 + 朝向行进方向），不用 Tween。
static func step_cursor(cursor: Node3D, path: Array, progress: float) -> void:
	var position := packet_position(path, progress)
	var ahead := packet_position(path, minf(progress + 0.01, 1.0))
	var direction := ahead - position
	direction.y = 0.0
	if direction.length() > 0.001:
		cursor.rotation.y = atan2(-direction.x, -direction.z)
	var bob := BOB * absf(sin(progress * TAU * 4.0))
	cursor.position = position + Vector3(0, bob, 0)


## 批量入队执行事件（保持到达顺序）。
static func queue_events(state: Dictionary, events: Array) -> void:
	state["queue"].append_array(events)


## 事件限速回放：每 EVENT_INTERVAL 秒出队一条；顺带推进本状态的数据包（到站即释放）。
## 返回本帧激活的节点 id 列表（供调用方点亮）。
static func update(state: Dictionary, delta: float, hooks: Dictionary) -> Array:
	var activated: Array = []
	var wires: Dictionary = hooks.get("wires", {})
	var nodes: Dictionary = hooks.get("nodes", {})
	state["timer"] = float(state["timer"]) + delta
	# 0.0001 容差吃掉浮点累加噪音（0.6 = 4×0.15 在二进制里并不精确）。
	while float(state["timer"]) >= EVENT_INTERVAL - 0.0001 and not state["queue"].is_empty():
		state["timer"] -= EVENT_INTERVAL
		activated.append_array(_apply_event(state, state["queue"].pop_front(), wires, nodes, hooks))
	var live: Array = []
	for packet in state["packets"]:
		if advance_packet(packet, delta):
			packet["node"].queue_free()
		else:
			live.append(packet)
	state["packets"] = live
	return activated


static func _apply_event(state: Dictionary, event: Dictionary, wires: Dictionary, nodes: Dictionary, hooks: Dictionary) -> Array:
	match str(event.get("kind", "")):
		"enter":
			state["calls"][str(event.get("callId", ""))] = true
			state["depth"] = state["calls"].size()
			state["max_depth"] = maxi(int(state["max_depth"]), int(state["depth"]))
			return []
		"leave":
			state["calls"].erase(str(event.get("callId", "")))
			state["depth"] = state["calls"].size()
			return []
		"node":
			var fired := str(event.get("nodeId", ""))
			_spawn_packet_on(state, hooks, _incoming_exec(wires, fired), View.EXEC_COLOR)
			return [fired]
		"value":
			var fired := str(event.get("nodeId", ""))
			_spawn_packet_on(state, hooks, _outgoing_value(wires, fired), View.DATA_COLOR)
			return [fired]
		"tool.start":
			var tool_id := str(hooks.get("tools", {}).get(str(event.get("tool", "")), ""))
			if tool_id == "" or not nodes.has(tool_id): return []
			var from: Node3D = nodes[tool_id]
			var target: Vector3 = hooks.get("tool_target", Vector3(0, 0.75, 0))
			var path := View.channel_path(from.position + Vector3(0, 0.5, 0), target)
			_spawn_packet_on(state, hooks, path, TOOL_PULSE_COLOR)
			return [tool_id]
	return []


## 找进入该节点的 exec 控制线（键形如 "*->nodeId.exec"）。
static func _incoming_exec(wires: Dictionary, node_id: String) -> Array:
	var suffix := "->" + node_id + ".exec"
	for key in wires:
		if str(key).ends_with(suffix): return wires[key]
	return []


## 找离开该节点的首条 value 数据线（键形如 "nodeId.value->*"）。
static func _outgoing_value(wires: Dictionary, node_id: String) -> Array:
	var prefix := node_id + ".value->"
	for key in wires:
		if str(key).begins_with(prefix): return wires[key]
	return []


static func _spawn_packet_on(state: Dictionary, hooks: Dictionary, path: Array, color: Color) -> void:
	if path.size() < 2: return
	var root: Node3D = hooks.get("packet_root", null)
	if root == null or not is_instance_valid(root): return
	state["packets"].append(spawn_packet(root, path, color))


## 节点发光工作态：遍历 holder 下所有 MeshInstance3D，在哑光与自发光间切换；
## 基色存 meta（"base_color"），关闭时还原。字砖（meta "text"）不参与：
## 其材质带烘焙 albedo_texture，换材质会把文字洗成白板。
static func set_working(holder: Node3D, on: bool) -> void:
	_for_each_mesh(holder, func(mesh_node: MeshInstance3D): _set_mesh_lit(mesh_node, on))


## call 节点三层叠板按深度点亮前 N 层（取前三个 MeshInstance3D 子节点）；
## holder 下名为 "DepthBadge" 的贴地字砖存在则重写文字并重烘（没有则不建；
## enter/leave 频率低，重烘可接受；headless 下烘焙自动跳过、文字留在砖面 meta）。
static func depth_plates(holder: Node3D, depth: int) -> void:
	var plates: Array = []
	for child in holder.get_children():
		if child is MeshInstance3D and plates.size() < 3: plates.append(child)
	for i in plates.size():
		_set_mesh_lit(plates[i], i < depth)
	var badge := holder.get_node_or_null("DepthBadge")
	if badge is MeshInstance3D and badge.has_meta("text"):
		badge.set_meta("text", PackedStringArray([str(depth)]))
		badge.visible = true
		TextTile.bake_all(holder)


static func _for_each_mesh(node: Node, action: Callable) -> void:
	if node is MeshInstance3D and not node.has_meta("text"): action.call(node)
	for child in node.get_children(): _for_each_mesh(child, action)


static func _set_mesh_lit(mesh_node: MeshInstance3D, on: bool) -> void:
	if mesh_node.material_override == null: return
	if not mesh_node.has_meta("base_color"):
		mesh_node.set_meta("base_color", mesh_node.material_override.albedo_color)
	var base: Color = mesh_node.get_meta("base_color")
	mesh_node.material_override = _lit(base) if on else Style.matte(base)


## 共享自发光材质（按色缓存，与 Style.matte 同一套约定）。
static func _lit(color: Color) -> StandardMaterial3D:
	if _lit_materials.has(color): return _lit_materials[color]
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.emission_enabled = true
	material.emission = color
	material.emission_energy_multiplier = 0.55
	material.roughness = 0.6
	_lit_materials[color] = material
	return material


static func _path_length(path: Array) -> float:
	var total := 0.0
	for i in path.size() - 1:
		total += (path[i + 1] - path[i]).length()
	return total
