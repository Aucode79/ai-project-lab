class_name StepRecorderCore
extends Node

## 步记录内核（autoload 薄壳：autoload/step_recorder.gd）。
##
## spec §6，schema v6，逐字段照抄：
##
##   schemaVersion: 6
##   run:    { runId, kind, episode?, seed, rulesetVersion, engineHash, startedAt }
##           kind: explore（交互探索）| task（学员完成任务的运行，可判定）
##               | production（拍片用的运行）
##   steps:  [{ i, t, phase, actor, causes, input, action, output,
##              tokens, ops, costMs, world: { entities, highlight },
##              caption, formula }]
##   failures: [{ stepRef, failId, code, diagnosis }]
##
## 契约：与渲染无关；**一次运行一份，写完即冻结**（文件只写一次）；
## 时间只有 t（世界秒），costMs 与 ops 不驱动任何逻辑，仅供诊断；
## action 含工具名与完整参数；判定只对 kind == task 的运行做，
## 依据是这份记录本身，不需要重跑世界。

const SCHEMA_VERSION := 6
const RULESET_VERSION := "world-kernel/1"

const KIND_EXPLORE := "explore"
const KIND_TASK := "task"
const KIND_PRODUCTION := "production"

const RUN_OUT_ROOT := "res://runs"

var _doc: Dictionary = {}
var _state_name := "idle" # idle | recording | frozen
var _run_seq := 0
var _last_step := -1
var _frozen_text := ""
var _out_path := ""


## 开启一次运行。episode >= 0 才写进 run（spec 标了 episode?，explore 常无集号）。
## seed 仍记录（同一初始条件好复现现场），但不承诺两次跑出相同物理（spec §6）。
func begin_run(kind: String, episode := -1, seed := 0) -> Dictionary:
	if not [KIND_EXPLORE, KIND_TASK, KIND_PRODUCTION].has(kind):
		return {"ok": false, "code": "bad_kind", "message": "kind 必须是 explore/task/production，得到：%s" % kind}
	_run_seq += 1
	var run_id := "r%d-%03d" % [Time.get_unix_time_from_system() as int, _run_seq]
	var run := {
		"runId": run_id,
		"kind": kind,
		"seed": seed,
		"rulesetVersion": RULESET_VERSION,
		"engineHash": _engine_hash(),
		"startedAt": Time.get_datetime_string_from_system(true) + "Z",
	}
	if episode >= 0:
		run["episode"] = episode
	_doc = {"schemaVersion": SCHEMA_VERSION, "run": run, "steps": [], "failures": []}
	_state_name = "recording"
	_last_step = -1
	_frozen_text = ""
	_out_path = ""
	return {"ok": true, "runId": run_id}


## 记一步。字段齐进（调用方缺什么用什么值），返回步号；非 recording 状态返回 -1。
## t 必须由调用方传入（世界秒），本类不知道世界，也就不可能拿真实时钟冒充逻辑时间。
func record_step(fields: Dictionary) -> int:
	if _state_name != "recording":
		return -1
	var i := (_doc["steps"] as Array).size()
	var causes: Array = fields.get("causes", [])
	if causes.is_empty() and _last_step >= 0:
		causes = [_last_step]
	var step := {
		"i": i,
		"t": fields.get("t", 0.0),
		"phase": fields.get("phase", "observe"),
		"actor": fields.get("actor", "agent"),
		"causes": causes,
		"input": fields.get("input", {}),
		"action": fields.get("action", {}),
		"output": fields.get("output", {}),
		"tokens": fields.get("tokens", 0),
		"ops": fields.get("ops", 0),
		"costMs": fields.get("costMs", 0.0),
		"world": fields.get("world", {"entities": {}, "highlight": []}),
		"caption": fields.get("caption", ""),
		"formula": fields.get("formula", ""),
	}
	(_doc["steps"] as Array).append(step)
	_last_step = i
	return i


## 记一条失败。stepRef 指向步号；failId 取概念侧 fail 条目或 "tool:{工具名}"。
func record_failure(step_ref: int, fail_id: String, code: String, diagnosis: String) -> void:
	if _state_name != "recording" or step_ref < 0:
		return
	(_doc["failures"] as Array).append({
		"stepRef": step_ref,
		"failId": fail_id,
		"code": code,
		"diagnosis": diagnosis,
	})


## 落盘并冻结：runs/e{集号或0}/{runId}.json，文件只写一次。
func end_run(out_root := RUN_OUT_ROOT) -> Dictionary:
	if _state_name == "idle":
		return {"ok": false, "code": "no_active_run", "message": "没有进行中的运行"}
	if _state_name == "frozen":
		return {"ok": false, "code": "already_frozen", "message": "本次运行已冻结（runId=%s，文件只写一次）" % run_id()}
	var episode := int((_doc["run"] as Dictionary).get("episode", 0))
	var dir_path := "%s/e%d" % [out_root, episode]
	var path := "%s/%s.json" % [dir_path, run_id()]
	DirAccess.make_dir_recursive_absolute(dir_path)
	if FileAccess.file_exists(path):
		return {"ok": false, "code": "already_exists", "message": "目标文件已存在，拒绝覆盖：%s" % path}
	var text := JSON.stringify(_doc, "\t")
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return {"ok": false, "code": "io_error", "message": "打不开落盘文件 %s：%s" % [path, error_string(FileAccess.get_open_error())]}
	f.store_string(text)
	f.close()
	_state_name = "frozen"
	_frozen_text = text
	_out_path = path
	return {"ok": true, "path": path, "bytes": text.length()}


## 冻结后允许开新 run（新 runId、新文件）；本次记录本身从此只读。
func state_name() -> String:
	return _state_name


func run_id() -> String:
	return str((_doc["run"] as Dictionary).get("runId", ""))


func frozen_text() -> String:
	return _frozen_text


func out_path() -> String:
	return _out_path


## 只读视图（深拷贝，防外部篡改记录）。
func get_doc() -> Dictionary:
	return _doc.duplicate(true)


func get_steps() -> Array:
	return (_doc["steps"] as Array).duplicate(false)


func _engine_hash() -> String:
	var v := Engine.get_version_info()
	return "godot-%d.%d.%d-%s-%s" % [
		int(v.get("major", 0)),
		int(v.get("minor", 0)),
		int(v.get("patch", 0)),
		str(v.get("status", "?")),
		str(v.get("hash", "?")).substr(0, 8),
	]
