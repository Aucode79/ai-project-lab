extends Node3D

## L4 占位幕布（player_ 展示方块的关卡侧包装）。
## 复用 scenes/blocks/player_block.tscn 的全部造型与播/停逻辑，只把占位标题
## 从「L1 · E49 占位视频」换成「L4 · E40 占位视频」——player_block 是共享资产
## （不在 L4 文件所有权内），所以这里用包装 + 标题覆盖，不改原文件。

const PlayerBlockScene := preload("res://scenes/blocks/player_block.tscn")

const TITLE := "L4 · E40 占位视频"

var _inner: Node3D


func _ready() -> void:
	_inner = PlayerBlockScene.instantiate()
	_inner.name = "Screen"
	add_child(_inner)
	# 子节点 _ready 在 add_child 时已跑完（设了 L1 默认标题），这里换成 E40 的
	var label := _inner.get_node_or_null("ScreenLabel") as Label3D
	if label != null:
		label.text = TITLE


# ---------- 对外 API（与 player_block 同形，l4_flow 只认这几个） ----------

func play() -> void:
	_inner.play()


func pause() -> void:
	_inner.pause()


func is_playing() -> bool:
	return _inner.is_playing()


func get_title() -> String:
	return TITLE
