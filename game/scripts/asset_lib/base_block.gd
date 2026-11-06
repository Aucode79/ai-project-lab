extends "res://scripts/asset_lib/asset_node.gd"

## base_block 通用方块：沙盒里最基本的 token 载体，纯静态几何。
## 两个 BOOL 端口在左右两面（流向：-X 进、+X 出），占 1 格。
## 尺寸是标准方块：STANDARD_CUBE_SIZE（基座常量，0.5 m 正立方体，不可调）——
## 1 方块 = 1 个 token/样本，方块是这套世界的基本量
## （docs/10-契约/方块体系.md「标准方块 · 基本量」）。
## 块状化 v2：旧裙边底座（厚 0.06 无法落格）删除——本体 0.5³ 即全部，
## 安装位语义由端口方标承担；端口方标 0.25³ 整贴本体 ±X 面外侧（间隙 0，
## 心挪半格使六面落 0.25 m 世界格——T7 外延落格口径，2026-09-17）。
## assets/base_block/asset.yaml: defaults {color_index: 3}

@export var color_index: int = PAL_DECK

var _built := false


func _ready() -> void:
	_build()


func _build() -> void:
	if _built:
		return
	_built = true
	add_box(self, "Body", Vector3.ONE * STANDARD_CUBE_SIZE,
		Vector3(0.0, STANDARD_CUBE_SIZE * 0.5, 0.0), color_index)
	var half := STANDARD_CUBE_SIZE * 0.5
	# 端口方标 0.25³：0.25 部件的中心落在 0.25 m 格点时六面全在半格上（T7 外延落格判红），
	# 所以方标改整贴在本体 ±X 面外侧、心各向挪半格落格（露出 0.25，对本体仍是间隙 0 的贴合）。
	# 只挪 Mark 网格，Marker3D 端口位置一字不动（编译器不读端口位置，语义不变）
	var in_mark := add_port("in", Vector3(-half, half, 0.0)).get_node("Mark") as MeshInstance3D
	in_mark.position = Vector3(-0.125, 0.125, 0.125)   # 贴 -X 面外，六面落 0.25 m 格
	var out_mark := add_port("out", Vector3(half, half, 0.0)).get_node("Mark") as MeshInstance3D
	out_mark.position = Vector3(0.125, 0.125, 0.125)   # 贴 +X 面外，六面落 0.25 m 格
