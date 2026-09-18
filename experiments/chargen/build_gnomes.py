"""Add shared gnome modules and nine presets without rebuilding old parts."""

import json
import sys
from pathlib import Path

import bpy

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Library = Root.parent / 'polyworld_data/characters/chargen'
Source = Library / 'source'
Output = Root / 'tmp/chargen/gnomes'
Folders = {'Nose': 'noses', 'Ears': 'ears', 'Beard': 'beards', 'Eyes': 'eyes'}
sys.path.insert(0, str(Experiment))
sys.dont_write_bytecode = True
import glbs
from gnomes import buildGnomes, gnomeParts, gnomePresets

Output.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(Source / 'character.blend'))
rig = bpy.data.objects['CharacterRig']
head = bpy.data.objects['Head']
collection = head.users_collection[0]
items = buildGnomes(collection, head)
for item in items:
  item.parent = rig
  item.modifiers.new('Shared humanoid rig', 'ARMATURE').object = rig
  if not item.data.uv_layers:
    bpy.ops.object.select_all(action='DESELECT')
    item.select_set(True)
    bpy.context.view_layer.objects.active = item
    bpy.ops.object.mode_set(mode='EDIT')
    bpy.ops.mesh.select_all(action='SELECT')
    bpy.ops.uv.smart_project(island_margin=.02)
    bpy.ops.object.mode_set(mode='OBJECT')
  assert all(abs(sum(group.weight for group in vertex.groups) - 1) < 1e-6
             for vertex in item.data.vertices)
savedAction = rig.animation_data.action
rig.animation_data.action = None
rig.data.pose_position = 'REST'
bpy.ops.object.select_all(action='DESELECT')
for item in items + [rig]:
  item.hide_set(False)
  item.select_set(True)
bpy.context.view_layer.objects.active = rig
bpy.ops.export_scene.gltf(
  filepath=str(Output / 'parts.glb'), export_format='GLB',
  use_selection=True, export_animations=False, export_skins=True,
  export_materials='EXPORT', export_yup=True)
document, binary = glbs.read(Output / 'parts.glb')
manifest = json.loads((Source / 'manifest.json').read_text())
for category, part in gnomeParts():
  identity = Folders[category] + '/' + part['name'].lower().replace(' ', '_')
  part = dict(part, singleFile=True, alignment='good' if category == 'Eyes' else 'both')
  data, blob = glbs.subset(document, binary, meshes=part['nodes'])
  shades = []
  if category == 'Eyes':
    data['images'] = [{'uri': 'gnome_kind.png'}]
    for material in data['materials']:
      material['alphaMode'], material['alphaCutoff'] = 'MASK', .5
      material['pbrMetallicRoughness'] = dict(
        baseColorFactor=[1, 1, 1, 1], baseColorTexture={'index': 0},
        metallicFactor=0, roughnessFactor=1)
      material.pop('emissiveTexture', None)
      material.pop('emissiveFactor', None)
      material.setdefault('extensions', {})['KHR_materials_unlit'] = {}
    data.setdefault('extensionsUsed', []).append('KHR_materials_unlit')
    data['extensionsUsed'] = list(dict.fromkeys(data['extensionsUsed']))
    data, blob = glbs.subset(data, blob, meshes=part['nodes'])
  if category == 'Beard':
    for node in data['nodes']:
      if 'mesh' in node:
        shades += [dict(node=node['name'], primitive=i, shade=1)
                   for i, primitive in enumerate(data['meshes'][node['mesh']]['primitives'])]
  glbs.write(Library / (identity + '.glb'), data, blob)
  metadata = dict(part, id=identity, files=[identity + '.glb'],
                  hairShades=shades, skinNodes=part.get('skinNodes', []))
  (Library / (identity + '.json')).write_text(json.dumps(metadata, indent=2) + '\n')
  current = next(entry for entry in manifest['categories'] if entry['key'] == category)
  current['items'] = [entry for entry in current['items'] if entry['name'] != part['name']]
  current['items'].append(part)
  manifest['skinNodes'] = list(dict.fromkeys(manifest['skinNodes'] + metadata['skinNodes']))
  manifest['hairShades'] = [entry for entry in manifest['hairShades'] if entry['node'] not in part['nodes']] + shades
manifest['presets'] = [preset for preset in manifest['presets']
                       if preset.get('group') != 'Gnomes'] + gnomePresets()
runtime = json.loads((Library / 'manifest.json').read_text())
runtime['presets'] = [preset for preset in runtime['presets']
                      if preset.get('group') != 'Gnomes'] + gnomePresets()
(Library / 'manifest.json').write_text(json.dumps(runtime, indent=2) + '\n')
(Source / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
report = json.loads((Source / 'model.json').read_text())
names = {item.name for item in items}
report['meshes'] = [entry for entry in report['meshes'] if entry['name'] not in names]
report['meshes'] += [dict(name=item.name, vertices=len(item.data.vertices),
                          polygons=len(item.data.polygons)) for item in items]
(Source / 'model.json').write_text(json.dumps(report, indent=2) + '\n')
rig.data.pose_position = 'POSE'
rig.animation_data.action = savedAction
if savedAction:
  rig.animation_data.action_slot = savedAction.slots[0]
# Refresh the assembled verification export while preserving old runtime files.
bpy.ops.object.select_all(action='DESELECT')
allNames = {entry['name'] for entry in report['meshes']}
allItems = [bpy.data.objects[name] for name in allNames]
visibility = [(item, item.hide_get()) for item in allItems]
for item in allItems + [rig]:
  item.hide_set(False)
  item.select_set(True)
bpy.context.scene.frame_set(0)
bpy.ops.export_scene.gltf(
  filepath=str(Root / 'tmp/chargen/character.glb'), export_format='GLB',
  use_selection=True, export_animations=True, export_animation_mode='ACTIONS',
  export_frame_range=False, export_force_sampling=True, export_skins=True,
  export_materials='EXPORT', export_yup=True)
for item, hidden in visibility:
  item.hide_set(hidden)
for item in items:
  item.hide_set(True)
  item.hide_render = True
  if item.name == 'Eyes_Gnome':
    for material in item.data.materials:
      for node in material.node_tree.nodes:
        if node.type == 'TEX_IMAGE':
          node.image.pack()
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=str(Source / 'character.blend'))
print('BUILT four shared gnome parts in', len(items), 'meshes', flush=True)
