"""Build simple shared gnome hat shapes with fixed-color decorations."""

import math

import bmesh

from mathutils import Vector

from gnomes import material, mesh
from hairs import HairBuilder, frames

Names = ['Pointed', 'Folded', 'Wide brim', 'Mushroom', 'Leaf', 'Feather']
Colors = [
  ('Red', (.78, .025, .018)), ('Blue', (.035, .16, .85)),
  ('Mushroom red', (.60, .09, .035)), ('Green', (.18, .39, .035)),
  ('Gray', (.48, .49, .52)), ('Purple', (.33, .045, .55)),
  ('Brown', (.27, .115, .052)), ('Tan', (.67, .365, .21)),
  ('Orange', (.96, .235, .025)), ('Cream', (.84, .77, .61)),
  ('Black', (.035, .03, .025)), ('Teal', (.025, .46, .42)),
  ('Pink', (.86, .13, .36)),
]


def crown(builder, folded=False):
  """Sweep a smooth cloth shell with a real opening and a rolled lower edge."""
  rings = [(0, .015, 2.625, .535, .553),
           (0, .015, 2.685, .55, .565),
           (-.025, .03, 2.88, .466, .472),
           (-.015, .045, 3.105, .355, .357),
           (.035, .055, 3.34, .235, .243)]
  if folded:
    rings += [(.105, .045, 3.55, .163, .169),
              (.245, .02, 3.65, .124, .127),
              (.42, -.005, 3.60, .090, .092),
              (.49, -.015, 3.49, .008, .009)]
  else:
    rings += [(.065, .065, 3.56, .125, .131),
              (.13, .07, 3.76, .008, .009)]
  count = 16
  points = [Vector(ring[:3]) for ring in rings]
  bases = frames(points, (0, -1, 0))
  vertices, faces = [], []
  for row, ((x, y, z, rx, ry), basis) in enumerate(zip(rings, bases)):
    wide, outward, _ = basis
    for i in range(count):
      theta = math.tau * i / count
      if row < 5:
        point = Vector((x + rx * math.sin(theta), y - ry * math.cos(theta), z))
      else:
        point = points[row] - wide * rx * math.sin(theta) + outward * ry * math.cos(theta)
      if row < 2:
        point.z += .052 * math.cos(theta)
      vertices.append(point)
      if row:
        a = (row - 1) * count + i
        b = (row - 1) * count + (i + 1) % count
        faces += [(a, b, b + count), (a, b + count, a + count)]
  faces.append(tuple(range((len(rings) - 1) * count, len(vertices))))
  inner = len(vertices)
  for point in vertices[:count]:
    vertices.append(Vector((point.x * .945, .015 + (point.y - .015) * .945,
                            point.z + .04)))
  for i in range(count):
    j = (i + 1) % count
    faces.append((j, i, inner + i, inner + j))
  builder.mesh(vertices, faces, smooth=True)


def brim(builder):
  """Add a shallow floppy brim with a visible rounded thickness."""
  count = 24
  vertices, faces = [], []
  for row, (rx, ry, height) in enumerate([
    (.52, .535, 2.69), (.70, .67, 2.655), (.855, .77, 2.62),
    (.862, .775, 2.585), (.70, .67, 2.61), (.51, .53, 2.65),
  ]):
    for i in range(count):
      angle = math.tau * i / count
      wave = (.028 * math.sin(angle * 3 + .5) + .024 * math.cos(angle)) * (rx - .50) / .36
      vertices.append((rx * math.sin(angle), .015 - ry * math.cos(angle), height + wave))
      if row:
        a = (row - 1) * count + i
        b = (row - 1) * count + (i + 1) % count
        faces.append((a, b, b + count, a + count))
  for i in range(count):
    j = (i + 1) % count
    faces.append((i, j, 5 * count + j, 5 * count + i))
  builder.mesh(vertices, faces, smooth=True)


def mushroom(builder):
  """Build a domed cap with a cream underside and surface-fitted spots."""
  count = 24
  rings = [(.008, 3.40), (.22, 3.38), (.43, 3.31),
           (.61, 3.19), (.76, 2.99), (.84, 2.82), (.87, 2.72),
           (.84, 2.645), (.72, 2.65), (.54, 2.70), (.51, 2.645)]
  vertices, faces, shades = [], [], []
  for row, (radius, z) in enumerate(rings):
    for i in range(count):
      angle = math.tau * i / count
      vertices.append((radius * math.sin(angle), .015 - radius * .96 * math.cos(angle), z))
      if row:
        a = (row - 1) * count + i
        b = (row - 1) * count + (i + 1) % count
        faces += [(a, b, b + count), (a, b + count, a + count)]
        shades += [0 if row <= 6 else 1] * 2
  faces.append(tuple(reversed(range(count))))
  shades.append(0)
  builder.mesh(vertices, faces, smooth=True)
  builder.materials[-len(shades):] = shades
  # Clip each spot to cap triangles so every patch is exactly surface-aligned.
  specs = [(-.14, -.22, .091, .079), (.35, -.40, .107, .089),
           (-.52, -.27, .087, .071), (.63, .14, .092, .07),
           (-.40, .44, .10, .086), (.12, .54, .09, .08),
           (.10, .13, .075, .073), (-.67, .08, .064, .057),
           (.11, -.64, .079, .068)]

  def cross(a, b, point):
    """Measure a point's signed distance from a projected triangle edge."""
    return (b[0] - a[0]) * (point[1] - a[1]) - (b[1] - a[1]) * (point[0] - a[0])

  def clipped(polygon, triangle):
    """Clip the spot polygon against one cap face in the horizontal plane."""
    sign = 1 if cross(triangle[0], triangle[1], triangle[2]) > 0 else -1
    for a, b in zip(triangle, triangle[1:] + triangle[:1]):
      output = []
      for first, second in zip(polygon, polygon[1:] + polygon[:1]):
        start, end = cross(a, b, first) * sign, cross(a, b, second) * sign
        if start >= 0:
          output.append(first)
        if (start >= 0) != (end >= 0):
          t = start / (start - end)
          output.append(tuple(first[i] + (second[i] - first[i]) * t for i in range(2)))
      polygon = output
      if not polygon:
        break
    return polygon

  for x, y, rx, ry in specs:
    circle = [(x + rx * math.cos(math.tau * i / 20),
               y + ry * math.sin(math.tau * i / 20)) for i in range(20)]
    for face in faces[:6 * count * 2]:
      triangle = [Vector(vertices[i]) for i in face]
      normal = (triangle[1] - triangle[0]).cross(triangle[2] - triangle[0])
      if abs(normal.z) < 1e-8:
        continue
      polygon = clipped(circle, [tuple(point[:2]) for point in triangle])
      if len(polygon) < 3:
        continue
      origin = triangle[0]
      patch = [(px, py, origin.z - (normal.x * (px - origin.x) +
                                    normal.y * (py - origin.y)) / normal.z + .002)
               for px, py in polygon]
      builder.mesh(patch, [tuple(range(len(patch)))], material=4, smooth=True)


def leaf(builder, root, tip, width, color):
  """Make a thick broad leaf or feather with a raised central vein."""
  root, tip = Vector(root), Vector(tip)
  along = tip - root
  side = Vector((-along.z, 0, along.x)).normalized() * width
  middle = root + along * .52
  ridge = middle + Vector((0, -.065, 0))
  vertices = [root, middle + side, tip, middle - side, ridge,
              middle + Vector((0, .025, 0))]
  faces = [(0, 1, 4), (1, 2, 4), (2, 3, 4), (3, 0, 4),
           (1, 0, 5), (2, 1, 5), (3, 2, 5), (0, 3, 5)]
  builder.mesh(vertices, faces, color, smooth=False)


def decoration(builder, feather=False):
  """Place a simple leaf sprig or contrasting feather fan on the right side."""
  if feather:
    for tip, width, shade in [((.59, -.32, 3.30), .09, 3),
                              ((.78, -.34, 3.15), .088, 3),
                              ((.77, -.36, 2.98), .08, 3),
                              ((.59, -.39, 3.18), .074, 1),
                              ((.69, -.405, 3.02), .073, 1)]:
      leaf(builder, (.40, -.405, 2.78), tip, width, shade)
  else:
    leaf(builder, (.43, -.40, 2.79), (.76, -.355, 3.255), .115, 2)
    leaf(builder, (.43, -.41, 2.79), (.35, -.415, 3.125), .082, 2)
  builder.lock([(.415, -.427, 2.74), (.45, -.429, 2.83),
                (.47, -.425, 2.875)], [.037, .043, .032],
               sides=6, steps=1, material=2 if not feather else 1)


def spotMaterial():
  """Keep mushroom pigment pure white without lighting or normal artifacts."""
  result = material('Gnome hat white spots', (1, 1, 1))
  nodes = result.node_tree.nodes
  nodes.clear()
  white = nodes.new('ShaderNodeRGB')
  white.outputs[0].default_value = (1, 1, 1, 1)
  output = nodes.new('ShaderNodeOutputMaterial')
  result.node_tree.links.new(white.outputs[0], output.inputs['Surface'])
  return result


def smoothCaps(item, builder):
  """Smooth curved fabric while retaining sharp folds, hems, and leaf ridges."""
  for face, shade, smooth in zip(item.data.polygons, builder.materials,
                                  builder.smooth):
    face.material_index = shade
    face.use_smooth = smooth
  edit = bmesh.new()
  edit.from_mesh(item.data)
  for edge in edit.edges:
    edge.smooth = not (len(edge.link_faces) == 2 and
                       edge.calc_face_angle() > math.radians(50))
  edit.to_mesh(item.data)
  edit.free()
  item.data.update()


def buildHats(collection):
  """Build six selectable hats from four crowns and two small decorations."""
  palette = [material('Gnome hat tint', (1, 1, 1)),
             material('Gnome hat cream', (.93, .86, .65)),
             material('Gnome hat leaf', (.33, .57, .035)),
             material('Gnome hat feather blue', (.025, .18, .64)),
             spotMaterial()]
  items = []
  for name in Names:
    builder = HairBuilder()
    if name == 'Mushroom':
      mushroom(builder)
    else:
      crown(builder, folded=name in ['Folded', 'Wide brim', 'Feather'])
      if name == 'Wide brim':
        brim(builder)
      if name in ['Leaf', 'Feather']:
        decoration(builder, feather=name == 'Feather')
    item = mesh(collection, 'Hat_' + name.replace(' ', '_'),
                builder.vertices, builder.faces, palette)
    smoothCaps(item, builder)
    items.append(item)
  return items


def hatParts():
  """Describe independent hats and hide scalp hair beneath closed crowns."""
  return [('Headgear', dict(name='Gnome ' + name.lower(),
                           nodes=['Hat_' + name.replace(' ', '_')],
                           singleFile=True, alignment='both',
                           hides=[f'Hair_{i:02d}' for i in range(1, 17)]))
          for name in Names]


def hatPresets(presets):
  """Dress the existing nine face presets in reference-matched hat variants."""
  variants = ['folded', 'pointed', 'mushroom', 'leaf', 'folded',
              'folded', 'wide brim', 'feather', 'pointed']
  index = 0
  for preset in presets:
    if preset.get('group') != 'Gnomes':
      continue
    preset['hatColor'] = Colors[index][0]
    preset['parts'] = [part for part in preset['parts'] if part['category'] != 'Headgear']
    preset['parts'].append(dict(category='Headgear', item='Gnome ' + variants[index]))
    index += 1
  return presets
