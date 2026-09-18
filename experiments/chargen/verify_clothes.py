"""Check actual garment skinning, topology and animated body clearance."""

import json
import math
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree

Root = Path(__file__).resolve().parents[2]
Output = Root / 'tmp/chargen/clothing_reviews'
sys.dont_write_bytecode = True
bpy.ops.wm.open_mainfile(filepath=str(
  Root.parent / 'polyworld_data/characters/chargen/source/character.blend'))
rig = bpy.data.objects['CharacterRig']
items = [item for item in bpy.data.objects if item.type == 'MESH' and
         item.name.startswith('Clothing_')]
body = bpy.data.objects['Body']
report = {'garments': 16, 'sections': len(items), 'geometry': [], 'clearance': []}
for item in items:
  item.hide_set(False)
  assert any(modifier.type == 'ARMATURE' and modifier.object == rig
             for modifier in item.modifiers), item.name
  for vertex in item.data.vertices:
    assert all(math.isfinite(value) for value in vertex.co), item.name
    assert abs(sum(group.weight for group in vertex.groups) - 1) < .00001
    assert all(item.vertex_groups[group.group].name in rig.data.bones
               for group in vertex.groups)
  data = bmesh.new()
  data.from_mesh(item.data)
  tiny = sum(face.calc_area() < 1e-10 for face in data.faces)
  report['geometry'].append({'name': item.name, 'tinyFaces': tiny,
    'boundaryEdges': sum(edge.is_boundary for edge in data.edges),
    'nonmanifoldEdges': sum(not edge.is_manifold and not edge.is_boundary
                          for edge in data.edges)})
  data.free()
  assert tiny == 0, (item.name, tiny)
body.hide_set(False)
for name in ['Walk_Loop', 'Jog_Fwd_Loop', 'Crouch_Fwd_Loop',
             'Sitting_Idle_Loop', 'Punch_Cross', 'Jump_Loop']:
  action = bpy.data.actions[name]
  rig.animation_data.action = action
  rig.animation_data.action_slot = action.slots[0]
  for amount in [0, .25, .5, .75]:
    bpy.context.scene.frame_set(int(action.frame_range[1] * amount))
    bpy.context.view_layer.update()
    graph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(graph)
    mesh = evaluated.to_mesh()
    surface = BVHTree.FromPolygons([vertex.co for vertex in mesh.vertices],
                                  [face.vertices[:] for face in mesh.polygons])
    evaluated.to_mesh_clear()
    for item in items:
      if int(item['clothingNumber']) > 8:
        continue
      evaluated = item.evaluated_get(graph)
      mesh = evaluated.to_mesh()
      deepest, count, position = 0, 0, None
      for vertex in mesh.vertices:
        near, normal, face, distance = surface.find_nearest(vertex.co)
        signed = (vertex.co - near).dot(normal)
        if signed < -.008:
          count += 1
        if signed < deepest:
          deepest, position = signed, tuple(vertex.co)
      evaluated.to_mesh_clear()
      if count:
        report['clearance'].append({'clip': name, 'phase': amount,
          'garment': item.name, 'insideVertices': count,
          'deepest': deepest, 'position': position})
(Output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('VERIFIED', len(items), 'weighted clothing mesh sections')
print('Body clearance diagnostics saved to', Output / 'verification.json')
