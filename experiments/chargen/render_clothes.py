"""Render the actual clothing models in matching front and back pairs."""

import math
import sys
from pathlib import Path

import bpy
import bmesh
from mathutils import Matrix, Quaternion, Vector

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Output = Root / 'tmp/chargen/clothing_reviews'
sys.path.insert(0, str(Experiment))
sys.dont_write_bytecode = True
from clothes import Specs, nodeName

Output.mkdir(parents=True, exist_ok=True)
bpy.ops.wm.open_mainfile(filepath=str(
  Root.parent / 'polyworld_data/characters/chargen/source/character.blend'))
rig = bpy.data.objects['CharacterRig']
rig.animation_data.action = None
for bone in rig.pose.bones:
  bone.matrix_basis.identity()
for side, sign in [('Left', 1), ('Right', -1)]:
  bone = rig.pose.bones[side + 'Arm']
  rotation = bone.bone.matrix_local.to_quaternion()
  bone.rotation_mode = 'QUATERNION'
  bone.rotation_quaternion = (rotation.inverted() @
    Quaternion((0, 1, 0), sign * math.radians(52)) @ rotation)
bpy.context.view_layer.update()
meshes = {}
for spec in Specs:
  for item in bpy.data.objects:
    if item.name == nodeName(spec) or item.name.startswith(nodeName(spec) + '_'):
      item.hide_set(False)
bpy.context.view_layer.update()
graph = bpy.context.evaluated_depsgraph_get()
for spec in Specs:
  parts = [item for item in bpy.data.objects if item.type == 'MESH' and
           (item.name == nodeName(spec) or item.name.startswith(nodeName(spec) + '_'))]
  mesh = bpy.data.meshes.new(nodeName(spec) + ' preview')
  data = bmesh.new()
  for item in parts:
    part = bpy.data.meshes.new_from_object(item.evaluated_get(graph))
    data.from_mesh(part)
    bpy.data.meshes.remove(part)
  bmesh.ops.remove_doubles(data, verts=list(data.verts), dist=.00001)
  data.to_mesh(mesh)
  data.free()
  for material in parts[0].data.materials:
    mesh.materials.append(material)
  meshes[spec['number']] = mesh
for material in bpy.data.materials:
  if material.name.startswith('Clothing'):
    shader = material.node_tree.nodes.get('Principled BSDF')
    color = shader.inputs['Base Color'].default_value
    shader.inputs['Base Color'].default_value = (*[
      value / 12.92 if value <= .04045 else ((value + .055) / 1.055) ** 2.4
      for value in color[:3]], 1)
for item in list(bpy.data.objects):
  bpy.data.objects.remove(item, do_unlink=True)
scene = bpy.context.scene
scene.render.engine = 'CYCLES'
scene.cycles.samples = 20
scene.cycles.use_denoising = True
scene.cycles.use_adaptive_sampling = True
scene.cycles.adaptive_threshold = .04
scene.render.resolution_x, scene.render.resolution_y = 1000, 620
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = 'PNG'
scene.render.image_settings.color_mode = 'RGBA'
scene.render.film_transparent = True
scene.view_settings.view_transform = 'Standard'
scene.view_settings.look = 'None'
world = bpy.data.worlds.new('Clothing studio')
world.use_nodes = True
world.node_tree.nodes['Background'].inputs[0].default_value = (1, 1, 1, 1)
world.node_tree.nodes['Background'].inputs[1].default_value = .65
scene.world = world
for name, direction, power in [('Key', (-3, -5, 7), 1.8),
                               ('Fill', (4, -3, 3), .5)]:
  light = bpy.data.lights.new(name, 'SUN')
  light.energy, light.angle = power, .4
  item = bpy.data.objects.new(name, light)
  scene.collection.objects.link(item)
  item.rotation_euler = (-Vector(direction)).to_track_quat('-Z', 'Y').to_euler()
camera = bpy.data.objects.new('Clothing camera', bpy.data.cameras.new('Camera'))
scene.collection.objects.link(camera)
camera.location = (0, -30, 6)
camera.rotation_euler = (-camera.location).to_track_quat('-Z', 'Y').to_euler()
camera.data.type = 'ORTHO'
scene.camera = camera
for spec in Specs:
  mesh = meshes[spec['number']]
  low = Vector(tuple(min(vertex.co[i] for vertex in mesh.vertices) for i in range(3)))
  high = Vector(tuple(max(vertex.co[i] for vertex in mesh.vertices) for i in range(3)))
  center = (low + high) / 2
  width, height = high.x - low.x, high.z - low.z
  span = max(width * 1.13, height * .89)
  camera.data.ortho_scale = max(span * 2.15, height * 1.95)
  objects = []
  for x, angle in [(-span * .54, -.12), (span * .54, math.pi - .12)]:
    item = bpy.data.objects.new('Turnaround', mesh)
    scene.collection.objects.link(item)
    item.matrix_world = (Matrix.Translation((x, 0, 0)) @
                         Matrix.Rotation(angle, 4, 'Z') @
                         Matrix.Translation(-center))
    objects.append(item)
  scene.render.filepath = str(Output / f'render_{spec["number"]:02}.png')
  bpy.ops.render.render(write_still=True)
  for item in objects:
    bpy.data.objects.remove(item, do_unlink=True)
  print('CLOTHING_RENDERED', spec['number'], flush=True)
