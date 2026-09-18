"""Read, subset, and remap binary glTF assets without changing skin data."""

import copy
import json
import struct


def read(path):
  """Read the JSON and optional binary chunks of a local GLB."""
  data = path.read_bytes()
  magic, version, size = struct.unpack_from('<III', data)
  assert magic == 0x46546C67 and version == 2 and size == len(data), path
  document, binary, offset = None, b'', 12
  while offset < len(data):
    length, kind = struct.unpack_from('<II', data, offset)
    chunk = data[offset + 8:offset + 8 + length]
    if kind == 0x4E4F534A:
      document = json.loads(chunk)
    elif kind == 0x004E4942:
      binary = chunk
    offset += 8 + length
  return document, binary


def write(path, document, binary):
  """Write aligned glTF chunks with no implicit external binary files."""
  document = copy.deepcopy(document)
  document['buffers'] = [{'byteLength': len(binary)}] if binary else []
  for key in ['accessors', 'animations', 'bufferViews', 'buffers', 'cameras',
              'images', 'materials', 'meshes', 'samplers', 'skins', 'textures']:
    if key in document and not document[key]:
      del document[key]
  encoded = json.dumps(document, separators=(',', ':')).encode()
  encoded += b' ' * (-len(encoded) % 4)
  binary += b'\0' * (-len(binary) % 4)
  chunks = struct.pack('<II', len(encoded), 0x4E4F534A) + encoded
  if binary:
    chunks += struct.pack('<II', len(binary), 0x004E4942) + binary
  path.parent.mkdir(parents=True, exist_ok=True)
  path.write_bytes(struct.pack('<III', 0x46546C67, 2, len(chunks) + 12) + chunks)


def subset(document, binary, meshes=(), clips=()):
  """Retain requested meshes and clips, their rig, and referenced data only."""
  doc = copy.deepcopy(document)
  nodes = doc['nodes']
  kept = {i for i, node in enumerate(nodes)
          if 'mesh' not in node or node.get('name') in meshes}
  parents = {child: i for i, node in enumerate(nodes)
             for child in node.get('children', [])}
  for index in list(kept):
    while index in parents:
      index = parents[index]
      kept.add(index)
  mapping = {old: new for new, old in enumerate(sorted(kept))}
  doc['nodes'] = [nodes[i] for i in sorted(kept)]
  for node in doc['nodes']:
    if 'children' in node:
      node['children'] = [mapping[i] for i in node['children'] if i in kept]
  for scene in doc['scenes']:
    scene['nodes'] = [mapping[i] for i in scene['nodes'] if i in kept]
  doc['animations'] = [clip for clip in doc.get('animations', [])
                       if clip['name'] in clips]
  for clip in doc['animations']:
    for channel in clip['channels']:
      channel['target']['node'] = mapping[channel['target']['node']]

  def compact(key, references):
    """Compact one indexed array and rewrite its explicit references."""
    indices = sorted({parent[field] for parent, field in references})
    remap = {old: new for new, old in enumerate(indices)}
    entries = doc.get(key, [])
    doc[key] = [entries[index] for index in indices]
    for parent, field in references:
      parent[field] = remap[parent[field]]

  compact('meshes', [(node, 'mesh') for node in doc['nodes'] if 'mesh' in node])
  compact('skins', [(node, 'skin') for node in doc['nodes'] if 'skin' in node])
  for skin in doc['skins']:
    skin['joints'] = [mapping[index] for index in skin['joints']]
    if 'skeleton' in skin:
      skin['skeleton'] = mapping[skin['skeleton']]
  primitives = [primitive for mesh in doc['meshes'] for primitive in mesh['primitives']]
  compact('materials', [(p, 'material') for p in primitives if 'material' in p])
  textureRefs = []

  def textures(value):
    """Collect texture slots in core and extension material properties."""
    if isinstance(value, dict):
      for key, child in value.items():
        if key.endswith('Texture') and isinstance(child, dict) and 'index' in child:
          textureRefs.append((child, 'index'))
        else:
          textures(child)

  for material in doc['materials']:
    textures(material)
  compact('textures', textureRefs)
  compact('images', [(texture, 'source') for texture in doc['textures']])
  compact('samplers', [(texture, 'sampler') for texture in doc['textures'] if 'sampler' in texture])
  refs = [(p, 'indices') for p in primitives if 'indices' in p]
  for primitive in primitives:
    for attributes in [primitive['attributes']] + primitive.get('targets', []):
      refs.extend((attributes, key) for key in attributes)
  refs.extend((skin, 'inverseBindMatrices') for skin in doc['skins'] if 'inverseBindMatrices' in skin)
  for clip in doc['animations']:
    for sampler in clip['samplers']:
      refs.extend([(sampler, 'input'), (sampler, 'output')])
  compact('accessors', refs)
  refs = [(accessor, 'bufferView') for accessor in doc['accessors'] if 'bufferView' in accessor]
  for accessor in doc['accessors']:
    if 'sparse' in accessor:
      refs.extend((accessor['sparse'][key], 'bufferView') for key in ['indices', 'values'])
  refs.extend((image, 'bufferView') for image in doc['images'] if 'bufferView' in image)
  compact('bufferViews', refs)
  packed = bytearray()
  for view in doc['bufferViews']:
    assert view['buffer'] == 0
    packed.extend(b'\0' * (-len(packed) % 4))
    offset = view.get('byteOffset', 0)
    content = binary[offset:offset + view['byteLength']]
    assert len(content) == view['byteLength']
    view['byteOffset'] = len(packed)
    packed.extend(content)
  return doc, bytes(packed)


def remapUvs(document, binary, transform):
  """Transform each UV accessor once while preserving every other attribute."""
  data, seen = bytearray(binary), set()
  for mesh in document.get('meshes', []):
    for primitive in mesh['primitives']:
      index = primitive['attributes'].get('TEXCOORD_0')
      if index is None or index in seen:
        continue
      seen.add(index)
      accessor = document['accessors'][index]
      assert accessor['componentType'] == 5126 and accessor['type'] == 'VEC2'
      view = document['bufferViews'][accessor['bufferView']]
      start = view.get('byteOffset', 0) + accessor.get('byteOffset', 0)
      values = []
      for i in range(accessor['count']):
        offset = start + i * view.get('byteStride', 8)
        value = transform(*struct.unpack_from('<ff', data, offset))
        struct.pack_into('<ff', data, offset, *value)
        values.append(value)
      for key, function in [('min', min), ('max', max)]:
        if key in accessor:
          accessor[key] = [function(value[i] for value in values) for i in range(2)]
  return bytes(data)
