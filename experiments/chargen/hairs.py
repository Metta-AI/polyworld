"""Build editable, interchangeable sculpted hair meshes for the shared head."""

import importlib
import math

import bmesh
import bpy
from mathutils import Euler, Matrix, Vector

Names = [
  'French crop', 'Bowl cut', 'Flat top', 'Clustered afro',
  'Twist crop', 'Asymmetric bob', 'Dutch braid', 'Braided bun',
  'Twin braids', 'Blunt bob', 'Wavy panels', 'Wolf cut',
  'Pixie', 'Low ponytail', 'Swept locs', 'Side braid',
]
HeadProfile = [
  (1.980, .225, .280, -.080), (2.035, .365, .400, -.045),
  (2.145, .455, .485, -.008), (2.320, .497, .510, .014),
  (2.540, .502, .520, .015), (2.775, .465, .470, .023),
  (2.935, .345, .340, .025), (3.010, .180, .170, .020),
  (3.025, .070, .065, .020),
]


def signedPower(value, exponent=.88):
  """Round a square section without introducing dense subdivision geometry."""
  return math.copysign(abs(value) ** exponent, value)


def profileAt(profile, height):
  """Interpolate a radius profile using its explicit horizontal sections."""
  if height <= profile[0][0]:
    return profile[0][1:]
  for first, second in zip(profile, profile[1:]):
    if height <= second[0]:
      t = (height - first[0]) / (second[0] - first[0])
      return tuple(a + (b - a) * t for a, b in zip(first[1:], second[1:]))
  return profile[-1][1:]


def sampleCurve(points, values, steps):
  """Sample a Catmull-Rom path and matching scalar radii deterministically."""
  points = [Vector(point) for point in points]
  result, sampled = [], []
  for i in range(len(points) - 1):
    a, b = points[max(0, i - 1)], points[i]
    c, d = points[i + 1], points[min(len(points) - 1, i + 2)]
    for j in range(steps):
      t = j / steps
      result.append(.5 * ((2 * b) + (-a + c) * t +
                    (2 * a - 5 * b + 4 * c - d) * t * t +
                    (-a + 3 * b - 3 * c + d) * t * t * t))
      sampled.append([v[i] * (1 - t) + v[i + 1] * t for v in values])
  result.append(points[-1])
  sampled.append([v[-1] for v in values])
  return result, sampled


def frames(points, normal):
  """Keep a stable swept section when a lock bends through the crown."""
  outward = Vector(normal).normalized()
  result, previous = [], None
  for i, point in enumerate(points):
    tangent = points[min(i + 1, len(points) - 1)] - points[max(0, i - 1)]
    if tangent.length < 1e-7:
      tangent = Vector((0, 0, -1))
    tangent.normalize()
    depth = outward - tangent * outward.dot(tangent)
    if depth.length < .12:
      if previous is not None:
        depth = previous - tangent * previous.dot(tangent)
      if depth.length < .12:
        candidate = min([Vector((1, 0, 0)), Vector((0, 1, 0)),
                         Vector((0, 0, 1))], key=lambda v: abs(v.dot(tangent)))
        depth = candidate - tangent * candidate.dot(tangent)
    depth.normalize()
    if previous is not None and depth.dot(previous) < 0:
      depth = -depth
    width = depth.cross(tangent).normalized()
    result.append((width, depth, tangent))
    previous = depth
  return result


class HairBuilder:
  """Accumulate closed sculpted pieces in a single flat mesh buffer."""

  def __init__(self):
    """Start one hairstyle with independent vertex and face buffers."""
    self.vertices, self.faces, self.materials, self.smooth = [], [], [], []

  def mesh(self, vertices, faces, material=0, smooth=True):
    """Append a closed local mesh without adding hidden scene objects."""
    offset = len(self.vertices)
    self.vertices.extend(tuple(point) for point in vertices)
    self.faces.extend(tuple(index + offset for index in face) for face in faces)
    self.materials.extend([material] * len(faces))
    self.smooth.extend([smooth] * len(faces))

  def scalp(self, theta, z, offset=.04):
    """Locate a point on the original rounded head with explicit clearance."""
    x, y, centerY = profileAt(HeadProfile, z)
    return ((x + offset) * signedPower(math.sin(theta)),
            centerY - (y + offset) * signedPower(math.cos(theta)), z)

  def cap(self, front=2.62, side=2.46, back=2.38, top=3.12,
          puff=.045, segments=48, rings=10, hem=None, profile=None,
          material=0):
    """Build a closed crown shell with a variable fringe and nape boundary."""
    if profile is None:
      lift = top - HeadProfile[-1][0]
      profile = [(z + lift, x, y, centerY) for z, x, y, centerY in HeadProfile]
    vertices, faces = [], []
    for row in range(rings + 1):
      t = row / rings
      for column in range(segments):
        theta = column * math.tau / segments
        signed = (theta + math.pi) % math.tau - math.pi
        if hem is None:
          weight = abs(math.cos(theta)) ** 2
          bottom = side + ((front if math.cos(theta) >= 0 else back) - side) * weight
        else:
          bottom = hem(signed)
        z = bottom + (top - bottom) * t
        x, y, centerY = profileAt(profile, z)
        vertices.append(((x + puff) * signedPower(math.sin(theta)),
                         centerY - (y + puff) * signedPower(math.cos(theta)), z))
        if row:
          a = (row - 1) * segments + column
          b = (row - 1) * segments + (column + 1) % segments
          faces.append((a, b, b + segments, a + segments))
    inner = len(vertices)
    for x, y, z in vertices[:segments]:
      vertices.append((x * .84, .02 + (y - .02) * .84, z + .015))
    for i in range(segments):
      j = (i + 1) % segments
      faces.append((j, i, inner + i, inner + j))
    faces.append(tuple(inner + i for i in reversed(range(segments))))
    faces.append(tuple(rings * segments + i for i in range(segments)))
    self.mesh(vertices, faces, material)

  def lock(self, points, widths, depths=None, normal=(0, -1, 0),
           sides=8, steps=3, material=0):
    """Sweep a closed tapered lock with broad, editable cross sections."""
    if isinstance(widths, (int, float)):
      widths = [widths] * len(points)
    if depths is None:
      depths = [width * .55 for width in widths]
    elif isinstance(depths, (int, float)):
      depths = [depths] * len(points)
    assert len(points) == len(widths) == len(depths) and len(points) >= 2
    positions, radii = sampleCurve(points, [widths, depths], steps)
    bases = frames(positions, normal)
    vertices, faces = [], []
    for i, (point, (width, depth), basis) in enumerate(zip(positions, radii, bases)):
      wide, outward, tangent = basis
      for j in range(sides):
        angle = math.tau * j / sides
        vertices.append(point + wide * (max(.004, width) * math.cos(angle)) +
                        outward * (max(.004, depth) * math.sin(angle)))
        if i:
          a = (i - 1) * sides + j
          b = (i - 1) * sides + (j + 1) % sides
          faces.append((a, b, b + sides, a + sides))
    faces.append(tuple(reversed(range(sides))))
    faces.append(tuple((len(positions) - 1) * sides + j for j in range(sides)))
    self.mesh(vertices, faces, material)

  def ellipsoid(self, center, radii, subdivisions=1, rotation=None, material=0):
    """Add a deliberately faceted closed hair clump."""
    mesh = bmesh.new()
    bmesh.ops.create_icosphere(mesh, subdivisions=subdivisions, radius=1)
    mesh.verts.ensure_lookup_table()
    mesh.verts.index_update()
    transform = Euler(rotation or (0, 0, 0), 'XYZ').to_matrix()
    vertices = [Vector(center) + transform @ Vector(tuple(
      vertex.co[i] * radii[i] for i in range(3))) for vertex in mesh.verts]
    faces = [tuple(vertex.index for vertex in face.verts) for face in mesh.faces]
    self.mesh(vertices, faces, material, smooth=False)
    mesh.free()

  def braid(self, points, radius=.13, links=7, normal=(0, 1, 0),
            taper=.55, material=0):
    """Weave three chunky strands along a curved, tapering centerline."""
    count = max(links * 8 // (len(points) - 1), 5)
    positions, radii = sampleCurve(points, [[radius] * len(points)], count)
    bases = frames(positions, normal)
    lengths = [0.0]
    for first, second in zip(positions, positions[1:]):
      lengths.append(lengths[-1] + (second - first).length)

    def along(t):
      """Interpolate one center and local frame by arc length."""
      distance = max(0, min(1, t)) * lengths[-1]
      index = next((i for i in range(len(lengths) - 1)
                    if lengths[i + 1] >= distance), len(lengths) - 2)
      mix = (distance - lengths[index]) / max(1e-7, lengths[index + 1] - lengths[index])
      point = positions[index].lerp(positions[index + 1], mix)
      return point, bases[index]

    for link in range(links):
      for sign in [-1, 1]:
        controls, widths, depths = [], [], []
        for phase, horizontal, fatness, relief in [
          (0, -.54, .26, -.04),
          (.43, .20, .62, .12),
          (1.06, .53, .10, .04),
        ]:
          t = (link + phase) / links
          point, (wide, depth, tangent) = along(t)
          size = radius * (1 - (1 - taper) * min(1, t))
          controls.append(point + wide * (horizontal * size * sign) +
                          depth * (size * (relief + .45 + (.08 if sign == 1 else 0))))
          widths.append(size * fatness)
          depths.append(size * fatness * .55)
        self.lock(controls, widths, depths, normal=normal,
                  sides=7, steps=3, material=material)

  def ring(self, center, radius, thickness=.025, normal=(0, 1, 0), material=3):
    """Make a plain closed hair tie around an explicitly oriented axis."""
    normal = Vector(normal).normalized()
    axis = Vector((0, 0, 1)) if abs(normal.z) < .9 else Vector((1, 0, 0))
    x = axis.cross(normal).normalized()
    y = normal.cross(x).normalized()
    vertices, faces = [], []
    for i in range(20):
      angle = math.tau * i / 20
      radial = math.cos(angle) * x + math.sin(angle) * y
      for j in range(6):
        phase = math.tau * j / 6
        vertices.append(Vector(center) + radial * (radius + thickness * math.cos(phase)) +
                        normal * (thickness * math.sin(phase)))
        faces.append((i * 6 + j, ((i + 1) % 20) * 6 + j,
                      ((i + 1) % 20) * 6 + (j + 1) % 6,
                      i * 6 + (j + 1) % 6))
    self.mesh(vertices, faces, material)


def materials():
  """Share a restrained chestnut palette across every interchangeable style."""
  result = []
  for name, color in [
    ('Chestnut', (.32, .078, .037, 1)),
    ('Chestnut light', (.35, .089, .043, 1)),
    ('Chestnut shade', (.29, .068, .031, 1)),
    ('Brown hair tie', (.07, .045, .03, 1)),
  ]:
    item = bpy.data.materials.get(name) or bpy.data.materials.new(name)
    item.diffuse_color = color
    item.use_nodes = True
    shader = item.node_tree.nodes.get('Principled BSDF')
    shader.inputs['Base Color'].default_value = color
    shader.inputs['Roughness'].default_value = .88
    shader.inputs['Specular IOR Level'].default_value = .20
    result.append(item)
  return result


def buildHair(collection, styles=range(1, 17)):
  """Create independent Head-weighted hair modules in the requested collection."""
  palette = materials()
  result = []
  for style in styles:
    assert 1 <= style <= 16
    start = ((style - 1) // 4) * 4 + 1
    module = importlib.import_module(f'hair_styles_{start:02}_{start + 3:02}')
    hair = HairBuilder()
    module.build(style, hair)
    name = f'Hair_{style:02}'
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
    item['style'] = style
    item['label'] = Names[style - 1]
    result.append(item)
  return result
