"""Build interchangeable sculpted facial hair on the shared animated head."""

import importlib
import math

import bmesh
import bpy

from hairs import HairBuilder, HeadProfile, materials, profileAt, signedPower

Names = [
  'Split chin tuft', 'Parted chevron', 'Handlebar', 'Anchor goatee',
  'Square jaw', 'Swept chops', 'Rounded beard', 'Fork beard',
  'Tapered wedge', 'Spade beard', 'Van Dyke', 'Single tassel',
  'Twin tassels', 'Tiered fan', 'Tied jaw beard', 'Windswept beard',
]


def surface(x, z, offset=.018):
  """Find the actual polygonal front of the head at a given face coordinate."""
  rx, ry, cy = profileAt(HeadProfile, max(1.980, z))
  contour = [(rx * signedPower(math.sin(i * math.pi / 8)),
              cy - ry * signedPower(math.cos(i * math.pi / 8)))
             for i in range(-4, 5)]
  for first, second in zip(contour, contour[1:]):
    if first[0] <= x <= second[0]:
      t = (x - first[0]) / max(1e-8, second[0] - first[0])
      return (x, first[1] * (1 - t) + second[1] * t - offset, z)
  return (x, cy - offset, z)


def jaw(hair, top=None, bottom=None, width=.48, depth=.51,
        centerY=.005, extent=1.48, thickness=.055, material=0):
  """Form a closed cheek-to-chin shell with an explicit upper lip opening."""
  top = top or (lambda theta: 2.045 + .34 * abs(math.sin(theta)) ** 3)
  bottom = bottom or (lambda theta: 1.90 + .18 * abs(math.sin(theta)) ** 2)
  columns, rows = 32, 6
  vertices, faces = [], []
  for layer in range(2):
    for row in range(rows + 1):
      t = row / rows
      for column in range(columns + 1):
        theta = -extent + 2 * extent * column / columns
        upper, lower = top(theta), bottom(theta)
        rx, ry, cy = profileAt(HeadProfile, upper)
        clearance = .024 if layer == 0 else -.035
        lowerWidth = width if isinstance(width, (int, float)) else width(theta)
        lowerDepth = depth if isinstance(depth, (int, float)) else depth(theta)
        radial = thickness if layer else 0
        x = ((rx + clearance) * (1 - t) + (lowerWidth - radial) * t)
        y = ((ry + clearance) * (1 - t) + (lowerDepth - radial) * t)
        z = upper * (1 - t) + lower * t
        if z >= HeadProfile[0][0]:
          headX, headY, headCenter = profileAt(HeadProfile, z)
          x = max(x, headX + clearance)
          y = max(y, headY + clearance + cy * (1 - t) + centerY * t - headCenter)
        vertices.append((x * signedPower(math.sin(theta)),
                         cy * (1 - t) + centerY * t - y * signedPower(math.cos(theta)),
                         z))
  size = (rows + 1) * (columns + 1)
  for layer in range(2):
    shift = layer * size
    for row in range(rows):
      for column in range(columns):
        a = shift + row * (columns + 1) + column
        face = (a, a + 1, a + columns + 2, a + columns + 1)
        faces.append(face if layer == 0 else tuple(reversed(face)))
  border = (list(range(columns + 1)) +
            [row * (columns + 1) + columns for row in range(1, rows + 1)] +
            [rows * (columns + 1) + column for column in range(columns - 1, -1, -1)] +
            [row * (columns + 1) for row in range(rows - 1, 0, -1)])
  for a, b in zip(border, border[1:] + border[:1]):
    faces.append((a, a + size, b + size, b))
  hair.mesh(vertices, faces, material)


def buildBeards(collection, styles=range(1, 17)):
  """Create separate facial-hair modules weighted entirely to the head."""
  palette, result = materials(), []
  for style in styles:
    assert 1 <= style <= 16
    start = ((style - 1) // 4) * 4 + 1
    module = importlib.import_module(f'beard_styles_{start:02}_{start + 3:02}')
    hair = HairBuilder()
    module.build(style, hair)
    name = f'Beard_{style:02}'
    mesh = bpy.data.meshes.new(name)
    mesh.from_pydata(hair.vertices, [], hair.faces)
    mesh.update()
    data = bmesh.new()
    data.from_mesh(mesh)
    bmesh.ops.recalc_face_normals(data, faces=list(data.faces))
    data.to_mesh(mesh)
    data.free()
    for material in palette:
      mesh.materials.append(material)
    for polygon, material, smooth in zip(mesh.polygons, hair.materials, hair.smooth):
      polygon.material_index = material
      polygon.use_smooth = smooth
    item = bpy.data.objects.new(name, mesh)
    collection.objects.link(item)
    group = item.vertex_groups.new(name='Head')
    group.add(list(range(len(mesh.vertices))), 1, 'REPLACE')
    item['style'], item['label'] = style, Names[style - 1]
    result.append(item)
  return result
