"""Export separately shippable character parts, textures, and animation clips."""

import json
import re
import shutil
from pathlib import Path

from PIL import Image

import glbs

Experiment = Path(__file__).resolve().parent
Root = Experiment.parents[1]
Library = Root.parent / 'polyworld_data/characters/chargen'
Source = Library / 'source'
Preview = Root / 'tmp/chargen'
Folders = {
  'Body': 'body', 'Face': 'heads', 'Eyes': 'eyes', 'Mouth': 'mouths',
  'Nose': 'noses', 'Ears': 'ears', 'Brow': 'eyebrows', 'Hair': 'hair',
  'Beard': 'beards', 'Earring': 'earrings', 'Eyewear': 'eyewear',
  'Headgear': 'hats', 'Chest': 'clothing/torsos', 'Back': 'clothing/backs',
  'Hand': 'clothing/gloves', 'Leg': 'clothing/pants', 'Foot': 'clothing/boots',
  'Left hand': 'props/left', 'Right hand': 'props/right',
}


def slug(value):
  """Make stable lowercase file names from human-readable labels."""
  return re.sub(r'[^a-z0-9]+', '_', value.lower()).strip('_')


def saveJson(path, value):
  """Write readable asset metadata next to its corresponding files."""
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_text(json.dumps(value, indent=2) + '\n')


def exportLibrary():
  """Split a freshly built authoring export without duplicating animations."""
  Library.mkdir(parents=True, exist_ok=True)
  manifest = json.loads((Source / 'manifest.json').read_text())
  document, binary = glbs.read(Preview / 'character.glb')
  rig, rigBytes = glbs.subset(document, binary)
  glbs.write(Library / 'rig/humanoid.glb', rig, rigBytes)
  model = json.loads((Source / 'model.json').read_text())
  saveJson(Library / 'rig/skeleton.json', {'skeleton': model['skeleton']})
  atlases = {}
  for category, folder, version in [('Eyes', 'eyes', 'generated_v2'),
                                    ('Mouth', 'mouths', 'generated_v1'),
                                    ('Brow', 'brows', 'generated_v1')]:
    directory = Source / folder / version
    atlas = json.loads((directory / 'atlas.json').read_text())
    atlases[category] = (atlas, Image.open(directory / atlas['art']).convert('RGBA'),
                        Image.open(directory / atlas['tintMask']).convert('RGBA')
                        if 'tintMask' in atlas else None)
  catalog = {
    'version': 2, 'rig': 'rig/humanoid.glb', 'skeleton': 'rig/skeleton.json',
    'skinPalette': 'colors/skin.json', 'hairPalette': 'colors/hair.json',
    'pupilPalette': 'colors/eyes.json', 'defaultSkin': manifest['defaultSkin'],
    'defaultHairColor': 'Chestnut', 'defaultPupilColor': 'Gray',
    'base': manifest['base'], 'categories': [], 'clips': [],
    'clipSource': manifest['clipSource'], 'presets': manifest['presets'],
    'defaultAnimation': manifest.get('defaultAnimation', 'Walk'),
  }
  if not (Library / 'colors/skin.json').exists():
    saveJson(Library / 'colors/skin.json', manifest['skins'])
  for category in manifest['categories']:
    folder = Folders[category['key']]
    (Library / folder).mkdir(parents=True, exist_ok=True)
    selected = category['selected']
    catalog['categories'].append({
      'key': category['key'], 'directory': folder,
      'defaultItem': category['items'][selected]['name'] if selected >= 0 else '',
    })
    for item in category['items']:
      identity = folder + '/' + slug(item['name'])
      metadataPath = Library / (identity + '.json')
      previous = json.loads(metadataPath.read_text()) if metadataPath.exists() else {}
      alignment = previous.get('alignment', item.get('alignment', 'both'))
      if alignment not in ['good', 'evil', 'both']:
        raise ValueError('Invalid part alignment: ' + identity)
      metadata = dict(item, id=identity, files=[],
                      alignment=alignment,
                      skinNodes=[name for name in item['nodes'] if name in manifest['skinNodes']],
                      hairShades=[shade for shade in manifest['hairShades'] if shade['node'] in item['nodes']])
      if category['key'] == 'Brow':
        metadata['tint'] = 'hair'
      crop, texture = None, None
      if len(item['nodes']) == 1:
        node = item['nodes'][0]
        if item.get('texture'):
          texture = item['texture']
          if not (Library / texture).is_file():
            raise FileNotFoundError('Missing face texture: ' + texture)
        elif category['key'] in atlases and '_Atlas' in node:
          atlas, art, mask = atlases[category['key']]
          cell = atlas['cells'][int(node.rsplit('Atlas', 1)[1]) - 1]
          left, top, right, bottom = cell['contentRect']
          crop = (left - 2, top - 2, right + 2, bottom + 2)
          texture = identity + '.png'
          art.crop(crop).save(Library / texture)
          if mask is not None:
            metadata['pupilMask'] = identity + '.mask.png'
            mask.crop(crop).save(Library / metadata['pupilMask'])
          metadata['texture'] = texture
        elif category['key'] == 'Eyes':
          texture = identity + '.png'
          shutil.copy2(Source / 'eyes' / (node.removeprefix('Eyes_') + '.png'), Library / texture)
          metadata['texture'] = texture
      for node in item['nodes']:
        filename = identity if len(item['nodes']) == 1 else folder + '/' + slug(node)
        part, partBytes = glbs.subset(document, binary, meshes=[node])
        if texture is not None:
          assert len(part['images']) == 1
          part['images'] = [{'uri': Path(texture).name}]
          if crop is not None:
            width, height = atlases[category['key']][0]['size']
            left, top, right, bottom = crop
            partBytes = glbs.remapUvs(part, partBytes, lambda u, v: (
              (u * width - left) / (right - left), (v * height - top) / (bottom - top)))
          part, partBytes = glbs.subset(part, partBytes, meshes=[node])
        path = filename + '.glb'
        glbs.write(Library / path, part, partBytes)
        metadata['files'].append(path)
      saveJson(metadataPath, metadata)
  for clip in manifest['clips']:
    folder = 'animations/universal/' if clip['kind'] == 'universal' else 'animations/'
    path = folder + slug(clip['name']) + '.glb'
    part, partBytes = glbs.subset(document, binary, clips=[clip['name']])
    glbs.write(Library / path, part, partBytes)
    catalog['clips'].append(dict(clip, file=path))
  previousPath = Library / 'manifest.json'
  if previousPath.exists():
    previous = json.loads(previousPath.read_text())
    for field in ['defaultSkin', 'skinPalette', 'hairPalette', 'pupilPalette',
                  'defaultHairColor', 'defaultPupilColor', 'base', 'presets']:
      if field in previous:
        catalog[field] = previous[field]
    known = {category['key'] for category in catalog['categories']}
    for category in previous['categories']:
      if category['key'] not in known:
        catalog['categories'].append(category)
      else:
        for current in catalog['categories']:
          if current['key'] == category['key']:
            current['defaultItem'] = category.get('defaultItem', '')
  for preset in catalog['presets']:
    mapping = {'Base': ('Idle', 'Idle_Loop'), 'Happy': ('Walk', 'Walk_Loop'),
               'Elf': ('Victory', 'Dance_Loop')}
    if preset['name'] in mapping:
      old, new = mapping[preset['name']]
      if preset['pose'] == old and any(clip['name'] == new for clip in catalog['clips']):
        preset['pose'] = new
  saveJson(Library / 'manifest.json', catalog)
  print('EXPORTED', len(model['meshes']), 'meshes and', len(catalog['clips']), 'clips to', Library)


if __name__ == '__main__':
  exportLibrary()
