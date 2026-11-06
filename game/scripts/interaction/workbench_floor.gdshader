shader_type spatial;
render_mode diffuse_burley;

varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 grid = world_position.xz / 0.5;
	vec2 width = max(fwidth(grid), vec2(0.001));
	vec2 distance_to_edge = min(fract(grid), 1.0 - fract(grid));
	float fine = 1.0 - min(smoothstep(vec2(0.0), width, distance_to_edge).x,
		smoothstep(vec2(0.0), width, distance_to_edge).y);
	vec2 major_grid = world_position.xz / 5.0;
	vec2 major_width = max(fwidth(major_grid), vec2(0.001));
	vec2 major_edge = min(fract(major_grid), 1.0 - fract(major_grid));
	vec2 major_line = smoothstep(vec2(0.0), major_width, major_edge);
	float major = 1.0 - min(major_line.x, major_line.y);
	ALBEDO = vec3(0.68, 0.71, 0.63) * (1.0 - 0.035 * fine - 0.06 * major);
	ROUGHNESS = 0.94;
}
