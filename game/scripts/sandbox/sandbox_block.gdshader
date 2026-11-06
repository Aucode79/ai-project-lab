shader_type spatial;

// 沙盒方块表面的「砖」这一层 —— 几何负责倒角（sandbox_block.gd），这里负责砖缝、
// 斑驳与雕饰花纹。对标《Zoy》前瞻片的石砌：表面不是一整块平整色，而是
//   大块顺砖砌法（2:1 的砖）+ 逐砖深浅不一 + 少量砖上压芽纹/菱形/鳞纹
//   + 少数方块的中缝上来一道锯齿镶边
//
// 坐标来源：地形网格把世界坐标烘进了顶点，但那**不是**在 fragment 里能直接读到的 —— 
// Godot 的 spatial fragment 内建表里 VERTEX 与 NORMAL 都是**视空间**
// （docs: spatial_shader → fragment 内建：VERTEX "in view space"、NORMAL "in view space"），
// 而 MODEL_MATRIX 是"模型→世界"。所以 `MODEL_MATRIX * vec4(VERTEX, 1.0)` 是拿模型→世界
// 的矩阵去乘一个视空间的点，得到的既不是世界也不是视空间，而是**跟着相机转**的坐标。
// 实测症状（用 fract(该值) 直接上色的诊断图可复现）：砖格、斑驳、花纹、风化全焊在
// 相机上，环绕时在方块表面游动；`NORMAL.y` 同样随俯角改变"哪块面算顶面"。
// 正确做法：世界坐标与世界法线都在 vertex() 里算好、走 varying 传到 fragment。
//   game/shots/art-upgrade/A1/ 留着三张诊断图：repro_y_space.png（视空间证据）、
//   repro_coord_current.png / repro_coord_world.png（修复前后对照）。
//
// 面内两轴由世界法线挑：竖直面取 (x+z, y) —— 轴对齐面的 x 或 z 必是常量，相加后
// 另一项自然落成 0，等于取到真正的面内水平轴（斜倒角面上略拉伸，可忽略，而且那一条
// 已被倒角几何本身接上）。
//
// 一切尺寸都用**米**：砖格、砖缝、花纹线宽都是世界尺寸，与相机远近、分辨率无关。
// 第一版把线宽写成"占砖格的比例"，结果线只有零点几像素，花纹整片消失。

render_mode cull_disabled, diffuse_burley, specular_schlick_ggx;

uniform int pattern_kind = 0;              // 0 = 砖砌石面 / 1 = 土质地皮 / 2 = 素面
uniform vec2 brick_size = vec2(1.0, 0.5);  // 砖的世界尺寸（米）—— 2:1 是参考图的比例
uniform float seam_m = 0.030;              // 砖缝宽度（米）
uniform float mortar_dark = 0.55;          // 缝里压暗到多少（石缝是影子，不是黑线）
uniform float tone_var = 0.150;            // 逐砖深浅离散：这条最撑"石砌"的读感
uniform float motif_density = 0.13;        // 带花纹的砖占比（稀疏才像雕饰，密了成花纹纸）
uniform vec3 motif_color : source_color = vec3(0.98, 0.93, 0.80);
uniform float motif_strength = 0.55;       // 低对比：花纹是雕进去的，不是贴上去的
uniform float motif_stroke = 0.100;        // 花纹线宽（米）：34 m 机位下 1 m ≈ 37 px，
                                           // 低于 ~0.05 m 的线只有 1-2 px，整片会被滤没
uniform float grain_amount = 0.05;
uniform float grime_amount = 0.17;         // 低频风化/污渍：均匀的砖=瓷砖，脏一点才像石砌
uniform float grime_scale = 0.27;          // 污渍的空间频率（1/米）
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float emission_energy = 0.0;

// ---- 草皮顶块（pattern_kind = 3）----
// 用户口径（2026-09-16）：**草不做成高草几何，只把方块最上面那一层渲染成草的样子，
// 总体形状还是正方体。** 所以这一档只改颜色、不动几何：
//   顶面      → 成片的草色（平滑噪声定深浅，逐块再微差），方块轮廓仍是直角
//   侧面      → 土壤色 + 顶部一道"草皮断面"（草皮块的经典读法），界线带锯齿
//   倒角面    → nrm.y 在 0.5 以上算顶面，于是顶棱的倒角自然"翻"成草色（草翻过棱角）
//
// 两条踩过的坑（都写在这里免得再犯）：
//   1. **成片要用平滑噪声，不能用 `floor()` 的硬格子**。硬格子出来的是一块块高对比
//      方斑，读作"烧焦的印记"，不是草。
//   2. 草顶色 2026-09-17 用户裁定**改暖调**（依据《美术方向》：绿草+蓝天+暖沙同框
//      太接近《我的世界》签名配色）。已知代价：草/铺装/沙三层退化为同色系明度对比，
//      分层靠铺装边线救场——调色时别再把铺装也往暖里推。第一版 #FFA529 整圈读作
//      麦田/沙地，第二轮把草面回调到芥末琥珀 #E8B23E（保持暖调、更像干草）。
uniform vec3 grass_deep : source_color = vec3(0.208, 0.145, 0.035);   // #352509 暖深草根
uniform vec3 grass_tip : source_color = vec3(0.910, 0.698, 0.243);    // #E8B23E 芥末琥珀草面（2026-09-17 暖调第二轮，自 #FFA529 回调色相）
uniform float grass_side_band = 0.20;      // 侧面顶部那道草皮断面的高度（米）

// 世界空间的位置与法线：由 vertex() 写出、在 fragment 里读。视空间的内建量（VERTEX /
// NORMAL）在 fragment 里不能当世界量用，这是本文件修过的一个真 bug。
varying vec3 v_world_pos;
varying vec3 v_world_nrm;

void vertex() {
	// vertex() 里 VERTEX / NORMAL 是**模型空间**的，左乘 MODEL_MATRIX 才到世界
	v_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	v_world_nrm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}


float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float hash31(vec3 p) {
	p = fract(p * 0.3183099 + vec3(0.11, 0.17, 0.13));
	p *= 17.0;
	return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
}

// 平滑值噪声（双线性 + smoothstep）。草要成片，就得用这个而不是 floor() 的硬格子。
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float seg_dist(vec2 p, vec2 a, vec2 b) {
	vec2 pa = p - a;
	vec2 ba = b - a;
	return length(pa - ba * clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0));
}

float stroke(vec2 p, vec2 a, vec2 b, float w) {
	return 1.0 - smoothstep(w, w * 2.0, seg_dist(p, a, b));
}

// 花纹画在**单位方块空间** [0,1]²（与砖的实际长宽比无关），线宽 w 由调用方按砖的
// 小边换算成同一空间 —— 这样 1 m 石板与 1×0.5 m 砖上的花纹看起来一样大、线一样粗。
// 芽纹（参考图里最常出现的那枚）：一根茎 + 两片斜叶 + 叶尖两个实心点。
// 点比线抗缩放 —— 远景里线会被滤掉，点还能留成一个小记号。
float motif_sprout(vec2 p, float w) {
	float m = stroke(p, vec2(0.50, 0.14), vec2(0.50, 0.76), w * 0.85);
	m = max(m, stroke(p, vec2(0.50, 0.40), vec2(0.30, 0.62), w * 0.78));
	m = max(m, stroke(p, vec2(0.50, 0.54), vec2(0.70, 0.72), w * 0.78));
	float r = w * 1.75;
	m = max(m, 1.0 - smoothstep(r, r * 1.7, length(p - vec2(0.28, 0.62))));
	m = max(m, 1.0 - smoothstep(r, r * 1.7, length(p - vec2(0.72, 0.72))));
	return m;
}

// 菱形嵌饰：双层菱形（外框 + 内芯）
float motif_diamond(vec2 p, float w) {
	vec2 d = abs(p - vec2(0.5, 0.5));
	float r = d.x + d.y;
	float outer = 1.0 - smoothstep(w, w * 1.9, abs(r - 0.27));
	float inner = 1.0 - smoothstep(w, w * 1.9, abs(r - 0.11));
	return max(outer, inner * 0.75);
}

// 鳞纹：一排叠瓦的半圆
float motif_scallop(vec2 p, float w) {
	float m = 0.0;
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		vec2 c = vec2(0.26 + fi * 0.24, 0.52 + mod(fi, 2.0) * 0.20);
		m = max(m, 1.0 - smoothstep(w, w * 1.9, abs(length(p - c) - 0.16)));
	}
	return m;
}

// 锯齿镶边：一道横贯整面的装饰带（不跟着砖分格切）
float trim_zigzag(vec2 uv, float w) {
	float in_band = 1.0 - smoothstep(0.14, 0.21, abs(uv.y - 0.5));
	float zig = abs(fract(uv.x * 2.5) * 2.0 - 1.0);
	return in_band * (1.0 - smoothstep(w, w * 2.2, abs(zig - 0.5) * 0.42));
}

void fragment() {
	vec3 wp = v_world_pos;
	vec3 nrm = normalize(v_world_nrm);
	vec3 blk = floor(wp + 0.0001);
	vec3 f = fract(wp + 0.0001);
	vec2 uv = abs(nrm.y) > 0.5 ? f.xz : vec2(f.x + f.z, f.y);   // 单位：米（面 1 m 见方）
	// 平的那块面只占 [CHAMFER, 1-CHAMFER]，先拉回 0..1 再进砖格，砖格才与面严格对齐。
	// 这两个数**硬编码**并对着 sandbox_block.gd 的 CHAMFER = 0.05（改倒角必须同步改这里，
	// 否则砖格会与倒角错位）；1.0 - 0.10 = 两侧各让一个 CHAMFER。
	uv = clamp((uv - vec2(0.05)) / (1.0 - 0.10), 0.0, 1.0);

	// 不做"平不平整"的掩码：曾经用 max(|法线|) 去挑平面，结果它在网格器插值后的
	// 法线上几乎恒为 0，把整段砌体图案与花纹全吃掉了（表面只剩倒角几何 + 调色板色，
	// 读作瓷砖）。倒角棱面宽 ≈ 7.07 cm（直角边 0.05 m 的 45° 直切，斜面 = 0.05×√2），
	// 图案直接漫上去更自然 —— 见下方 uv 的取法，
	// 顶面与其倒角都取 f.xz，竖直面与其倒角都取 (f.x+f.z, f.y)，两边本来就接得上。

	float gr = hash21(wp.xz * 37.0 + wp.y * 11.0);
	// 低频斑驳：按 ~3.7 m 的格子压暗一点，整面因此有"这块晒白了、那块积了灰"的层次
	float gm = hash31(vec3(floor(wp.x * grime_scale), 0.0, floor(wp.z * grime_scale)));
	float grime = 1.0 - grime_amount * smoothstep(0.25, 0.85, gm);
	vec3 albedo = COLOR.rgb * grime;

	if (pattern_kind == 0) {
		// 顺砖：逐行错半砖，再按方块坐标整体错一次 —— 两向都错开，竖缝才不会连成直线
		float row = floor(uv.y / brick_size.y);
		float offs = mod(row + blk.x + blk.z, 2.0) * 0.5 * brick_size.x;
		vec2 g = vec2(uv.x + offs, uv.y) / brick_size;
		vec2 cell = floor(g);
		vec2 bp = fract(g);
		vec3 seed = vec3(blk.x + cell.x * 3.7, blk.y, blk.z + cell.y * 7.9);

		// 逐砖深浅 + 逐砖倒角（上亮下暗）—— 砖因此读作一块块砌起来的
		float h = hash31(seed);
		albedo *= 1.0 + (h - 0.5) * 2.0 * tone_var;
		albedo *= 1.0 + ((0.5 - bp.y) * 0.30 + (0.5 - bp.x) * 0.14) * 0.7;

		// 花纹：只有一小部分砖有
		float sel = hash31(seed * 1.37 + vec3(3.1, 7.7, 1.9));
		float motif = 0.0;
		if (sel < motif_density) {
			float w = motif_stroke / min(brick_size.x, brick_size.y);
			float kind = hash21(vec2(seed.x, seed.z));
			if (kind < 0.44) {
				motif = motif_sprout(bp, w);
			} else if (kind < 0.76) {
				motif = motif_diamond(bp, w);
			} else {
				motif = motif_scallop(bp, w);
			}
		}
		// 锯齿镶边：少数方块上来一道，读作砌体里的装饰层
		if (hash31(blk * 0.73 + vec3(11.0)) < 0.10) {
			motif = max(motif, trim_zigzag(uv, motif_stroke * 0.9));
		}
		albedo = mix(albedo, motif_color, motif * motif_strength);

		// 砖缝：下沉 → 压暗；缝里不该有花纹
		vec2 d_m = vec2(min(bp.x, 1.0 - bp.x) * brick_size.x,
			min(bp.y, 1.0 - bp.y) * brick_size.y);
		// max(seam_m, ...)：石板那档 seam_m=0（缝交给倒角几何），而 smoothstep(0,0,x)
		// 在 GLSL 里是除以零（未定义）
		float seam = 1.0 - smoothstep(0.0, max(seam_m, 0.002), min(d_m.x, d_m.y));
		albedo = mix(albedo, albedo * mortar_dark, seam);

		// 竖直面上补一道"砖上沿的受光亮棱"：砌体的层次感七成来自这条亮边。
		// 只在墙上做 —— 地面是水平的，没有朝上的棱可亮。
		if (abs(nrm.y) < 0.5) {
			float lip = 1.0 - smoothstep(0.006, 0.060, (1.0 - bp.y) * brick_size.y);
			albedo *= 1.0 + lip * (1.0 - seam) * 0.22;
		}
	} else if (pattern_kind == 1) {
		// 土质地皮：不分砖，只做低频斑驳 + 细颗粒（草皮 / 草斑 / 壤土 / 陶土）
		float m = hash31(vec3(blk.x * 0.31, 0.0, blk.z * 0.29));
		albedo *= 1.0 + (m - 0.5) * 1.3 * tone_var;
	} else if (pattern_kind == 3) {
		// 草皮顶块：草只改颜色，不生成任何几何 —— 方块轮廓仍是正方体（见文件头的口径）。
		// 深浅来自**两级平滑噪声**：n1 成片（~2 m，一片茂一片疏），n2 细斑（~0.3 m）。
		// 幅度都压得小（±15% / ±8%）—— 草是"有深浅的草地"，不是一块块色斑。
		float n1 = vnoise(wp.xz * 0.55);
		float n2 = vnoise(wp.xz * 3.10);
		float cover = clamp(0.68 + (n1 - 0.5) * 0.30 + (n2 - 0.5) * 0.16, 0.0, 1.0);
		vec3 grass = mix(grass_deep, grass_tip, cover);
		grass *= 1.0 + (gr - 0.5) * 0.10;          // 逐块微差（同族方块之间不同色）
		if (abs(nrm.y) > 0.5) {
			// 顶面（含顶棱倒角）：整片草；再留一点底色，让调色板的三档微差透出来
			albedo = mix(albedo * 0.5, grass, 0.86);
		} else {
			// 侧面：只有离块顶 grass_side_band 以内是草（草皮断面），其下仍是土。
			// 界线用 n2 抖一下，免得一圈草皮像贴了一条胶带。
			float below_top = ceil(wp.y) - wp.y;   // 0 = 块顶，1 = 块底
			float edge = grass_side_band + (n2 - 0.5) * 0.10;
			float k = 1.0 - smoothstep(edge - 0.040, edge + 0.040, below_top);
			albedo = mix(albedo, grass * 0.90, k);
		}
	}

	albedo *= 1.0 + (gr - 0.5) * grain_amount;
	ALBEDO = albedo;

	ROUGHNESS = 0.80;
	SPECULAR = 0.14;
	METALLIC = 0.0;
	if (emission_energy > 0.0) {
		EMISSION = emission_color * emission_energy;
	}
}
