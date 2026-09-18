"""Add body-derived clothing without rebuilding existing meshes or animation."""

import json
import sys
from pathlib import Path

import bpy

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Library = Root.parent / 'polyworld_data/characters/chargen'
Source = Library / 'source'
Preview = Root / 'tmp/chargen/clothing_reviews'
sys.path.insert(0, str(Experiment))
sys.dont_write_bytecode = True
from clothes import Specs, buildClothes, clothingParts
import glbs

Preview.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(Source / 'character.blend'))
rig = bpy.data.objects['CharacterRig']
collection = bpy.data.objects['Body'].users_collection[0]
body = [bpy.data.objects[name] for name in ['Body', 'Foot.Left', 'Foot.Right']]
items = buildClothes(collection, body)
for item in items:
  modifier = item.modifiers.new('Shared humanoid rig', 'ARMATURE')
  modifier.object = rig
  item.parent = rig
  bpy.ops.object.select_all(action='DESELECT')
  item.select_set(True)
  bpy.context.view_layer.objects.active = item
  bpy.ops.object.mode_set(mode='EDIT')
  bpy.ops.mesh.select_all(action='SELECT')
  bpy.ops.uv.smart_project(island_margin=.02)
  bpy.ops.object.mode_set(mode='OBJECT')
  item.select_set(False)
  for vertex in item.data.vertices:
    assert abs(sum(group.weight for group in vertex.groups) - 1) < 1e-5

savedAction = rig.animation_data.action
rig.animation_data.action = None
for bone in rig.pose.bones:
  bone.matrix_basis.identity()
rig.data.pose_position = 'REST'
bpy.ops.object.select_all(action='DESELECT')
for item in items + [rig]:
  item.hide_set(False)
  item.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(
  filepath=str(Preview / 'clothing.glb'), export_format='GLB',
  use_selection=True, export_animations=False, export_skins=True,
  export_materials='EXPORT', export_yup=True,
)
document, binary = glbs.read(Preview / 'clothing.glb')
folders = {'Chest': 'clothing/torsos', 'Leg': 'clothing/pants',
           'Foot': 'clothing/boots'}
for category, part in clothingParts():
  identity = folders[category] + '/' + part['name'].lower().replace(' ', '_')
  path = Library / (identity + '.json')
  previous = json.loads(path.read_text()) if path.exists() else {}
  mesh, data = glbs.subset(document, binary, meshes=part['nodes'])
  glbs.write(Library / (identity + '.glb'), mesh, data)
  metadata = dict(part, id=identity, files=[identity + '.glb'],
                  skinNodes=[], hairShades=[],
                  alignment=previous.get('alignment', 'both'))
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(json.dumps(metadata, indent=2) + '\n')

manifest = json.loads((Source / 'manifest.json').read_text())
for category in manifest['categories']:
  if category['key'] in folders:
    category['items'] = [item for item in category['items']
                         if not any(name.startswith('Clothing_') for name in item['nodes'])]
    category['items'] += [item for key, item in clothingParts() if key == category['key']]
(Source / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
report = json.loads((Source / 'model.json').read_text())
report['meshes'] = [mesh for mesh in report['meshes']
                    if not mesh['name'].startswith('Clothing_')]
report['meshes'] += [{'name': item.name, 'vertices': len(item.data.vertices),
                      'polygons': len(item.data.polygons)} for item in items]
(Source / 'model.json').write_text(json.dumps(report, indent=2) + '\n')
rig.data.pose_position = 'POSE'
rig.animation_data.action = bpy.data.actions['A_TPose']
rig.animation_data.action_slot = rig.animation_data.action.slots[0]
bpy.context.scene.frame_set(0)
allMeshes = [item for item in collection.objects if item.type == 'MESH']
hidden = {item.name: item.hide_get() for item in allMeshes}
bpy.ops.object.select_all(action='DESELECT')
for item in allMeshes + [rig]:
  item.hide_set(False)
  item.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(
  filepath=str(Root / 'tmp/chargen/character.glb'), export_format='GLB',
  use_selection=True, export_animations=True, export_animation_mode='ACTIONS',
  export_frame_range=False, export_force_sampling=True, export_skins=True,
  export_materials='EXPORT', export_yup=True,
)
for item in allMeshes:
  item.hide_set(hidden[item.name])
rig.animation_data.action = savedAction
if savedAction:
  rig.animation_data.action_slot = savedAction.slots[0]
bpy.context.scene.frame_set(0)
for item in items:
  item.hide_set(True)
  item.hide_render = True
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=str(Source / 'character.blend'))
(Preview / 'construction.json').write_text(json.dumps([
  {'number': spec['number'], 'name': item.name,
   'source': item['derivedFrom'], 'construction': item['construction'],
   'vertices': len(item.data.vertices), 'faces': len(item.data.polygons)}
  for item in items for spec in Specs if spec['number'] == item['clothingNumber']
], indent=2) + '\n')
print('BUILT', len(Specs), 'body-derived garments in', len(items), 'mesh sections', flush=True)
