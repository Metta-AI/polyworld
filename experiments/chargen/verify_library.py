"""Verify split meshes and animation keys against the assembled Blender export."""

import json

import glbs
from export_library import Library, Preview
from pack import inventory


def payload(document, binary, index):
  """Extract dense accessor elements without their optional interleaved padding."""
  accessor = document['accessors'][index]
  assert 'sparse' not in accessor
  width = {'SCALAR': 1, 'VEC2': 2, 'VEC3': 3, 'VEC4': 4, 'MAT4': 16}[accessor['type']]
  size = {5120: 1, 5121: 1, 5122: 2, 5123: 2, 5125: 4, 5126: 4}[accessor['componentType']] * width
  view = document['bufferViews'][accessor['bufferView']]
  offset = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
  stride = view.get('byteStride', size)
  return b''.join(binary[offset + i * stride:offset + i * stride + size]
                  for i in range(accessor['count']))


def channels(document, binary, clip):
  """Identify animation tracks by joint names instead of local node indices."""
  result = {}
  for channel in clip['channels']:
    target = channel['target']
    sampler = clip['samplers'][channel['sampler']]
    result[(document['nodes'][target['node']]['name'], target['path'])] = (
      sampler.get('interpolation', 'LINEAR'),
      payload(document, binary, sampler['input']),
      payload(document, binary, sampler['output']))
  return result


def main():
  """Check geometry, normals, weights, bind matrices, and clips byte for byte."""
  manifest = json.loads((Library / 'manifest.json').read_text())
  source, sourceBytes = glbs.read(Preview / 'character.glb')
  originals = {node['name']: node for node in source['nodes'] if 'mesh' in node}
  checked, files = set(), set()
  for _, _, item in inventory(Library, manifest).values():
    for path in item['files']:
      if path in files:
        continue
      files.add(path)
      document, binary = glbs.read(Library / path)
      assert not document.get('animations')
      for node in document['nodes']:
        if 'mesh' not in node:
          continue
        original = originals[node['name']]
        checked.add(node['name'])
        for field in ['matrix', 'translation', 'rotation', 'scale']:
          assert node.get(field) == original.get(field), (path, field)
        first = document['meshes'][node['mesh']]['primitives']
        second = source['meshes'][original['mesh']]['primitives']
        assert len(first) == len(second)
        for part, whole in zip(first, second):
          assert payload(document, binary, part['indices']) == payload(source, sourceBytes, whole['indices'])
          assert part['attributes'].keys() == whole['attributes'].keys()
          for key, index in part['attributes'].items():
            if key == 'TEXCOORD_0' and item.get('texture'):
              continue
            assert payload(document, binary, index) == payload(source, sourceBytes, whole['attributes'][key]), (path, key)
        skin, oldSkin = document['skins'][node['skin']], source['skins'][original['skin']]
        assert [document['nodes'][i]['name'] for i in skin['joints']] == [source['nodes'][i]['name'] for i in oldSkin['joints']]
        assert payload(document, binary, skin['inverseBindMatrices']) == payload(source, sourceBytes, oldSkin['inverseBindMatrices'])
  assert checked == originals.keys()
  originals = {clip['name']: clip for clip in source['animations']}
  for clip in manifest['clips']:
    document, binary = glbs.read(Library / clip['file'])
    assert not document.get('meshes')
    assert len(document['animations']) == 1
    assert channels(document, binary, document['animations'][0]) == channels(source, sourceBytes, originals[clip['name']])
  print('VERIFIED', len(checked), 'split meshes and', len(manifest['clips']), 'clips match the assembled export.')


if __name__ == '__main__':
  main()
