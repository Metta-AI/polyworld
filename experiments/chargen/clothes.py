"""Cut and offset the real skinned body to make simple modular clothing."""

import bmesh
import bpy
from mathutils import Vector
from mathutils.kdtree import KDTree

Specs = [
  dict(number=1, category='Chest', name='Linen tunic', color='#d5c9a7',
       sleeve=.535, hem=1.055, neck='split'),
  dict(number=2, category='Chest', name='Bound blue tunic', color='#426895',
       sleeve=.535, hem=1.095, neck='round', trim='#d5c9a7'),
  dict(number=3, category='Chest', name='Belted green tabard', color='#536938',
       sleeve=.325, hem=1.045, neck='round', belt=True, slit=True),
  dict(number=4, category='Chest', name='Red work shirt', color='#95433e',
       sleeve=.685, hem=1.115, neck='square', cuff=True),
  dict(number=5, category='Chest', name='Belted ochre tunic', color='#b78631',
       sleeve=.910, hem=1.025, neck='split', cuff=True, belt=True),
  dict(number=6, category='Chest', name='Leather jerkin', color='#624431',
       sleeve=.325, hem=1.085, neck='v', opening=True),
  dict(number=7, category='Chest', name='Blue linen shirt', color='#7195bb',
       sleeve=.910, hem=1.085, neck='split', cuff=True, trim='#d5c9a7'),
  dict(number=8, category='Chest', name='Plum wrap tunic', color='#63425e',
       sleeve=.540, hem=1.065, neck='v', wrap=True),
  dict(number=9, category='Leg', name='Brown trousers', color='#574334',
       hem=.170, loose=.008),
  dict(number=10, category='Leg', name='Loose blue breeches', color='#4b6482',
       hem=.205, loose=.055, cuff=True),
  dict(number=11, category='Leg', name='Tan knee breeches', color='#b39362',
       hem=.465, loose=.018, cuff=True),
  dict(number=12, category='Leg', name='Cuffed charcoal trousers',
       color='#42454e', hem=.205, loose=.004, cuff=True, trim='#756047'),
  dict(number=13, category='Foot', name='Strapped ankle boots',
       color='#5b3e2b', top=.315, strap=True),
  dict(number=14, category='Foot', name='Tan cuff boots', color='#ac7b42',
       top=.460, cuff=True),
  dict(number=15, category='Foot', name='Tall leather boots',
       color='#493428', top=.595),
  dict(number=16, category='Foot', name='Folded travel boots',
       color='#77543a', top=.425, cuff=True, toe=True),
]
BootCuts = [.300, .410, .445, .580]


def label(spec):
  """Keep sheet numbers in the runtime picker and stable asset filenames."""
  return f'{spec["number"]:02} {spec["name"]}'


def nodeName(spec):
  """Give every complete garment one unique mesh node on the common rig."""
  return f'Clothing_{spec["number"]:02}'


def material(name, color, factor=1):
  """Use the same display-space palette convention as the character renderer."""
  result = bpy.data.materials.get(name) or bpy.data.materials.new(name)
  channels = [int(color[i:i + 2], 16) / 255 * factor for i in (1, 3, 5)]
  result.diffuse_color = (*channels, 1)
  result.use_nodes = True
  shader = result.node_tree.nodes.get('Principled BSDF')
  shader.inputs['Base Color'].default_value = (*channels, 1)
  shader.inputs['Roughness'].default_value = .95
  shader.inputs['Specular IOR Level'].default_value = .12
  return result


def bodySurface(objects):
  """Read actual rest vertices, surface normals, faces and deformation weights."""
  faces = []
  for item in objects:
    normals = [Vector() for vertex in item.data.vertices]
    for loop, normal in zip(item.data.loops, item.data.corner_normals):
      normals[loop.vertex_index] += normal.vector
    vertices = [(vertex.co.copy(), normals[vertex.index].normalized(), {
      item.vertex_groups[group.group].name: group.weight
      for group in vertex.groups if group.weight > 1e-7
    }) for vertex in item.data.vertices]
    for face in item.data.polygons:
      faces.append([vertices[i] for i in face.vertices])
  return faces


def interpolate(first, second, amount):
  """Interpolate source skin weights as an edge is cut at a garment opening."""
  weights = {name: first[2].get(name, 0) * (1 - amount) +
             second[2].get(name, 0) * amount
             for name in first[2].keys() | second[2].keys()}
  return (first[0].lerp(second[0], amount),
          first[1].lerp(second[1], amount).normalized(), weights)


def clip(surface, distance):
  """Keep the positive side of a cut without capping wearable openings."""
  result = []
  for face in surface:
    polygon = []
    previous = face[-1]
    before = distance(previous[0])
    for current in face:
      after = distance(current[0])
      if (before >= 0) != (after >= 0):
        polygon.append(interpolate(previous, current, before / (before - after)))
      if after >= 0:
        polygon.append(current)
      previous, before = current, after
    if len(polygon) >= 3:
      result.append(polygon)
  return result


def offset(surface, amount):
  """Extrude the copied body surface outward, retaining the same skin weights."""
  return [[(point + normal * amount, normal, weights)
           for point, normal, weights in face] for face in surface]


def meshObject(collection, name, surfaces, materials, preserveNormals=False):
  """Weld copied surfaces and create a weighted clothing shell with open edges."""
  vertices, faces, weights, indices, normals, mapping = [], [], [], [], [], {}
  for surface, index in surfaces:
    for polygon in surface:
      face = []
      for point, normal, influences in polygon:
        key = tuple(round(value, 6) for value in point)
        if key not in mapping:
          mapping[key] = len(vertices)
          vertices.append(tuple(point))
          normals.append(tuple(normal))
          weights.append(influences)
        face.append(mapping[key])
      face = list(dict.fromkeys(face))
      if len(face) >= 3:
        faces.append(face)
        indices.append(index)
  mesh = bpy.data.meshes.new(name)
  mesh.from_pydata(vertices, [], faces)
  mesh.update()
  for mat in materials:
    mesh.materials.append(mat)
  for face, index in zip(mesh.polygons, indices):
    face.material_index = index
    face.use_smooth = True
  item = bpy.data.objects.new(name, mesh)
  collection.objects.link(item)
  if preserveNormals:
    mesh.normals_split_custom_set_from_vertices(normals)
  for i, influences in enumerate(weights):
    total = sum(influences.values())
    assert total > .99, (name, i, total)
    for bone, weight in influences.items():
      if weight > 1e-7:
        group = item.vertex_groups.get(bone) or item.vertex_groups.new(name=bone)
        group.add([i], weight / total, 'REPLACE')
  return item


def splitTrousers(collection, item):
  """Keep seamless leg sections independently hideable inside selected boots."""
  surface = bodySurface([item])
  groups = [[] for material in item.data.materials]
  for face, polygon in zip(surface, item.data.polygons):
    groups[polygon.material_index].append(face)
  name = item.name
  item.name = name + '_Unsplit'
  result = []
  for index in range(5):
    lower = BootCuts[index - 1] if index > 0 else -1
    upper = BootCuts[index] if index < 4 else 5
    surfaces = []
    for materialIndex, group in enumerate(groups):
      section = clip(clip(group, lambda p: p.z - lower), lambda p: upper - p.z)
      if section:
        surfaces.append((section, materialIndex))
    if not surfaces:
      continue
    part = meshObject(collection, name if index == 4 else name + f'_BootCut{index}',
                      surfaces, list(item.data.materials), preserveNormals=True)
    for key in ['derivedFrom', 'construction', 'clothingNumber']:
      part[key] = item[key]
    result.append(part)
  bpy.data.objects.remove(item, do_unlink=True)
  return result


def sourceWeights(surface):
  """Sample original body weights for newly extruded skirt vertices."""
  points = {}
  for face in surface:
    for point, normal, weights in face:
      points[tuple(point)] = weights
  records = list(points.items())
  tree = KDTree(len(records))
  for i, (point, weights) in enumerate(records):
    tree.insert(point, i)
  tree.balance()

  def sample(point):
    """Interpolate nearby body weights instead of rigidly fixing hems to hips."""
    weights = {}
    for position, index, distance in tree.find_n(point, 4):
      factor = 1 / max(distance, .005) ** 3
      for name, value in records[index][1].items():
        weights[name] = weights.get(name, 0) + value * factor
    weights = dict(sorted(weights.items(), key=lambda item: -item[1])[:4])
    total = sum(weights.values())
    return {name: value / total for name, value in weights.items()}

  return sample


def hemExtrusion(surface, level, bottom, sample, slit=False):
  """Extend the body's waist loop into a continuous tunic skirt, not two legs."""
  result = list(surface)
  seen = set()
  for face in surface:
    for first, second in zip(face, face[1:] + face[:1]):
      if abs(first[0].z - level) > 1e-5 or abs(second[0].z - level) > 1e-5:
        continue
      key = tuple(sorted(tuple(round(v, 6) for v in point[0])
                         for point in [first, second]))
      if key in seen:
        continue
      seen.add(key)
      previous = [first, second]
      for amount in [.5, 1]:
        lower = []
        for point, normal, weights in [first, second]:
          target = Vector((point.x * (1 + .07 * amount),
                           point.y * (1 + .035 * amount),
                           level + (bottom - level) * amount))
          if slit and point.y < -.10:
            target.z += max(0, 1 - abs(point.x) / .035) * .10 * amount
          lower.append((target, normal, sample(target)))
        result.append([previous[1], previous[0], lower[0], lower[1]])
        previous = lower
  return result


def neckline(point, kind):
  """Cut modest round, square and split neck openings into the copied torso."""
  front = max(0, min(1, -point.y / .10))
  width = abs(point.x)
  depth = .055 * front * max(0, 1 - width / .24)
  if kind == 'square':
    depth = .115 * front * min(1, max(0, (.19 - width) / .045))
  elif kind == 'split':
    depth += .080 * front * max(0, 1 - width / .050)
  elif kind == 'v':
    depth += .075 * front * max(0, 1 - width / .17)
  return 1.935 - depth - point.z


def band(surface, cuts, amount=.004):
  """Lift a broad cloth band from the same garment and its exact deformation."""
  for cut in cuts:
    surface = clip(surface, cut)
  return offset(surface, amount)


def block(center, size, weights):
  """Build one small rectangular buckle bar with the nearest cloth weights."""
  points = [Vector((center.x + x * size[0] / 2,
                    center.y + y * size[1] / 2,
                    center.z + z * size[2] / 2))
            for x, y, z in [(-1, -1, -1), (1, -1, -1), (1, 1, -1),
                            (-1, 1, -1), (-1, -1, 1), (1, -1, 1),
                            (1, 1, 1), (-1, 1, 1)]]
  result = []
  for indices in [(3, 2, 1, 0), (4, 5, 6, 7), (0, 1, 5, 4),
                  (1, 2, 6, 5), (2, 3, 7, 6), (3, 0, 4, 7)]:
    normal = (points[indices[1]] - points[indices[0]]).cross(
      points[indices[2]] - points[indices[0]]).normalized()
    result.append([(points[i], normal, weights) for i in indices])
  return result


def buckle(surface, height, width=.052, tall=.044, bar=.007):
  """Place a simple open buckle on the garment rather than guessing its depth."""
  nearest = min((record for face in surface for record in face),
                key=lambda record: record[0].x ** 2 +
                (record[0].z - height) ** 2 + max(0, record[0].y) ** 2 * 8)
  y = nearest[0].y - .022
  weights = nearest[2]
  result = []
  for z in [height - tall / 2, height + tall / 2]:
    result += block(Vector((0, y, z)), (width, .012, bar), weights)
  for x in [-width / 2, width / 2]:
    result += block(Vector((x, y, height)), (bar, .012, tall), weights)
  return result


def shell(collection, spec, source):
  """Cut a top, trousers or boots from the original body and offset for fit."""
  number = spec['number']
  main = material(f'Clothing {number:02} fabric', spec['color'])
  trim = material(f'Clothing {number:02} trim', spec.get('trim', spec['color']),
                  1 if 'trim' in spec else 1.09)
  leather = material('Clothing belt leather', '#57402c')
  metal = material('Clothing simple buckles', '#b6aea0')
  sole = material('Clothing boot soles', '#2f2923')
  surface = source
  surfaces = []
  if spec['category'] == 'Chest':
    sleeve, hem = spec['sleeve'], spec['hem']
    surface = clip(surface, lambda p: p.z - 1.220)
    surface = clip(surface, lambda p: max(sleeve - abs(p.x), 1.56 - p.z))
    surface = clip(surface, lambda p: neckline(p, spec['neck']))
    surface = hemExtrusion(surface, 1.220, hem, sourceWeights(source),
                            spec.get('slit', False))
    if spec.get('opening'):
      surface = clip(surface, lambda p: max(abs(p.x) - .014, p.y + .08))
    if number == 1:
      surface = clip(surface, lambda p: max(p.z - hem - .055,
                                            .305 - abs(p.x)))
    surface = offset(surface, .044)
    surfaces.append((surface, 0))
    if number == 2:
      surfaces.append((band(surface, [lambda p: hem + .070 - p.z]), 1))
      surfaces.append((band(surface, [lambda p: .020 - neckline(p, 'round'),
                                      lambda p: .205 - abs(p.x)]), 1))
    if spec.get('cuff'):
      surfaces.append((band(surface, [lambda p: abs(p.x) - sleeve + .075], .013), 1))
    if spec.get('belt'):
      belt = band(surface, [lambda p: p.z - 1.248,
                            lambda p: 1.312 - p.z], .008)
      surfaces.append((belt, 2))
      surfaces.append((buckle(belt, 1.280), 3))
    if spec.get('opening'):
      for height in [1.620, 1.385]:
        strap = band(surface, [lambda p, z=height: p.z - z + .018,
                               lambda p, z=height: z + .018 - p.z,
                               lambda p: p.x + .085,
                               lambda p: .085 - p.x,
                               lambda p: -p.y - .08], .009)
        surfaces.append((strap, 2))
        surfaces.append((buckle(strap, height, .044, .030), 3))
    if spec.get('wrap'):
      surfaces.append((band(surface, [lambda p: -p.y - .05,
        lambda p: p.z - 1.425,
        lambda p: p.x - (.17 - (1.89 - p.z) * .85) + .016,
        lambda p: .016 - p.x + (.17 - (1.89 - p.z) * .85)]), 1))
  elif spec['category'] == 'Leg':
    hem, loose = spec['hem'], spec['loose']
    surface = clip(surface, lambda p: 1.255 - p.z)
    surface = clip(surface, lambda p: p.z - hem)
    shaped = []
    for face in surface:
      polygon = []
      for point, normal, weights in face:
        extra = loose * max(0, min(1, (1.10 - point.z) / .20))
        if number == 10:
          extra *= min(1, max(0, (point.z - hem - .04) / .09))
        amount = .024 + extra
        polygon.append((point + normal * amount, normal, weights))
      shaped.append(polygon)
    surface = shaped
    surfaces.append((surface, 0))
    surfaces.append((band(surface, [lambda p: p.z - 1.215]), 0))
    if spec.get('cuff'):
      depth = .145 if number == 12 else .075
      surfaces.append((band(surface, [lambda p: hem + depth - p.z],
                            .012 if number != 10 else .004), 1))
  else:
    top = spec['top']
    surface = clip(surface, lambda p: top - p.z)
    shaped = []
    for face in surface:
      polygon = []
      for point, normal, weights in face:
        target = point + normal * .043
        target.z = max(.006, target.z)
        polygon.append((target, normal, weights))
      shaped.append(polygon)
    surface = shaped
    surfaces.append((clip(surface, lambda p: p.z - .055), 0))
    surfaces.append((clip(surface, lambda p: .055 - p.z), 4))
    if spec.get('cuff'):
      surfaces.append((band(surface, [lambda p: p.z - top + .120], .035), 1))
    if spec.get('strap'):
      surfaces.append((band(surface, [lambda p: p.z - .127,
                                      lambda p: .187 - p.z,
                                      lambda p: -p.y - .04], .011), 2))
    if spec.get('toe'):
      surfaces.append((band(surface, [lambda p: -p.y - .135,
                                      lambda p: p.z - .056], .002), 1))
  item = meshObject(collection, nodeName(spec), surfaces,
                    [main, trim, leather, metal, sole])
  data = bmesh.new()
  data.from_mesh(item.data)
  bmesh.ops.remove_doubles(data, verts=list(data.verts), dist=.00002)
  bmesh.ops.dissolve_degenerate(data, edges=list(data.edges), dist=.000001)
  bmesh.ops.recalc_face_normals(data, faces=list(data.faces))
  data.to_mesh(item.data)
  data.free()
  bpy.context.view_layer.objects.active = item
  thickness = item.modifiers.new('Extruded garment edge thickness', 'SOLIDIFY')
  thickness.thickness = .007
  thickness.offset = -1
  thickness.use_even_offset = False
  bpy.ops.object.modifier_apply(modifier=thickness.name)
  item['derivedFrom'] = 'Body' if spec['category'] != 'Foot' else 'Body + Foot.Left + Foot.Right'
  item['clothingNumber'] = number
  item['construction'] = 'Copied body faces, interpolated source weights, outward shell extrusion'
  return item


def buildClothes(collection, bodyParts):
  """Build all sixteen designs from the supplied actual body mesh parts."""
  source = {item.name: item for item in bodyParts}
  body = bodySurface([source['Body']])
  feet = bodySurface([source['Body'], source['Foot.Left'], source['Foot.Right']])
  result = []
  for spec in Specs:
    name = nodeName(spec)
    for old in list(bpy.data.objects):
      if old.name == name or old.name.startswith(name + '_'):
        bpy.data.objects.remove(old, do_unlink=True)
    item = shell(collection, spec, feet if spec['category'] == 'Foot' else body)
    if spec['category'] == 'Leg':
      result.extend(splitTrousers(collection, item))
    else:
      result.append(item)
  return result


def clothingParts():
  """Describe modular items and the bare feet replaced by boot geometry."""
  result = []
  for spec in Specs:
    name = nodeName(spec)
    names = sorted(item.name for item in bpy.data.objects if item.type == 'MESH'
                    and (item.name == name or item.name.startswith(name + '_')))
    hidden = []
    if spec['category'] == 'Foot':
      hidden = ['Foot.Left', 'Foot.Right']
      for index, height in enumerate(BootCuts):
        if height <= spec['top'] - .014:
          hidden += [f'Clothing_{number:02}_BootCut{index}' for number in range(9, 13)]
    result.append((spec['category'], {
      'name': label(spec), 'nodes': names, 'alignment': 'both',
      'hides': hidden, 'singleFile': True,
    }))
  return result
