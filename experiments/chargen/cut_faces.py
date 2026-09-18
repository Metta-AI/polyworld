"""Cut approved monster face sheets into independently shippable textures."""

import json
import subprocess
from collections import deque
from pathlib import Path

from PIL import Image

from export_library import Library, Preview, Source, saveJson, slug

Sheets = [
  ('Eyes', 'eyes', 'monster_v1', 'Monster', [
    'Stalking cat', 'Feral cat', 'Hooded lizard', 'Dragon',
    'Viper', 'Crocodile', 'Cursed goat', 'Deep sea',
    'Demon', 'Possessed', 'Undead', 'Shadow wraith',
    None, 'Berserk beast', 'Pirate', 'Reptile raider']),
  ('Mouth', 'mouths', 'evil_v1', 'Evil', [
    'Villain smirk', 'Hard scowl', 'Cruel grin', 'Cackle',
    'Sewn shut', 'Stitched smile', 'Broken teeth', 'Undead snarl',
    'Orc sneer', 'Orc roar', 'Goblin grin', 'Beast maw',
    'Vampire smirk', 'Vampire grin', 'Vampire hiss', 'Demon grin']),
]


def components(width, height, pixels, predicate, minimum=1):
  """Find connected artwork regions and their pixel coordinates."""
  pending = bytearray(predicate(pixel) for pixel in pixels)
  result = []
  for start in range(len(pending)):
    if not pending[start]:
      continue
    queue, points = deque([start]), []
    pending[start] = 0
    while queue:
      index = queue.popleft()
      x, y = index % width, index // width
      points.append((x, y))
      for neighbor in [index - 1 if x else -1,
                       index + 1 if x + 1 < width else -1,
                       index - width if y else -1,
                       index + width if y + 1 < height else -1]:
        if neighbor >= 0 and pending[neighbor]:
          pending[neighbor] = 0
          queue.append(neighbor)
    if len(points) >= minimum:
      result.append(points)
  return result


def bounds(points):
  """Measure pixel bounds with exclusive right and bottom edges."""
  return [min(x for x, y in points), min(y for x, y in points),
          max(x for x, y in points) + 1, max(y for x, y in points) + 1]


def cross(a, b, c):
  """Measure orientation of three points for the convex iris boundary."""
  return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])


def hull(points):
  """Enclose gray iris facets without selecting disconnected dark eyelids."""
  points = sorted(set(points))
  lower, upper = [], []
  for point in points:
    while len(lower) > 1 and cross(lower[-2], lower[-1], point) <= 0:
      lower.pop()
    lower.append(point)
  for point in reversed(points):
    while len(upper) > 1 and cross(upper[-2], upper[-1], point) <= 0:
      upper.pop()
    upper.append(point)
  return lower[:-1] + upper[:-1]


def irisMask(image, groups, patch, output):
  """Build linear tint data while protecting sclera, highlights, and patches."""
  width, height = image.size
  pixels = list(image.getdata())
  mask = bytearray(width * height)
  regions = []
  for eye in groups[:1] if patch else groups:
    rectangle = bounds(eye)
    left, top, right, bottom = rectangle
    points = []
    # Dark upper accents and eyepatches are outside the iris value range.
    local = image.crop(rectangle)
    gray = components(local.width, local.height, list(local.getdata()),
      lambda p: p[3] >= 128 and 60 <= min(p[:3]) <= 225 and
      max(p[:3]) - min(p[:3]) < 28, minimum=24)
    minimum = max((len(group) for group in gray), default=0) * .1
    for group in gray:
      if len(group) >= minimum:
        points.extend((x + left, y + top) for x, y in group)
    if len(points) < 20:
      raise ValueError('No tintable iris found: ' + str(output))
    polygon = hull(points)
    regions.append(bounds(points))
    for y in range(top, bottom):
      for x in range(left, right):
        r, g, b, alpha = pixels[y * width + x]
        if alpha < 128 or max(r, g, b) >= 236:
          continue
        if all(cross(polygon[i - 1], polygon[i], (x, y)) >= 0
               for i in range(len(polygon))):
          mask[y * width + x] = 255
  scratch = Preview / 'faces/iris.pgm'
  scratch.parent.mkdir(parents=True, exist_ok=True)
  scratch.write_bytes(f'P5\n{width} {height}\n255\n'.encode() + mask)
  subprocess.run(['magick', str(scratch), str(output)], check=True)
  return regions


def cutSheets():
  """Normalize export alpha, cut sprites, and record their head projections."""
  facePath = Source / 'faces.json'
  faces = json.loads(facePath.read_text()) if facePath.exists() else []
  for category, folder, version, prefix, names in Sheets:
    directory = Source / folder / version
    clean = directory / 'transparent.png'
    # Match the game's cutout material while clearing subvisible matte noise.
    subprocess.run(['magick', str(directory / 'extracted.png'),
      '-channel', 'A', '-level', '8%,92%', '+channel', str(clean)], check=True)
    image = Image.open(clean).convert('RGBA')
    groups = components(image.width, image.height, list(image.getdata()),
                        lambda pixel: pixel[3] >= 128, minimum=100)
    perPart = 2 if category == 'Eyes' else 1
    if len(groups) != 16 * perPart:
      raise ValueError(f'Expected {16 * perPart} components, found {len(groups)}')
    groups.sort(key=lambda points: sum(y for x, y in points) / len(points))
    parts = []
    for row in range(4):
      line = groups[row * 4 * perPart:(row + 1) * 4 * perPart]
      line.sort(key=lambda points: sum(x for x, y in points) / len(points))
      for column in range(4):
        index = row * 4 + column + 1
        node = f'{category}_{prefix}{index:02}'
        faces = [face for face in faces if face['node'] != node]
        # Skip sheet cells that do not belong on the current character body.
        if names[index - 1] is None:
          continue
        name = f'{prefix} {index:02} {names[index - 1]}'
        pair = line[column * perPart:(column + 1) * perPart]
        left, top, right, bottom = bounds([point for eye in pair for point in eye])
        rectangle = [max(0, left - 4), max(0, top - 4),
                     min(image.width, right + 4), min(image.height, bottom + 4)]
        left, top, right, bottom = rectangle
        texture = folder + '/' + slug(name) + '.png'
        subprocess.run(['magick', str(clean), '-crop',
          f'{right-left}x{bottom-top}+{left}+{top}', '+repage',
          str(Library / texture)], check=True)
        override = directory / 'overrides' / (slug(name) + '.png')
        if override.exists():
          subprocess.run(['magick', str(override), '-channel', 'A',
            '-level', '8%,92%', '+channel', '-trim', '+repage',
            '-resize', f'{right-left-8}x', '-bordercolor', 'none',
            '-border', '4', str(Library / texture)], check=True)
        cut = Image.open(Library / texture).convert('RGBA')
        spec = {'category': category, 'name': name, 'node': node,
                'texture': texture, 'size': list(cut.size),
                'sourceRect': rectangle, 'source': str(clean.relative_to(Library))}
        if override.exists():
          spec['override'] = str(override.relative_to(Library))
        if category == 'Eyes':
          local = [[(x - left, y - top) for x, y in eye] for eye in pair]
          mask = folder + '/' + slug(name) + '.mask.png'
          spec['irisRects'] = irisMask(cut, local, index >= 15, Library / mask)
          spec['pupilMask'] = mask
          whites = [(x, y) for y in range(cut.height) for x in range(cut.width)
                    if cut.getpixel((x, y))[3] >= 128 and
                    min(cut.getpixel((x, y))[:3]) >= 220]
          spec['scleraRect'] = bounds(whites)
        faces.append(spec)
        parts.append(spec)
    saveJson(directory / 'cuts.json', {'size': list(image.size), 'parts': parts})
    print('CUT', len(parts), category, 'textures')
  saveJson(facePath, faces)


if __name__ == '__main__':
  cutSheets()
