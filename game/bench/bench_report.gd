extends RefCounted

## 测量产物的公共小工具：JSON 落盘、基础统计。四个 bench 共用。


const OUT_DIR := "res://bench/out"


static func write_json(name: String, data: Dictionary) -> String:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var path := OUT_DIR + "/" + name
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_error("无法写 %s" % path)
		return ""
	f.store_string(JSON.stringify(data, "\t", false))
	f.close()
	print("REPORT: " + path)
	return path


static func mean(values: Array[float]) -> float:
	if values.is_empty():
		return 0.0
	var s := 0.0
	for v in values:
		s += v
	return s / float(values.size())


static func percentile(values: Array[float], p: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array[float] = values.duplicate()
	sorted.sort()
	var idx := clampi(int(floor(p * float(sorted.size() - 1))), 0, sorted.size() - 1)
	return sorted[idx]


static func run_id() -> String:
	# 形如 bench_20260914_153045，可读且当文件名安全
	var s := Time.get_datetime_string_from_system(false)
	s = s.replace("-", "").replace(":", "").replace(" ", "_").replace("T", "_")
	return "bench_" + s
