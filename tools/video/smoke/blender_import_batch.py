import bpy, glob
bpy.ops.wm.read_factory_settings()
for ob in list(bpy.data.objects):
    bpy.data.objects.remove(ob, do_unlink=True)
files = sorted(glob.glob('D:/ai-project-lab/game/shots/video3d/components/*.glb'))
ok, fail = 0, []
for f in files:
    try:
        bpy.ops.import_scene.gltf(filepath=f)
        ok += 1
    except Exception as e:
        fail.append((f, str(e)[:80]))
meshes = [o for o in bpy.data.objects if o.type == 'MESH']
print('FILES_TOTAL', len(files), 'IMPORTED_OK', ok, 'FAILED', len(fail))
print('MESH_OBJECTS_TOTAL', len(meshes))
print('FAIL_DETAIL', fail)
print('SAMPLE', [(o.name, tuple(round(v, 3) for v in o.dimensions)) for o in meshes[:3]])
print('SCENE_DIMS', tuple(round(v, 2) for v in bpy.context.scene.box if False) if False else 'skip')
print('BLENDER_GLTF_BATCH_OK' if ok == len(files) and not fail else 'BLENDER_GLTF_BATCH_FAIL')
