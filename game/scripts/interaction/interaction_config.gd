class_name InteractionConfig
extends Resource

## 学员交互系统的全部可调参数（docs/10-契约/交互方案.md §十三待补项 5：长按阈值与预测预算）。
##
## 全部走 @export，运行前可整体替换（测试里就是靠换一份 config 改阈值来验证的）。
## 数字口径来源：
##   long_press_threshold_ms  250 —— 交互方案 §二"≤250ms 松开=点按，>250ms 按住=长按"
##   prediction_horizon_s     1.5 —— 测量结果 §数三：2s 前推要 2s 墙钟，缩视界到 1.5s
##   recompute_interval_ms    100 —— 测量结果：100ms 降频在 CPU 上零代价，无条件采纳
## 预测绝不放大物理步长、绝不在主线程同步跑满（见 ghost_predictor.gd 头注释）。

## 长按判定阈值：按住超过这个毫秒数即进入拖拽（松开早于等于它是点按）。
@export var long_press_threshold_ms: float = 250.0

## 虚影前推视界（秒）。测量结果：同引擎前推以真实速度推进，视界=延迟，故取小。
@export var prediction_horizon_s: float = 1.5

## 预测重算降频间隔（毫秒）。手再怎么动，两次重算之间至少隔这么久。
@export var recompute_interval_ms: float = 100.0

## 手移动重算阈值（米）：手挪动超过这个距离才值得重算一次预测。
@export var hand_move_threshold_m: float = 0.10

## 拖拽抬起高度（米）：长按抓起后物件悬在手位置上方多少。
@export var lift_height_m: float = 0.6

## 抬起跟随速度（1/秒，越大越跟手）。"有重量感"= 缓动跟随而不是瞬移。
@export var follow_speed: float = 10.0

## 松手携带系数：手上惯性多大比例传给物件（抛掷手感）。
@export var carry_factor: float = 0.8

## 停手判定（毫秒）：手停住超过这么久，松手不再沿用最后一次移动的速度。
## 没有它时"移动→停顿→松手"仍按最后一次移动速度抛出（实测会把物件扔出场外）。
@export var hand_stop_ms: float = 150.0

## 落定判定：线速度/角速度低于阈值并保持这么多个物理帧才算停稳。
@export var settle_speed: float = 0.08
@export var settle_frames: int = 10

## 预设位切换过渡时长（秒）。
@export var preset_transition_s: float = 0.45

## 慢放/加速档位循环（取帧策略，绝不放大物理步长）。
@export var speed_steps: Array[float] = [1.0, 0.5, 0.25, 2.0, 4.0]
