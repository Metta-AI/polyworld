"""Verify inherited garment weights, valid geometry, and posed body clearance."""

import json
import math
from pathlib import Path

import bmesh
import bpy
from mathutils.bvhtree import BVHTree

Root = Path(__file__).resolve().parents[2]
Output = Root / 'tmp/chargen/garments'
bpy.ops.wm.open_mainfile(filepath=str(
  Root.parent / 'polyworld_data/characters/chargen/source/character.blend'))
rig = bpy.data.objects['CharacterRig']
items = [item for item in bpy.data.objects if item.name.startswith('Gnome_')
         and item.type == 'MESH']
body = bpy.data.objects['Body']
report = dict(geometry=[], clearance=[])
for item in items:
  item.hide_set(False)
  assert any(m.type == 'ARMATURE' and m.object == rig for m in item.modifiers)
  for vertex in item.data.vertices:
    assert all(math.isfinite(v) for v in vertex.co)
    assert abs(sum(g.weight for g in vertex.groups) - 1) < .00001
    assert all(item.vertex_groups[g.group].name in rig.data.bones for g in vertex.groups)
  edit = bmesh.new()
  edit.from_mesh(item.data)
  tiny = sum(face.calc_area() < 1e-10 for face in edit.faces)
  report['geometry'].append(dict(name=item.name, tinyFaces=tiny,
    vertices=len(edit.verts), faces=len(edit.faces),
    boundaryEdges=sum(edge.is_boundary for edge in edit.edges),
    nonmanifoldEdges=sum(not e.is_manifold and not e.is_boundary for e in edit.edges)))
  edit.free()
  assert tiny == 0, (item.name, tiny)
body.hide_set(False)
for clip in ['A_TPose', 'Walk_Loop', 'Jog_Fwd_Loop', 'Crouch_Fwd_Loop',
             'Sitting_Idle_Loop', 'Punch_Cross', 'Jump_Loop']:
  action = bpy.data.actions[clip]
  rig.animation_data.action = action
  rig.animation_data.action_slot = action.slots[0]
  for phase in [0, .25, .5, .75]:
    bpy.context.scene.frame_set(int(action.frame_range[1] * phase))
    bpy.context.view_layer.update()
    graph = bpy.context.evaluated_depsgraph_get()
    evaluated = body.evaluated_get(graph)
    mesh = evaluated.to_mesh()
    tree = BVHTree.FromPolygons([v.co for v in mesh.vertices],
                               [p.vertices[:] for p in mesh.polygons])
    evaluated.to_mesh_clear()
    for item in items:
      evaluated = item.evaluated_get(graph)
      mesh = evaluated.to_mesh()
      deepest, count = 0, 0
      for vertex in mesh.vertices:
        near, normal, index, distance = tree.find_nearest(vertex.co)
        signed = (vertex.co - near).dot(normal)
        if signed < -.012:
          count += 1
          deepest = min(deepest, signed)
      evaluated.to_mesh_clear()
      if count:
        report['clearance'].append(dict(name=item.name, clip=clip, phase=phase,
                                        insideVertices=count, deepest=deepest))
(Output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
print('Verified', len(items), 'skinned garments across 28 poses.')
print('Body clearance diagnostic entries:', len(report['clearance']))
