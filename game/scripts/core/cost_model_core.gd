class_name CostModelCore
extends Node

## 成本模型内核（autoload 薄壳：autoload/cost_model.gd）。
##
## spec §7.2：改世界与只读查询**定价不同**，且该数字**能被学员代码读到**，
## 兼作优化指标、行为激励与步骤面板上的标量。落到已有口径：token 即电力，
## ops 是每步的可读计数。
##
## 三档定价：
##   write —— 修改世界的工具（place / connect / set_param）
##   exec  —— 推进世界演化的工具（run / step），同样改世界
##   read  —— 只读查询（inspect / snapshot / read / trace / watch / diff / export_netlist）
## 失败调用不收费（它什么都没改变）。
##
## 这套数字只是默认值，不是物理常数：教学侧可以改价（比如把 snapshot 调贵），
## 只要"写贵读廉"的结构不变。

const MODE_WRITE := "write"
const MODE_EXEC := "exec"
const MODE_READ := "read"

## 默认定价（改造自《编程农场》的 200 : 1，demo 先取 20 : 1）
const WRITE_OPS := 20
const EXEC_OPS := 20
const READ_OPS := 1
const FAILED_OPS := 0

## 累计 ops。外部代码（学员的校验器、步骤面板）直接读这个数。
var total_ops: int = 0

## 各档单价。学员代码可读：让"贵在哪"成为可推理的事实。
func price_of(mode: String) -> int:
	match mode:
		MODE_WRITE:
			return WRITE_OPS
		MODE_EXEC:
			return EXEC_OPS
		MODE_READ:
			return READ_OPS
		_:
			return FAILED_OPS


## 成功调用后计费，返回该步的 ops。
func charge(mode: String) -> int:
	var price := price_of(mode)
	total_ops += price
	return price


## 失败调用计费（0），保证"每个工具调用都有 ops 数字"这个不变量。
func charge_failed() -> int:
	total_ops += FAILED_OPS
	return FAILED_OPS


func reset_totals() -> void:
	total_ops = 0
