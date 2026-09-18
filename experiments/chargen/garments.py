"""Extend the existing fitted clothes into simple modular gnome outfits."""

import math

import bmesh
import bpy
from mathutils import Vector
from mathutils.bvhtree import BVHTree

from clothes import (band, bodySurface, buckle, clip, hemExtrusion,
                     material, meshObject, offset, sourceWeights)

Folders = {'Jacket': 'clothing/jackets', 'Belt': 'clothing/belts',
           'Suspenders': 'clothing/suspenders', 'Leg': 'clothing/pants',
           'Chest': 'clothing/torsos'}
Specs = [
  ('Chest', 'Gnome tucked shirt', 'Gnome_Shirt'),
  ('Jacket', 'Gnome jacket', 'Gnome_Jacket'),
  ('Jacket', 'Gnome long coat', 'Gnome_Coat'),
  ('Jacket', 'Gnome vest', 'Gnome_Vest'),
  ('Leg', 'Gnome shorts', 'Gnome_Shorts'),
  ('Belt', 'Gnome buckle belt', 'Gnome_Belt'),
  ('Suspenders', 'Gnome suspenders', 'Gnome_Suspenders'),
  ('Suspenders', 'Gnome bib', 'Gnome_Bib'),
]


def exterior(items, body):
  """Read the existing outer fabric, excluding solidified linings and trim."""
  tree = BVHTree.FromPolygons([v.co for v in body.data.vertices],
                             [p.vertices[:] for p in body.data.polygons])
  result = []
  for item in items:
    for records, polygon in zip(bodySurface([item]), item.data.polygons):
      center = sum((record[0] for record in records), Vector()) / len(records)
      near, normal, index, distance = tree.find_nearest(center)
      if polygon.material_index == 0 and polygon.normal.dot(normal) > .15:
        result.append(records)
  assert result, 'Missing exterior fabric.'
  return result


def finish(collection, name, surfaces, palette, source):
  """Thicken an inherited fabric shell and preserve visible seam creases."""
  item = meshObject(collection, name, surfaces, palette)
  edit = bmesh.new()
  edit.from_mesh(item.data)
  bmesh.ops.remove_doubles(edit, verts=list(edit.verts), dist=.00001)
  bmesh.ops.dissolve_degenerate(edit, edges=list(edit.edges), dist=.000001)
  bmesh.ops.recalc_face_normals(edit, faces=list(edit.faces))
  for edge in edit.edges:
    edge.smooth = not (len(edge.link_faces) == 2 and
                       edge.calc_face_angle() > math.radians(45))
  edit.to_mesh(item.data)
  edit.free()
  bpy.context.view_layer.objects.active = item
  thickness = item.modifiers.new('Cloth edge thickness', 'SOLIDIFY')
  thickness.thickness = .006
  thickness.offset = -1
  bpy.ops.object.modifier_apply(modifier=thickness.name)
  item['derivedFrom'] = source
  item['construction'] = 'Existing outer fabric, offset and cut; inherited weights'
  return item


def button(surface, x, z, radius=.020):
  """Place a small raised octagonal button on the actual cloth surface."""
  candidates = [record for face in surface for record in face if record[0].y < 0]
  near = min(candidates, key=lambda r: (r[0].x - x) ** 2 + (r[0].z - z) ** 2)
  y = near[0].y - .018
  points = [Vector((x + math.cos(i * math.tau / 8) * radius, y,
                    z + math.sin(i * math.tau / 8) * radius)) for i in range(8)]
  return [[(point, Vector((0, -1, 0)), near[2]) for point in points]]


def opening(point):
  """Leave a shirt-width gap with a wider lapel and gently parted hem."""
  width = .102 + max(0, point.z - 1.48) * .22 + max(0, 1.24 - point.z) * .20
  return max(abs(point.x) - width, point.y + .035)


def jacket(collection, name, shirt, sample, kind, palette):
  """Extend the long-sleeved shirt into an open jacket, vest, or coat."""
  surface = clip(shirt, lambda p: p.z - 1.22)
  if kind == 'vest':
    surface = clip(surface, lambda p: max(.30 - abs(p.x), 1.53 - p.z))
  hem = .91 if kind == 'coat' else 1.025
  surface = hemExtrusion(surface, 1.22, hem, sample)
  surface = offset(surface, .038)
  surface = clip(surface, opening)
  surfaces = [(surface, 0)]
  lapels = band(surface, [lambda p: -p.y - .055,
                          lambda p: p.z - 1.53,
                          lambda p: .070 - opening(p)], .016)
  surfaces.append((lapels, 1))
  surfaces.append((band(surface, [lambda p: hem + .030 - p.z], .003), 1))
  if kind != 'vest':
    surfaces.append((band(surface, [lambda p: abs(p.x) - .83], .012), 1))
  for sign in [-1, 1]:
    pocket = band(surface, [lambda p: -p.y - .07,
      lambda p, s=sign: s * p.x - .16,
      lambda p, s=sign: .28 - s * p.x,
      lambda p: p.z - 1.10, lambda p: 1.235 - p.z], .012)
    surfaces.append((pocket, 0))
    surfaces.append((band(pocket, [lambda p: p.z - 1.208], .006), 1))
  for z in [1.44, 1.27, 1.10]:
    surfaces.append((button(surface, .145, z), 2))
  return finish(collection, name, surfaces, palette, 'Clothing_07')


def shorts(collection, trousers, palette):
  """Shorten existing trousers, adding loose thighs and a turned-up hem."""
  surface = clip(trousers, lambda p: p.z - .56)
  surface = offset(surface, .025)
  surfaces = [(surface, 0),
              (band(surface, [lambda p: .64 - p.z], .022), 1),
              (band(surface, [lambda p: p.z - 1.20], .008), 1)]
  return finish(collection, 'Gnome_Shorts', surfaces, palette, 'Clothing_09')


def belt(collection, body, palette):
  """Wrap a separate broad leather belt and hollow brass buckle at the waist."""
  surface = band(body, [lambda p: p.z - 1.255,
                        lambda p: 1.355 - p.z], .108)
  surfaces = [(surface, 0), (buckle(surface, 1.305, .16, .13, .016), 2)]
  return finish(collection, 'Gnome_Belt', surfaces, palette, 'Clothing_05 belt')


def suspenders(collection, shirt, body, palette, bib=False):
  """Cut wide shoulder straps from the shirt, with an optional overall bib."""
  surface = band(shirt, [lambda p: p.z - (1.29 if bib else 1.245),
    lambda p: .046 - abs(abs(p.x) - .185)], .027)
  if bib:
    surface = clip(surface, lambda p: max(p.y + .055, p.z - 1.57))
  surfaces = [(surface, 0)]
  if bib:
    surfaces.append((band(body, [lambda p: p.z - 1.215,
                                 lambda p: 1.30 - p.z], .073), 0))
    front = band(shirt, [lambda p: -p.y - .06,
      lambda p: .232 - abs(p.x), lambda p: p.z - 1.29,
      lambda p: 1.57 - p.z], .027)
    surfaces.append((front, 0))
    pocket = band(front, [lambda p: .125 - abs(p.x),
      lambda p: p.z - 1.315, lambda p: 1.465 - p.z], .008)
    surfaces += [(pocket, 0), (band(pocket, [lambda p: p.z - 1.44], .004), 1)]
  for sign in [-1, 1]:
    surfaces.append((button(surface, sign * .185, 1.555 if bib else 1.32), 2))
  return finish(collection, 'Gnome_Bib' if bib else 'Gnome_Suspenders',
                 surfaces, palette, 'Clothing_07')


def buildGarments(collection):
  """Reuse the existing fitted garments while retaining their shared rig."""
  for category, label, name in Specs:
    old = bpy.data.objects.get(name)
    if old:
      bpy.data.objects.remove(old, do_unlink=True)
  body = bpy.data.objects['Body']
  shirt = exterior([bpy.data.objects['Clothing_07']], body)
  trousers = exterior([item for item in bpy.data.objects
                        if item.name == 'Clothing_09' or
                        item.name.startswith('Clothing_09_BootCut')], body)
  source = bodySurface([body])
  sample = sourceWeights(source)
  brass = material('Gnome clothing brass', '#dca643')
  def palette(name, color):
    """Keep fabric, raised fabric edges, and fixed brass independently tagged."""
    return [material(name + ' fabric', color),
            material(name + ' edging', color, 1.14), brass]
  result = []
  tucked = clip(shirt, lambda p: p.z - 1.265)
  result.append(finish(collection, 'Gnome_Shirt', [
    (tucked, 0), (band(tucked, [lambda p: abs(p.x) - .83], .012), 1)],
    palette('Gnome_Shirt', '#e6d8b7'), 'Clothing_07'))
  for name, kind in [('Gnome_Jacket', 'jacket'), ('Gnome_Coat', 'coat'),
                      ('Gnome_Vest', 'vest')]:
    result.append(jacket(collection, name, shirt, sample, kind,
                          palette(name, '#527535')))
  result.append(shorts(collection, trousers, palette('Gnome_Shorts', '#746044')))
  result.append(belt(collection, source, palette('Gnome_Belt', '#66432c')))
  result.append(suspenders(collection, shirt, source, palette('Gnome_Suspenders', '#67442c')))
  result.append(suspenders(collection, shirt, source, palette('Gnome_Bib', '#405632'), True))
  return result


def garmentParts():
  """Expose independently swappable outerwear, legwear, and waist accessories."""
  return [(category, dict(name=label, nodes=[name], alignment='both',
                          hides=[], singleFile=True))
          for category, label, name in Specs]


def outfitPresets(presets):
  """Dress the nine existing gnomes using shared shapes and fabric colors."""
  cream, blue, orange = '#e6d8b7', '#376eaa', '#c55c20'
  green, brown, dark = '#4c702f', '#67432c', '#38383d'
  outfits = [
    ('Gnome jacket', green, cream, '11 Tan knee breeches', '#ac9168', 'None'),
    ('Gnome vest', brown, orange, '09 Brown trousers', dark, 'None'),
    ('None', green, cream, '09 Brown trousers', '#405632', 'Gnome bib'),
    ('Gnome vest', '#93663f', cream, 'Gnome shorts', '#626b31', 'None'),
    ('Gnome long coat', '#858792', blue, '09 Brown trousers', dark, 'None'),
    ('Gnome jacket', '#703198', '#71369c', '09 Brown trousers', '#433647', 'None'),
    ('Gnome jacket', blue, cream, '09 Brown trousers', brown, 'None'),
    ('Gnome jacket', '#b45464', cream, '11 Tan knee breeches', '#be902f', 'None'),
    ('Gnome vest', green, '#ce982d', 'Gnome shorts', brown, 'Gnome suspenders'),
  ]
  index = 0
  for preset in presets:
    if preset.get('group') != 'Gnomes':
      continue
    jacketName, jacketColor, shirtColor, pants, pantsColor, straps = outfits[index]
    changes = [('Chest', 'Gnome tucked shirt' if index in [2, 8]
                 else '07 Blue linen shirt', shirtColor),
               ('Jacket', jacketName, jacketColor), ('Leg', pants, pantsColor),
               ('Foot', '16 Folded travel boots', brown),
               ('Belt', 'None' if index == 2 else 'Gnome buckle belt', brown),
               ('Suspenders', straps, '#405632' if index == 2 else brown)]
    keys = {category for category, name, color in changes}
    preset['parts'] = [p for p in preset['parts'] if p['category'] not in keys]
    for category, name, color in changes:
      rgb = [int(color[i:i + 2], 16) / 255 for i in (1, 3, 5)]
      preset['parts'].append(dict(category=category, item=name, rgb=rgb))
    index += 1
  return presets
