extends SceneTree

## 工具脚本：生成 L4 相关的 5 个 tscn。
##
## 为什么不手写 tscn：文本资产安全——手写容易造出无效 uid。
## 这里只写 Godot 4.7 能安全加载的最小形式（ext_resource 用 path、不带 uid，
## 与 bench/gen_scene.gd、levels/l1/gen_l1_scenes.gd 同一模式）。场景内容全部由
## 各脚本在 _ready 里用代码搭建，tscn 只做"根节点 + 脚本"的挂接。
##
## 用法：godot --headless --path game -s res://scripts/levels/l4/gen_l4_scenes.gd

const SCENES := [
	["res://scenes/levels/l4/components/thinker.tscn", "Thinker", "res://scenes/levels/l4/components/thinker.gd"],
	["res://scenes/levels/l4/components/plan_board.tscn", "PlanBoard", "res://scenes/levels/l4/components/plan_board.gd"],
	["res://scenes/levels/l4/components/tool_belt.tscn", "ToolBelt", "res://scenes/levels/l4/components/tool_belt.gd"],
	["res://scenes/levels/l4/components/e40_screen.tscn", "E40Screen", "res://scenes/levels/l4/components/e40_screen.gd"],
	["res://scenes/levels/l4/l4.tscn", "L4", "res://scripts/levels/l4/l4_scene.gd"],
]


func _initialize() -> void:
	for entry in SCENES:
		var path: String = entry[0]
		var node_name: String = entry[1]
		var script_path: String = entry[2]
		DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		var text := "[gd_scene load_steps=2 format=3]\n\
\n\
[ext_resource type=\"Script\" path=\"%s\" id=\"1_root\"]\n\
\n\
[node name=\"%s\" type=\"Node3D\"]\n\
script = ExtResource(\"1_root\")\n" % [script_path, node_name]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_error("无法写入 %s" % path)
			quit(1)
			return
		f.store_string(text)
		f.close()
		print("GEN: %s（根节点 %s + %s，无 uid，path 引用）" % [path, node_name, script_path])
	quit(0)
