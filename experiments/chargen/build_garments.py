"""Add gnome outerwear and outfit presets without rebuilding existing assets."""

import json
import sys
from pathlib import Path

import bpy

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Library = Root.parent / 'polyworld_data/characters/chargen'
Source = Library / 'source'
Output = Root / 'tmp/chargen/garments'
sys.path.insert(0, str(Experiment))
sys.dont_write_bytecode = True
import glbs
from garments import Folders, buildGarments, garmentParts, outfitPresets


def shades(document, names):
  """Bind fabric primitives explicitly while leaving metal and trim unchanged."""
  result = []
  for node in document['nodes']:
    if node.get('name') not in names or 'mesh' not in node:
      continue
    for i, primitive in enumerate(document['meshes'][node['mesh']]['primitives']):
      name = document['materials'][primitive['material']].get('name', '')
      if name.endswith(' fabric') or name.endswith(' edging'):
        result.append(dict(node=node['name'], primitive=i,
                            shade=1.14 if name.endswith(' edging') else 1))
  return result


def write(path, data):
  """Write readable metadata beside individually shippable meshes."""
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(json.dumps(data, indent=2) + '\n')


Output.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(Source / 'character.blend'))
rig = bpy.data.objects['CharacterRig']
collection = bpy.data.objects['Body'].users_collection[0]
items = buildGarments(collection)
for item in items:
  item.parent = rig
  item.modifiers.new('Shared humanoid rig', 'ARMATURE').object = rig
  bpy.ops.object.select_all(action='DESELECT')
  item.select_set(True)
  bpy.context.view_layer.objects.active = item
  bpy.ops.object.mode_set(mode='EDIT')
  bpy.ops.mesh.select_all(action='SELECT')
  bpy.ops.uv.smart_project(island_margin=.02)
  bpy.ops.object.mode_set(mode='OBJECT')
  assert all(abs(sum(g.weight for g in v.groups) - 1) < 1e-5
             for v in item.data.vertices)
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
runtime = json.loads((Library / 'manifest.json').read_text())
for category, part in garmentParts():
  identity = Folders[category] + '/' + part['name'].lower().replace(' ', '_')
  data, blob = glbs.subset(document, binary, meshes=part['nodes'])
  glbs.write(Library / (identity + '.glb'), data, blob)
  part['clothShades'] = shades(data, part['nodes'])
  metadata = dict(part, id=identity, files=[identity + '.glb'], skinNodes=[])
  write(Library / (identity + '.json'), metadata)
  current = next((c for c in manifest['categories'] if c['key'] == category), None)
  if current is None:
    current = dict(key=category, selected=-1, items=[])
    manifest['categories'].append(current)
    runtime['categories'].append(dict(key=category, directory=Folders[category], defaultItem=''))
  current['items'] = [p for p in current['items'] if p['name'] != part['name']]
  current['items'].append(part)
# Existing clothing receives tint bindings, without rewriting its geometry.
for category in runtime['categories']:
  if not category['directory'].startswith('clothing/'):
    continue
  for path in (Library / category['directory']).glob('*.json'):
    metadata = json.loads(path.read_text())
    metadata['clothShades'] = []
    for file in metadata['files']:
      data, blob = glbs.read(Library / file)
      metadata['clothShades'] += shades(data, metadata['nodes'])
    write(path, metadata)
    authoring = next(c for c in manifest['categories'] if c['key'] == category['key'])
    for part in authoring['items']:
      if part['name'] == metadata['name']:
        part['clothShades'] = metadata['clothShades']
manifest['presets'] = outfitPresets(manifest['presets'])
runtime['presets'] = outfitPresets(runtime['presets'])
write(Source / 'manifest.json', manifest)
write(Library / 'manifest.json', runtime)
report = json.loads((Source / 'model.json').read_text())
names = {item.name for item in items}
report['meshes'] = [entry for entry in report['meshes'] if entry['name'] not in names]
report['meshes'] += [dict(name=item.name, vertices=len(item.data.vertices),
                          polygons=len(item.data.polygons)) for item in items]
write(Source / 'model.json', report)
rig.data.pose_position = 'POSE'
rig.animation_data.action = savedAction
if savedAction:
  rig.animation_data.action_slot = savedAction.slots[0]
bpy.ops.object.select_all(action='DESELECT')
allItems = [bpy.data.objects[entry['name']] for entry in report['meshes']]
visibility = [(item, item.hide_get()) for item in allItems]
for item in allItems + [rig]:
  item.hide_set(False)
  item.select_set(True)
bpy.context.view_layer.objects.active = rig
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
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=str(Source / 'character.blend'))
print('BUILT', len(items), 'garments from existing clothing.', flush=True)
