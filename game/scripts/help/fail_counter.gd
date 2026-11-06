extends RefCounted

## 失败计数服务（docs/10-契约/交互方案.md §五 + §十三 待定 2）。
## 触发阈值：同一关内尝试失败 3 次才开始给提示（Code.org 实测参数
## hintPromptAttemptsThreshold: 3——太早给提示让人不再思考，太晚就流失）。
##
## 计数口径（待定 2 的默认裁决）：**按关卡计**（level_id 为键），
## 不按组件计——按关卡更宽松，让"卡住了"这件事本身够数。
##
## 纯逻辑：不知道场景、不知道节点、不进步记录。
## 这是求助服务自身的工作状态（允许——它不是组件四态；组件的显示状态
## 仍由步记录派生，见 mini-codex §2.1 的纪律）。
##
## 不用 class_name：消费方一律 preload 本路径
## （check-only 干净缓存下 class_name 解析不到，见 asset_lib/asset_node.gd 注释）。

var threshold := 3

var _fails := {}   # level_id -> 已失败次数


## 记一次失败，返回该关当前累计。
func count_fail(level_id: String) -> int:
	_fails[level_id] = int(_fails.get(level_id, 0)) + 1
	return int(_fails[level_id])


func fails(level_id: String) -> int:
	return int(_fails.get(level_id, 0))


## 是否已达提示解锁阈值。
func unlocked(level_id: String) -> bool:
	return fails(level_id) >= threshold


## 清某一关的计数（进下一关/重开时用）。
func reset(level_id: String) -> void:
	_fails.erase(level_id)


func clear() -> void:
	_fails.clear()
