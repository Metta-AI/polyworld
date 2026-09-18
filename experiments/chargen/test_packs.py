"""Check selected exports, exact atlas pixels, and extensible part discovery."""

import argparse
import json
import subprocess
import tempfile
from pathlib import Path

from PIL import Image

import glbs
from export_library import Library, Root, saveJson
from pack import inventory, packLibrary


def checkPack(output, selected, report):
  """Verify the pack contains only selected runtime data and exact image crops."""
  manifest = json.loads((output / 'manifest.json').read_text())
  items = inventory(output, manifest)
  assert set(items) == set(selected)
  assert not (output / 'source').exists()
  assert len(list((output / 'animations').rglob('*.glb'))) == report['clips']
  expected = {clip['file'] for clip in manifest['clips']} | {manifest['rig']}
  for _, _, item in items.values():
    expected.update(item['files'])
    original = json.loads((Library / (item['id'] + '.json')).read_text())
    assert item.get('alignment', 'both') == original.get('alignment', 'both')
  assert {str(path.relative_to(output)) for path in output.rglob('*.glb')} == expected
  for atlas in report['atlases']:
    art = Image.open(output / atlas['art']).convert('RGBA')
    mask = Image.open(output / atlas['mask']).convert('RGBA') if atlas['mask'] else None
    for part in atlas['parts']:
      source = json.loads((Library / (part['id'] + '.json')).read_text())
      original = Image.open(Library / source['texture']).convert('RGBA')
      assert art.crop(part['rect']).tobytes() == original.tobytes()
      if source.get('pupilMask'):
        originalMask = Image.open(Library / source['pupilMask']).convert('RGBA')
        assert mask.crop(part['rect']).tobytes() == originalMask.tobytes()
      if mask is not None and not source.get('pupilMask'):
        assert mask.crop(part['rect']).getchannel('R').getextrema() == (0, 0)
      item = items[part['id']][2]
      for filename in item['files']:
        document, binary = glbs.read(output / filename)
        for image in document['images']:
          assert (output / filename).parent.joinpath(image['uri']).resolve().is_file()
  return manifest


def main():
  """Exercise full and minimal packs, including a newly discovered torso."""
  parser = argparse.ArgumentParser(description=__doc__)
  parser.add_argument('--runtime-tests', type=Path)
  args = parser.parse_args()
  selected = ['body/base', 'heads/base', 'eyes/02_focused', 'eyes/04_calm',
              'eyes/06_fierce', 'eyes/original2', 'mouths/01_relaxed_smile',
              'eyebrows/01_soft_arch', 'hair/01_french_crop', 'noses/tiny',
              'eyes/monster_07_cursed_goat', 'eyes/monster_15_pirate',
              'mouths/evil_05_sewn_shut', 'mouths/evil_10_orc_roar',
              'mouths/evil_15_vampire_hiss']
  with tempfile.TemporaryDirectory(prefix='packs-', dir=Root / 'tmp/chargen') as directory:
    output = Path(directory) / 'game'
    report = packLibrary(Library, output, selected, ['Idle', 'Walk', 'JumpStart'])
    manifest = checkPack(output, selected, report)
    assert {clip['name'] for clip in manifest['clips']} == {'Idle', 'Walk', 'JumpStart', 'JumpAir'}
    assert len(report['atlases']) == 3
    if args.runtime_tests:
      subprocess.run([str(args.runtime_tests.resolve()), str(output)], check=True)
    universal = Path(directory) / 'universal'
    report = packLibrary(Library, universal, selected,
                         ['Walk_Loop', 'Jump_Start', 'Death01'])
    universalManifest = checkPack(universal, selected, report)
    assert universalManifest['defaultAnimation'] == 'Walk_Loop'
    assert {clip['name'] for clip in universalManifest['clips']} == {
      'Walk_Loop', 'Jump_Start', 'Jump_Loop', 'Death01'}
    assert next(clip for clip in universalManifest['clips']
                if clip['name'] == 'Death01')['hold']
    if args.runtime_tests:
      subprocess.run([str(args.runtime_tests.resolve()), str(universal)], check=True)
    clothing = Path(directory) / 'clothing'
    outfit = ['body/base', 'heads/base', 'clothing/torsos/05_belted_ochre_tunic',
              'clothing/pants/10_loose_blue_breeches',
              'clothing/boots/14_tan_cuff_boots']
    report = packLibrary(Library, clothing, outfit, ['Walk_Loop'])
    checkPack(clothing, outfit, report)
    assert len(list((clothing / 'clothing').rglob('*.glb'))) == 3
    trousers = json.loads((clothing / 'clothing/pants/10_loose_blue_breeches.json').read_text())
    boots = json.loads((clothing / 'clothing/boots/14_tan_cuff_boots.json').read_text())
    assert len(trousers['files']) == 1 and len(trousers['nodes']) == 5
    assert set(trousers['nodes']) & set(boots['hides'])
    if args.runtime_tests:
      subprocess.run([str(args.runtime_tests.resolve()), str(clothing)], check=True)
    # A future torso can be added without changing the compiled inventory.
    document, binary = glbs.read(Library / 'body/body.glb')
    for node in document['nodes']:
      if 'mesh' in node:
        node['name'] = 'TestTorso'
    glbs.write(output / 'clothing/torsos/test.glb', document, binary)
    saveJson(output / 'clothing/torsos/test.json', {
      'id': 'clothing/torsos/test', 'name': 'Test shirt', 'nodes': ['TestTorso'],
      'files': ['clothing/torsos/test.glb'], 'hides': ['Body'],
    })
    if args.runtime_tests:
      subprocess.run([str(args.runtime_tests.resolve()), str(output)], check=True)
    minimal = Path(directory) / 'minimal'
    report = packLibrary(Library, minimal, ['body/base', 'heads/base'], [], False)
    checkPack(minimal, ['body/base', 'heads/base'], report)
    if args.runtime_tests:
      subprocess.run([str(args.runtime_tests.resolve()), str(minimal)], check=True)
    for parts, clips in [(['missing'], []), (['body/base'], ['Missing'])]:
      try:
        packLibrary(Library, Path(directory) / 'invalid', parts, clips)
      except ValueError:
        pass
      else:
        raise AssertionError('Invalid selection accepted.')
    try:
      packLibrary(Library, output, selected, [])
    except ValueError:
      pass
    else:
      raise AssertionError('Existing output was overwritten.')
  print('Pack tests passed: selected assets, atlas pixels, clip chains, new torsos.')


if __name__ == '__main__':
  main()
