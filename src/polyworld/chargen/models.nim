import
  std/[sets, tables],
  gltf, vmath,
  parts

proc readModel(directory, path: string): GltfFile =
  ## Wraps model loading errors with the offending library asset path.
  try:
    readGltfFile(directory.assetPath(path))
  except IOError, GltfError:
    raise newException(
      ChargenError, "Cannot load " & path & ": " & getCurrentExceptionMsg()
    )

proc rigNodes(root: Node): Table[string, Node] =
  ## Indexes the canonical skeleton used by every loaded component.
  for node in root.walkNodes:
    if node.mesh == nil:
      if node.name in result:
        raise newException(ChargenError, "Duplicate rig node: " & node.name)
      result[node.name] = node

proc attachPart*(root: Node, directory, path: string) =
  ## Attaches one GLB's meshes and rebinds its skin to the shared skeleton.
  let
    source = readModel(directory, path)
    joints = rigNodes(root)
  var
    existing = partNodes(root)
    parents: Table[string, string]
    attached: seq[tuple[parent, node: Node]]
  for parent in source.root.walkNodes:
    for child in parent.nodes:
      parents[child.name] = parent.name
  for node in source.root.walkNodes:
    if node.mesh == nil:
      continue
    if node.name in existing:
      raise newException(ChargenError, "Duplicate attached mesh: " & node.name)
    if node.skin == nil:
      raise newException(ChargenError, "Part needs a skin: " & path)
    if node.skin.joints.len != node.skin.inverseBindMatrices.len:
      raise newException(ChargenError, "Invalid inverse bind count: " & path)
    let skin = gltf.Skin(inverseBindMatrices: node.skin.inverseBindMatrices)
    for joint in node.skin.joints:
      if joint.name notin joints:
        raise newException(ChargenError, "Unknown part joint: " & joint.name)
      let canonical = joints[joint.name]
      if length(joint.basePos - canonical.basePos) > 0.0001 or
        length(joint.baseScale - canonical.baseScale) > 0.0001 or
        abs(abs(dot(joint.baseRot, canonical.baseRot)) - 1) > 0.0001:
          raise newException(
            ChargenError, "Incompatible bind pose: " & joint.name
          )
      skin.joints.add canonical
    if node.skin.skeleton != nil:
      let name = node.skin.skeleton.name
      if name notin joints:
        raise newException(ChargenError, "Unknown skeleton root: " & name)
      skin.skeleton = joints[name]
    node.skin = skin
    let parent = parents.getOrDefault(node.name)
    if parent notin joints:
      raise newException(ChargenError, "Unknown part parent: " & parent)
    attached.add (joints[parent], node)
    existing[node.name] = node
  if attached.len == 0:
    raise newException(ChargenError, "Part has no meshes: " & path)
  for part in attached:
    part.parent.nodes.add part.node
  root.updateTransforms()

proc rotateAttachment(root: Node, item: PartItem) =
  ## Rotates rigid equipment about its grip in the glTF bind-space axes.
  if item.attachmentRotation == [0'f, 0'f, 0'f]:
    return
  if item.attachmentBone.len == 0:
    raise newException(ChargenError, "Missing attachment bone: " & item.name)
  let
    pivot = vec3(
      item.attachmentPivot[0],
      item.attachmentPivot[1],
      item.attachmentPivot[2]
    )
    angles = vec3(
      item.attachmentRotation[0],
      item.attachmentRotation[1],
      item.attachmentRotation[2]
    ) * (PI.float32 / 180)
    offset = translate(pivot) * rotateZ(angles.z) * rotateY(angles.y) *
      rotateX(angles.x) * translate(-pivot)
    nodes = partNodes(root)
  for name in item.nodes:
    if name notin nodes or nodes[name].skin == nil:
      raise newException(ChargenError, "Missing attachment mesh: " & name)
    let node = nodes[name]
    var socket = -1
    for i, joint in node.skin.joints:
      if joint.name == item.attachmentBone:
        socket = i
    if socket < 0:
      raise newException(ChargenError, "Unknown attachment bone: " & item.name)
    for primitive in node.mesh.primitives:
      for vertex, weights in primitive.jointWeights:
        for i in 0 ..< 4:
          if weights[i] > 0.0001 and
            primitive.jointIds[vertex][i].int != socket:
              raise newException(
                ChargenError, "Attachment must be rigid: " & item.name
              )
    node.skin.inverseBindMatrices[socket] =
      node.skin.inverseBindMatrices[socket] * offset

proc readCharacter*(directory: string, manifest: Manifest): GltfFile =
  ## Assembles the library's selected inventory around a single animated rig.
  result = readModel(directory, manifest.rig)
  let joints = rigNodes(result.root)
  var loaded: HashSet[string]
  for category in manifest.categories:
    for item in category.items:
      for path in item.files:
        if path notin loaded:
          result.root.attachPart(directory, path)
          loaded.incl path
      result.root.rotateAttachment(item)
  for spec in manifest.clips:
    let source = readModel(directory, spec.file)
    if source.root.animations.len != 1 or
      source.root.animations[0].name != spec.name:
        raise newException(ChargenError, "Invalid animation file: " & spec.file)
    let clip = source.root.animations[0]
    for channel in clip.channels:
      if channel.target.name notin joints:
        raise newException(
          ChargenError, "Unknown animated bone: " & channel.target.name
        )
      channel.target = joints[channel.target.name]
    result.root.animations.add clip
  result.skins.setLen(0)
  for node in result.root.walkNodes:
    if node.skin != nil:
      result.skins.add node.skin
  result.root.updateTransforms()

proc readCharacter*(directory: string): GltfFile =
  ## Loads all discovered parts and clips for browsing in the generator.
  readCharacter(directory, readManifest(directory))
