extends RefCounted
const Style := preload("res://scripts/asset_lib/asset_style.gd")

## 沙盒资产常量表（spec §9.1 自由沙盒：已解锁组件可自由拼装）。
##
## 28 件资产（base_ 7 / mach_ 5 / l2_ 3 / conc_ 13）的 kind / blockTypes /
## footprint / ports / defaults / 场景路径，**硬编码常量**。
## 为什么不运行时解析 yaml：资产库的 yaml（assets/assets.yaml 主索引 +
## assets/{assetId}/asset.yaml 单件真相）是给 tools/validate_assets.py 的，
## 游戏侧没有 yaml 解析器；Godot 内置只有 ConfigFile（ini 系），手写完整
## yaml 解析器风险大于收益。取舍：**硬编码 + 测试对账**——
## tests/sandbox/run_sandbox_tests.gd 每次跑都抽样 5 件与
## assets/assets.yaml、assets/{assetId}/asset.yaml 逐字段对账，漂移即 FAIL。
##
## 字段来源（逐件照抄，2026-09-14 快照）：
##   kind/blockTypes/footprint  ← assets/assets.yaml（主索引）
##   ports/defaults              ← assets/{assetId}/asset.yaml（单件真相）
##   scene                       ← 各 asset.yaml 的 scene: 字段（res:// 形式）
##
## 不使用 class_name（同 device_store.gd 纪律：消费方一律 preload）。

# ---- 方块类型 → 生成台基座配色（docs/10-契约/方块体系.md 家族一/二 + 美术方向调色板）----
# 基座颜色取资产 blockTypes 的**首个**类型；一件多类型时首类型是主身份。
const BLOCK_TYPE_COLORS := {
	"code_block": Style.SECONDARY,
	"table_": Style.STRUCTURE,
	"timeline_": Style.SHELL,
	"flow_": Style.SIGNAL,
	"text_": Style.PAPER,
}

## 分组标签（生成台排布用；组内顺序与 assets.yaml 出现顺序一致）。
const GROUP_LABELS := {
	"base": "基础件 base_",
	"mach": "机械件 mach_",
	"l2": "关卡件 l2_",
	"conc": "概念装置 conc_",
}

## 28 件资产规格。每件：
##   kind: register_asset 的类别（全部 parametric）
##   block_types: 方块类型（基座分色 + 点按描述用）
##   footprint: [宽, 深]（格；生成台排布估宽用）
##   scene: 实例化的 tscn（res://）
##   ports: [{id, kind("BOOL"/"ANALOG"), dir("in"/"out"/"io")}]
##   defaults: 参数默认值（register_asset 的 defaults，逐键照抄 asset.yaml）
const SPECS := {
	"base_block": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [1, 1],
		"scene": "res://scenes/assets/base_block.tscn",
		"ports": [
			{"id": "in", "kind": "BOOL", "dir": "in"},
			{"id": "out", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"color_index": 3},
	},
	"base_track": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [4, 1],
		"scene": "res://scenes/assets/base_track.tscn",
		"ports": [
			{"id": "entry", "kind": "BOOL", "dir": "in"},
			{"id": "exit", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"length": 4.0},
	},
	"base_container": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [2, 2],
		"scene": "res://scenes/assets/base_container.tscn",
		"ports": [
			{"id": "mouth", "kind": "BOOL", "dir": "in"},
			{"id": "drain", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"capacity": 8, "wall_height": 0.5},
	},
	"base_gate": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [2, 1],
		"scene": "res://scenes/assets/base_gate.tscn",
		"ports": [
			{"id": "in", "kind": "BOOL", "dir": "in"},
			{"id": "out", "kind": "BOOL", "dir": "out"},
			{"id": "control", "kind": "BOOL", "dir": "in"},
		],
		"defaults": {"door_width": 1.0, "open_by_default": false},
	},
	"base_slot": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [1, 1],
		"scene": "res://scenes/assets/base_slot.tscn",
		"ports": [
			{"id": "slot", "kind": "BOOL", "dir": "io"},
		],
		"defaults": {"accepted_kind": "code_block", "slot_width": 0.5},
	},
	"base_wire": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [2, 1],
		"scene": "res://scenes/assets/base_wire.tscn",
		"ports": [
			{"id": "a", "kind": "BOOL", "dir": "io"},
			{"id": "b", "kind": "BOOL", "dir": "io"},
		],
		"defaults": {"length": 1.0, "carries_analog": false},
	},
	"base_label": {
		"kind": "parametric", "block_types": ["text_"], "footprint": [2, 1],
		"scene": "res://scenes/assets/base_label.tscn",
		"ports": [],
		"defaults": {"label_text": "标签", "panel_width": 1.5},
	},
	"mach_conveyor": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [4, 1],
		"scene": "res://scenes/assets/mach_conveyor.tscn",
		"ports": [
			{"id": "feed", "kind": "BOOL", "dir": "in"},
			{"id": "discharge", "kind": "BOOL", "dir": "out"},
			{"id": "power", "kind": "BOOL", "dir": "in"},
		],
		"defaults": {"belt_speed": 0.8, "belt_length": 4.0},
	},
	"mach_splitter": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [2, 2],
		"scene": "res://scenes/assets/mach_splitter.tscn",
		"ports": [
			{"id": "feed", "kind": "BOOL", "dir": "in"},
			{"id": "out_a", "kind": "BOOL", "dir": "out"},
			{"id": "out_b", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"split_ratio": 0.5},
	},
	"mach_stacker": {
		"kind": "parametric", "block_types": ["code_block", "table_"], "footprint": [2, 2],
		"scene": "res://scenes/assets/mach_stacker.tscn",
		"ports": [
			{"id": "intake", "kind": "BOOL", "dir": "in"},
			{"id": "release", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"stack_height": 3},
	},
	"mach_counter": {
		"kind": "parametric", "block_types": ["code_block", "timeline_"], "footprint": [1, 1],
		"scene": "res://scenes/assets/mach_counter.tscn",
		"ports": [
			{"id": "tick", "kind": "BOOL", "dir": "in"},
			{"id": "count", "kind": "ANALOG", "dir": "out"},
			{"id": "overflow", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"count_start": 0, "digit_count": 3},
	},
	"mach_verify_gate": {
		"kind": "parametric", "block_types": ["code_block", "flow_"], "footprint": [3, 2],
		"scene": "res://scenes/assets/mach_verify_gate.tscn",
		"ports": [
			{"id": "input", "kind": "BOOL", "dir": "in"},
			{"id": "pass", "kind": "BOOL", "dir": "out"},
			{"id": "reject", "kind": "BOOL", "dir": "out"},
			{"id": "control", "kind": "BOOL", "dir": "in"},
		],
		"defaults": {"door_width": 1.0, "fail_closed": true},
	},
	"l2_file_cabinet": {
		"kind": "parametric", "block_types": ["code_block", "table_"], "footprint": [6, 1],
		"scene": "res://scenes/levels/l2/components/file_cabinet.tscn",
		"ports": [],
		"defaults": {"files": "report.txt,data.csv,notes.md,secret.txt,out.txt,config.yaml"},
	},
	"l2_scanner": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [1, 1],
		"scene": "res://scenes/levels/l2/components/scanner.tscn",
		"ports": [
			{"id": "scan_out", "kind": "ANALOG", "dir": "out"},
		],
		"defaults": {"target_file": "report.txt", "scan_range": 3.0, "fade_seconds": 3.0},
	},
	"l2_arm": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [2, 2],
		"scene": "res://scenes/levels/l2/components/arm.tscn",
		"ports": [
			{"id": "grip_busy", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"step_seconds": 0.6},
	},
	"conc_task_board": {
		"kind": "parametric", "block_types": ["code_block", "text_"], "footprint": [3, 1],
		"scene": "res://scenes/levels/l1/components/task_board.tscn",
		"ports": [
			{"id": "task_in", "kind": "ANALOG", "dir": "in"},
			{"id": "task_out", "kind": "ANALOG", "dir": "out"},
		],
		"defaults": {"task_text": ""},
	},
	"conc_nameplate": {
		"kind": "parametric", "block_types": ["text_"], "footprint": [2, 1],
		"scene": "res://scenes/levels/l1/components/nameplate.tscn",
		"ports": [
			{"id": "identity_out", "kind": "ANALOG", "dir": "out"},
		],
		"defaults": {"display_name": "mini codex", "role": "接活与报数"},
	},
	"conc_context_container": {
		"kind": "parametric", "block_types": ["code_block", "table_"], "footprint": [2, 2],
		"scene": "res://scenes/levels/l3/components/context_container.tscn",
		"ports": [
			{"id": "load_in", "kind": "ANALOG", "dir": "in"},
			{"id": "fill_out", "kind": "ANALOG", "dir": "out"},
		],
		"defaults": {"capacity": 8},
	},
	"conc_memory_cabinet": {
		"kind": "parametric", "block_types": ["code_block", "table_"], "footprint": [2, 1],
		"scene": "res://scenes/levels/l3/components/memory_cabinet.tscn",
		"ports": [
			{"id": "note_in", "kind": "ANALOG", "dir": "in"},
			{"id": "note_out", "kind": "ANALOG", "dir": "out"},
		],
		"defaults": {"drawer1": "", "drawer2": "", "drawer3": ""},
	},
	"conc_thinker": {
		"kind": "parametric", "block_types": ["code_block", "flow_", "dialogue_"], "footprint": [2, 1],
		"scene": "res://scenes/levels/l4/components/thinker.tscn",
		"ports": [
			{"id": "prompt_in", "kind": "ANALOG", "dir": "in"},
			{"id": "tokens_out", "kind": "ANALOG", "dir": "out"},
		],
		"defaults": {"prompt": ""},
	},
	"conc_plan_board": {
		"kind": "parametric", "block_types": ["code_block", "flow_"], "footprint": [3, 1],
		"scene": "res://scenes/levels/l4/components/plan_board.tscn",
		"ports": [
			{"id": "plan_in", "kind": "ANALOG", "dir": "in"},
			{"id": "step_out", "kind": "ANALOG", "dir": "out"},
		],
		"defaults": {"plan_text": "[]"},
	},
	"conc_tool_belt": {
		"kind": "parametric", "block_types": ["code_block"], "footprint": [3, 1],
		"scene": "res://scenes/levels/l4/components/tool_belt.tscn",
		"ports": [
			{"id": "tool_in", "kind": "ANALOG", "dir": "in"},
		],
		"defaults": {"selected_tool": ""},
	},
	"conc_runner": {
		"kind": "parametric", "block_types": ["code_block", "flow_", "output_"], "footprint": [2, 1],
		"scene": "res://scenes/levels/l5/components/runner.tscn",
		"ports": [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
			{"id": "out", "kind": "ANALOG", "dir": "out"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"block": "generate_call", "command": "run.count", "bad_calls": 1},
	},
	"conc_verify_gate": {
		"kind": "parametric", "block_types": ["code_block", "flow_"], "footprint": [2, 3],
		"scene": "res://scenes/levels/l5/components/verify_gate.tscn",
		"ports": [
			{"id": "payload", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "next", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"block": "validate"},
	},
	"conc_bypass": {
		"kind": "parametric", "block_types": ["code_block", "flow_"], "footprint": [2, 1],
		"scene": "res://scenes/levels/l5/components/bypass.tscn",
		"ports": [
			{"id": "in", "kind": "ANALOG", "dir": "in"},
		],
		"defaults": {"block": "recover", "max_retries": 3, "retry_count": 0},
	},
	"conc_loop_gallery": {
		"kind": "parametric", "block_types": ["code_block", "flow_"], "footprint": [3, 2],
		"scene": "res://scenes/levels/l5/components/loop_gallery.tscn",
		"ports": [
			{"id": "payload", "kind": "ANALOG", "dir": "in"},
			{"id": "ctl", "kind": "BOOL", "dir": "in"},
			{"id": "loop", "kind": "BOOL", "dir": "out"},
			{"id": "done", "kind": "BOOL", "dir": "out"},
		],
		"defaults": {"block": "guard", "loop_limit": 3, "rounds": 0},
	},
	"conc_ops_chart": {
		"kind": "exhibit", "block_types": ["chart_"], "footprint": [2, 1],
		"scene": "res://scenes/blocks/ops_chart.tscn",
		"ports": [],
		"defaults": {"bars": "", "title": "ops comparison", "max_height": 1.0},
	},
	"player_screen": {
		"kind": "exhibit", "block_types": ["player_"], "footprint": [4, 3],
		"scene": "res://scenes/blocks/player_block.tscn",
		"ports": [],
		"defaults": {"screen_title": "L1 · E49 placeholder video"},
	},
}

## 分组显示顺序（与 assets.yaml 的分节顺序一致：base → mach → L2 → L3-L5 conc）。
const GROUP_ORDER := ["base", "mach", "l2", "conc"]

## Display names only; asset IDs remain the persistence/compiler keys.
const DISPLAY_NAMES := {
	"base_block": "方块", "base_track": "轨道", "base_container": "容器",
	"base_gate": "闸门", "base_slot": "插槽", "base_wire": "导线",
	"base_label": "标签", "mach_conveyor": "传送带", "mach_splitter": "分流器",
	"mach_stacker": "堆叠器", "mach_counter": "计数器", "mach_verify_gate": "校验闸门",
	"l2_file_cabinet": "文件柜", "l2_scanner": "扫描器", "l2_arm": "机械臂",
	"conc_task_board": "任务板", "conc_nameplate": "身份牌",
	"conc_context_container": "上下文容器", "conc_memory_cabinet": "记忆柜",
	"conc_thinker": "思考器", "conc_plan_board": "计划板", "conc_tool_belt": "工具架",
	"conc_runner": "执行器", "conc_verify_gate": "校验器", "conc_bypass": "恢复通道",
	"conc_loop_gallery": "循环回廊", "conc_ops_chart": "统计图", "player_screen": "播放器",
}


static func display_name(asset_id: String) -> String:
	return str(DISPLAY_NAMES.get(asset_id, asset_id))


static func group_of(asset_id: String) -> String:
	var head := asset_id.split("_")[0]
	return head if GROUP_LABELS.has(head) else "conc"


## 28 件资产的 id 列表（分组顺序、组内 assets.yaml 出现顺序）。
static func asset_ids() -> Array:
	var out: Array = []
	for group in GROUP_ORDER:
		for aid in SPECS:
			if group_of(aid) == group:
				out.append(aid)
	return out


## 单件规格（深拷贝，调用方可放心改）。未知 id 返回空表。
static func spec_of(asset_id: String) -> Dictionary:
	if not SPECS.has(asset_id):
		return {}
	var spec: Dictionary = SPECS[asset_id]
	return {
		"kind": str(spec["kind"]),
		"block_types": (spec["block_types"] as Array).duplicate(),
		"footprint": (spec["footprint"] as Array).duplicate(),
		"scene": str(spec["scene"]),
		"ports": (spec["ports"] as Array).duplicate(true),
		"defaults": (spec["defaults"] as Dictionary).duplicate(true),
	}


## 基座配色：首方块类型的颜色（未登记的类型给中性灰）。
static func block_type_color(asset_id: String) -> Color:
	var spec := spec_of(asset_id)
	var types: Array = spec.get("block_types", [])
	var primary := str(types[0]) if not types.is_empty() else "code_block"
	return BLOCK_TYPE_COLORS.get(primary, Color(0.55, 0.55, 0.55))
