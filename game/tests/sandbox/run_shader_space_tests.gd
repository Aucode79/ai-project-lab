extends SceneTree

## 着色器坐标空间契约（headless，退出码制）。跑法：
##   tools/godot/Godot_v4.7.2-stable_win64_console.exe --headless --path game \
##     -s res://tests/sandbox/run_shader_space_tests.gd
## 退出码 0 = 全部 PASS；非 0 = 有 FAIL。逐条 print PASS/FAIL。
##
## 为什么单开一套：Godot 的 spatial shader 里，**fragment 阶段的 VERTEX 与 NORMAL 都是
## 视空间**（官方文档 built-ins 表原文："Position of the fragment (pixel), in view space."
## / "Normal that comes from the vertex() function, in view space."），而 MODEL_MATRIX 是
## "model/local space to world space"。于是这两类写法都是错的，而且**错得很难发现**：
##   1. `MODEL_MATRIX * vec4(VERTEX, 1.0)` —— 拿模型→世界的矩阵乘一个视空间的点
##   （同类错法还有 `mix(NORMAL, vec3(0.0, 1.0, 0.0), k)` —— 把视空间法线和"世界向上"混在一起
##    把视空间法线和"世界向上"混在一起。那处出现在原草叶 shader 上；草改成顶层方块的
##    表面之后该文件已删，这条判定随之移除，但错法本身仍记在 AGENTS.md 已知坑位 7。）
## 这种写法**编译得过、跑得起来、单张截图看着还挺像**（沙盒 2026-09-16 那版就是这样：
## 砖格花纹与风化全焊在相机上，环绕时在方块表面游动）。
## 症状只在转镜头时才显现，而 headless 又不执行 shader —— 所以这里钉的是**坐标空间
## 契约本身**：世界量必须在 vertex() 里算好、经 varying 传到 fragment。
## 这是对一条有官方文档背书的既知坑位上的锁，不是对 shader 实现的镜像复刻。
## 修复前后对照证据：game/shots/art-upgrade/A1/diag_y_before.png（视空间）/
## diag_y_after.png（世界空间）。
##
## 覆盖（3 条）：
##  T1 方块 shader：fragment() 段内不得出现 MODEL_MATRIX
##  T2 方块 shader：世界位置/法线由 vertex() 经 varying 传出，且 fragment 读的是它
##  T3 装配对账：场景里的地形方块库确实挂着这份 shader
##  （"草是顶层方块表面"那套口径在 run_island_tests 的 T10 钉，不在这里重复）

const BlockShader := preload("res://scripts/sandbox/sandbox_block.gdshader")
const DioramaScript := preload("res://scripts/sandbox/sandbox_diorama.gd")
const SandboxScene := preload("res://scenes/sandbox/sandbox.tscn")

var _passed := 0
var _failed := 0


func _initialize() -> void:
	_t01_block_no_view_space_world_recon()
	_t02_block_world_via_varying()
	await _t03_materials_use_this_shader()
	print("TOTAL: %d passed, %d failed" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _check(cond: bool, label: String) -> bool:
	if cond:
		_passed += 1
		print("PASS: " + label)
	else:
		_failed += 1
		print("FAIL: " + label)
	return cond


# ---------- 源码工具 ----------

## 取某个阶段的函数体（从 "void <stage>(" 到该函数收口的行首 "}"），并**剥掉注释**。
## 剥注释是必须的：注释里提到 MODEL_MATRIX / VIEW_MATRIX 是常有的事（修这个 bug 时
## 注释就会解释这个坑），不剥的话判定会被注释文本喂饱 —— 实测过：T3 在修复前的
## 草 shader 上假绿过，成因正是 fragment 里那句解释里出现了 VIEW_MATRIX 这个词。
func _stage_body(code: String, stage: String) -> String:
	var lines := code.split("\n")
	var start := -1
	for i in lines.size():
		if lines[i].begins_with("void %s(" % stage):
			start = i
			break
	if start < 0:
		return ""
	var out := PackedStringArray()
	for i in range(start, lines.size()):
		out.append(lines[i])
		if i > start and lines[i].begins_with("}"):
			break
	return _strip_comments("\n".join(out))


## 去掉 // 行注释与 /* */ 块注释。
func _strip_comments(s: String) -> String:
	var out := PackedStringArray()
	var in_block := false
	for line in s.split("\n"):
		var t := line
		if in_block:
			var e := t.find("*/")
			if e < 0:
				continue
			t = t.substr(e + 2)
			in_block = false
		var b := t.find("/*")
		if b >= 0:
			t = t.substr(0, b)
			in_block = true
		var c := t.find("//")
		if c >= 0:
			t = t.substr(0, c)
		out.append(t)
	return "\n".join(out)


## 去掉全部空白，便于匹配字面量（写法上空格/换行不该影响判定）。
func _squash(s: String) -> String:
	return s.replace(" ", "").replace("\t", "").replace("\n", "").replace("\r", "")


## 文件里声明了哪些 varying vec3。
func _varying_names(code: String) -> Array:
	var out: Array = []
	for line in code.split("\n"):
		var t := line.strip_edges()
		if t.begins_with("varying vec3 "):
			var n := t.substr("varying vec3 ".length()).strip_edges()
			out.append(n.trim_suffix(";").strip_edges())
	return out


# ---------- T1 方块 shader 不在 fragment 里重建世界坐标 ----------

## 视空间里重建世界坐标是做不到的：`MODEL_MATRIX * VERTEX` 得到的既不是世界也不是
## 视空间，而是跟着相机转的坐标。fragment 段一旦出现 MODEL_MATRIX，就是在犯这个错。
func _t01_block_no_view_space_world_recon() -> void:
	var frag := _squash(_stage_body(BlockShader.code, "fragment"))
	_check(frag != "" and not frag.contains("MODEL_MATRIX"),
		"T1 方块 shader：fragment() 段内不出现 MODEL_MATRIX（视空间重建世界坐标必错，"
		+ "症状是砖格/花纹环绕时在表面游动）")


# ---------- T2 世界量走 vertex() → varying ----------

func _t02_block_world_via_varying() -> void:
	var vert := _squash(_stage_body(BlockShader.code, "vertex"))
	var frag := _squash(_stage_body(BlockShader.code, "fragment"))
	var decls := _varying_names(BlockShader.code)
	var frag_uses := false
	for n in decls:
		if frag.contains(str(n)):
			frag_uses = true
	var ok: bool = vert != "" and vert.contains("MODEL_MATRIX") \
		and decls.size() >= 2 and frag_uses
	_check(ok, "T2 方块 shader：世界位置与世界法线由 vertex()（%d 个 varying vec3：%s）传出、"
		% [decls.size(), str(decls)]
		+ "fragment 读的是它们（世界量的唯一通路）")


# ---------- T3 装配对账：材质真的挂着这份 shader ----------

## 契约再对，接错文件也白搭：地形方块库必须挂着这份 shader。
func _t03_materials_use_this_shader() -> void:
	var lib := DioramaScript.build_library()
	var models := lib.get_models()
	var block_matched := 0
	var block_total := 0
	for i in range(1, models.size()):
		var mat = models[i].get_material_override(0)
		block_total += 1
		if mat is ShaderMaterial and (mat as ShaderMaterial).shader != null \
				and (mat as ShaderMaterial).shader.code == BlockShader.code:
			block_matched += 1

	var scene: Node3D = SandboxScene.instantiate()
	root.add_child(scene)
	for i in 5:
		await create_timer(0.02).timeout
	var terrain_ok := false
	var terrain := scene.get_node_or_null("Terrain")
	if terrain != null and terrain.mesher != null and terrain.mesher.library != null:
		terrain_ok = terrain.mesher.library.get_models().size() == models.size()
	_check(block_matched == block_total and block_total > 0 and terrain_ok,
		"T3 装配对账：地形方块库 %d/%d 个模型的材质是 block shader、"
		% [block_matched, block_total]
		+ "场景地形库与 build_library() 同尺寸=%s" % str(terrain_ok))
	scene.free()
	await physics_frame
