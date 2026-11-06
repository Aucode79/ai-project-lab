extends RefCounted

## 装置存档内核（docs/10-契约/交互方案.md §九 双轨之「存档 / 读档」）。
##
## 职责：把当前装置存成命名槽位（关卡检查点或学员自命名版本），
## 读档时清场重放——按记录重建实体 / 绑定 / 连接 / 参数。
## 重试成本要低：改参再跑是几秒的事，不是重新搭场景。
##
## 粒度裁决（记进注释，计划 §5「可延后」的开放问题在此取默认值）：
##   **只存装置与参数，不存整个世界。** 理由：
##   - 装置（实体 + 绑定 + 连接 + 参数）是学员的劳动成果，丢了心疼；
##   - 世界其余部分（地形 / 物理事件去重表 / tick / observe 声明）
##     是环境与过程，由世界初始化重建，不该占存档；
##   - 位置坐标**一律不进存档**（编译器契约同款红线，compiler/graph_model.gd
##     §6.2：逻辑不依赖摆法）。读档时按放置顺序摆在一条确定性直线上，
##     逻辑结论（snapshot 除 pos 外）与存档时逐字段一致。
##
## 自包含性：存档不只存「差异」，还从实体当前形状反推资产模板
## （kind / defaults / ports）一并重建——读档目标可以是任何刚 reset 过的
## 世界，不需要先注册原资产。已知取舍：反推模板的 defaults 取自第一个
## 实例的当前参数、端口模板值取自当前端口值，所以读档后**新放**的同资产
## 实体会继承这些值；装置本身的复原不受影响（参数逐键重放兜底）。
##
## 本类纯逻辑、只碰传入的 WorldStateCore 与 user://saves/；
## 不知道渲染、物理与关卡的存在。别 import levels / scoring。
## 不使用 class_name，消费方一律 preload（同 compiler/graph_model.gd，
## 避开新建脚本的全局类名缓存问题）。
##
## 折叠组：状态层没有组概念（fold_groups 是编译器层的视图标记，
## compiler/graph_model.gd §6.3），存档按同形状 [{id, members}] 原样
## 透传：save 可传入、load 原样奉还，由调用方（未来的 UI/编译入口）重放。

const SCHEMA := "device-save/1"
const SAVES_DIR := "user://saves"

## 折叠组透传上限：防坏档塞进一个巨型数组把读档拖死。
const MAX_GROUPS := 64
const MAX_ENTITIES := 4096
const MAX_EDGES := 8192


# ---------- 存 ----------

## 存当前装置到槽位。level_id 记关卡号（可空）；groups 是编译器层折叠组
## （[{id, members}]，可空）。同名槽位直接覆盖（学员重存自己命名的版本是常态）。
func save(world_state: WorldStateCore, slot_name: String, level_id := "", groups := []) -> Dictionary:
	var name_err := _check_slot_name(slot_name)
	if name_err != "":
		return _err("bad_slot_name", name_err)
	if world_state == null:
		return _err("bad_world", "world_state 为空，没东西可存")
	var snap: Dictionary = world_state.logical_snapshot()
	var entities_in: Dictionary = snap["entities"]
	if entities_in.size() > MAX_ENTITIES:
		return _err("too_many_entities", "实体数 %d 超过存档上限 %d" % [entities_in.size(), MAX_ENTITIES])
	var edges_in: Array = snap["edges"]
	if edges_in.size() > MAX_EDGES:
		return _err("too_many_edges", "连接数 %d 超过存档上限 %d" % [edges_in.size(), MAX_EDGES])
	var groups_in := _sanitize_groups(groups)

	# 实体按（assetId, index）排序落盘：读档按同序重放，实例号才对得上。
	var entities_out: Array = []
	var order: Array = entities_in.keys()
	order.sort_custom(func(a, b): return _entity_sort_key(str(a)) < _entity_sort_key(str(b)))
	for eid in order:
		var e: Dictionary = entities_in[eid]
		entities_out.append({
			"entityId": str(e["entityId"]),
			"assetId": str(e["assetId"]),
			"index": int(e["index"]),
			"kind": str(e["kind"]),
			"params": (e["params"] as Dictionary).duplicate(true),
			"ports": _ports_plain(e["ports"]),
			# 注意：没有 pos——位置不进存档（红线，见类注释）。
			"exists": bool(e["exists"]),
		})

	var doc := {
		"schema": SCHEMA,
		"slot": slot_name,
		"savedAt": Time.get_datetime_string_from_system(true) + "Z",
		"level": level_id,
		"device": {
			"entities": entities_out,
			"bindings": _str_map(snap["bindings"]),
			"edges": edges_in.duplicate(true),
			"groups": groups_in,
		},
	}
	var path := "%s/%s.json" % [SAVES_DIR, slot_name]
	var dir_err := DirAccess.make_dir_recursive_absolute(SAVES_DIR)
	if dir_err != OK and not DirAccess.dir_exists_absolute(SAVES_DIR):
		return _err("io_error", "建不出存档目录 %s：%s" % [SAVES_DIR, error_string(dir_err)])
	var text := JSON.stringify(doc, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return _err("io_error", "打不开存档文件 %s：%s" % [path, error_string(FileAccess.get_open_error())])
	f.store_string(text)
	f.close()
	return {
		"ok": true,
		"slot": slot_name,
		"path": path,
		"level": level_id,
		"entities": entities_out.size(),
		"edges": edges_in.size(),
	}


# ---------- 读 ----------

## 清场重放：目标世界整个 reset（含资产注册表），再按存档记录重建
## 资产模板 → 实体 → 参数 → 绑定 → 连接。返回 {ok, slot, level, groups,
## entities, edges}；文件缺失 / 损坏 / 形状不对时结构化失败，**世界原样不动**。
func load(world_state: WorldStateCore, slot_name: String) -> Dictionary:
	var name_err := _check_slot_name(slot_name)
	if name_err != "":
		return _err("bad_slot_name", name_err)
	if world_state == null:
		return _err("bad_world", "world_state 为空，没地方可恢复")
	var path := "%s/%s.json" % [SAVES_DIR, slot_name]
	if not FileAccess.file_exists(path):
		return _err("no_such_slot", "没有这个存档槽位：%s" % slot_name)
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		return _err("corrupt_slot", "槽位 %s 的文件不是合法 JSON，读档拒绝（世界未动）" % slot_name)
	var doc: Dictionary = parsed
	if str(doc.get("schema", "")) != SCHEMA:
		return _err("bad_schema", "槽位 %s 的 schema 是 %s，本类只认 %s" % [slot_name, str(doc.get("schema", "")), SCHEMA])
	var device_v: Variant = doc.get("device", {})
	if not (device_v is Dictionary):
		return _err("corrupt_slot", "槽位 %s 的 device 不是对象" % slot_name)
	var device: Dictionary = device_v
	var entities_v: Variant = device.get("entities", [])
	if not (entities_v is Array):
		return _err("corrupt_slot", "槽位 %s 的 device.entities 不是数组" % slot_name)
	var entities_in: Array = entities_v
	var bindings_in: Dictionary = {}
	var bindings_v: Variant = device.get("bindings", {})
	if bindings_v is Dictionary:
		for k in bindings_v:
			bindings_in[str(k)] = str((bindings_v as Dictionary)[k])
	var edges_v: Variant = device.get("edges", [])
	var edges_in: Array = edges_v if edges_v is Array else []
	var groups_in := _sanitize_groups(device.get("groups", []))

	# ---- 校验全过才开始动世界（corrupt 档绝不清场） ----
	for e in entities_in:
		if not (e is Dictionary) or str((e as Dictionary).get("assetId", "")) == "":
			return _err("corrupt_slot", "槽位 %s 有实体记录缺 assetId" % slot_name)
		if not ((e as Dictionary).get("params", {}) is Dictionary) \
				or not ((e as Dictionary).get("ports", {}) is Dictionary):
			return _err("corrupt_slot", "槽位 %s 有实体记录的 params/ports 形状不对" % slot_name)

	world_state.reset()

	# 1) 资产模板：同一 assetId 取首个实体反推（defaults=当前参数，ports=当前端口形状）。
	var templates: Dictionary = {}
	for e in entities_in:
		var ent: Dictionary = e
		var aid := str(ent["assetId"])
		if templates.has(aid):
			continue
		templates[aid] = _derive_template(ent)
	for aid in templates:
		var tpl: Dictionary = templates[aid]
		var reg := world_state.register_asset(str(aid), str(tpl["kind"]), tpl["defaults"], tpl["ports"])
		if not bool(reg.get("ok", false)):
			return _err("restore_failed", "重建资产 %s 失败：%s" % [aid, str(reg.get("message", ""))])

	# 2) 实体：按落盘顺序摆到确定性直线 [k,0,0] 上（位置不进档，摆法不影响逻辑）。
	var id_map: Dictionary = {} # 旧 entityId -> 新 entityId
	var k := 0
	for e in entities_in:
		var ent: Dictionary = e
		var placed := world_state.place(str(ent["assetId"]), [k, 0, 0])
		k += 1
		if not bool(placed.get("ok", false)):
			return _err("restore_failed", "重建实体 %s 失败：%s" % [str(ent["entityId"]), str(placed.get("message", ""))])
		id_map[str(ent["entityId"])] = str(placed["entityId"])

	# 3) 参数逐键重放（含 @端口写）。写口径与内核一致：只有被绑定表选中的
	#    实例可写——同资产多实例、绑定指向非首个实例时，先临时改绑到当前
	#    实例重放完，下一步再把绑定表放回存档的样子（bind 是公开改绑入口，
	#    存档时这些参数也只可能是绑定时写进去的）。
	for e in entities_in:
		var ent: Dictionary = e
		if str(ent.get("kind", "")) != WorldStateCore.KIND_PARAMETRIC:
			continue # exhibit/deco 的参数只能是模板默认值，随反推模板带回
		var new_eid := str(id_map[str(ent["entityId"])])
		if not world_state.is_bound(new_eid):
			world_state.bind(str(ent["assetId"]), new_eid)
		var params: Dictionary = ent.get("params", {})
		for key in params:
			var set_ret := world_state.set_param(new_eid, str(key), params[key])
			if not bool(set_ret.get("ok", false)):
				return _err("restore_failed", "重放参数 %s:%s 失败：%s" % [new_eid, str(key), str(set_ret.get("message", ""))])
		var ports: Dictionary = ent.get("ports", {})
		for pid in ports:
			var port: Dictionary = ports[pid]
			var dir := str(port.get("dir", ""))
			if dir == WorldStateCore.PORT_DIR_IN:
				continue # in 口由连线驱动，模板值已随 place 复位，不重放
			# out/io 口显式重放；失败不拦读档——模板值已随 place 带回，
			# 这里只是把「参数逐键重放」做全（同资产多实例端口分叉时兜底）。
			world_state.set_param(new_eid, "@" + str(pid), port.get("value", false))

	# 4) 绑定：place 只做「首个实例自动绑」，显式补齐成存档的样子
	#    （也把第 3 步的临时改绑拨回来）。
	for aid in bindings_in:
		var old_eid := str(bindings_in[aid])
		if not id_map.has(old_eid):
			continue # 坏档里指向不存在的实体：跳过，绑定表保持 place 的默认
		var rebind := world_state.bind(str(aid), str(id_map[old_eid]))
		if not bool(rebind.get("ok", false)):
			return _err("restore_failed", "恢复绑定 %s -> %s 失败：%s" % [aid, old_eid, str(rebind.get("message", ""))])

	# 5) 连接：端口引用里的实体段经 id_map 换成新实例号。
	var restored_edges := 0
	for edge in edges_in:
		var from_old := str((edge as Dictionary).get("from", ""))
		var to_old := str((edge as Dictionary).get("to", ""))
		var from_new := _map_port_ref(from_old, id_map)
		var to_new := _map_port_ref(to_old, id_map)
		if from_new == "" or to_new == "":
			continue # 引用不存在的实体：坏档残余，跳过这条线
		var conn := world_state.connect_ports(from_new, to_new)
		if bool(conn.get("ok", false)):
			restored_edges += 1

	return {
		"ok": true,
		"slot": slot_name,
		"level": str(doc.get("level", "")),
		"savedAt": str(doc.get("savedAt", "")),
		"entities": id_map.size(),
		"edges": restored_edges,
		"groups": groups_in,
		"skippedEdges": (edges_in.size() - restored_edges),
	}


# ---------- 槽位管理 ----------

## 列出全部槽位（文件名序）。坏档不炸：以 valid:false 列出，UI 才能引导删除。
func list_slots() -> Array:
	var out: Array = []
	var dir := DirAccess.open(SAVES_DIR)
	if dir == null:
		return out
	var names: Array = []
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if name.ends_with(".json"):
			names.append(name)
		name = dir.get_next()
	dir.list_dir_end()
	names.sort()
	for fname in names:
		var slot := str(fname).substr(0, str(fname).length() - 5)
		var entry: Dictionary = {"slot": slot, "file": str(fname), "valid": true}
		var parsed = JSON.parse_string(FileAccess.get_file_as_string("%s/%s" % [SAVES_DIR, fname]))
		if parsed is Dictionary and str((parsed as Dictionary).get("schema", "")) == SCHEMA:
			var doc: Dictionary = parsed
			var device: Dictionary = doc.get("device", {})
			entry["savedAt"] = str(doc.get("savedAt", ""))
			entry["level"] = str(doc.get("level", ""))
			entry["entities"] = (device.get("entities", []) as Array).size()
			entry["edges"] = (device.get("edges", []) as Array).size()
		else:
			entry["valid"] = false
		out.append(entry)
	return out


func delete_slot(slot_name: String) -> Dictionary:
	var name_err := _check_slot_name(slot_name)
	if name_err != "":
		return _err("bad_slot_name", name_err)
	var path := "%s/%s.json" % [SAVES_DIR, slot_name]
	if not FileAccess.file_exists(path):
		return _err("no_such_slot", "没有这个存档槽位：%s" % slot_name)
	var rm := DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	if rm != OK:
		return _err("io_error", "删除 %s 失败：%s" % [path, error_string(rm)])
	return {"ok": true, "slot": slot_name}


# ---------- 内部 ----------

func _check_slot_name(slot_name: String) -> String:
	if slot_name == "":
		return "槽位名不能为空"
	for ch in ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]:
		if slot_name.contains(str(ch)):
			return "槽位名不能包含 %s" % str(ch)
	if slot_name.begins_with(".") or slot_name.ends_with("."):
		return "槽位名不能以点开头或结尾"
	return ""


## 实体排序键：assetId 按字典序，index 按数值。拼成定长字符串保证
## sort_custom 只做字符串比较（# 在资产 id 里被禁止，分隔无歧义）。
func _entity_sort_key(eid: String) -> String:
	var cut := eid.find("#")
	var asset := eid if cut < 0 else eid.substr(0, cut)
	var idx := 0
	if cut >= 0:
		var tail := eid.substr(cut + 1)
		if tail.is_valid_int():
			idx = tail.to_int()
	return "%s#%08d" % [asset, idx]


func _ports_plain(ports: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for pid in ports:
		var p: Dictionary = ports[pid]
		out[str(pid)] = {
			"kind": str(p.get("kind", "BOOL")),
			"dir": str(p.get("dir", WorldStateCore.PORT_DIR_IO)),
			"value": p.get("value", false),
		}
	return out


func _str_map(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d:
		out[str(k)] = str(d[k])
	return out


## 从实体当前形状反推资产模板：defaults 取当前参数（读档后 place 即带值），
## ports 取当前端口（kind/dir 保真，模板值取当前值）。
func _derive_template(ent: Dictionary) -> Dictionary:
	var ports: Array = []
	var ports_in: Dictionary = ent.get("ports", {})
	var pids: Array = ports_in.keys()
	pids.sort()
	for pid in pids:
		var p: Dictionary = ports_in[pid]
		ports.append({
			"id": str(pid),
			"kind": str(p.get("kind", "BOOL")),
			"dir": str(p.get("dir", WorldStateCore.PORT_DIR_IO)),
			"value": p.get("value", false),
		})
	return {
		"kind": str(ent.get("kind", WorldStateCore.KIND_PARAMETRIC)),
		"defaults": (ent.get("params", {}) as Dictionary).duplicate(true),
		"ports": ports,
	}


func _map_port_ref(ref: String, id_map: Dictionary) -> String:
	var cut := ref.find(":")
	var eid := ref if cut < 0 else ref.substr(0, cut)
	if not id_map.has(eid):
		return ""
	var new_eid := str(id_map[eid])
	return new_eid if cut < 0 else "%s:%s" % [new_eid, ref.substr(cut + 1)]


## 折叠组白名单化：只留 [{id, members:[字符串]}] 形状的项，数量封顶。
func _sanitize_groups(groups: Variant) -> Array:
	var out: Array = []
	if not (groups is Array):
		return out
	for g in (groups as Array):
		if out.size() >= MAX_GROUPS:
			break
		if not (g is Dictionary):
			continue
		var gid := str((g as Dictionary).get("id", ""))
		if gid == "":
			continue
		var members: Array = []
		for m in ((g as Dictionary).get("members", []) as Array):
			members.append(str(m))
		members.sort()
		out.append({"id": gid, "members": members})
	return out


func _err(code: String, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message}
