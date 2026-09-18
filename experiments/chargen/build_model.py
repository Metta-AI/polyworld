"""Build an editable character using the original modular kit proportions."""

import json
import math
import os
import subprocess
import struct
import sys
from pathlib import Path

import bmesh
import bpy
from mathutils import Matrix, Quaternion, Vector
from mathutils.bvhtree import BVHTree

Root = Path(__file__).resolve().parents[2]
Library = Root.parent / "polyworld_data/characters/chargen"
Output = Library / "source"
Preview = Root / "tmp/chargen"
Reference = Preview / "reference/01_base_body.png"
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.dont_write_bytecode = True
from retarget import FrameRate, retarget
from universal import retargetUniversal
from hairs import Names as HairNames, buildHair
from beards import Names as BeardNames, buildBeards
from clothes import buildClothes, clothingParts
from gnomes import buildGnomes, gnomeParts, gnomePresets
from hats import buildHats, hatParts
from garments import buildGarments, garmentParts

Tau = math.tau
Output.mkdir(parents=True, exist_ok=True)
Preview.mkdir(parents=True, exist_ok=True)


def signedPower(value, exponent):
  """Round a box cross section without adding subdivision modifiers."""
  return math.copysign(abs(value) ** exponent, value)


def meshObject(name, vertices, faces, weights):
  """Create outward-facing editable geometry and named skin weights."""
  mesh = bpy.data.meshes.new(name)
  mesh.from_pydata(vertices, [], faces)
  mesh.update()
  data = bmesh.new()
  data.from_mesh(mesh)
  bmesh.ops.recalc_face_normals(data, faces=list(data.faces))
  data.to_mesh(mesh)
  data.free()
  item = bpy.data.objects.new(name, mesh)
  character.objects.link(item)
  item.data.materials.append(clay)
  for polygon in mesh.polygons:
    polygon.use_smooth = True
  for i, influences in enumerate(weights):
    for bone, weight in influences.items():
      group = item.vertex_groups.get(bone) or item.vertex_groups.new(name=bone)
      group.add([i], weight, "REPLACE")
  return item


def connect(faces, first, second):
  """Bridge equally sized rings with editable quads."""
  assert len(first) == len(second)
  for i in range(len(first)):
    j = (i + 1) % len(first)
    faces.append((first[i], first[j], second[j], second[i]))


def verticalRings(name, profile, count, exponent, bone):
  """Build a closed faceted surface from horizontal rounded-box sections."""
  vertices, faces, weights, rings = [], [], [], []
  for z, centerX, centerY, radiusX, radiusY in profile:
    ring = []
    for i in range(count):
      angle = Tau * i / count
      ring.append(len(vertices))
      vertices.append((
        centerX + radiusX * signedPower(math.cos(angle), exponent),
        centerY + radiusY * signedPower(math.sin(angle), exponent),
        z
      ))
      weights.append({bone: 1.0})
    if rings:
      connect(faces, rings[-1], ring)
    rings.append(ring)
  faces.extend([tuple(reversed(rings[0])), tuple(rings[-1])])
  return meshObject(name, vertices, faces, weights)


def makeBody():
  """Build a continuous body before separating its modular hands and feet."""
  vertices, faces, weights, rings = [], [], [], []
  regions = {}
  profile = [
    (1.075, 0.320, 0.225, {"Hips": 1}),
    (1.200, 0.350, 0.265, {"Hips": 0.7, "Spine": 0.3}),
    (1.355, 0.335, 0.250, {"Spine": 0.8, "Spine1": 0.2}),
    (1.660, 0.310, 0.215, {"Spine1": 0.7, "Spine2": 0.3}),
    (1.780, 0.300, 0.205, {"Spine2": 1}),
    (1.890, 0.260, 0.160, {"Spine2": 1}),
    (1.960, 0.112, 0.105, {"Spine2": 0.35, "Neck": 0.65}),
    (2.080, 0.103, 0.100, {"Neck": 1}),
  ]
  count = 16
  for z, radiusX, radiusY, influences in profile:
    ring = []
    for i in range(count):
      angle = Tau * i / count
      ring.append(len(vertices))
      vertices.append((
        radiusX * signedPower(math.cos(angle), 0.82),
        radiusY * signedPower(math.sin(angle), 0.82), z
      ))
      weights.append(influences.copy())
    rings.append(ring)
  holes = {14, 15, 0, 1, 6, 7, 8, 9}
  for row in range(len(rings) - 1):
    for i in range(count):
      if row in (3, 4) and i in holes:
        continue
      j = (i + 1) % count
      faces.append((rings[row][i], rings[row][j],
                    rings[row + 1][j], rings[row + 1][i]))
  faces.append(tuple(rings[-1]))

  def addRing(center, radiusU, radiusV, angles, axisU, axisV, influences):
    """Append a limb ring and its explicit blend weights."""
    result = []
    for angle in angles:
      point = (Vector(center) + axisU * math.cos(angle) * radiusU
               + axisV * math.sin(angle) * radiusV)
      result.append(len(vertices))
      vertices.append(tuple(point))
      weights.append(influences.copy())
    return result

  for side, sign, sectors in [
    ("Left", 1, [14, 15, 0, 1, 2]),
    ("Right", -1, [6, 7, 8, 9, 10]),
  ]:
    shoulder = Vector((sign * 0.300, .015, 1.780))
    elbow = Vector((sign * 0.695, .015, 1.780))
    wrist = Vector((sign * 0.980, .015, 1.780))
    direction = (elbow - shoulder).normalized()
    axisU = Vector((0, -1, 0))
    axisV = direction.cross(axisU).normalized()
    boundary = (
      [rings[3][i] for i in sectors]
      + [rings[4][sectors[-1]]]
      + [rings[5][i] for i in reversed(sectors)]
      + [rings[4][sectors[0]]]
    )
    boundary.sort(key=lambda i: math.atan2(
      (Vector(vertices[i]) - shoulder).dot(axisV),
      (Vector(vertices[i]) - shoulder).dot(axisU)
    ))
    firstAngle = math.atan2(
      (Vector(vertices[boundary[0]]) - shoulder).dot(axisV),
      (Vector(vertices[boundary[0]]) - shoulder).dot(axisU)
    )
    angles = [firstAngle + Tau * i / len(boundary)
              for i in range(len(boundary))]
    for i in boundary:
      weights[i] = {"Spine2": 1}
    stations = [
      ((sign * .385, .015, 1.780), .095, .100,
       {side + "Shoulder": .25, side + "Arm": .75}),
      ((sign * .490, .015, 1.780), .084, .088, {side + "Arm": 1}),
      (elbow, .079, .079, {side + "Arm": .5, side + "ForeArm": .5}),
      ((sign * .830, .015, 1.780), .077, .078,
       {side + "ForeArm": 1}),
      ((sign * .935, .015, 1.780), .067, .070,
       {side + "ForeArm": .75, side + "Hand": .25}),
      (wrist, .064, .068, {side + "ForeArm": .3, side + "Hand": .7}),
    ]
    for center, radiusU, radiusV, influences in stations:
      ring = addRing(center, radiusU, radiusV, angles, axisU, axisV, influences)
      connect(faces, boundary, ring)
      boundary = ring
    firstFace = len(faces)
    for distance, top, bottom, depth in [
      (.025, .087, -.091, .078),
      (.050, .103, -.147, .090),
      (.068, .107, -.143, .096),
      (.090, .108, -.074, .099),
      (.110, .107, -.047, .100),
      (.131, .104, -.061, .100),
      (.158, .099, -.143, .098),
      (.184, .089, -.178, .091),
      (.227, .060, -.168, .077),
      (.253, .021, -.130, .048),
      (.263, -.039, -.078, .019),
    ]:
      center = (sign * (.980 + distance), .015, 1.780 + (top + bottom) / 2)
      ring = addRing(center, depth, (top - bottom) / 2, angles,
                     axisU, axisV, {side + "Hand": 1})
      connect(faces, boundary, ring)
      boundary = ring
    faces.append(tuple(boundary))
    regions["Hand." + side] = range(firstFace, len(faces))

  crotch = []
  for y in [-0.105, 0, 0.105]:
    crotch.append(len(vertices))
    vertices.append((0, y, 0.925 + abs(y) * 0.25))
    weights.append({"Hips": 1})
  for side, sign, perimeter in [
    ("Left", 1, [12, 13, 14, 15, 0, 1, 2, 3, 4]),
    ("Right", -1, [4, 5, 6, 7, 8, 9, 10, 11, 12]),
  ]:
    boundary = [rings[0][i] for i in perimeter] + (
      list(reversed(crotch)) if sign == 1 else crotch
    )
    center = Vector((sign * .201, 0, 1.068))
    boundary.sort(key=lambda i: math.atan2(
      vertices[i][1], vertices[i][0] - center.x
    ))
    firstAngle = math.atan2(vertices[boundary[0]][1],
                            vertices[boundary[0]][0] - center.x)
    angles = [firstAngle + Tau * i / len(boundary)
              for i in range(len(boundary))]
    stations = [
      ((sign * .201, 0, .975), .130, .155,
       {"Hips": .25, side + "UpLeg": .75}),
      ((sign * .201, 0, .780), .120, .140, {side + "UpLeg": 1}),
      ((sign * .201, -.002, .560), .104, .120,
       {side + "UpLeg": .5, side + "Leg": .5}),
      ((sign * .201, .005, .430), .108, .125, {side + "Leg": 1}),
      ((sign * .201, .005, .280), .095, .104, {side + "Leg": 1}),
      ((sign * .201, -.002, .205), .089, .099,
       {side + "Leg": .80, side + "Foot": .20}),
    ]
    for location, radiusX, radiusY, influences in stations:
      ring = addRing(location, radiusX, radiusY, angles,
                     Vector((1, 0, 0)), Vector((0, 1, 0)), influences)
      connect(faces, boundary, ring)
      boundary = ring
    firstFace = len(faces)
    for z, centerY, radiusX, radiusY, legWeight in [
      (.155, -.008, .091, .109, .45),
      (.105, -.036, .106, .143, .10),
      (.052, -.057, .115, .167, 0),
      (.015, -.058, .115, .169, 0),
      (.005, -.058, .112, .166, 0),
    ]:
      influences = {side + "Foot": 1 - legWeight}
      if legWeight:
        influences[side + "Leg"] = legWeight
      ring = addRing((sign * .201, centerY, z), radiusX, radiusY, angles,
                     Vector((1, 0, 0)), Vector((0, 1, 0)), influences)
      connect(faces, boundary, ring)
      boundary = ring
    faces.append(tuple(boundary))
    regions["Foot." + side] = range(firstFace, len(faces))
  used = sorted({index for face in faces for index in face})
  remap = {old: new for new, old in enumerate(used)}
  item = meshObject("Body", [vertices[i] for i in used],
                    [tuple(remap[i] for i in face) for face in faces],
                    [weights[i] for i in used])
  for index, faceIndices in enumerate(regions.values(), 1):
    item.data.materials.append(clay)
    for i in faceIndices:
      item.data.polygons[i].material_index = index
  bpy.context.view_layer.objects.active = item
  subdivision = item.modifiers.new("Rounded body joints", "SUBSURF")
  subdivision.levels = 1
  bpy.ops.object.modifier_apply(modifier=subdivision.name)
  return separateBody(item, ["Body"] + list(regions))


def separateBody(item, names):
  """Preserve identical seam positions, normals, and weights on each module."""
  mesh = item.data
  vertices = [tuple(vertex.co) for vertex in mesh.vertices]
  normals = [tuple(vertex.normal) for vertex in mesh.vertices]
  weights = [{item.vertex_groups[group.group].name: group.weight
              for group in vertex.groups} for vertex in mesh.vertices]
  result = []
  item.name = "Connected body source"
  for index, name in enumerate(names):
    faces = [tuple(face.vertices) for face in mesh.polygons
             if face.material_index == index]
    used = sorted({i for face in faces for i in face})
    remap = {old: new for new, old in enumerate(used)}
    part = meshObject(name, [vertices[i] for i in used],
                      [tuple(remap[i] for i in face) for face in faces],
                      [weights[i] for i in used])
    part.data.normals_split_custom_set_from_vertices([normals[i] for i in used])
    result.append(part)
  bpy.data.objects.remove(item, do_unlink=True)
  bpy.data.meshes.remove(mesh)
  return result


def makeRig():
  """Create one explicit humanoid deformation skeleton in the T pose."""
  data = bpy.data.armatures.new("Humanoid")
  rig = bpy.data.objects.new("CharacterRig", data)
  character.objects.link(rig)
  bpy.context.view_layer.objects.active = rig
  rig.select_set(True)
  rig.show_in_front = True
  bpy.ops.object.mode_set(mode="EDIT")

  def bone(name, start, end, parent=None):
    """Add a named bone while preserving the supplied rest transforms."""
    result = data.edit_bones.new(name)
    result.head, result.tail = start, end
    if parent:
      result.parent = data.edit_bones[parent]
    return result

  bone("Hips", (0, -.005, 1.070), (0, -.013, 1.242))
  bone("Spine", (0, -.013, 1.242), (0, -.014, 1.422), "Hips")
  bone("Spine1", (0, -.014, 1.422), (0, -.013, 1.618), "Spine")
  bone("Spine2", (0, -.013, 1.618), (0, .035, 1.925), "Spine1")
  bone("Neck", (0, .035, 1.925), (0, .006, 2.067), "Spine2")
  bone("Head", (0, .006, 2.067), (0, .006, 2.900), "Neck")
  for side, sign in [("Left", 1), ("Right", -1)]:
    shoulder = (sign * .300, .015, 1.780)
    elbow = (sign * .695, .015, 1.780)
    wrist = (sign * .980, .015, 1.780)
    bone(side + "Shoulder", (sign * .127, -.001, 1.728), shoulder, "Spine2")
    bone(side + "Arm", shoulder, elbow, side + "Shoulder")
    bone(side + "ForeArm", elbow, wrist, side + "Arm")
    bone(side + "Hand", wrist, (sign * 1.25, .015, 1.78), side + "ForeArm")
    bone(side + "UpLeg", (sign * .201, -.001, 1.068),
         (sign * .201, -.002, .560), "Hips")
    bone(side + "Leg", (sign * .201, -.002, .560),
         (sign * .201, -.002, .146), side + "UpLeg")
    bone(side + "Foot", (sign * .201, -.002, .146),
         (sign * .201, -.088, .048), side + "Leg")
    bone(side + "ToeBase", (sign * .201, -.088, .048),
         (sign * .201, -.215, .040), side + "Foot")
  bpy.ops.object.mode_set(mode="OBJECT")
  rig.select_set(False)
  return rig


def addUv(item):
  """Create a usable initial UV layout for later palette or texture work."""
  bpy.ops.object.select_all(action="DESELECT")
  item.select_set(True)
  bpy.context.view_layer.objects.active = item
  bpy.ops.object.mode_set(mode="EDIT")
  bpy.ops.mesh.select_all(action="SELECT")
  bpy.ops.uv.smart_project(angle_limit=math.radians(70), island_margin=.025)
  bpy.ops.object.mode_set(mode="OBJECT")
  item.select_set(False)


def facePart(name, shapes):
  """Build closed colored face patches following the actual head surface."""
  vertices, faces, weights, colors = [], [], [], []
  for outline, depth, color in shapes:
    rings = []
    for offset in [depth, depth + .006]:
      ring = []
      for x, z in outline:
        hit = headSurface.ray_cast(Vector((x, -2, z)), Vector((0, 1, 0)))
        assert hit[0] is not None, (name, x, z)
        ring.append(len(vertices))
        vertices.append((x, hit[0].y - offset, z))
        weights.append({"Head": 1})
      rings.append(ring)
    first = len(faces)
    connect(faces, rings[0], rings[1])
    faces.extend([tuple(reversed(rings[0])), tuple(rings[1])])
    colors.extend([color] * (len(faces) - first))
  item = meshObject(name, vertices, faces, weights)
  item.data.materials.clear()
  for material in [ink, ivory, iris]:
    item.data.materials.append(material)
  for polygon, color in zip(item.data.polygons, colors):
    polygon.material_index = color
  return item


def ellipse(x, z, width, height, count=20):
  """Describe one small faceted eye or mouth outline."""
  return [(x + width * math.cos(Tau * i / count),
           z + height * math.sin(Tau * i / count)) for i in range(count)]


def smile(x, z, width, depth, thickness):
  """Describe a closed strip around a simple quadratic expression curve."""
  points = [(x + width * t, z + depth * t * t)
            for t in [i / 5 for i in range(-5, 6)]]
  return [(x, z + thickness / 2) for x, z in points] + [
    (x, z - thickness / 2) for x, z in reversed(points)
  ]


def makeEyes(name, cell=None):
  """Fit one transparent image to a thin surface weighted to the head."""
  path = (Output / "eyes/generated_v2/eyes_4x4_transparent.png" if cell
          else Output / "eyes" / (name + ".png"))
  if not path.exists():
    raise FileNotFoundError("Missing eye texture: " + str(path))
  frame = json.loads((Output / "eyes/mapping.json").read_text())["frame"]
  vertices, faces, weights, uvs = [], [], [], []
  columns, rows = 24, 12
  if cell:
    left, top, right, bottom = cell["contentRect"]
    left, top, right, bottom = left - 2, top - 2, right + 2, bottom + 2
    width, height = (right - left) * .0026, (bottom - top) * .0026
    white = cell["scleraRect"]
    whiteCenter = (white[1] + white[3]) / 2
    centerZ = 2.315 - ((top + bottom) / 2 - whiteCenter) * .0026
  for row in range(rows + 1):
    z = (centerZ - height / 2 + height * row / rows if cell
         else 2.18 + .46 * row / rows)
    for column in range(columns + 1):
      x = (-width / 2 + width * column / columns if cell
           else -.44 + .88 * column / columns)
      if cell:
        # Widen the transparent bridge without enlarging either iris.
        x += .045 * max(-1, min(1, x / .06))
      hit = headSurface.ray_cast(Vector((x, -2, z)), Vector((0, 1, 0)))
      assert hit[0] is not None, (name, x, z)
      vertices.append((x, hit[0].y - .007, z))
      weights.append({"Head": 1})
      if cell:
        uvs.append(((left + (right - left) * column / columns) /
                    eyeAtlas["size"][0],
                    1 - (bottom - (bottom - top) * row / rows) /
                    eyeAtlas["size"][1]))
      else:
        uvs.append(((x - frame[0]) / (frame[1] - frame[0]),
                    (z - frame[2]) / (frame[3] - frame[2])))
  for row in range(rows):
    for column in range(columns):
      index = row * (columns + 1) + column
      faces.append((index, index + 1, index + columns + 2,
                    index + columns + 1))
  item = meshObject("Eyes_" + name, vertices, faces, weights)
  layer = item.data.uv_layers.new(name="Eye projection")
  for loop in item.data.loops:
    layer.data[loop.index].uv = uvs[loop.vertex_index]
  applyFaceTexture(item, path)
  return item


def applyFaceTexture(item, path):
  """Pack an unlit face texture with an alpha cutout for Blender and glTF."""
  material = bpy.data.materials.new("Face texture / " + item.name)
  material.use_nodes = True
  nodes, links = material.node_tree.nodes, material.node_tree.links
  nodes.clear()
  output = nodes.new("ShaderNodeOutputMaterial")
  texture = nodes.new("ShaderNodeTexImage")
  texture.image = bpy.data.images.load(str(path), check_existing=True)
  texture.image.pack()
  texture.extension = "EXTEND"
  clip = nodes.new("ShaderNodeMath")
  clip.operation = "ROUND"
  transparent = nodes.new("ShaderNodeBsdfTransparent")
  mix = nodes.new("ShaderNodeMixShader")
  links.new(texture.outputs["Alpha"], clip.inputs[0])
  links.new(clip.outputs[0], mix.inputs[0])
  links.new(transparent.outputs[0], mix.inputs[1])
  links.new(texture.outputs["Color"], mix.inputs[2])
  links.new(mix.outputs[0], output.inputs["Surface"])
  item.data.materials.clear()
  item.data.materials.append(material)


def makeMouthTexture(cell):
  """Fit an atlas expression below the nose while preserving its aspect."""
  name = "Mouth_Atlas" + str(cell["index"]).zfill(2)
  left, top, right, bottom = cell["contentRect"]
  left, top, right, bottom = left - 2, top - 2, right + 2, bottom + 2
  scale = min(.0016, .17 / (bottom - top))
  width, height = (right - left) * scale, (bottom - top) * scale
  centerZ = min(2.115, 2.165 - height / 2)
  columns, rows = 24, 12
  vertices, faces, weights, uvs = [], [], [], []
  for row in range(rows + 1):
    z = centerZ - height / 2 + height * row / rows
    for column in range(columns + 1):
      x = -width / 2 + width * column / columns
      hit = headSurface.ray_cast(Vector((x, -2, z)), Vector((0, 1, 0)))
      assert hit[0] is not None, (name, x, z)
      vertices.append((x, hit[0].y - .007, z))
      weights.append({"Head": 1})
      uvs.append(((left + (right - left) * column / columns) /
                  mouthAtlas["size"][0],
                  1 - (bottom - (bottom - top) * row / rows) /
                  mouthAtlas["size"][1]))
  for row in range(rows):
    for column in range(columns):
      index = row * (columns + 1) + column
      faces.append((index, index + 1, index + columns + 2,
                    index + columns + 1))
  item = meshObject(name, vertices, faces, weights)
  layer = item.data.uv_layers.new(name="Mouth projection")
  for loop in item.data.loops:
    layer.data[loop.index].uv = uvs[loop.vertex_index]
  applyFaceTexture(item, Output / "mouths/generated_v1" / mouthAtlas["art"])
  return item


def makeMouth(name):
  """Create a separate expression mesh without any nose geometry."""
  if name == "Smile":
    shapes = [(smile(0, 2.105, .112, .045, .018), .017, 0)]
  elif name == "Neutral":
    shapes = [(ellipse(0, 2.125, .087, .012, 16), .017, 0)]
  else:
    shapes = [(ellipse(0, 2.120, .082, .075), .017, 0)]
  return facePart("Mouth_" + name, shapes)


def makeImageFace(spec):
  """Project an individual face cutout onto the head with local texture UVs."""
  pixelWidth, pixelHeight = spec["size"]
  eyes = spec["category"] == "Eyes"
  scale = .0026 if eyes else min(.0016, .17 / pixelHeight)
  width, height = pixelWidth * scale, pixelHeight * scale
  if eyes:
    white = spec["scleraRect"]
    centerZ = 2.315 - (pixelHeight / 2 - (white[1] + white[3]) / 2) * scale
  else:
    centerZ = min(2.115, 2.165 - height / 2)
  columns, rows = 24, 12
  vertices, faces, weights, uvs = [], [], [], []
  for row in range(rows + 1):
    z = centerZ - height / 2 + height * row / rows
    for column in range(columns + 1):
      x = -width / 2 + width * column / columns
      if eyes:
        x += .045 * max(-1, min(1, x / .06))
      hit = headSurface.ray_cast(Vector((x, -2, z)), Vector((0, 1, 0)))
      assert hit[0] is not None, (spec["node"], x, z)
      vertices.append((x, hit[0].y - .007, z))
      weights.append({"Head": 1})
      uvs.append((column / columns, row / rows))
  for row in range(rows):
    for column in range(columns):
      index = row * (columns + 1) + column
      faces.append((index, index + 1, index + columns + 2,
                    index + columns + 1))
  item = meshObject(spec["node"], vertices, faces, weights)
  layer = item.data.uv_layers.new(name="Face projection")
  for loop in item.data.loops:
    layer.data[loop.index].uv = uvs[loop.vertex_index]
  applyFaceTexture(item, Library / spec["texture"])
  return item


def makeBrowTexture(cell):
  """Project a white tintable eyebrow pair onto the forehead and head rig."""
  name = "Brow_Atlas" + str(cell["index"]).zfill(2)
  left, top, right, bottom = cell["contentRect"]
  left, top, right, bottom = left - 2, top - 2, right + 2, bottom + 2
  width, height = (right - left) * .0026, (bottom - top) * .0026
  columns, rows = 24, 12
  vertices, faces, weights, uvs = [], [], [], []
  for row in range(rows + 1):
    z = 2.555 - height / 2 + height * row / rows
    for column in range(columns + 1):
      x = -width / 2 + width * column / columns
      x += .035 * max(-1, min(1, x / .06))
      hit = headSurface.ray_cast(Vector((x, -2, z)), Vector((0, 1, 0)))
      assert hit[0] is not None, (name, x, z)
      vertices.append((x, hit[0].y - .009, z))
      weights.append({"Head": 1})
      uvs.append(((left + (right - left) * column / columns) /
                  browAtlas["size"][0],
                  1 - (bottom - (bottom - top) * row / rows) /
                  browAtlas["size"][1]))
  for row in range(rows):
    for column in range(columns):
      index = row * (columns + 1) + column
      faces.append((index, index + 1, index + columns + 2,
                    index + columns + 1))
  item = meshObject(name, vertices, faces, weights)
  layer = item.data.uv_layers.new(name="Brow projection")
  for loop in item.data.loops:
    layer.data[loop.index].uv = uvs[loop.vertex_index]
  applyFaceTexture(item, Output / "brows/generated_v1" / browAtlas["art"])
  return item


def makeEar(kind, side, sign):
  """Create a detachable closed ear with a raised rim and recessed bowl."""
  if kind == "Round":
    centerX, centerZ = .540, 2.275
    outline = [(centerX + .105 * signedPower(math.cos(Tau * i / 16), .85),
                centerZ + .142 * signedPower(math.sin(Tau * i / 16), .90))
               for i in range(16)]
  else:
    centerX, centerZ = .575, 2.280
    outline = [(.460, 2.165), (.530, 2.135), (.630, 2.160),
               (.705, 2.255), (.805, 2.390), (.900, 2.480),
               (.765, 2.435), (.680, 2.390), (.475, 2.390),
               (.450, 2.310)]
  vertices, faces, rings = [], [], []
  for scale, depth in [
    (.62, .072), (.90, .053), (1.00, .008), (.97, -.059),
    (.85, -.097), (.64, -.094), (.47, -.025), (.23, -.009),
  ]:
    ring = []
    for x, z in outline:
      ring.append(len(vertices))
      vertices.append((sign * (centerX + (x - centerX) * scale), depth,
                       centerZ + (z - centerZ) * scale))
    if rings:
      connect(faces, rings[-1], ring)
    rings.append(ring)
  faces.extend([tuple(reversed(rings[0])), tuple(rings[-1])])
  return meshObject("Ears_" + kind + "_" + side, vertices, faces,
                    [{"Head": 1}] * len(vertices))


def areaLight(name, location, energy, size):
  """Add a soft studio light directed toward the middle of the model."""
  data = bpy.data.lights.new(name, "AREA")
  data.energy, data.shape, data.size = energy, "DISK", size
  item = bpy.data.objects.new(name, data)
  studio.objects.link(item)
  item.location = location
  item.rotation_euler = (Vector((0, 0, 1.5)) - item.location).to_track_quat(
    "-Z", "Y"
  ).to_euler()


def renderTurnaround(items):
  """Render the authored geometry from matching orthographic viewpoints."""
  copies = []
  rig.hide_render = True
  for item in items:
    item.hide_render = True
  for x, angle in [(-2.1, 0), (0, -math.pi / 2), (2.1, math.pi)]:
    transform = Matrix.Translation((x, 0, 0)) @ Matrix.Rotation(angle, 4, "Z")
    for item in items:
      copy = bpy.data.objects.new(item.name + ".Preview", item.data)
      studio.objects.link(copy)
      copy.matrix_world = transform
      copies.append(copy)
  camera.location = (0, -12, 1.50)
  camera.rotation_euler = (math.pi / 2, 0, 0)
  camera.data.ortho_scale = 6.60
  scene.render.resolution_x = 2400
  scene.render.resolution_y = 1300
  scene.render.filepath = str(Preview / "turnaround.png")
  bpy.ops.render.render(write_still=True)
  for item in copies:
    bpy.data.objects.remove(item, do_unlink=True)
  for item in items:
    item.hide_render = False
  rig.hide_render = False


bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
for collection in list(bpy.data.collections):
  bpy.data.collections.remove(collection)
character = bpy.data.collections.new("Character")
studio = bpy.data.collections.new("Studio")
references = bpy.data.collections.new("Reference")
for collection in [character, studio, references]:
  bpy.context.scene.collection.children.link(collection)

clay = bpy.data.materials.new("Warm gray clay")
clay.diffuse_color = (.40, .385, .36, 1)
clay.use_nodes = True
shader = clay.node_tree.nodes.get("Principled BSDF")
shader.inputs["Base Color"].default_value = clay.diffuse_color
shader.inputs["Roughness"].default_value = .92
ink = bpy.data.materials.new("Face ink")
ivory = bpy.data.materials.new("Eye white")
iris = bpy.data.materials.new("Slate iris")
for material, color in [
  (ink, (.012, .014, .020, 1)),
  (ivory, (.95, .95, .92, 1)),
  (iris, (.055, .070, .082, 1)),
]:
  material.diffuse_color = color
  material.use_nodes = True
  shader = material.node_tree.nodes.get("Principled BSDF")
  shader.inputs["Base Color"].default_value = color
  shader.inputs["Roughness"].default_value = .92

bodyParts = makeBody()
head = verticalRings("Head", [
  (1.980, 0, -.080, .225, .280),
  (2.035, 0, -.045, .365, .400),
  (2.145, 0, -.008, .455, .485),
  (2.320, 0, .014, .497, .510),
  (2.540, 0, .015, .502, .520),
  (2.775, 0, .023, .465, .470),
  (2.935, 0, .025, .345, .340),
  (3.010, 0, .020, .180, .170),
  (3.025, 0, .020, .070, .065),
], 16, .88, "Head")
headSurface = BVHTree.FromPolygons(
  [vertex.co for vertex in head.data.vertices],
  [tuple(polygon.vertices) for polygon in head.data.polygons]
)
items = bodyParts + [head]
baseNames = ["Body", "Head", "Hand.Left", "Hand.Right", "Foot.Left", "Foot.Right"]
for side, sign in [("Left", 1), ("Right", -1)]:
  items.extend(makeEar(kind, side, sign) for kind in ["Round", "Elf"])
noseProfile = []
for z, radiusX, radiusY in [(2.185, .019, .016), (2.210, .038, .036),
                           (2.245, .025, .021), (2.265, .010, .008)]:
  surface = headSurface.ray_cast(Vector((0, -2, z)), Vector((0, 1, 0)))[0]
  noseProfile.append((z, 0, surface.y - .010, radiusX, radiusY))
items.append(verticalRings("Nose_Tiny", noseProfile, 8, .9, "Head"))
eyeNames = ["Neutral", "Happy", "Angry", "Original2"]
eyeAtlas = json.loads((Output / "eyes/generated_v2/atlas.json").read_text())
items.extend(makeEyes(cell["name"], cell) for cell in eyeAtlas["cells"])
items.extend(makeEyes(name) for name in eyeNames)
mouthAtlas = json.loads((Output / "mouths/generated_v1/atlas.json").read_text())
items.extend(makeMouthTexture(cell) for cell in mouthAtlas["cells"])
items.extend(makeMouth(name) for name in ["Smile", "Neutral", "Open"])
browAtlas = json.loads((Output / "brows/generated_v1/atlas.json").read_text())
items.extend(makeBrowTexture(cell) for cell in browAtlas["cells"])
imageFaces = json.loads((Output / "faces.json").read_text())
imageFaceNames = {spec["node"] for spec in imageFaces}
items.extend(makeImageFace(spec) for spec in imageFaces)
items.extend(buildHair(character))
items.extend(buildBeards(character))
items.extend(buildClothes(character, bodyParts))
items.extend(buildGarments(character))
items.extend(buildGnomes(character, head))
items.extend(buildHats(character))
defaultNames = baseNames + ["Eyes_Atlas02", "Mouth_Atlas01", "Brow_Atlas01",
                            "Nose_Tiny", "Hair_01"]
defaultItems = [item for item in items if item.name in defaultNames]
for item in items:
  item.hide_render = item.name not in defaultNames

rig = makeRig()
for item in items:
  modifier = item.modifiers.new("Shared humanoid rig", "ARMATURE")
  modifier.object = rig
  item.parent = rig
  if (item.name not in imageFaceNames and
      not item.name.startswith(("Eyes_", "Mouth_Atlas", "Brow_Atlas"))):
    addUv(item)
  for vertex in item.data.vertices:
    total = sum(group.weight for group in vertex.groups)
    assert abs(total - 1) < 1e-5, (item.name, vertex.index, total)
actions, sourceClips = retarget(rig)
universalActions, universalClips = retargetUniversal(rig)
actions.extend(universalActions)
sourceClips.extend(universalClips)
rig.animation_data.action = None
for pose in rig.pose.bones:
  pose.rotation_mode = "QUATERNION"
  pose.rotation_quaternion = Quaternion()
  pose.location = (0, 0, 0)

if Reference.exists():
  image = bpy.data.images.load(str(Reference), check_existing=True)
  image.pack()
  reference = bpy.data.objects.new("Approved concept", None)
  references.objects.link(reference)
  reference.empty_display_type = "IMAGE"
  reference.data = image
  reference.empty_display_size = 6.0
  reference.location = (0, 1.5, 1.5)
  reference.rotation_euler = (math.pi / 2, 0, 0)
  reference.hide_render = True
  reference.hide_set(True)

scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 48
scene.cycles.use_denoising = True
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGB"
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
scene.world.use_nodes = True
nodes, links = scene.world.node_tree.nodes, scene.world.node_tree.links
nodes["Background"].inputs["Color"].default_value = (1, 1, 1, 1)
nodes["Background"].inputs["Strength"].default_value = .45
cameraBackground = nodes.new("ShaderNodeBackground")
cameraBackground.inputs["Color"].default_value = (1, 1, 1, 1)
cameraBackground.inputs["Strength"].default_value = 1
lightPath = nodes.new("ShaderNodeLightPath")
mix = nodes.new("ShaderNodeMixShader")
links.new(lightPath.outputs["Is Camera Ray"], mix.inputs[0])
links.new(nodes["Background"].outputs[0], mix.inputs[1])
links.new(cameraBackground.outputs[0], mix.inputs[2])
links.new(mix.outputs[0], nodes["World Output"].inputs[0])
areaLight("Large key", (-3, -4, 7), 350, 5)
areaLight("Soft fill", (4, -2, 4), 100, 5)
areaLight("Top rim", (0, 3, 6), 180, 4)
camera = bpy.data.objects.new("Camera", bpy.data.cameras.new("Camera"))
studio.objects.link(camera)
camera.data.type = "ORTHO"
scene.camera = camera
scene.render.fps = FrameRate
scene.frame_start, scene.frame_end = 0, 112
renderTurnaround(defaultItems)

camera.location = (4.5, -8, 3.9)
camera.rotation_euler = (Vector((0, 0, 1.5)) - camera.location).to_track_quat(
  "-Z", "Y"
).to_euler()
camera.data.ortho_scale = 3.75
scene.render.resolution_x, scene.render.resolution_y = 1200, 1400
scene.render.filepath = str(Preview / "perspective.png")
bpy.ops.render.render(write_still=True)

bpy.ops.object.select_all(action="DESELECT")
for item in items + [rig]:
  item.select_set(True)
bpy.context.view_layer.objects.active = rig
rig.animation_data.action = universalActions[0]
scene.frame_set(0)
bpy.ops.export_scene.gltf(
  filepath=str(Preview / "character.glb"), export_format="GLB",
  use_selection=True, export_animations=True, export_animation_mode="ACTIONS",
  export_frame_range=False, export_force_sampling=True, export_skins=True,
  export_materials="EXPORT", export_yup=True
)
rig.animation_data.action = bpy.data.actions['Idle_Loop']
rig.animation_data.action_slot = rig.animation_data.action.slots[0]
scene.frame_set(0)
for item in items:
  item.hide_set(item.name not in defaultNames)
for screen in bpy.data.screens:
  for area in screen.areas:
    if area.type == "VIEW_3D":
      area.spaces.active.region_3d.view_distance = 5.5
      area.spaces.active.region_3d.view_location = (0, 0, 1.5)
      area.spaces.active.shading.type = "MATERIAL"
      area.spaces.active.shading.color_type = "MATERIAL"
bpy.context.preferences.filepaths.save_version = 0
bpy.ops.wm.save_as_mainfile(filepath=str(Output / "character.blend"))

report = {
  "height": 3.025, "unit": "Blender units", "front": "-Y", "up": "+Z",
  "pose": "T pose", "bones": len(rig.data.bones),
  "skeleton": [{"name": bone.name,
                "parent": bone.parent.name if bone.parent else "",
                "head": [bone.head_local.x, bone.head_local.z, -bone.head_local.y],
                "tail": [bone.tail_local.x, bone.tail_local.z, -bone.tail_local.y]}
               for bone in rig.data.bones],
  "meshes": [{"name": item.name, "vertices": len(item.data.vertices),
              "polygons": len(item.data.polygons)} for item in items],
  "animations": [action.name for action in actions], "reference": str(Reference),
  "notes": "Matched modular_chars proportions with shared wrist and ankle seams, downward mitten grips, recessed detachable ears, and a tiny nose."
}
(Output / "model.json").write_text(json.dumps(report, indent=2) + "\n")
manifest = {
  "model": "character.glb", "base": [], "defaultSkin": 5,
  "skinNodes": [item.name for item in items
                if clay in list(item.data.materials)],
  "skins": [
    {"name": "Clay", "color": [.40, .385, .36, 1]},
    {"name": "Sand", "color": [.72, .48, .30, 1]},
    {"name": "Brown", "color": [.28, .13, .075, 1]},
    {"name": "Green", "color": [.25, .42, .18, 1]},
    {"name": "Purple", "color": [.39, .24, .46, 1]},
    {"name": "White", "color": [247 / 255, 209 / 255, 181 / 255, 1]},
    {"name": "Red", "color": [195 / 255, 75 / 255, 69 / 255, 1]},
    {"name": "Blue", "color": [70 / 255, 130 / 255, 189 / 255, 1]},
    {"name": "Porcelain", "color": [244 / 255, 217 / 255, 200 / 255, 1]},
    {"name": "Rosy", "color": [223 / 255, 172 / 255, 155 / 255, 1]},
    {"name": "Beige", "color": [210 / 255, 172 / 255, 137 / 255, 1]},
    {"name": "Golden", "color": [192 / 255, 135 / 255, 82 / 255, 1]},
    {"name": "Olive", "color": [165 / 255, 135 / 255, 88 / 255, 1]},
    {"name": "Sienna", "color": [153 / 255, 91 / 255, 57 / 255, 1]},
    {"name": "Umber", "color": [104 / 255, 63 / 255, 43 / 255, 1]},
    {"name": "Deep brown", "color": [58 / 255, 34 / 255, 26 / 255, 1]},
  ],
  "categories": [
    {"key": "Body", "selected": 0, "items": [
      {"name": "Base", "nodes": [name for name in baseNames if name != "Head"]}]},
    {"key": "Face", "selected": 0, "items": [
      {"name": "Base", "nodes": ["Head"]}]},
    {"key": "Eyes", "selected": 1, "items": [
      {"name": cell["label"], "nodes": ["Eyes_" + cell["name"]]}
      for cell in eyeAtlas["cells"]] + [
      {"name": name, "nodes": ["Eyes_" + name]}
      for name in eyeNames]},
    {"key": "Mouth", "selected": 0, "items": [
      {"name": str(cell["index"]).zfill(2) + " " + cell["name"],
       "nodes": ["Mouth_Atlas" + str(cell["index"]).zfill(2)]}
      for cell in mouthAtlas["cells"]] + [
      {"name": name, "nodes": ["Mouth_" + name]}
      for name in ["Smile", "Neutral", "Open"]]},
    {"key": "Nose", "selected": 0, "items": [
      {"name": "Tiny", "nodes": ["Nose_Tiny"]}]},
    {"key": "Ears", "selected": -1, "items": [
      {"name": name, "nodes": ["Ears_" + name + "_" + side
                               for side in ["Left", "Right"]]}
      for name in ["Round", "Elf"]]},
    {"key": "Brow", "selected": 0, "items": [
      {"name": cell["label"],
       "nodes": ["Brow_Atlas" + str(cell["index"]).zfill(2)]}
      for cell in browAtlas["cells"]]},
    {"key": "Hair", "selected": 0, "items": [
      {"name": str(i + 1).zfill(2) + " " + name,
       "nodes": ["Hair_" + str(i + 1).zfill(2)]}
      for i, name in enumerate(HairNames)]},
    {"key": "Beard", "selected": -1, "items": [
      {"name": str(i + 1).zfill(2) + " " + name,
       "nodes": ["Beard_" + str(i + 1).zfill(2)]}
      for i, name in enumerate(BeardNames)]},
  ],
  "clipSource": "Quaternius Universal Standard; RPG Tiny Hero Duo and Layer Lab poses",
  "defaultAnimation": "Walk_Loop",
  "clips": sourceClips,
  "presets": [
    {"name": "Base", "pose": "Idle_Loop", "skin": 5, "parts": []},
    {"name": "Happy", "pose": "Walk_Loop", "skin": 1, "parts": [
      {"category": "Eyes", "item": "05 Open"},
      {"category": "Mouth", "item": "10 Laugh"},
      {"category": "Ears", "item": "Round"}]},
    {"name": "Elf", "pose": "Dance_Loop", "skin": 0, "parts": [
      {"category": "Ears", "item": "Elf"}]},
  ],
}
for spec in imageFaces:
  category = next(category for category in manifest["categories"]
                  if category["key"] == spec["category"])
  part = {"name": spec["name"], "nodes": [spec["node"]],
          "texture": spec["texture"]}
  if "pupilMask" in spec:
    part["pupilMask"] = spec["pupilMask"]
  category["items"].append(part)
for name in ["Earring", "Eyewear", "Headgear",
             "Chest", "Jacket", "Belt", "Suspenders", "Back", "Hand", "Leg",
             "Foot", "Left hand", "Right hand"]:
  manifest["categories"].append({"key": name, "selected": -1, "items": []})
for key, part in clothingParts() + garmentParts():
  next(category for category in manifest['categories']
       if category['key'] == key)['items'].append(part)
for key, part in gnomeParts() + hatParts():
  part = dict(part, singleFile=True,
              alignment='good' if key == 'Eyes' else 'both')
  next(category for category in manifest['categories']
       if category['key'] == key)['items'].append(part)
  manifest['skinNodes'].extend(part.get('skinNodes', []))
manifest['presets'].extend(gnomePresets())
data = (Preview / "character.glb").read_bytes()
size = struct.unpack_from("<I", data, 12)[0]
document = json.loads(data[20:20 + size])
for category in manifest['categories']:
  if category['key'] not in ['Chest', 'Jacket', 'Belt', 'Suspenders', 'Leg', 'Foot']:
    continue
  for part in category['items']:
    part['clothShades'] = []
    for node in document['nodes']:
      if node.get('name') not in part['nodes'] or 'mesh' not in node:
        continue
      for i, primitive in enumerate(document['meshes'][node['mesh']]['primitives']):
        name = document['materials'][primitive['material']].get('name', '')
        if name.endswith(' fabric') or name.endswith(' edging'):
          part['clothShades'].append(dict(node=node['name'], primitive=i,
            shade=1.14 if name.endswith(' edging') else 1))
shades = {'Chestnut': 1.0, 'Chestnut light': 1.1, 'Chestnut shade': .9,
          'Gnome beard white': 1.0}
manifest['hairShades'] = []
for node in document['nodes']:
  if not node.get('name', '').startswith(('Hair_', 'Beard_')) or 'mesh' not in node:
    continue
  for index, primitive in enumerate(document['meshes'][node['mesh']]['primitives']):
    material = document['materials'][primitive['material']]['name']
    if material in shades:
      manifest['hairShades'].append({'node': node['name'], 'primitive': index,
                                     'shade': shades[material]})
manifest['hatShades'] = []
for node in document['nodes']:
  if not node.get('name', '').startswith('Hat_') or 'mesh' not in node:
    continue
  for index, primitive in enumerate(document['meshes'][node['mesh']]['primitives']):
    if document['materials'][primitive['material']]['name'] == 'Gnome hat tint':
      manifest['hatShades'].append(dict(node=node['name'], primitive=index, shade=1))
(Output / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
print("MODEL_REPORT", json.dumps(report))

# Export the runtime library through the image-processing Python environment.
subprocess.run([os.environ.get("CHARGEN_PYTHON", "python3"),
                str(Path(__file__).with_name("export_library.py"))], check=True)
