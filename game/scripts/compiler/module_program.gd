extends RefCounted

## One compiler implementation shared by Godot export and the live editor service.
static func compile(program: Dictionary) -> Dictionary:
	var filename := "user://module-" + str(Time.get_ticks_usec()) + ".json"
	var file := FileAccess.open(filename, FileAccess.WRITE)
	if file == null: return {"ok": false, "python": "", "errors": [{"message": "无法写入编译输入"}]}
	file.store_string(JSON.stringify(program))
	file.close()
	var python := OS.get_environment("AGENT_LAB_PYTHON")
	if python == "": python = "D:/smolagents/.venv/Scripts/python.exe"
	var script := ProjectSettings.globalize_path("res://../tools/lesson/module_compiler.py")
	var output: Array = []
	var rc := OS.execute(python, [script, ProjectSettings.globalize_path(filename)], output, true)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(filename))
	if rc != 0 or output.is_empty(): return {"ok": false, "python": "", "errors": [{"message": "模块编译进程失败"}]}
	var result: Variant = JSON.parse_string(output[0])
	return result if result is Dictionary else {"ok": false, "python": "", "errors": [{"message": "模块编译返回无效 JSON"}]}
