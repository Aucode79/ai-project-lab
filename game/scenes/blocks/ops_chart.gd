extends Node3D
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 图表方块（家族二 chart_ 前缀的展示方块；docs/10-契约/方块体系.md §五 #1：透明展柜——
## 分布、曲线、柱状、条形比较、排名图）。本件 = 3D 柱状图，**真实数据驱动、
## 非装饰**：L1 评分后把两次 world.run（stage_run / stage_tune）的实测 ops
## 喂进来（l1_flow.gd _refresh_ops_chart），柱体高度按值比例立起，值变柱变。
##
## 数据契约（与 assets/conc_ops_chart/asset.yaml defaults 对齐）：
##   bars       "label:数字,label:数字"（最多 4 组；非法组跳过、负值钳 0；
##              空串 = 清空展柜——解析永不崩，set_param 返回 false 仅当
##              key 未知或 max_height 非正，图表失败不影响过关判定）
##   title      展柜标题（Label3D）
##   max_height 最大值柱的柱高（米，参数化；其余柱按 v/vmax 比例）
##
## 展示纪律同 player_block：纯显示，不参与判定（判定只看步记录，
## mini-codex §2.1）；柱高数学见 _bar_height（归一化比例，全零不除零）。

const MAX_BARS := 4
const DEFAULT_TITLE := "两次 run 的 ops 对比"

const BASE_COLOR := Style.STRUCTURE
const FRAME_COLOR := Style.SIGNAL
const BAR_COLOR := Style.SIGNAL
const BAR_TEXT_COLOR := Style.INK

const BASE_SIZE := Vector3(2.0, 0.25, 1.0)       # 透明展柜的底板（六面落 0.25 格——2026-09-17 外延落格口径）

## 最大值柱的柱高（米）。可经 set_param("max_height", …) 参数化（须为正）。
var max_height := 1.2

var _title_label: Label3D = null
var _bars_root: Node3D = null
var _bars_text := ""
var _bars: Array = []            # [{label: String, value: float}]（解析后，≤4 组）
var _built := false


func _ready() -> void:
	_ensure_built()


# ---------- 对外 API（l1_scene.refresh_ops_chart 喂图；测试观察口） ----------

## 设参数（资产 defaults 的同名键）。返回 false 仅当 key 未知或 max_height
## 非正；bars 的任何内容（空串/非法 token/全零）都安全落地，绝不崩。
func set_param(key: String, value) -> bool:
	match key:
		"bars":
			_bars_text = str(value)
			_bars = _parse_bars(_bars_text)
			_rebuild()
			return true
		"title":
			_ensure_built()
			_title_label.text = str(value)
			return true
		"max_height":
			var h := float(value)
			if not is_finite(h) or h <= 0.0:
				return false
			max_height = h
			_rebuild()
			return true
		_:
			return false


func get_bars_text() -> String:
	return _bars_text


## 当前柱数（解析后，非法组被跳过）。
func bar_count() -> int:
	return _bars.size()


## 第 i 柱的显示高度（米）：h = max_height * v / vmax，全零时全为 0（不除零）。
func bar_height(i: int) -> float:
	var node := _bar_node(i)
	if node == null:
		return -1.0
	return float(node.get_meta("height", -1.0))


## 第 i 柱的原始值（解析钳 0 后）。
func bar_value(i: int) -> float:
	if i < 0 or i >= _bars.size():
		return -1.0
	return float(_bars[i]["value"])


## 第 i 柱的标签文本。
func bar_label(i: int) -> String:
	if i < 0 or i >= _bars.size():
		return ""
	return str(_bars[i]["label"])


func get_title() -> String:
	return _title_label.text if _title_label != null else DEFAULT_TITLE


# ---------- 内部 ----------

func _ensure_built() -> void:
	if _built:
		return
	_built = true

	# 展柜底板（透明感由低 roughness + 半透明近似）
	var base := MeshInstance3D.new()
	base.name = "Base"
	var base_mesh := BoxMesh.new()
	base_mesh.size = BASE_SIZE
	base.mesh = base_mesh
	base.position = Vector3(0.0, BASE_SIZE.y * 0.5, 0.0)
	var base_mat := StandardMaterial3D.new()
	base_mat.albedo_color = Color(BASE_COLOR, 0.55)
	base_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	base_mat.roughness = 0.25
	base_mat.metallic = 0.1
	base_mesh.material = base_mat
	add_child(base)

	# 展柜边框（顶沿一圈，标记"展柜"范围；沿加宽到 0.25、厚 0.25 使六面落格；
	# y 心 = 柱顶 + 半厚 0.125 + 顶隙 0.05 → y 面 (…+0.05, …+0.3) 落格。高度随 max_height 由 _rebuild 调整）
	var frame := MeshInstance3D.new()
	frame.name = "Frame"
	var frame_mesh := BoxMesh.new()
	frame_mesh.size = Vector3(BASE_SIZE.x + 0.5, 0.25, BASE_SIZE.z + 0.5)
	frame.mesh = frame_mesh
	frame.position = Vector3(0.0, BASE_SIZE.y + max_height + 0.175, 0.0)
	var frame_mat := StandardMaterial3D.new()
	frame_mat.albedo_color = FRAME_COLOR
	frame_mat.emission_enabled = true
	frame_mat.emission = FRAME_COLOR
	frame_mat.emission_energy_multiplier = 0.6
	frame_mesh.material = frame_mat
	add_child(frame)

	# 标题（贴底板前沿）
	_title_label = Label3D.new()
	_title_label.name = "TitleLabel"
	_title_label.text = DEFAULT_TITLE
	_title_label.position = Vector3(0.0, 0.02, BASE_SIZE.z * 0.5 + 0.03)
	_title_label.font_size = 40
	_title_label.pixel_size = 0.003
	_title_label.modulate = BAR_TEXT_COLOR
	_title_label.billboard = BaseMaterial3D.BILLBOARD_DISABLED
	_title_label.double_sided = false
	add_child(_title_label)

	# 柱容器（_rebuild 只动它的子树）
	_bars_root = Node3D.new()
	_bars_root.name = "Bars"
	add_child(_bars_root)

	_rebuild()


## 解析 "label:数字,label:数字"：≤4 组；组内缺冒号/值非数字/标签空 → 跳过该组；
## 负值钳 0。永不崩，空串/全非法 → 空数组（展柜清空）。
func _parse_bars(text: String) -> Array:
	var out: Array = []
	var t := text.strip_edges()
	if t == "":
		return out
	for token in t.split(",", false):
		if out.size() >= MAX_BARS:
			break
		var parts: PackedStringArray = token.split(":", false)
		if parts.size() != 2:
			continue
		var label := parts[0].strip_edges()
		var raw_value := parts[1].strip_edges()
		if label == "" or not raw_value.is_valid_float() or not is_finite(raw_value.to_float()):
			continue
		out.append({"label": label, "value": maxf(0.0, raw_value.to_float())})
	return out


## 柱高数学（测试按归一化比例断言这里）：vmax = max(所有值)；
## v > 0 时 h = max_height * v / vmax，v == 0 时 h = 0；vmax == 0（全零/空）时全 0。
func _bar_height(value: float, vmax: float) -> float:
	if vmax <= 0.0 or value <= 0.0:
		return 0.0
	return max_height * (value / vmax)


## 按当前 _bars 重建柱体：每柱 = Node3D{MeshInstance3D(单位盒按 h 缩放) +
## Label3D(label) + Label3D(数值)}；h == 0 的柱隐藏（meta 仍记 height=0）。
func _rebuild() -> void:
	if not _built or _bars_root == null:
		return
	# 立即释放旧柱（queue_free 会把同名节点留到帧末，get_node_or_null 会撞名）
	for c in _bars_root.get_children():
		_bars_root.remove_child(c)
		c.free()

	var vmax := 0.0
	for b in _bars:
		vmax = maxf(vmax, float(b["value"]))

	# 展柜顶沿跟 max_height 走（参数化最大高度的视觉体现；y 心口径同 _ensure_built）
	var frame := get_node_or_null("Frame") as MeshInstance3D
	if frame != null:
		frame.position.y = BASE_SIZE.y + max_height + 0.175

	var slot_w := BASE_SIZE.x / float(MAX_BARS)
	var bar_w := slot_w * 0.52
	for i in _bars.size():
		var b: Dictionary = _bars[i]
		var h := _bar_height(float(b["value"]), vmax)
		var bar := Node3D.new()
		bar.name = "Bar%d" % i
		bar.set_meta("height", h)
		var x := -BASE_SIZE.x * 0.5 + slot_w * (float(i) + 0.5)

		if h > 0.0:
			var mesh := MeshInstance3D.new()
			mesh.name = "Column"
			var box := BoxMesh.new()
			box.size = Vector3(bar_w, 1.0, bar_w)
			var mat := StandardMaterial3D.new()
			mat.albedo_color = BAR_COLOR
			mat.emission_enabled = true
			mat.emission = BAR_COLOR
			mat.emission_energy_multiplier = 0.55
			box.material = mat
			mesh.mesh = box
			mesh.scale = Vector3(1.0, h, 1.0)
			mesh.position = Vector3(x, BASE_SIZE.y + h * 0.5, 0.0)
			bar.add_child(mesh)
		else:
			# 零值柱：不立柱（数学上高度就是 0），数值标签贴底以示"有数据、无高度"
			bar.set_meta("flat", true)

		var name_lbl := Label3D.new()
		name_lbl.name = "NameLabel"
		name_lbl.text = "%s" % str(b["label"])
		name_lbl.position = Vector3(x, BASE_SIZE.y + h + 0.16, 0.0)
		name_lbl.font_size = 34
		name_lbl.pixel_size = 0.003
		name_lbl.modulate = BAR_TEXT_COLOR
		name_lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		name_lbl.double_sided = false
		bar.add_child(name_lbl)

		var val_lbl := Label3D.new()
		val_lbl.name = "ValueLabel"
		val_lbl.text = "%d" % int(round(float(b["value"])))
		val_lbl.position = Vector3(x, maxf(BASE_SIZE.y, BASE_SIZE.y + h * 0.5), 0.0)
		val_lbl.font_size = 40
		val_lbl.pixel_size = 0.0032
		val_lbl.modulate = BAR_TEXT_COLOR
		val_lbl.billboard = BaseMaterial3D.BILLBOARD_DISABLED
		val_lbl.double_sided = false
		bar.add_child(val_lbl)

		_bars_root.add_child(bar)


func _bar_node(i: int) -> Node3D:
	if _bars_root == null:
		return null
	var node := _bars_root.get_node_or_null("Bar%d" % i)
	return node
