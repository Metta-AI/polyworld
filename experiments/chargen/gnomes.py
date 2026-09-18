"""Build the shared gnome face modules on the existing character head rig."""

import math
from pathlib import Path

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

from beards import jaw, surface
from hairs import HairBuilder

Library = Path(__file__).resolve().parents[3] / 'polyworld_data/characters/chargen'


def material(name, color):
  """Create a matte material using the runtime's display-space palette."""
  result = bpy.data.materials.get(name) or bpy.data.materials.new(name)
  result.diffuse_color = (*color, 1)
  result.use_nodes = True
  shader = result.node_tree.nodes.get('Principled BSDF')
  if shader is None:
    shader = result.node_tree.nodes.new('ShaderNodeBsdfPrincipled')
  shader.inputs['Base Color'].default_value = (*color, 1)
  shader.inputs['Roughness'].default_value = .92
  return result


def mesh(collection, name, vertices, faces, palette, smooth=False):
  """Make one editable mesh attached rigidly to the common head bone."""
  previous = bpy.data.objects.get(name)
  if previous:
    bpy.data.objects.remove(previous, do_unlink=True)
  data = bpy.data.meshes.new(name)
  data.from_pydata(vertices, [], faces)
  data.update()
  edit = bmesh.new()
  edit.from_mesh(data)
  bmesh.ops.recalc_face_normals(edit, faces=list(edit.faces))
  edit.to_mesh(data)
  edit.free()
  for entry in palette:
    data.materials.append(entry)
  for face in data.polygons:
    face.use_smooth = smooth
  result = bpy.data.objects.new(name, data)
  collection.objects.link(result)
  result.vertex_groups.new(name='Head').add(
    list(range(len(data.vertices))), 1, 'REPLACE')
  result['family'] = 'Gnome'
  return result


def nose(collection, skin):
  """Sculpt a broad button nose that intersects the actual face naturally."""
  vertices, faces = [], []
  columns, rows = 16, 8
  for row in range(1, rows):
    latitude = math.pi * row / rows
    for column in range(columns):
      angle = math.tau * column / columns
      vertices.append((.152 * math.sin(latitude) * math.cos(angle),
                       -.546 + .145 * math.sin(latitude) * math.sin(angle),
                       2.285 + .112 * math.cos(latitude)))
      if row > 1:
        a = (row - 2) * columns + column
        b = (row - 2) * columns + (column + 1) % columns
        faces.append((a, b, b + columns, a + columns))
  for ring, z in [(0, 2.397), ((rows - 2) * columns, 2.173)]:
    tip = len(vertices)
    vertices.append((0, -.546, z))
    for column in range(columns):
      faces.append((ring + column, ring + (column + 1) % columns, tip))
  return mesh(collection, 'Nose_Gnome', vertices, faces, [skin], True)


def ears(collection, skin):
  """Build larger open-looking cupped ears with closed backs and thick rims."""
  outline = [(-.12, -.08), (-.07, -.145), (.025, -.15), (.13, -.07),
             (.15, .04), (.10, .135), (.015, .16), (-.09, .115)]
  result = []
  for sign, side in [(1, 'Left'), (-1, 'Right')]:
    vertices, faces = [], []
    for row, (scale, depth) in enumerate([
      (.65, .075), (.96, .035), (1, -.055), (.88, -.14),
      (.67, -.145), (.47, -.055), (.18, -.035),
    ]):
      for x, z in outline:
        vertices.append((sign * (.579 + x * scale), depth, 2.355 + z * scale))
      if row:
        for column in range(len(outline)):
          a = (row - 1) * len(outline) + column
          b = (row - 1) * len(outline) + (column + 1) % len(outline)
          faces.append((a, b, b + len(outline), a + len(outline)))
    faces += [tuple(reversed(range(8))), tuple(range(48, 56))]
    result.append(mesh(collection, 'Ears_Gnome_' + side,
                       vertices, faces, [skin]))
  return result


def beard(collection, white):
  """Layer broad pointed locks around both cheeks and below the chin."""
  hair = HairBuilder()
  jaw(hair,
      top=lambda angle: 2.045 + .39 * abs(math.sin(angle)) ** 3,
      bottom=lambda angle: 1.64 + .51 * abs(math.sin(angle)) ** 1.35,
      width=lambda angle: .13 + .40 * abs(math.sin(angle)),
      depth=.52, extent=1.54, thickness=.07)
  for sign in [-1, 1]:
    hair.lock([surface(sign * .45, 2.435, -.025),
               (sign * .49, -.27, 2.335),
               (sign * .515, -.30, 2.22),
               (sign * .50, -.30, 2.11)],
              [.024, .085, .075, .003], [.02, .06, .05, .003],
              normal=(sign * .6, -1, 0), sides=7, steps=3)
    hair.lock([(sign * .34, -.36, 2.265),
               (sign * .41, -.425, 2.13),
               (sign * .41, -.465, 2.015),
               (sign * .38, -.445, 1.91),
               (sign * .335, -.39, 1.825)],
              [.025, .13, .13, .073, .003],
              [.02, .085, .09, .05, .003],
              normal=(sign * .2, -1, 0), sides=7, steps=3)
    hair.lock([(sign * .18, -.45, 2.11),
               (sign * .24, -.51, 2.0),
               (sign * .225, -.555, 1.86),
               (sign * .19, -.53, 1.76),
               (sign * .135, -.48, 1.675)],
              [.028, .16, .145, .082, .003],
              [.024, .095, .10, .06, .003], sides=7, steps=3)
  hair.lock([(0, -.48, 2.11), (0, -.555, 1.985),
             (0, -.605, 1.835), (0, -.58, 1.69), (0, -.50, 1.585)],
            [.04, .19, .165, .09, .003],
            [.025, .11, .115, .065, .003], sides=7, steps=3)
  result = [mesh(collection, 'Beard_Gnome', hair.vertices, hair.faces, [white], True)]
  moustache = HairBuilder()
  for sign in [-1, 1]:
    moustache.lock([(sign * .018, -.56, 2.178),
                    (sign * .10, -.605, 2.155),
                    (sign * .225, -.58, 2.15),
                    (sign * .30, -.53, 2.17),
                    (sign * .355, -.47, 2.205)],
                   [.035, .071, .067, .036, .003],
                   [.025, .073, .062, .033, .003], sides=10, steps=3)
  result.append(mesh(collection, 'Beard_Gnome_Moustache',
                     moustache.vertices, moustache.faces, [white], True))
  return result


def eyes(collection, head):
  """Project the shared kind-eye sprite onto the existing head surface."""
  tree = BVHTree.FromPolygons([vertex.co for vertex in head.data.vertices],
                             [tuple(face.vertices) for face in head.data.polygons])
  vertices, faces, uvs = [], [], []
  columns, rows = 24, 16
  for row in range(rows + 1):
    for column in range(columns + 1):
      u, v = column / columns, row / rows
      x, z = -.345 + .69 * u, 2.365 + (v - .5) * .368
      point = tree.ray_cast(Vector((x, -2, z)), Vector((0, 1, 0)))[0]
      assert point is not None, (x, z)
      vertices.append((x, point.y - .008, z))
      uvs.append((u, v))
      if row and column:
        a = (row - 1) * (columns + 1) + column - 1
        faces.append((a, a + 1, a + columns + 2, a + columns + 1))
  mat = material('Gnome kind eyes', (1, 1, 1))
  nodes = mat.node_tree.nodes
  nodes.clear()
  texture = nodes.new('ShaderNodeTexImage')
  texture.image = bpy.data.images.load(str(Library / 'eyes/gnome_kind.png'),
                                      check_existing=False)
  texture.extension = 'EXTEND'
  clip = nodes.new('ShaderNodeMath')
  clip.operation = 'ROUND'
  transparent = nodes.new('ShaderNodeBsdfTransparent')
  blend = nodes.new('ShaderNodeMixShader')
  output = nodes.new('ShaderNodeOutputMaterial')
  mat.node_tree.links.new(texture.outputs['Alpha'], clip.inputs[0])
  mat.node_tree.links.new(clip.outputs[0], blend.inputs[0])
  mat.node_tree.links.new(transparent.outputs[0], blend.inputs[1])
  mat.node_tree.links.new(texture.outputs['Color'], blend.inputs[2])
  mat.node_tree.links.new(blend.outputs[0], output.inputs[0])
  mat.surface_render_method = 'DITHERED'
  result = mesh(collection, 'Eyes_Gnome', vertices, faces, [mat], True)
  layer = result.data.uv_layers.new(name='Face projection')
  for loop in result.data.loops:
    layer.data[loop.index].uv = uvs[loop.vertex_index]
  return result


def buildGnomes(collection, head):
  """Build four shared swappable features without changing existing assets."""
  skin = material('Gnome skin', (.96, .70, .49))
  white = material('Gnome beard white', (1, 1, 1))
  return [nose(collection, skin), *ears(collection, skin),
          *beard(collection, white), eyes(collection, head)]


def gnomeParts():
  """Describe the shared modules using the standard character sidecars."""
  return [
    ('Nose', dict(name='Gnome bulb', nodes=['Nose_Gnome'],
                  skinNodes=['Nose_Gnome'])),
    ('Ears', dict(name='Gnome cups',
                  nodes=['Ears_Gnome_Left', 'Ears_Gnome_Right'],
                  skinNodes=['Ears_Gnome_Left', 'Ears_Gnome_Right'])),
    ('Beard', dict(name='Gnome pointed',
                   nodes=['Beard_Gnome', 'Beard_Gnome_Moustache'])),
    ('Eyes', dict(name='Gnome kind', nodes=['Eyes_Gnome'],
                  texture='eyes/gnome_kind.png',
                  pupilMask='eyes/gnome_kind.mask.png')),
  ]


def gnomePresets():
  """Reuse one face kit and the existing brows across nine color presets."""
  colors = [('White', 'Blue'), ('Dark brown', 'Brown'), ('White', 'Green'),
            ('Copper', 'Green'), ('White', 'Blue'), ('Soft black', 'Amber'),
            ('Silver', 'Amber'), ('Chestnut', 'Teal'), ('Copper', 'Amber')]
  from hats import hatPresets
  from garments import outfitPresets
  return outfitPresets(hatPresets([dict(name=f'Gnome {i + 1:02d}', group='Gnomes', pose='A_TPose',
               skin=5, hairColor=hair, pupilColor=eye,
               parts=[dict(category=category, item=name) for category, name in [
                 ('Eyes', 'Gnome kind'), ('Nose', 'Gnome bulb'),
                 ('Ears', 'Gnome cups'), ('Beard', 'Gnome pointed'),
                 ('Brow', '01 Soft arch'), ('Hair', 'None'),
                 ('Mouth', '01 Relaxed smile')]])
          for i, (hair, eye) in enumerate(colors)]))
