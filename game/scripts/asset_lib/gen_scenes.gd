extends SceneTree

## 工具脚本：生成 game/scenes/assets/*.tscn（三层资产库前两层 12 件的最小场景）。
##
## 与 bench/gen_scene.gd 同一模式：不手写 tscn——文本资产安全，手写容易造出
## 无效 uid。这里只写"根节点 + 脚本"的最小形式（ext_resource 用 path、不带
## uid），几何、端口 Marker3D、@export 参数全部由各资产脚本在 _ready 里自建。
##
## 用法："$GODOT" --headless --path game -s res://scripts/asset_lib/gen_scenes.gd
## 幂等：重跑覆盖为相同内容。

const OUT_DIR := "res://scenes/assets"

# [assetId, 根节点名]：assetId 与 assets/{assetId}/asset.yaml 一一对应
const ASSETS := [
	["base_block", "BaseBlock"],
	["base_track", "BaseTrack"],
	["base_container", "BaseContainer"],
	["base_gate", "BaseGate"],
	["base_slot", "BaseSlot"],
	["base_wire", "BaseWire"],
	["base_label", "BaseLabel"],
	["mach_conveyor", "MachConveyor"],
	["mach_splitter", "MachSplitter"],
	["mach_stacker", "MachStacker"],
	["mach_counter", "MachCounter"],
	["mach_verify_gate", "MachVerifyGate"],
]

const TSCN_TMPL := "[gd_scene load_steps=2 format=3]\n\n[ext_resource type=\"Script\" path=\"res://scripts/asset_lib/%s.gd\" id=\"1_%s\"]\n\n[node name=\"%s\" type=\"Node3D\"]\nscript = ExtResource(\"1_%s\")\n"


func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var failed := 0
	for pair in ASSETS:
		var asset_id := str(pair[0])
		var root_name := str(pair[1])
		var path := "%s/%s.tscn" % [OUT_DIR, asset_id]
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f == null:
			push_error("无法写入 %s" % path)
			failed += 1
			continue
		f.store_string(TSCN_TMPL % [asset_id, asset_id, root_name, asset_id])
		f.close()
		print("GEN: %s" % path)
	print("GEN: %d 件资产场景（%s）" % [ASSETS.size() - failed, OUT_DIR])
	quit(1 if failed > 0 else 0)
