"""【3D 遗产·已退役】Blender 3D 时代产物，仅存档可查；现行渲染＝render_lesson_2d.py（见 tools/video/README.md）。原说明：Blender 5.2: actual Godot meshes, a single sandbox, schema-v6-driven replay.

blender -b -t 8 --python render_lesson.py -- --preview
blender -b -t 8 --python render_lesson.py -- --start 1 --end 500
"""
import argparse
import bisect
import json
import hashlib
import math
import sys
from pathlib import Path

import bpy
from mathutils import Vector

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "tools/video/lesson01"
EDIT = json.loads((OUT / "edit.json").read_text(encoding="utf-8"))
args = argparse.ArgumentParser()
args.add_argument("--preview", action="store_true")
args.add_argument("--start", type=int, default=1)
args.add_argument("--end", type=int, default=0)
args.add_argument("--samples", type=int, default=16)
args.add_argument("--engine", choices=["workbench", "eevee"], default="workbench")
args.add_argument("--preview-ids", default="agent,model,closure")
args.add_argument("--bake", action="store_true", help="Store editable animation keys in the .blend")
opts = args.parse_args(sys.argv[sys.argv.index("--")+1:] if "--" in sys.argv else [])
bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = "BLENDER_WORKBENCH" if opts.engine == "workbench" else "BLENDER_EEVEE"
scene.render.resolution_x = 1920
scene.render.resolution_y = 1080
scene.render.resolution_percentage = 100
scene.render.fps = EDIT["fps"]
scene["source_run_id"] = EDIT["runId"]
scene["source_run_sha256"] = hashlib.sha256((OUT / "run.json").read_bytes()).hexdigest()
scene.render.image_settings.file_format = "JPEG"
scene.render.image_settings.quality = 93
scene.render.film_transparent = False
scene.eevee.taa_render_samples = opts.samples
scene.display.render_aa = "FXAA"
scene.display.shading.light = "FLAT"
scene.display.shading.studiolight_rotate_z = 0.5
scene.display.shading.color_type = "MATERIAL"
scene.display.shading.show_shadows = False
scene.display.shading.show_cavity = True
scene.display.shading.cavity_type = "SCREEN"
scene.display.shading.curvature_ridge_factor = 0.55
scene.display.shading.curvature_valley_factor = 0.55
scene.display.shading.show_specular_highlight = False
scene.display.shading.background_type = "WORLD"
scene.world.color = (0.72, 0.72, 0.72)
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "Medium High Contrast" if "Medium High Contrast" in scene.view_settings.bl_rna.properties["look"].enum_items.keys() else "None"


def rgba(code):
    vals = [int(code[i:i+2], 16)/255 for i in (0, 2, 4)]
    return tuple(v/12.92 if v <= 0.04045 else ((v+0.055)/1.055)**2.4 for v in vals) + (1,)


def material(name, color):
    mat = bpy.data.materials.new(name)
    mat.diffuse_color = rgba(color)
    mat.use_nodes = True
    node = mat.node_tree.nodes.get("Principled BSDF")
    node.inputs["Base Color"].default_value = rgba(color)
    node.inputs["Roughness"].default_value = 0.8
    return mat


palette = {name: material(name, color) for name, color in {
    "paper": "f7f0d8", "background": "fdfcf9", "ink": "263b40", "deck": "b9cbcb",
    "structure": "536b73", "orange": "ef743b", "blue": "24b9cf", "yellow": "f2c43d",
    "red": "db6268", "green": "68ab5d", "purple": "9261c5"}.items()}


def box(name, pos, size, role, bevel=True):
    bpy.ops.mesh.primitive_cube_add(size=1, location=pos)
    obj = bpy.context.object
    obj.name = name
    obj.dimensions = size
    bpy.ops.object.transform_apply(location=False, rotation=False, scale=True)
    obj.data.materials.append(palette[role])
    if bevel:
        edge = obj.modifiers.new("0.05m inward chamfer", "BEVEL")
        edge.width = 0.05
        edge.segments = 1
        edge.affect = "EDGES"
        obj.modifiers.new("Weighted normals", "WEIGHTED_NORMAL")
    return obj


box("Backdrop", (0, 0, -0.65), (200, 200, 0.5), "background")
box("Sandbox", (0, 1, -0.25), (13, 12, 0.5), "deck")
nodes = {name: [xy[0], -xy[1]] for name, xy in EDIT["initial"]["nodes"].items()}
for a, b in EDIT["initial"]["edges"]:
    x, y = nodes[a]
    xx, yy = nodes[b]
    box("Road_"+a+b, ((x+xx)/2, (y+yy)/2, 0.125), (abs(x-xx)+1, abs(y-yy)+1, 0.25), "paper")
carrier = box("Carrier", (-4, 0, 0.5), (1, 1, 0.5), "structure")
box("DeliveryBay", (4, 1.25, 0.125), (3, 1, 0.25), "green")
crates = {name: box(name, (0, 0, 0), (0.5, 0.5, 0.5), color)
          for name, color in [("货物", "orange"), ("蓝方块", "blue"), ("黄方块", "yellow")]}
barrier = box("Roadblock", (0, 0, 0.5), (0.5, 1.5, 1), "red")
barrier.hide_render = True
modules = []
module_ids = ["agent_model_well", "agent_tool_rack", "agent_observation_tray", "agent_message_table", "agent_loop_table"]
for index, name in enumerate(module_ids):
    previous = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=str(ROOT / "game/shots/video3d/components" / (name + ".glb")))
    imported = set(bpy.data.objects)-previous
    parent = bpy.data.objects.new("Module_"+name, None)
    scene.collection.objects.link(parent)
    for obj in imported:
        if obj.parent is None:
            obj.parent = parent
    parent.location = (-5.5+index*2.75, 4.25, 0)
    modules.append(parent)

# 可执行整机（Agent Lab 同源几何：export_agent_lab_gltf.gd 导出的真实程序视图）。
# Godot 布局 (x, y=up, z=depth) → Blender (x, y=-z, z=y)；原点已由导出器移到包围盒底部中心。
machine_map = json.loads((ROOT / "game/shots/video3d/agent-lab/machine_map.json").read_text(encoding="utf-8"))
previous = set(bpy.data.objects)
bpy.ops.import_scene.gltf(filepath=str(ROOT / "game/shots/video3d/agent-lab/machine.glb"))
imported = set(bpy.data.objects)-previous
machine = bpy.data.objects.new("Module_agent_lab_machine", None)
scene.collection.objects.link(machine)
for obj in imported:
    if obj.parent is None:
        obj.parent = machine
MACHINE_AT = Vector((11.5, 4.5, 0))
machine.location = MACHINE_AT
span_x = max(p[0] for p in (i["pos"] for i in machine_map["nodes"].values())) - min(p[0] for p in (i["pos"] for i in machine_map["nodes"].values()))
span_y = max(p[2] for p in (i["pos"] for i in machine_map["nodes"].values())) - min(p[2] for p in (i["pos"] for i in machine_map["nodes"].values()))
box("MachinePlatform", MACHINE_AT + Vector((0, 0, -0.125)), (span_x+2.5, span_y+2.5, 0.25), "deck")

# Full-size export geometry is retained, including the project's chamfer mesh.
font = bpy.data.fonts.load("C:/Windows/Fonts/msyh.ttc")
billboards = []


def label(text, pos, size=0.3, role="ink"):
    curve = bpy.data.curves.new("Label_"+text, "FONT")
    curve.body = text
    curve.font = font
    curve.align_x = "CENTER"
    curve.align_y = "CENTER"
    curve.size = size
    obj = bpy.data.objects.new("Label_"+text, curve)
    scene.collection.objects.link(obj)
    obj.location = pos
    curve.materials.append(palette[role])
    billboards.append(obj)
    return obj


node_labels = []
module_labels = []
machine_labels = [label("可执行的方块程序", MACHINE_AT + Vector((0, 0, 2.9)), 0.27)]
for key in ("task", "tools", "start", "done"):
    info = machine_map["nodes"][key]
    machine_labels.append(label(info["label"], MACHINE_AT + Vector((info["pos"][0], -info["pos"][2], 1.7)), 0.2))
for node, (x, y) in nodes.items():
    node_labels.append(label(node, (x, y-0.85, 0.35), 0.34))
for index, text in enumerate(["大语言模型", "工具", "观测", "上下文", "控制循环"]):
    module_labels.append(label(text, (-5.5+index*2.75, 4.25, 2.5), 0.27))
concept_labels = [label("观测 ↑", (-1.75, 1.8, 0.65), 0.36, "blue"),
                  label("行动 ↓", (1.75, 1.8, 0.65), 0.36, "orange")]

for loc, energy, size in [((-7, 1, 12), 1800, 9), ((7, -7, 9), 1100, 8)]:
    data = bpy.data.lights.new("Softbox", "AREA")
    data.energy = energy
    data.shape = "DISK"
    data.size = size
    obj = bpy.data.objects.new("Softbox", data)
    scene.collection.objects.link(obj)
    obj.location = loc
    obj.rotation_euler = (Vector((0, -1, 0))-obj.location).to_track_quat("-Z", "Y").to_euler()
camera_data = bpy.data.cameras.new("LessonCamera")
camera = bpy.data.objects.new("LessonCamera", camera_data)
scene.collection.objects.link(camera)
scene.camera = camera
camera_data.type = "ORTHO"
camera_data.lens = 45
signal = box("Concept_signal", (0, 0, -10), (0.25, 0.25, 0.25), "blue")
focus_frames = []
for index, obj in enumerate(modules):
    ring = box("Module focus", (obj.location.x, obj.location.y, -0.005), (2, 2, 0.25), "yellow")
    focus_frames.append(ring)
times = [e["time"] for e in EDIT["events"]]
starts = [s["start"] for s in EDIT["shots"]]
# v11 混合管线：3D 只承担真实运行段（旁白日常语），概念/复盘镜走 2D。
RUN_IDS = {"task", "read", "pickup", "closure", "feedback", "reroute",
           "boundary", "delivery", "evidence", "second", "collect"}


def update(scene):
    time = (scene.frame_current-1)/EDIT["fps"]
    shot = EDIT["shots"][min(len(starts)-1, max(0, bisect.bisect_right(starts, time)-1))]
    ident = shot["id"]
    progress = max(0, min(1, (time-shot["start"])/shot["duration"]))
    event_index = bisect.bisect_right(times, time)-1
    event = EDIT["events"][event_index] if event_index >= 0 else None
    state = event["state"] if event else EDIT["initial"]
    # Movement interpolation changes presentation time only. Endpoints are recorded states.
    xy = Vector(nodes[state["carrier"]])
    if event and event["tool"] == "move" and event_index > 0:
        old = Vector(nodes[EDIT["events"][event_index-1]["state"]["carrier"]])
        following = times[event_index+1] if event_index+1 < len(times) else time+1
        duration = min(0.75, max(0.1, following-event["time"]))
        amount = min(1, max(0, (time-event["time"])/duration))
        amount = amount*amount*(3-2*amount)
        xy = old.lerp(xy, amount)
    carrier.location = (xy.x, xy.y, 0.5)
    for index, (name, obj) in enumerate(crates.items()):
        x, y = nodes[state["crates"][name]]
        if state["carrying"] == name:
            obj.location = (xy.x, xy.y, 1.0)
        elif state["crates"][name] == "D":
            obj.location = (x+(index-1)*0.75, y+1.25, 0.5)
        else:
            obj.location = (x, y+0.5, 0.5)
    barrier.hide_render = not bool(state["blocked_edges"])
    target, scale = Vector((0, 1, 0.5)), 22.5
    focus = {"model": 0, "tools": 1, "observation": 2, "context": 3}.get(ident, -1)
    if ident in ("system", "build", "next", "loop"):
        target, scale = Vector((3.0, 3.6, 0.6)), 18.0
    if ident == "representation":
        # 从概念件横移到右侧的可执行整机：方块即软件模块的可视化表示。
        target, scale = Vector((2.0 + 6.5*progress, 3.6, 0.6)), 17.5
    if ident == "scope":
        # 工具与权限：聚焦整机左侧已连接的工具绑定列与工具集合。
        target, scale = MACHINE_AT + Vector((-span_x/2 + 0.9, 0.5, 0.6)), 8.5
    if focus >= 0:
        target, scale = modules[focus].location + Vector((0, 0, 0.6)), 8.2
    if ident in ("task", "read", "closure", "reroute", "boundary", "delivery", "evidence", "second", "collect", "pickup"):
        target, scale = Vector((0, -1, 0.5)), 16.0
    if ident == "feedback":
        target, scale = Vector((1.5, 2.2, 0.7)), 11.5
    angle = -0.48 + 0.04*(progress-0.5)
    camera.location = target + Vector((math.sin(angle)*17, -math.cos(angle)*17, 17))
    camera.rotation_euler = (target-camera.location).to_track_quat("-Z", "Y").to_euler()
    camera_data.ortho_scale = scale*(1.015-0.03*progress)
    for obj in billboards:
        obj.rotation_euler = camera.rotation_euler
    for obj in concept_labels:
        obj.hide_render = ident != "agent"
    for obj in node_labels:
        obj.hide_render = focus >= 0
    for index, obj in enumerate(module_labels):
        obj.hide_render = (focus >= 0 and focus != index) or ident in RUN_IDS
    for obj in machine_labels:
        obj.hide_render = ident in RUN_IDS or focus >= 0
    active = focus
    if event and time-event["time"] < 0.6:
        active = 0 if event["tool"] == "model.generate" else (2 if event["tool"] == "tool.observation" else 1)
    for index, frame in enumerate(focus_frames):
        frame.hide_render = index != active
    signal.hide_render = ident not in ("agent", "loop", "build", "context")
    if not signal.hide_render:
        phase = (time % 4)/4*(len(modules)-1)
        left = min(int(phase), len(modules)-2)
        pos = modules[left].location.lerp(modules[left+1].location, phase-left)
        signal.location = pos + Vector((0, 0, 1.6))


bpy.app.handlers.frame_change_pre.append(update)
scene.frame_start = opts.start
scene.frame_end = opts.end or EDIT["frames"]
scene.render.filepath = str(OUT / "frames" / "frame_")
(OUT / "frames").mkdir(exist_ok=True)
if opts.bake:
    # Baking keeps the delivered .blend playable without a Python handler.
    # Evaluate old animation first, then set the desired state; a pre-handler
    # would be overwritten by the animation evaluation once keys exist.
    bpy.app.handlers.frame_change_pre.remove(update)
    frames = set(range(1, EDIT["frames"]+1, 5)) | {EDIT["frames"]}
    for shot in EDIT["shots"]:
        frame = round(shot["start"]*EDIT["fps"])+1
        frames.update([max(1,frame-1),frame])
    for event in EDIT["events"]:
        frame = round(event["time"]*EDIT["fps"])+1
        frames.update([max(1,frame-1),frame,min(EDIT["frames"],frame+18)])
    moving = [carrier, *crates.values(), camera, signal]
    visibility = [barrier, signal, *focus_frames, *concept_labels, *node_labels, *module_labels, *machine_labels]
    for frame in sorted(frames):
        scene.frame_set(frame)
        update(scene)
        for obj in moving:
            obj.keyframe_insert("location", frame=frame)
        for obj in [camera, *billboards]:
            obj.keyframe_insert("rotation_euler", frame=frame)
        for obj in visibility:
            obj.keyframe_insert("hide_render", frame=frame)
        camera_data.keyframe_insert("ortho_scale", frame=frame)
    # Native animation remains; this process also renders those same stored keys.
    for action in bpy.data.actions:
        for layer in action.layers:
            for strip in layer.strips:
                for bag in strip.channelbags:
                    for curve in bag.fcurves:
                        for key in curve.keyframe_points:
                            key.interpolation = "CONSTANT" if "hide_render" in curve.data_path else "LINEAR"
    scene.frame_set(EDIT["frames"])
    assert (Vector(carrier.location)-Vector((4,0,0.5))).length < 0.001, "baked final delivery position drifted"
    assert not barrier.hide_render, "baked road closure disappeared"
    scene.frame_set(1)
    assert (Vector(carrier.location)-Vector((-4,0,0.5))).length < 0.001, "baked initial position drifted"
scene.frame_set(opts.start)
bpy.ops.wm.save_as_mainfile(filepath=str(OUT / ("lesson01.blend" if opts.bake else "lesson01-preview.blend")))
if opts.bake:
    # Preserve the editable bake on disk. For rendering, evaluate the full source
    # record directly; Blender's animated visibility otherwise rebuilds text
    # geometry every frame, despite unchanged visibility values.
    for obj in scene.objects:
        if obj.animation_data: obj.animation_data_clear()
    if camera_data.animation_data: camera_data.animation_data_clear()
    bpy.app.handlers.frame_change_pre.append(update)
    scene.frame_set(opts.start)
if opts.preview:
    for shot in EDIT["shots"]:
        if shot["id"] not in opts.preview_ids.split(","): continue
        frame = round((shot["start"]+shot["duration"]*0.5)*EDIT["fps"])+1
        scene.frame_set(frame)
        scene.render.filepath = str(OUT / ("preview_"+shot["id"]+".jpg"))
        bpy.ops.render.render(write_still=True)
else:
    bpy.ops.render.render(animation=True)
