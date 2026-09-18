"""Add the Universal library to the existing authoring model and split GLBs."""

import json
import os
import subprocess
import sys
from pathlib import Path

import bpy

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Library = Root.parent / 'polyworld_data/characters/chargen'
Source = Library / 'source'
Preview = Root / 'tmp/chargen'
sys.path.insert(0, str(Experiment))
sys.dont_write_bytecode = True
from universal import retargetUniversal
from retarget import FrameRate

bpy.ops.wm.open_mainfile(filepath=str(Source / 'character.blend'))
rig = bpy.data.objects['CharacterRig']
actions, clips = retargetUniversal(rig)
manifest = json.loads((Source / 'manifest.json').read_text())
manifest['clips'] = [clip for clip in manifest['clips'] if clip['kind'] != 'universal'] + clips
manifest['defaultAnimation'] = 'Walk_Loop'
manifest['clipSource'] = 'Quaternius Universal Standard; RPG Tiny Hero Duo and Layer Lab poses'
scene = bpy.context.scene
scene.render.fps = FrameRate
rig.animation_data.action = bpy.data.actions['Idle_Loop']
rig.animation_data.action_slot = rig.animation_data.action.slots[0]
scene.frame_set(0)
items = [item for item in bpy.data.objects if item.type == 'MESH'] + [rig]
hidden = {item.name: item.hide_get() for item in items}
bpy.ops.object.select_all(action='DESELECT')
for item in items:
  item.hide_set(False)
  item.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(
  filepath=str(Preview / 'character.glb'), export_format='GLB',
  use_selection=True, export_animations=True, export_animation_mode='ACTIONS',
  export_frame_range=False, export_force_sampling=True, export_skins=True,
  export_materials='EXPORT', export_yup=True,
)
for item in items:
  item.hide_set(hidden[item.name])
rig.animation_data.action = bpy.data.actions['Idle_Loop']
rig.animation_data.action_slot = rig.animation_data.action.slots[0]
scene.frame_start, scene.frame_end = 0, 75
scene.frame_set(0)
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=str(Source / 'character.blend'))
(Source / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
report = json.loads((Source / 'model.json').read_text())
report['animations'] = [clip['name'] for clip in manifest['clips']]
(Source / 'model.json').write_text(json.dumps(report, indent=2) + '\n')
subprocess.run([os.environ.get('CHARGEN_PYTHON', 'python3'),
                str(Experiment / 'export_library.py')], check=True)
print('IMPORTED', len(clips), 'Universal clips', flush=True)
