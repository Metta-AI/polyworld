"""Pack selected character parts and build atlases from only their textures."""

import argparse
import copy
import json
import math
import os
import shutil
import tempfile
from pathlib import Path

from PIL import Image

import glbs
from export_library import Library, saveJson


def assetPath(directory, value):
  """Resolve a portable asset path inside its library."""
  path = (directory / value).resolve()
  if not path.is_relative_to(directory.resolve()):
    raise ValueError('Asset is outside the library: ' + value)
  return path


def inventory(source, manifest):
  """Discover part sidecars without a fixed count or compiled item list."""
  result = {}
  for category in manifest['categories']:
    folder = assetPath(source, category['directory'])
    for path in sorted(folder.glob('*.json')):
      item = json.loads(path.read_text())
      identity = item['id']
      if identity in result:
        raise ValueError('Duplicate part: ' + identity)
      result[identity] = (category['key'], path.relative_to(source), item)
  return result


def layout(images, padding=4):
  """Choose a compact power-of-two shelf layout with transparent gutters."""
  ordered = sorted(images, key=lambda key: (-images[key].height, key))
  minimum = max(image.width + 2 * padding for image in images.values())
  maximum = sum(image.width + 2 * padding for image in images.values())
  best = None
  width = 2 ** math.ceil(math.log2(minimum))
  while width < maximum * 2:
    x, y, rowHeight, positions = 0, 0, 0, {}
    for key in ordered:
      image = images[key]
      if x + image.width + 2 * padding > width:
        x, y, rowHeight = 0, y + rowHeight, 0
      positions[key] = (x + padding, y + padding)
      x += image.width + 2 * padding
      rowHeight = max(rowHeight, image.height + 2 * padding)
    height = 2 ** math.ceil(math.log2(y + rowHeight))
    score = (width * height, max(width, height), width)
    if best is None or score < best[0]:
      best = (score, (width, height), positions)
    width *= 2
  return best[1], best[2]


def makeAtlases(source, output, parts):
  """Pack chosen eye, mouth, and brow images, retaining exact RGBA pixels."""
  transforms, reports = {}, []
  for category, label in [('Eyes', 'eyes'), ('Mouth', 'mouths'),
                          ('Brow', 'eyebrows')]:
    items = [item for key, _, item in parts if key == category and item.get('texture')]
    if not items:
      continue
    images = {item['id']: Image.open(assetPath(source, item['texture'])).convert('RGBA')
              for item in items}
    size, positions = layout(images)
    art = Image.new('RGBA', size)
    mask = Image.new('RGBA', size, (0, 0, 0, 255))
    hasMask = any(item.get('pupilMask') for item in items)
    texturePath = 'atlases/' + label + '.png'
    maskPath = 'atlases/' + label + '.mask.png' if hasMask else ''
    entries = []
    for item in items:
      identity = item['id']
      image = images[identity]
      left, top = positions[identity]
      art.paste(image, (left, top))
      if item.get('pupilMask'):
        pupilMask = Image.open(assetPath(source, item['pupilMask'])).convert('RGBA')
        if pupilMask.size != image.size:
          raise ValueError('Eye mask size differs: ' + identity)
        mask.paste(pupilMask, (left, top))
      rectangle = (left, top, left + image.width, top + image.height)
      transforms[identity] = (size, rectangle, texturePath, maskPath)
      entries.append({'id': identity, 'rect': rectangle})
    (output / 'atlases').mkdir(exist_ok=True)
    art.save(output / texturePath)
    if hasMask:
      mask.save(output / maskPath)
    reports.append({'art': texturePath, 'mask': maskPath,
                    'size': size, 'parts': entries})
  return transforms, reports


def copyAsset(source, output, name):
  """Copy one runtime dependency while preserving its relative path."""
  path = assetPath(source, name)
  destination = output / path.relative_to(source)
  destination.parent.mkdir(parents=True, exist_ok=True)
  shutil.copy2(path, destination)


def copyModel(source, output, name, transform=None, texture=''):
  """Copy geometry and dependencies, remapping only a packed face surface."""
  path = assetPath(source, name)
  if path.suffix.lower() == '.glb':
    document, binary = glbs.read(path)
  else:
    if transform:
      raise ValueError('Atlas remapping requires GLB face meshes: ' + name)
    document = json.loads(path.read_text())
  if transform:
    size, (left, top, right, bottom), target, _ = transform
    imagePath = assetPath(source, texture)
    found = False
    for image in document.get('images', []):
      if image.get('uri') and (path.parent / image['uri']).resolve() == imagePath:
        image['uri'] = os.path.relpath(output / target, (output / name).parent)
        found = True
    if not found or len(document.get('images', [])) != 1:
      raise ValueError('Atlas face must have exactly its declared texture: ' + name)
    binary = glbs.remapUvs(document, binary, lambda u, v: (
      (left + u * (right - left)) / size[0],
      (top + v * (bottom - top)) / size[1]))
    glbs.write(output / name, document, binary)
  else:
    copyAsset(source, output, name)
  for entry in document.get('images', []) + document.get('buffers', []):
    uri = entry.get('uri', '')
    if not uri or uri.startswith('data:') or transform:
      continue
    dependency = (path.parent / uri).resolve()
    copyAsset(source, output, str(dependency.relative_to(source)))


def packLibrary(source, output, partIds=None, clipNames=None, atlas=True):
  """Write an independent game library without shipping unused source assets."""
  source, output = source.resolve(), output.resolve()
  if output.exists():
    raise ValueError('Output already exists; choose a new directory: ' + str(output))
  if source.is_relative_to(output) or output.is_relative_to(source):
    raise ValueError('Output must be separate from the source library.')
  manifest = json.loads((source / 'manifest.json').read_text())
  available = inventory(source, manifest)
  selected = set(available if partIds is None else partIds)
  unknown = selected - available.keys()
  if unknown:
    raise ValueError('Unknown parts: ' + ', '.join(sorted(unknown)))
  parts = [copy.deepcopy(available[key]) for key in sorted(selected)]
  clips = {clip['name']: clip for clip in manifest['clips']}
  wanted = set(clips if clipNames is None else clipNames)
  unknown = wanted - clips.keys()
  if unknown:
    raise ValueError('Unknown clips: ' + ', '.join(sorted(unknown)))
  # Include transitions such as JumpStart to JumpAir automatically.
  pending = list(wanted)
  while pending:
    following = clips[pending.pop()].get('next', '')
    if following and following not in wanted:
      if following not in clips:
        raise ValueError('Missing next animation: ' + following)
      wanted.add(following)
      pending.append(following)
  manifest['clips'] = [clip for clip in manifest['clips'] if clip['name'] in wanted]
  nodes = {node for _, _, item in parts for node in item['nodes']}
  manifest['base'] = [node for node in manifest.get('base', []) if node in nodes]
  categories = {}
  for category in manifest['categories']:
    names = [item['name'] for key, _, item in parts if key == category['key']]
    categories[category['key']] = names
    if category.get('defaultItem') and category['defaultItem'] not in names:
      category['defaultItem'] = names[0] if names else ''
  manifest['presets'] = [preset for preset in manifest.get('presets', [])
    if all(part['item'] == 'None' or part['item'] in categories.get(part['category'], [])
           for part in preset['parts'])]
  defaultClip = manifest.get('defaultAnimation', 'Walk')
  if defaultClip not in wanted:
    defaultClip = next(iter(manifest['clips']), {}).get('name', '')
  manifest['defaultAnimation'] = defaultClip
  for preset in manifest['presets']:
    if preset['pose'] not in wanted:
      preset['pose'] = defaultClip
  output.parent.mkdir(parents=True, exist_ok=True)
  with tempfile.TemporaryDirectory(prefix='.chargen-', dir=output.parent) as temporary:
    stage = Path(temporary) / 'library'
    stage.mkdir()
    transforms, atlases = makeAtlases(source, stage, parts) if atlas else ({}, [])
    fields = ['rig', 'skeleton', 'skinPalette', 'hairPalette', 'pupilPalette']
    if manifest.get('hatPalette'):
      fields.append('hatPalette')
    for field in fields:
      copyAsset(source, stage, manifest[field])
    for clip in manifest['clips']:
      copyModel(source, stage, clip['file'])
    copied = {}
    for _, metadataPath, item in parts:
      transform = transforms.get(item['id'])
      for filename in item['files']:
        if filename in copied:
          if copied[filename] != transform:
            raise ValueError('Shared mesh has conflicting atlases: ' + filename)
          continue
        copyModel(source, stage, filename, transform, item.get('texture', ''))
        copied[filename] = transform
      if transform:
        item['texture'] = transform[2]
        if transform[3]:
          item['pupilMask'] = transform[3]
      else:
        for field in ['texture', 'pupilMask']:
          if item.get(field):
            copyAsset(source, stage, item[field])
      saveJson(stage / metadataPath, item)
    saveJson(stage / 'manifest.json', manifest)
    report = {'parts': len(parts), 'meshes': len(copied),
              'clips': len(manifest['clips']), 'atlases': atlases}
    saveJson(stage / 'pack.json', report)
    stage.rename(output)
  return report


def main():
  """Expose inventory inspection and reproducible per-game asset selection."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--source', type=Path, default=Library)
  parser.add_argument('--output', type=Path)
  parser.add_argument('--parts', nargs='+', help='Part IDs from --list; default is all.')
  parser.add_argument('--clips', nargs='*', help='Clip names; default is all.')
  parser.add_argument('--no-atlas', action='store_true')
  parser.add_argument('--list', action='store_true')
  args = parser.parse_args()
  if args.list:
    manifest = json.loads((args.source / 'manifest.json').read_text())
    for identity, (category, _, item) in inventory(args.source, manifest).items():
      print(identity + '\t' + category + '\t' + item['name'])
    print('Clips: ' + ', '.join(clip['name'] for clip in manifest['clips']))
    return
  if args.output is None:
    parser.error('--output is required unless using --list')
  report = packLibrary(args.source, args.output, args.parts, args.clips, not args.no_atlas)
  print('PACKED', report['parts'], 'parts,', report['clips'], 'clips, and',
        len(report['atlases']), 'atlases into', args.output)


if __name__ == '__main__':
  main()
