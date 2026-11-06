class_name PhysicsBridge
extends RefCounted

## 物理→逻辑事件桥（spec §7.1）。
##
## 方向是**单向且显式**的：
##   物理层把"接触"这类事件**上报一次**给状态层（WorldStateCore.apply_physics_event），
##   状态层据此改逻辑状态。本桥只做上报，绝不反向——不读物理引擎状态、
##   不允许状态层去摆弄物理体。红石的准连接性、0-tick 脉冲就是反向隐式耦合
##   的反面教材，这里从结构上杜绝。
##
## demo 只实现接触事件；其他事件类型（推开、堆倒……）保留同一上报通道：
##   report_event({type, entityId, ...})，状态层按 type 分发。
##
## 用法（物理侧示例——接触回调里只上报，不回头改状态层）：
##   var bridge := PhysicsBridge.new(WorldStateCore 实例)
##   var ret := bridge.report_contact("conc_tool_slot_gate#1", Vector3i(4, 0, 1))
##   if not ret.ok and ret.code == "duplicate_event":
##       # 同一事件只该报一次；重复上报被状态层拒绝是正常路径
##       pass
##
## 事件要不要进步记录：走 WorldToolsCore.report_physics_event（phase=event，
## actor=physics），它会记步；直连状态层则只改逻辑不入记录。demo 建议走前者。

var _state: WorldStateCore


func _init(state: WorldStateCore) -> void:
	_state = state


## 接触事件：判定实体（或装饰实体）在哪个格点被物理碰到。
## 同一 (entityId, cell) 的接触只生效一次，重复上报返回 duplicate_event。
func report_contact(entity_id: String, cell: Vector3i) -> Dictionary:
	return report_event({"type": "contact", "entityId": entity_id, "cell": [cell.x, cell.y, cell.z]})


## 通用事件上报入口。返回 {ok} 或 {ok: false, code, message}，绝不触发物理侧任何东西。
func report_event(event: Dictionary) -> Dictionary:
	assert(_state != null, "PhysicsBridge 构造时必须注入 WorldStateCore")
	return _state.apply_physics_event(event)
