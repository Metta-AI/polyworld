"""Render the real modeled hairstyles as paired concept-matching turnarounds."""

import argparse
import json
import math
import sys
from pathlib import Path

import bpy
from mathutils import Matrix, Vector

Experiment = Path(__file__).resolve().parent
sys.path.insert(0, str(Experiment))
sys.dont_write_bytecode = True
from hairs import Names, buildHair

parser = argparse.ArgumentParser()
parser.add_argument('--styles', default='')
parser.add_argument('--output', default=str(Experiment.parents[1] / 'tmp/blender_chars/hair_reviews'))
args = parser.parse_args(sys.argv[sys.argv.index('--') + 1:] if '--' in sys.argv else [])
Output = Path(args.output)
Output.mkdir(parents=True, exist_ok=True)
styles = [int(value) for value in args.styles.split(',')] if args.styles else list(range(1, 17))
bpy.ops.wm.open_mainfile(filepath=str(Experiment / 'assets/character.blend'))
parts = ['Head', 'Nose_Tiny', 'Ears_Round_Left', 'Ears_Round_Right',
         'Eyes_Atlas02', 'Mouth_Atlas01']
meshes = {name: bpy.data.objects[name].data.copy() for name in parts}
for item in list(bpy.data.objects):
  bpy.data.objects.remove(item, do_unlink=True)
collection = bpy.data.collections.new('Modeled hairstyles')
bpy.context.scene.collection.children.link(collection)
models = buildHair(collection, styles)
for item in models:
  item.hide_render = True
  meshes[item.name] = item.data

skin = bpy.data.materials.new('Turnaround skin')
skin.use_nodes = True
shader = skin.node_tree.nodes['Principled BSDF']
shader.inputs['Base Color'].default_value = (.77, .51, .34, 1)
shader.inputs['Roughness'].default_value = 1
shader.inputs['Specular IOR Level'].default_value = .1
for name in parts:
  if name.startswith(('Eyes_', 'Mouth_')):
    continue
  meshes[name].materials.clear()
  meshes[name].materials.append(skin)

scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 24
scene.cycles.use_denoising = True
scene.cycles.use_adaptive_sampling = True
scene.cycles.adaptive_threshold = .035
scene.render.resolution_x, scene.render.resolution_y = 1000, 650
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.film_transparent = True
scene.render.dither_intensity = 0
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
world = bpy.data.worlds.new('Hair studio')
world.use_nodes = True
world.node_tree.nodes['Background'].inputs[0].default_value = (1, 1, 1, 1)
world.node_tree.nodes['Background'].inputs[1].default_value = .5
scene.world = world
for name, direction, energy, angle in [
  ('Soft key', (-3, -4, 6), 1.9, .4),
  ('Soft fill', (4, -3, 2), .5, .6),
  ('Back edge', (1, 4, 4), .65, .5),
]:
  light = bpy.data.lights.new(name, 'SUN')
  light.energy, light.angle = energy, angle
  item = bpy.data.objects.new(name, light)
  scene.collection.objects.link(item)
  item.rotation_euler = (-Vector(direction)).to_track_quat('-Z', 'Y').to_euler()
camera = bpy.data.objects.new('Hair front and rear', bpy.data.cameras.new('Camera'))
scene.collection.objects.link(camera)
camera.location = (0, -20, 0)
camera.rotation_euler = (math.pi / 2, 0, 0)
camera.data.type = 'ORTHO'
camera.data.ortho_scale = 3.7
scene.camera = camera

report = []
for style in styles:
  rendered = []
  for x, yaw in [(-.91, -18), (.91, 148)]:
    transform = (Matrix.Translation((x, 0, .09)) @
                 Matrix.Rotation(math.radians(7), 4, 'X') @
                 Matrix.Rotation(math.radians(yaw), 4, 'Z') @
                 Matrix.Translation((0, 0, -2.53)))
    for name in parts + [f'Hair_{style:02}']:
      item = bpy.data.objects.new(name + ' render', meshes[name])
      scene.collection.objects.link(item)
      item.matrix_world = transform
      rendered.append(item)
  scene.render.filepath = str(Output / f'render_{style:02}.png')
  bpy.ops.render.render(write_still=True)
  hair = meshes[f'Hair_{style:02}']
  hair.calc_loop_triangles()
  report.append({'style': style, 'name': Names[style - 1],
                 'vertices': len(hair.vertices), 'triangles': len(hair.loop_triangles),
                 'render': f'render_{style:02}.png'})
  print('HAIR_RENDERED', style, report[-1], flush=True)
  for item in rendered:
    bpy.data.objects.remove(item, do_unlink=True)
(Output / 'geometry.json').write_text(json.dumps(report, indent=2) + '\n')
