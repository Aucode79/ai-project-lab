extends SceneTree

## chart_ 图表方块（conc_ops_chart）测试。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/blocks/run_ops_chart_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 覆盖（验收标准，≥6 条）：
##  T1  组件可实例化：展柜结构齐（Base/Frame/TitleLabel/Bars），离树 set_param 安全
##  T2  四组值柱高比例正确（数学断言，归一化：h = max_height * v / vmax）
##  T3  值更新刷新：换 bars / 换 max_height 都重算柱高
##  T4  零值/空值/非法输入不崩：空串、全零、纯垃圾串、非法组跳过、负值钳 0、
##      max_height 非法返回 false 不改状态
##  T5  资产台账自检（yaml 合法性文本断言）：conc_ops_chart=exhibit+[chart_]、
##      主索引 28 条、conc_thinker 含 dialogue_、conc_runner 含 output_、
##      scene 指向的 tscn 存在
##  T6  L1 回归（图表接入不破坏判定）：drive_full 后 check_pass=true（pass 为真），
##      且两次 world.run 的实测 ops 真喂进了图表（bars 含 run1:/run2: 两段）

const OpsChartScene := preload("res://scenes/blocks/ops_chart.tscn")
const L1FlowScript := preload("res://scripts/levels/l1/l1_flow.gd")

## l1_flow 的最小 view 替身：只兑现它点名的鸭子接口，捕获喂给图表的 bars。
class FakeView extends RefCounted:
	var captured_bars := ""

	func get_player_screen() -> RefCounted:
		return FakeScreen.new()

	func install_task_board() -> void:
		pass

	func install_nameplate() -> RefCounted:
		return FakePlate.new()

	func get_task_board() -> RefCounted:
		return FakeBoard.new()

	func get_nameplate() -> RefCounted:
		return FakePlate.new()

	func board_front_pos() -> Vector3:
		return Vector3.ZERO

	func codex_goto(_target: Vector3, _seconds := 0.8) -> void:
		pass

	func refresh_ops_chart(bars: String) -> void:
		captured_bars = bars


class FakeScreen extends RefCounted:
	func play() -> void:
		pass


class FakePlate extends RefCounted:
	func apply_identity(_n: String, _r: String) -> void:
		pass

	func set_identity_lit(_v: bool) -> void:
		pass


class FakeBoard extends RefCounted:
	func set_task_text(_t: String) -> void:
		pass

	func set_state_visual(_s: String) -> void:
		pass


var _passed := 0
var _failed := 0
var _garbage: Array[Node] = []


func _initialize() -> void:
	_run_all.call_deferred()


func _run_all() -> void:
	_t01_instantiate()
	_t02_height_math()
	_t03_refresh_on_update()
	_t04_bad_input_safe()
	_t05_asset_ledger()
	await _t06_l1_regression()
	_cleanup()
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


# ---------- 基础设施 ----------

func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


func _fresh_chart():
	var chart := OpsChartScene.instantiate()
	root.add_child(chart)   # _ready -> _ensure_built
	_garbage.append(chart)
	return chart


func _fresh_tools() -> WorldToolsCore:
	var st := WorldStateCore.new()
	var rc := StepRecorderCore.new()
	var cm := CostModelCore.new()
	var tools := WorldToolsCore.new()
	tools.own_state = st
	tools.own_recorder = rc
	tools.own_cost = cm
	_garbage.append_array([st, rc, cm, tools])
	return tools


## game/ 的上一级（仓库根）下读文本文件；headless 本地跑 res:// 即 game/。
func _repo_file_text(rel: String) -> String:
	var game_root := ProjectSettings.globalize_path("res://").rstrip("/")
	return FileAccess.get_file_as_string(game_root.get_base_dir().path_join(rel))


# ---------- 测试 ----------

func _t01_instantiate() -> void:
	var ok := true
	var chart: Node = _fresh_chart()
	ok = ok and chart.has_node("Base") and chart.has_node("Frame") \
		and chart.has_node("TitleLabel") and chart.has_node("Bars")
	ok = ok and chart.bar_count() == 0 and chart.get_title() == "两次 run 的 ops 对比"
	ok = ok and chart.set_param("title", "效率对比") and chart.get_title() == "效率对比"
	ok = ok and not chart.set_param("unknown_key", 1)      # 未知键返回 false
	# 离树实例化后立即 set_param 也不崩（懒构建）
	var off_tree := OpsChartScene.instantiate()
	ok = ok and off_tree.set_param("bars", "run1:10,run2:20") and off_tree.bar_count() == 2
	off_tree.free()
	_check(ok, "T1 图表方块可实例化：展柜结构齐（Base/Frame/TitleLabel/Bars）、title 可写、未知键拒绝、离树 set_param 安全")


func _t02_height_math() -> void:
	var ok := true
	var chart: Node = _fresh_chart()
	var mh: float = chart.max_height
	ok = ok and chart.set_param("bars", "run1:100,run2:200,run3:50,run4:150")
	ok = ok and chart.bar_count() == 4
	# 数学断言：h_i = max_height * v_i / vmax（vmax=200）
	var h1: float = chart.bar_height(0)
	var h2: float = chart.bar_height(1)
	var h3: float = chart.bar_height(2)
	var h4: float = chart.bar_height(3)
	ok = ok and is_equal_approx(h2, mh) and is_equal_approx(h1, mh * 0.5) \
		and is_equal_approx(h3, mh * 0.25) and is_equal_approx(h4, mh * 0.75)
	# 归一化比例：与 max_height 无关的相对关系
	ok = ok and is_equal_approx(h2 / h1, 2.0) and is_equal_approx(h3 / h1, 0.5) \
		and is_equal_approx(h4 / h2, 0.75)
	# 标签与值原样可读
	ok = ok and chart.bar_label(0) == "run1" and chart.bar_label(3) == "run4"
	ok = ok and is_equal_approx(chart.bar_value(1), 200.0)
	_check(ok, "T2 四组值柱高比例正确：h=max_height*v/vmax（%.2f/%.2f/%.2f/%.2f，归一化比 2.0/0.5/0.75）" % [h1, h2, h3, h4])


func _t03_refresh_on_update() -> void:
	var ok := true
	var chart: Node = _fresh_chart()
	chart.set_param("bars", "run1:100,run2:200")
	# 换 max_height（参数化最大高度）：柱高整体重算
	ok = ok and chart.set_param("max_height", 3.0)
	ok = ok and is_equal_approx(chart.bar_height(1), 3.0) \
		and is_equal_approx(chart.bar_height(0), 1.5)
	# 换值（同 2 柱改数值 + 加第 3 柱）：新最大值换主，旧柱按新比例缩
	ok = ok and chart.set_param("bars", "run1:100,run2:300,run3:600")
	ok = ok and chart.bar_count() == 3
	ok = ok and is_equal_approx(chart.bar_height(2), 3.0) \
		and is_equal_approx(chart.bar_height(1), 1.5) \
		and is_equal_approx(chart.bar_height(0), 0.5)
	ok = ok and chart.get_bars_text() == "run1:100,run2:300,run3:600"
	_check(ok, "T3 值更新刷新：换 max_height 与换 bars 都重算（600 为新峰，100/300/600 -> 0.5/1.5/3.0）")


func _t04_bad_input_safe() -> void:
	var ok := true
	var chart: Node = _fresh_chart()
	chart.set_param("bars", "run1:100,run2:200")
	# 空串：清空展柜，不崩
	ok = ok and chart.set_param("bars", "") and chart.bar_count() == 0
	# 全零：不除零，柱高全 0
	ok = ok and chart.set_param("bars", "a:0,b:0") and chart.bar_count() == 2
	ok = ok and chart.bar_height(0) == 0.0 and chart.bar_height(1) == 0.0
	# 纯垃圾串：0 组，不崩
	ok = ok and chart.set_param("bars", "junk") and chart.bar_count() == 0
	# 非法组跳过 + 负值钳 0：只有 y 落地
	ok = ok and chart.set_param("bars", "x:abc,y:-5") and chart.bar_count() == 1
	ok = ok and chart.bar_label(0) == "y" and chart.bar_value(0) == 0.0
	# max_height 非法：返回 false 且状态不变（柱高维持上一帧）
	ok = ok and not chart.set_param("max_height", 0.0)
	ok = ok and not chart.set_param("max_height", -2.0)
	ok = ok and is_equal_approx(chart.max_height, 1.2)
	# 越界下标读数安全
	ok = ok and chart.bar_height(9) == -1.0 and chart.bar_label(-1) == ""
	_check(ok, "T4 零值/空值/非法输入不崩：空串清空、全零不除零、垃圾串 0 组、非法组跳过、负值钳 0、max_height 非法拒绝")


func _t05_asset_ledger() -> void:
	var ok := true
	# 单件：exhibit + chart_ + c10.3，scene 指向真实 tscn
	var yaml := _repo_file_text("assets/conc_ops_chart/asset.yaml")
	ok = ok and yaml != "" and yaml.contains("kind: exhibit") \
		and yaml.contains("blockTypes: [chart_]") and yaml.contains("conceptIds: [c10.3]")
	ok = ok and yaml.contains("scene: game/scenes/blocks/ops_chart.tscn")
	ok = ok and FileAccess.file_exists("res://scenes/blocks/ops_chart.tscn")
	# 重指派两件：dialogue_ / output_（方块体系 §五 #8/#9 的语义）
	ok = ok and _repo_file_text("assets/conc_thinker/asset.yaml").contains("blockTypes: [code_block, flow_, dialogue_]")
	ok = ok and _repo_file_text("assets/conc_runner/asset.yaml").contains("blockTypes: [code_block, flow_, output_]")
	# 主索引：27 条，与单件一致（完整对账由 tools/validate_assets.py 把关，此处文本自证）
	var index := _repo_file_text("assets/assets.yaml")
	var entries := 0
	for line in index.split("\n"):
		if line.strip_edges().begins_with("- assetId:"):
			entries += 1
	ok = ok and entries == 28
	ok = ok and index.contains("assetId: conc_ops_chart") \
		and index.contains("blockTypes: [code_block, flow_, dialogue_]") \
		and index.contains("blockTypes: [code_block, flow_, output_]")
	_check(ok, "T5 资产台账自检：conc_ops_chart=exhibit+[chart_]+c10.3、tscn 在位、thinker+dialogue_/runner+output_、主索引 28 条")


func _t06_l1_regression() -> void:
	var ok := true
	var tools := _fresh_tools()
	var flow := L1FlowScript.new()
	var view := FakeView.new()
	flow.tools = tools
	flow.view = view
	var verdict: Dictionary = await flow.drive_full()
	# 图表接入不破坏判定：五阶段 + 落盘 + check_pass 照旧为真
	ok = ok and bool(verdict.get("pass", false))
	ok = ok and tools.recorder().state_name() == "frozen"
	# 两次 world.run 的实测 ops 真喂进了图表（score 段 _refresh_ops_chart）
	var bars := view.captured_bars
	ok = ok and bars.contains("run1:") and bars.contains(",run2:") and not bars.contains("run3:")
	var ops_pairs := bars.split(",", false)
	ok = ok and ops_pairs.size() == 2 \
		and str(ops_pairs[0]).begins_with("run1:") and str(ops_pairs[1]).begins_with("run2:")
	# 世界里图表实体就位（exhibit 声明，盘点的世界侧证据）
	ok = ok and flow.chart_eid != "" \
		and str(tools.state().state_digest()).contains("conc_ops_chart")
	flow.free()
	_check(ok, "T6 L1 回归：drive_full 判定照旧为真（图表不影响过关），两次 run 的实测 ops 已喂图（%s）" % bars)


func _cleanup() -> void:
	for n in _garbage:
		if n != null and is_instance_valid(n):
			n.free()
	_garbage.clear()
