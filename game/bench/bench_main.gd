extends SceneTree

## SceneTree 脚本入口：不依赖 spike 的 main.tscn，自成一个可独立跑的入口。
##
## 用法（headless 测物理/烘焙/预测/smoke）：
##   godot --headless --path game -s res://bench/bench_main.gd -- --mode=physics
##   godot --headless --path game -s res://bench/bench_main.gd -- --mode=bake
##   godot --headless --path game -s res://bench/bench_main.gd -- --mode=predict
##   godot --headless --path game -s res://bench/bench_main.gd -- --mode=smoke
## 渲染测量（数一）需要窗口与 Movie Maker，走场景直跑入口（见 tools/bench/run_bench.sh）。
##
## mode 用 meta "bench_mode" 传给 bench_world.gd，与场景直跑的 --mode= 参数共用一套分发。


const WORLD_SCENE := "res://bench/scenes/bench_world.tscn"


func _initialize() -> void:
	var mode := "smoke"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			mode = a.substr("--mode=".length())
	var packed := load(WORLD_SCENE) as PackedScene
	if packed == null:
		push_error("无法加载 %s（先跑 gen_scene.gd 生成）" % WORLD_SCENE)
		quit(1)
		return
	var world := packed.instantiate()
	world.set_meta("bench_mode", mode)
	root.add_child(world)
	print("BENCH MAIN: mode=%s" % mode)
