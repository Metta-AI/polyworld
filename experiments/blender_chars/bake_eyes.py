"""Bake the real modular eye meshes into transparent, unlit image assets."""

import json
import math
import struct
from pathlib import Path

import bpy
import numpy as np
from mathutils import Matrix, Quaternion, Vector

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Preview = Root / "tmp/blender_chars"
Output = Experiment / "assets/eyes"
Original = Root.parent / "polyworld_data/characters/modular_chars"
Frame = [-.50, .50, 2.17, 2.67]
Output.mkdir(exist_ok=True)
(Preview / "original_eye_textures").mkdir(exist_ok=True)


class Glb:
  """Read actual rest geometry and materials without importing animations."""

  def __init__(self, path, body):
    """Resolve the original hierarchy and normalize its body height."""
    data = path.read_bytes()
    size = struct.unpack_from("<I", data, 12)[0]
    self.doc = json.loads(data[20:20 + size])
    self.binary = data[size + 28:]
    self.nodes = self.doc["nodes"]
    self.parents = {child: i for i, node in enumerate(self.nodes)
                    for child in node.get("children", [])}
    self.worlds = {}
    self.factor, self.floor = 1, 0
    self.materials = {}
    self.label = path.parent.name
    points = np.concatenate([part[0] for name in body
                             for part in self.geometry(name)])
    self.floor = float(points[:, 2].min())
    self.factor = 3.025 / (float(points[:, 2].max()) - self.floor)

  def accessor(self, index):
    """Decode strided scalar and vector data with its declared component type."""
    entry = self.doc["accessors"][index]
    view = self.doc["bufferViews"][entry["bufferView"]]
    width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3,
             "VEC4": 4, "MAT4": 16}[entry["type"]]
    code = {5121: "B", 5123: "H", 5125: "I", 5126: "f"}[
      entry["componentType"]]
    fmt = "<" + code * width
    stride = view.get("byteStride", struct.calcsize(fmt))
    offset = view.get("byteOffset", 0) + entry.get("byteOffset", 0)
    return np.array([struct.unpack_from(fmt, self.binary, offset + i * stride)
                     for i in range(entry["count"])])

  def world(self, index):
    """Compose a node's rest transform using the file's own parents."""
    if index in self.worlds:
      return self.worlds[index]
    node = self.nodes[index]
    if "matrix" in node:
      values = node["matrix"]
      matrix = Matrix([values[i:i + 4] for i in range(0, 16, 4)]).transposed()
    else:
      rotation = node.get("rotation", [0, 0, 0, 1])
      matrix = Matrix.LocRotScale(
        Vector(node.get("translation", [0, 0, 0])),
        Quaternion((rotation[3], *rotation[:3])),
        Vector(node.get("scale", [1, 1, 1]))
      )
    if index in self.parents:
      matrix = self.world(self.parents[index]) @ matrix
    self.worlds[index] = matrix
    return matrix

  def geometry(self, name):
    """Skin the source vertices, retaining the original indices and UVs."""
    index, node = next((i, node) for i, node in enumerate(self.nodes)
                       if node.get("name") == name and "mesh" in node)
    parts = []
    for primitive in self.doc["meshes"][node["mesh"]]["primitives"]:
      attributes = primitive["attributes"]
      positions = self.accessor(attributes["POSITION"])
      positions = np.column_stack([positions, np.ones(len(positions))])
      if "skin" in node:
        skin = self.doc["skins"][node["skin"]]
        inverse = self.accessor(skin["inverseBindMatrices"])
        inverse = inverse.reshape(-1, 4, 4).transpose(0, 2, 1)
        matrices = np.array([self.world(i) for i in skin["joints"]]) @ inverse
        joints = self.accessor(attributes["JOINTS_0"]).astype(int)
        weights = self.accessor(attributes["WEIGHTS_0"])
        positions = np.einsum("vjab,vb,vj->va", matrices[joints],
                              positions, weights)
      else:
        positions = positions @ np.array(self.world(index)).T
      positions = positions[:, [0, 2, 1]] * [1, -1, 1]
      positions[:, 2] -= self.floor
      positions *= self.factor
      indices = self.accessor(primitive["indices"]).reshape(-1, 3)
      uvs = self.accessor(attributes["TEXCOORD_0"])
      parts.append((positions, indices, uvs, primitive["material"]))
    return parts

  def material(self, index):
    """Render palette colors without lighting, specular rings, or shadows."""
    if index in self.materials:
      return self.materials[index]
    spec = self.doc["materials"][index]["pbrMetallicRoughness"]
    material = bpy.data.materials.new(self.label + str(index))
    material.use_nodes = True
    nodes, links = material.node_tree.nodes, material.node_tree.links
    nodes.clear()
    output = nodes.new("ShaderNodeOutputMaterial")
    emission = nodes.new("ShaderNodeEmission")
    emission.inputs["Color"].default_value = spec.get(
      "baseColorFactor", [1, 1, 1, 1])
    links.new(emission.outputs[0], output.inputs["Surface"])
    if "baseColorTexture" in spec:
      texture = self.doc["textures"][spec["baseColorTexture"]["index"]]
      image = self.doc["images"][texture["source"]]
      view = self.doc["bufferViews"][image["bufferView"]]
      start = view.get("byteOffset", 0)
      path = Preview / ("eye_palette_" + self.label + str(index) + ".png")
      path.write_bytes(self.binary[start:start + view["byteLength"]])
      node = nodes.new("ShaderNodeTexImage")
      node.image = bpy.data.images.load(str(path), check_existing=True)
      links.new(node.outputs["Color"], emission.inputs["Color"])
    self.materials[index] = material
    return material


def bake(asset, name, path):
  """Project one real eye pair into the shared transparent face rectangle."""
  objects = []
  for positions, indices, uvs, material in asset.geometry(name):
    assert positions[:, 0].min() > Frame[0], name
    assert positions[:, 0].max() < Frame[1], name
    assert positions[:, 2].min() > Frame[2], (name, positions[:, 2].min())
    assert positions[:, 2].max() < Frame[3], (name, positions[:, 2].max())
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(positions.tolist(), [], indices.tolist())
    mesh.materials.append(asset.material(material))
    uv = mesh.uv_layers.new(name="UVMap")
    for loop in mesh.loops:
      point = uvs[loop.vertex_index]
      uv.data[loop.index].uv = (point[0], 1 - point[1])
    obj = bpy.data.objects.new(name, mesh)
    scene.collection.objects.link(obj)
    objects.append(obj)
  scene.render.filepath = str(path)
  bpy.ops.render.render(write_still=True)
  for obj in objects:
    mesh = obj.data
    bpy.data.objects.remove(obj, do_unlink=True)
    bpy.data.meshes.remove(mesh)


bpy.ops.object.select_all(action="SELECT")
bpy.ops.object.delete(use_global=False)
scene = bpy.context.scene
scene.render.engine = "CYCLES"
scene.cycles.samples = 8
scene.cycles.use_denoising = False
scene.render.film_transparent = True
scene.render.resolution_x, scene.render.resolution_y = 1024, 512
scene.render.resolution_percentage = 100
scene.render.image_settings.file_format = "PNG"
scene.render.image_settings.color_mode = "RGBA"
scene.render.dither_intensity = 0
scene.view_settings.view_transform = "Standard"
scene.view_settings.look = "None"
bpy.ops.object.camera_add(location=(0, -5, (Frame[2] + Frame[3]) / 2))
camera = bpy.context.object
camera.rotation_euler = (math.pi / 2, 0, 0)
camera.data.type = "ORTHO"
camera.data.ortho_scale = Frame[1] - Frame[0]
scene.camera = camera
original = Glb(Original / "character.glb",
               ["Body_White_1", "Body_White_Head_1"])
manifest = json.loads((Original / "manifest.json").read_text())
eyes = next(item for item in manifest["categories"] if item["key"] == "Eye")
for eye in eyes["items"]:
  bake(original, eye["name"],
       Preview / "original_eye_textures" / (eye["name"] + ".png"))
body = ["Body", "Head", "Hand.Left", "Hand.Right", "Foot.Left", "Foot.Right"]
snapshot = Preview / "eyes_before_textures/character.glb"
if snapshot.exists():
  ours = Glb(snapshot, body)
  for name in ["Neutral", "Happy", "Angry"]:
    path = Output / (name + ".png")
    if not path.exists():
      bake(ours, "Eyes_" + name, path)
snapshot = Preview / "loop_before/blender.glb"
if snapshot.exists():
  old = Glb(snapshot, body)
  bake(old, "Eyes_Neutral", Preview / "original_eye_textures/Ours_Round.png")
(Output / "mapping.json").write_text(json.dumps({
  "frame": Frame, "resolution": [1024, 512],
  "expressions": ["Neutral", "Happy", "Angry", "Original2"],
  "source": str(Original / "character.glb"),
  "originalEyeCount": len(eyes["items"])
}, indent=2) + "\n")
(Output / "Original2.png").write_bytes(
  (Preview / "original_eye_textures/Eye_Black_2.png").read_bytes())
print("BAKED_EYES", len(eyes["items"]), "original presets and 4 swappable textures")
