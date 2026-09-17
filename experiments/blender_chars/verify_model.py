"""Verify topology, attachment weights, animation, and GLB round trips."""

import json
import math
import struct
from pathlib import Path

import bmesh
import bpy

Output = Path(__file__).resolve().parent / "assets"
Preview = Output.parents[2] / "tmp/blender_chars"


def points(items):
  """Evaluate all skinned vertices in world space, including hidden variants."""
  graph = bpy.context.evaluated_depsgraph_get()
  result = []
  for item in items:
    evaluated = item.evaluated_get(graph)
    mesh = evaluated.to_mesh()
    result.extend(evaluated.matrix_world @ vertex.co for vertex in mesh.vertices)
    evaluated.to_mesh_clear()
  return result


def bounds(vertices):
  """Measure the mesh in Blender coordinates for the export comparison."""
  return [[function(point[i] for point in vertices) for i in range(3)]
          for function in [min, max]]


bpy.ops.wm.open_mainfile(filepath=str(Output / "character.blend"))
manifest = json.loads((Output / "manifest.json").read_text())
rig = bpy.data.objects["CharacterRig"]
items = [item for item in bpy.data.objects if item.type == "MESH"]
report = {"meshes": [], "bones": len(rig.data.bones), "motion": {}}
posedBounds = {}
bodyNames = {"Body", "Hand.Left", "Hand.Right", "Foot.Left", "Foot.Right"}
boundaries = {}
offsets = {}
offset = 0
assert report["bones"] == 22
assert not bpy.data.objects["Nose_Tiny"].hide_get()
assert all(item.hide_get() for item in items if item.name.startswith("Ears_"))
assert not bpy.data.objects["Eyes_Atlas02"].hide_get()
assert not bpy.data.objects["Mouth_Atlas01"].hide_get()
for item in items:
  offsets[item.name] = offset
  offset += len(item.data.vertices)
  item.hide_set(False)
  mesh = bmesh.new()
  mesh.from_mesh(item.data)
  boundary = {vertex.index for edge in mesh.edges if edge.is_boundary
              for vertex in edge.verts}
  assert all(edge.is_manifold or edge.is_boundary for edge in mesh.edges)
  if item.name in bodyNames:
    assert len(boundary) == (96 if item.name == "Body" else 24), item.name
    boundaries[item.name] = boundary
  elif item.name.startswith(("Eyes_", "Mouth_Atlas")):
    assert len(boundary) == 72, item.name
    assert len(item.data.uv_layers) == 1, item.name
    textures = [node.image for node in item.data.materials[0].node_tree.nodes
                if node.type == "TEX_IMAGE"]
    expected = ((1254, 1254) if item.name.startswith(("Eyes_Atlas", "Mouth_Atlas"))
                else (1024, 512))
    assert len(textures) == 1 and tuple(textures[0].size) == expected
  else:
    assert not boundary, item.name
  mesh.free()
  if item.name in ["Body", "Head", "Hand.Left", "Hand.Right", "Foot.Left", "Foot.Right"]:
    assert all(face.use_smooth for face in item.data.polygons)
  for vertex in item.data.vertices:
    assert all(math.isfinite(value) for value in vertex.co)
    assert abs(sum(group.weight for group in vertex.groups) - 1) < 1e-5
    if item.name.startswith(("Eyes_", "Mouth_", "Ears_", "Nose_")):
      assert all(item.vertex_groups[group.group].name == "Head"
                 for group in vertex.groups)
  report["meshes"].append({"name": item.name, "closed": not boundary,
                           "attachmentVertices": len(boundary)})

body = bpy.data.objects["Body"]
seams = []
bodyPositions = {tuple(round(value, 6) for value in body.data.vertices[i].co): i
                 for i in boundaries["Body"]}


def influences(item, index):
  """Read named weights independently of each object's vertex group order."""
  return {item.vertex_groups[group.group].name: group.weight
          for group in item.data.vertices[index].groups}


def normals(item):
  """Read the exported custom corner normals at shared module edges."""
  return {loop.vertex_index: item.data.corner_normals[loop.index].vector.copy()
          for loop in item.data.loops}


bodyNormals = normals(body)
for name, boundary in boundaries.items():
  if name == "Body":
    continue
  part = bpy.data.objects[name]
  partNormals = normals(part)
  for i in boundary:
    key = tuple(round(value, 6) for value in part.data.vertices[i].co)
    j = bodyPositions.pop(key)
    assert influences(body, j) == influences(part, i), (name, i, "Weights")
    assert (bodyNormals[j] - partNormals[i]).length < 1e-4, (name, i, "Normals")
    seams.append((offsets["Body"] + j, offsets[name] + i))
assert not bodyPositions
assembled = bmesh.new()
for item in items:
  if item.name in bodyNames:
    assembled.from_mesh(item.data)
bmesh.ops.remove_doubles(assembled, verts=list(assembled.verts), dist=1e-6)
assert all(edge.is_manifold for edge in assembled.edges)
assembled.free()
report["assembledBodyClosed"] = True
report["sharedSeamVertices"] = len(seams)
report["maxAnimatedSeamGap"] = 0


def verifySeams(vertices):
  """Require every shared wrist and ankle edge to stay joined while posed."""
  gap = max((vertices[first] - vertices[second]).length for first, second in seams)
  assert gap < 1e-5, (bpy.context.scene.frame_current, gap)
  report["maxAnimatedSeamGap"] = max(report["maxAnimatedSeamGap"], gap)


assert {node for category in manifest["categories"] for part in category["items"]
        for node in part["nodes"]} == {item.name for item in items}
scene = bpy.context.scene
for clip in manifest["clips"]:
  action = bpy.data.actions[clip["name"]]
  rig.animation_data.action = action
  rig.animation_data.action_slot = action.slots[0]
  scene.frame_set(1)
  if clip["name"] == "Idle":
    for side in ["Left", "Right"]:
      hip = rig.pose.bones[side + "UpLeg"].head
      knee = rig.pose.bones[side + "Leg"].head
      ankle = rig.pose.bones[side + "Foot"].head
      assert hip.z - knee.z > .3, (side, "The thigh must point down at idle.")
      assert knee.z - ankle.z > .3, (side, "The calf must point down at idle.")
      assert ankle.z < .35, (side, "The foot must stay near the floor at idle.")
  first = points(items)
  verifySeams(first)
  scene.frame_set(int(action.frame_range[1] * .35))
  second = points(items)
  verifySeams(second)
  time = scene.frame_current * scene.render.fps_base / scene.render.fps
  posedBounds[clip["name"]] = (time, bounds(second))
  movement = sum((a - b).length for a, b in zip(first, second))
  if clip["name"] in ["Idle", "Walk", "Run", "Attack01", "Jump", "Victory"]:
    assert movement > .1, clip["name"]
  report["motion"][clip["name"]] = round(movement, 3)
rig.data.pose_position = "REST"
bpy.context.view_layer.update()
originalBounds = bounds(points(items))

data = (Output / "character.glb").read_bytes()
size = struct.unpack_from("<I", data, 12)[0]
document = json.loads(data[20:20 + size])
for node in document["nodes"]:
  if node.get("name", "").startswith(("Eyes_", "Mouth_Atlas")) and "mesh" in node:
    primitives = document["meshes"][node["mesh"]]["primitives"]
    assert len(primitives) == 1, node["name"]
    material = document["materials"][primitives[0]["material"]]
    assert material["alphaMode"] == "MASK", node["name"]
    assert "baseColorTexture" in material["pbrMetallicRoughness"]
    assert "KHR_materials_unlit" in material["extensions"]
report["glbMeshes"] = len(document["meshes"])
report["glbTriangles"] = sum(
  document["accessors"][primitive["indices"]]["count"] // 3
  for mesh in document["meshes"] for primitive in mesh["primitives"]
)
report["glbAnimations"] = [clip["name"] for clip in document["animations"]]
assert report["glbMeshes"] == len(items)
assert set(report["glbAnimations"]) == {clip["name"] for clip in manifest["clips"]}
specs = {clip["name"]: clip for clip in manifest["clips"]}
for animation in document["animations"]:
  times = document["accessors"][animation["samplers"][0]["input"]]
  assert abs(times["min"][0]) < 1e-6
  assert abs(times["max"][0] - specs[animation["name"]]["duration"]) < 1e-3
report["sourceTimingMatch"] = True

bpy.ops.wm.read_factory_settings(use_empty=True)
bpy.ops.import_scene.gltf(filepath=str(Output / "character.glb"))
imported = [item for item in bpy.data.objects if item.type == "MESH"
            and any(modifier.type == "ARMATURE" for modifier in item.modifiers)]
armatures = [item for item in bpy.data.objects if item.type == "ARMATURE"]
assert len(imported) == report["glbMeshes"]
assert len(armatures) == 1
assert len(armatures[0].data.bones) == report["bones"]
assert {action.name for action in bpy.data.actions} == set(report["glbAnimations"])
for name, (time, expected) in posedBounds.items():
  action = bpy.data.actions[name]
  armatures[0].animation_data.action = action
  armatures[0].animation_data.action_slot = action.slots[0]
  scene = bpy.context.scene
  frame = time * scene.render.fps / scene.render.fps_base
  scene.frame_set(int(frame), subframe=frame - int(frame))
  actual = bounds(points(imported))
  assert max(abs(a - b) for first, second in zip(expected, actual)
             for a, b in zip(first, second)) < 1e-3, (name, expected, actual)
report["animatedBoundsMatch"] = True
armatures[0].data.pose_position = "REST"
bpy.context.view_layer.update()
importedBounds = bounds(points(imported))
assert max(abs(a - b) for first, second in zip(originalBounds, importedBounds)
           for a, b in zip(first, second)) < 1e-4
report["restBoundsMatch"] = True
report["roundTrip"] = "Passed mesh, skeleton, and animation import checks."
(Preview / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
print("VERIFIED", json.dumps(report))
