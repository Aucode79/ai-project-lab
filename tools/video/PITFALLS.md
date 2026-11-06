# 坑位手册（踩过的全部坑，按"当前管线 / 3D 时代归档"分栏）

> 2026-10-08 汇编。来源：第一课 v9→v12.14 全部迭代实录（`docs/20-验收/2026-10-08-第一课成片迭代全记录.md`）。
> 每条格式：现象 → 根因 → 解法。改相关代码前先扫一遍对应分栏。

## 一、Manim（CE 0.21）——当前管线主力

1. **帧数记账**：所有播放（含空转 idle）必须走 `play(Advance(tracker, k/FPS), run_time=(k-0.5)/FPS)` 路径，Manim 恰好产出 k 帧；纯 `wait()` 的时长取整会漂移（曾漂 ±2 帧）。
2. **任何 `scene.play` 都产帧**：绕过记账包装直调 play（哪怕只是淡出旧元素）会让段落多出帧——曾因此 +5 帧、帧数校验才抓到。挂起变量由调用方并入首个分段播放。
3. **空动画列表会崩**（`Scene.play with no animations`）：事件动画可能全被闸掉（如节拍过滤），play 包装里加 `Advance` 兜底退化为时间推进。
4. **缩进即死代码**：删分支时把下一行错误缩进到 `continue` 之下 → 全部事件动画静默消失，段照常出、帧数照常对、只有画面不动。**此类改动必须跑像素曲线验收**。
5. `CurvedArrow` 不认 `max_tip_length_to_length_ratio`（那是 `Arrow` 的参数），传入即 `TypeError`。
6. `ImageMobject` 不能进 `VGroup`（"Only VMobject can be added"）——用 `Group`。
7. 场景工厂（`type()` 批量造 Scene 类）必须在类定义**之后**执行，否则 `NameError`。
8. z_index 默认 0：卡片会被 z=5 的箭头穿过——卡片统一 `set_z_index(8)`。
9. `Succession` 平分总时长给各段；要按距离加权就拆成多次 play 手动分配。

## 二、管线（配音/对齐/时间轴/混流）

1. **voice_lesson 按 id 跳过已有 wav**：改台词必须先删 `voice/<id>.wav`，否则旧配音被沿用、内容错位。
2. **whisper `initial_prompt` 偶发幻听**（整段听成「请不吝点赞…明镜与点点栏目」，相似度≈0）：兜底——相似度 <0.6 自动去 prompt 重转写取更优（finish_lesson 已内置）。
3. **镜时长 = 语音时长 + 停顿垫**，事件时刻独立于镜长另行重排（词锚+推挤）；`atempo` 会按文字预算地板（字数/4 秒）自动放慢语音——s01 曾因此 19.28→22.5s。
4. **位移时长规则的物理约束**：N 次位移 × 最小时长必须 ≤ 旁白可用窗口，否则推挤算法把全部位移挤到尾部（s01 曾 B 点停 8 秒后三段连冲）。窗口不够就给该镜单独调小步长（s01 专用 1.0s）。
5. **Git Bash 的 `/tmp` 是 MSYS 路径**，Windows 版 ffmpeg 的 concat 清单读不到——清单放仓库内用相对路径。
6. **混流必须 cd 到 lessonNN/ 目录**（`ass=` 滤镜与输出文件名都是相对路径）。
7. 仓库文档多为 CRLF：多行文本锚点极易失配——**patch 前先 grep 实文**；补丁脚本的 write 在末尾，中途断言失败=零写入（一个 bug 修完没写盘、旧定义覆盖新版，排查过整轮）。

## 三、流程铁律（血泪换来的验收制度）

1. **像素级客观验收**：用货物像素中位 x 随时间的曲线验证动画真实发生/时长/与台词先后——肉眼判帧两次把"A 点"看成"半途"。
2. **几何包围盒审计**：按渲染器常量复算全部元素包围盒对画框/相邻件求交——s17 名牌"出生即出画"（y=4.6>画顶 4.0）这类问题目检永远发现不了。
3. **大改动先出小样**：结尾选型先做 A/C 两版样片（可加前后镜扩到 1 分钟上下文版）再定，避免整片返工。
4. 改旁白→删 wav→重配音→prepare→finish→重渲受影响镜→验收→混流，**这个顺序不能乱**（stills 依赖舞台镜先渲）。

## 四、3D 时代归档（当前管线用不到，重建 3D 时再看）

- Blender 5.2.2 的 EEVEE 引擎标识符是 `BLENDER_EEVEE`（非 4.x 的 `_NEXT`）；`Material.use_nodes` 弃用告警是噪音。
- Godot 4.7 `GLTFDocument` 写盘 API 叫 `write_to_filesystem`；结尾 ObjectDB 泄漏告警看退出码即可。
- Workbench 材质色+屏幕曲率轮廓可保留真实 glTF 几何出 3.5 分钟 2D 感画面；`--bake` 固化关键帧但逐帧渲染走 handler 更快。
- Godot→Blender 坐标映射：(x, y=up, z=depth) → (x, y=-z, z=y)。

## 五、Windows/WSL 环境坑（详见 ENVIRONMENT.md）

- faster-whisper 的 `av` 必须钉 14.2.0；模型平铺目录必须显式 `--model` 指路；HF 镜像 Xet 401 加 `HF_HUB_DISABLE_XET=1`。
- CosyVoice：wetext 预热必须循环重试到成功（限流 403 会静默退化）；新版 modelscope 即使缓存齐全也发 hub 请求（shim 已拦）；模型严禁放 /mnt/。
- WSL 系统源 Python 3.14 过新，统一 `uv venv --python 3.12`。
