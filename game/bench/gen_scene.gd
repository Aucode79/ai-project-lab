extends SceneTree

## 工具脚本：生成 game/bench/scenes/bench_world.tscn。
##
## 为什么不手写 tscn：文本资产安全——手写容易造出无效 uid。
## 这里只写 Godot 4.7 能安全加载的最小形式（ext_resource 用 path、不带 uid，
## 与 scenes/main.tscn 同一模式）。场景内容全部由 bench_world.gd 在 _ready 里
## 用代码搭建，tscn 只做"根节点 + 脚本"的挂接。
##
## 用法：godot --headless --path game -s res://bench/gen_scene.gd

const TSCN_PATH := "res://bench/scenes/bench_world.tscn"

const TSCN_TEXT := "[gd_scene load_steps=2 format=3]\n\
\n\
[ext_resource type=\"Script\" path=\"res://bench/bench_world.gd\" id=\"1_bench_world\"]\n\
\n\
[node name=\"BenchWorld\" type=\"Node3D\"]\n\
script = ExtResource(\"1_bench_world\")\n"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute("res://bench/scenes")
	var f := FileAccess.open(TSCN_PATH, FileAccess.WRITE)
	if f == null:
		push_error("无法写入 %s" % TSCN_PATH)
		quit(1)
		return
	f.store_string(TSCN_TEXT)
	f.close()
	print("GEN: %s 已生成（无 uid，path 引用）" % TSCN_PATH)
	quit(0)
