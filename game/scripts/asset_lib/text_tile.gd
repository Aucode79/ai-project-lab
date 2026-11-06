extends RefCounted

## World text is baked once per content/size; no live viewport or floating glyphs.
const Style := preload("res://scripts/asset_lib/asset_style.gd")
static var _textures := {}
static var _font: SystemFont

## 贴地字砖统一入口（studio_text_tile 约定）：名字/深度/路径等短文字的地面实体。
## 平面朝上，文字上缘朝 -Z（+Z 侧相机俯视可读）；未烘焙前以 PAPER 底示人，
## 窗口态由 bake_all 烘 PAPER 底 + INK 蚀刻纹理，headless 下 bake_all 直接跳过。
static func ground_label(parent: Node3D, tile_name: String, text: String, pos: Vector3, size: Vector2) -> MeshInstance3D:
	var tile := make(text, size)
	tile.name = tile_name
	tile.position = pos
	(tile.material_override as StandardMaterial3D).albedo_color = Style.PAPER
	parent.add_child(tile)
	return tile

static func make(text: String, size: Vector2 = Vector2(3, 1)) -> MeshInstance3D:
	var tile := MeshInstance3D.new()
	var mesh := PlaneMesh.new()
	mesh.size = size
	tile.mesh = mesh
	tile.set_meta("text", PackedStringArray(text.split("\n")))
	tile.set_meta("px", Vector2i(768, maxi(128, int(768 * size.y / size.x))))
	tile.set_meta("centered", false)
	tile.set_meta("placement_ignore", true)
	tile.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color.WHITE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.roughness = 0.92
	tile.material_override = mat
	return tile

static func bake_all(stage: Node) -> void:
	if DisplayServer.get_name() == "headless": return
	var quads: Array[MeshInstance3D] = []
	_collect(stage, quads)
	# Bounded batches avoid both 26 sequential frame waits and a large live viewport spike.
	for first in range(0, quads.size(), 8):
		var pending: Array = []
		for quad in quads.slice(first, first + 8):
			var key := str(quad.get_meta("text")) + str(quad.get_meta("px"))
			if _textures.has(key):
				_set_texture(quad, _textures[key])
				continue
			var viewport := _viewport_for(quad)
			stage.add_child(viewport)
			pending.append([quad, viewport, key])
		if pending.is_empty(): continue
		await stage.get_tree().process_frame
		await RenderingServer.frame_post_draw
		# Check the actual font/container layout before accepting a baked card.
		var resized := false
		for entry in pending:
			var viewport: SubViewport = entry[1]
			var stack := viewport.get_node("TextStack") as VBoxContainer
			var available := viewport.size.y - 56.0
			if stack.get_combined_minimum_size().y > available:
				var factor := available / stack.get_combined_minimum_size().y * 0.92
				for line in stack.get_children():
					line.add_theme_font_size_override("font_size", maxi(18, int(line.get_theme_font_size("font_size") * factor)))
				viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
				resized = true
		if resized:
			await stage.get_tree().process_frame
			await RenderingServer.frame_post_draw
		for entry in pending:
			var bitmap: Image = entry[1].get_texture().get_image()
			bitmap.generate_mipmaps()
			var texture := ImageTexture.create_from_image(bitmap)
			_textures[entry[2]] = texture
			_set_texture(entry[0], texture)
			entry[1].queue_free()

static func _set_texture(quad: MeshInstance3D, texture: Texture2D) -> void:
	var mat := quad.material_override as StandardMaterial3D
	mat.albedo_color = Color.WHITE
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = texture
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

static func _viewport_for(quad: MeshInstance3D) -> SubViewport:
	var viewport := SubViewport.new()
	viewport.size = quad.get_meta("px")
	viewport.disable_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	var background := ColorRect.new()
	background.color = Style.PAPER
	background.size = viewport.size
	viewport.add_child(background)
	if _font == null:
		_font = SystemFont.new()
		_font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "SimHei"])
	var raw: Variant = quad.get_meta("text")
	var lines := PackedStringArray([raw]) if raw is String else PackedStringArray(raw)
	var margin := 28.0
	var stack := VBoxContainer.new()
	stack.name = "TextStack"
	stack.position = Vector2(margin, margin)
	stack.size = Vector2(viewport.size) - Vector2.ONE * margin * 2
	stack.add_theme_constant_override("separation", 16)
	viewport.add_child(stack)
	for i in lines.size():
		var line := Label.new()
		line.text = lines[i]
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.custom_minimum_size.x = stack.size.x
		line.add_theme_font_override("font", _font)
		var font_size := 80 if i == 0 else 48
		if i == 0:
			while font_size > 28 and _font.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x > stack.size.x:
				font_size -= 2
		line.add_theme_font_size_override("font_size", font_size)
		line.add_theme_color_override("font_color", Style.INK)
		line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if quad.get_meta("centered", false) else HORIZONTAL_ALIGNMENT_LEFT
		stack.add_child(line)
	return viewport

static func _collect(node: Node, out: Array[MeshInstance3D]) -> void:
	if node is MeshInstance3D and node.has_meta("text") and node.has_meta("px"):
		out.append(node)
	for child in node.get_children(): _collect(child, out)
