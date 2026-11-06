extends RefCounted

## 三级提示服务（docs/10-契约/交互方案.md §五）：现象 → 诊断 → 代做，
## 逐级升级、都不直接给答案。纯逻辑：只管文案与数据流，不管显示——
## 求助屏（scenes/blocks/help_screen.gd）拿返回值去点气泡、发变红回调。
##
## 数据源纪律：
##   * L2 诊断文案的**唯一数据源**是 concepts.yaml 对应概念的 fail 条目
##     （spec 2026-09-13 §4.2：fail = [{failId, condition 条件, symptom 可观测表现}]），
##     本类不自己编诊断句子；关卡→conceptId 映射由屏的 @export 注入；
##   * L1 只说"哪台组件"不说原因；L3 只发 request_demo 信号（代做执行依赖
##     sidecar，后续接入；代做不参与判定，spec §7.1）。
##
## 口径（交互方案 §5.1）：
##   * 问什么不影响判定——对话不进 task 运行的步记录，只写 help 自己的
##     轻量日志 runs/help/{level}.json（含时间与级别，供评分与复习）；
##   * 达阈值解锁提示 L1，每问一次升一级，3 封顶；未解锁只回"再试一次"。
##
## 不用 class_name（同 fail_counter.gd 的注释）。

signal request_demo(level_id: String)   # L3：请求代做（本阶段只发信号，屏转发）

const MAX_HINT_LEVEL := 3
const DEFAULT_LOG_ROOT := "res://runs/help"
const REJECT_LEAD := "再试一次，你已经很接近了"

var fail_counter = null       # scripts/help/fail_counter.gd 实例
var concept_map := {}         # level_id -> conceptId（屏的 @export 注入）
var concepts := {}            # conceptId -> {label, fail}（concept_reader 载入）
var problem_names := {}       # level_id -> 问题组件显示名（屏注入；缺省"任务牌"）
var log_root := DEFAULT_LOG_ROOT

var _progress := {}           # level_id -> 已给到的最高提示级


## 问一次。返回：
##   未解锁 → {kind:"rejected", level:0, text}（不给内容）
##   已解锁 → {kind:"hint", level:1|2|3, anchor:"problem"|"fail"|"task",
##             component, text, ...（L2 另带 conceptId/fails，L3 另带 demo:true）}
## 问什么（question）只进 help 日志，不影响任何判定。
func ask(level_id: String, question := "") -> Dictionary:
	var fails_now := 0
	var threshold_now := 3
	if fail_counter != null:
		fails_now = fail_counter.fails(level_id)
		threshold_now = int(fail_counter.threshold)
	if fail_counter == null or not fail_counter.unlocked(level_id):
		var reject := {
			"kind": "rejected",
			"level": 0,
			"text": "%s（失败 %d/%d 次之后，我才开始给提示）" % [REJECT_LEAD, fails_now, threshold_now],
		}
		_append_log(level_id, question, reject)
		return reject
	var lvl := mini(int(_progress.get(level_id, 0)) + 1, MAX_HINT_LEVEL)
	_progress[level_id] = lvl
	var hint := _build(level_id, lvl)
	_append_log(level_id, question, hint)
	if lvl == 3:
		request_demo.emit(level_id)
	return hint


## 该关已给到的提示级（未问过为 0）。
func hint_level(level_id: String) -> int:
	return int(_progress.get(level_id, 0))


func log_path(level_id: String) -> String:
	return "%s/%s.json" % [log_root, level_id]


func reset_progress(level_id: String) -> void:
	_progress.erase(level_id)


# ---------- 三级文案 ----------

func _build(level_id: String, lvl: int) -> Dictionary:
	var comp_name := str(problem_names.get(level_id, "任务牌"))
	match lvl:
		1:
			# 现象：只指哪台组件，不解释原因（锚点气泡与变红由屏接手）
			return {
				"kind": "hint",
				"level": 1,
				"anchor": "problem",
				"component": comp_name,
				"highlight": true,
				"text": "现象：先去看「%s」——就是它不对劲。哪台出了问题我告诉你，原因先自己找。" % comp_name,
			}
		2:
			# 诊断：全部句子来自 concepts.yaml 的 fail 条目原文（条件 + 可观测表现）
			var cid := str(concept_map.get(level_id, ""))
			var fails: Array = []
			if concepts.has(cid):
				fails = (concepts[cid] as Dictionary).get("fail", [])
			var lines: Array[String] = []
			for f in fails:
				var fd: Dictionary = f
				lines.append("· %s：当%s——你会看到：%s" % [
					str(fd.get("failId", "")),
					str(fd.get("condition", "")),
					str(fd.get("symptom", "")),
				])
			var body := ""
			if lines.is_empty():
				body = "·（本关概念没有登记失败表现；再核对一次任务牌的连线与参数）"
			else:
				body = "\n".join(lines)
			return {
				"kind": "hint",
				"level": 2,
				"anchor": "fail",
				"component": comp_name,
				"conceptId": cid,
				"fails": fails,
				"text": "诊断（%s）：%s" % [cid if cid != "" else "本关未配概念映射", body],
			}
		_:
			# 代做：只发信号；执行依赖 sidecar 后续接入；代做不参与判定
			return {
				"kind": "hint",
				"level": 3,
				"anchor": "task",
				"component": comp_name,
				"demo": true,
				"text": "代做：让它做一遍给你看——慢速做，随时按空格暂停并接管。注意：代做不参与判定，判定只看你自己跑的任务记录。",
			}


# ---------- help 轻量日志（与 task 运行分开存，交互方案 §5.1） ----------

func _append_log(level_id: String, question: String, result: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(log_root)
	var path := log_path(level_id)
	var doc := {}
	if FileAccess.file_exists(path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(path))
		if parsed is Dictionary:
			doc = parsed
	if not doc.has("entries"):
		doc["entries"] = []
	(doc["entries"] as Array).append({
		"i": (doc["entries"] as Array).size(),
		"at": Time.get_datetime_string_from_system(true) + "Z",
		"unix": Time.get_unix_time_from_system(),
		"levelId": level_id,
		"question": question,
		"kind": str(result.get("kind", "")),
		"hintLevel": int(result.get("level", 0)),
		"text": str(result.get("text", "")),
	})
	doc["kind"] = "help_dialog"
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("hint_service: help 日志写不进 %s" % path)
		return
	f.store_string(JSON.stringify(doc, "\t"))
	f.close()
