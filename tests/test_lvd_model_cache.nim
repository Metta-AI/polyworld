## Requires the LvD CharGen library to compare cached and fresh variants.

import
  std/[sets, tables],
  gltf, vmath,
  polyworld/[characters, chargen],
  ../examples/light_vs_dark/[appearances, assets, content, factions]

proc vertex(
  node: Node, primitive: Primitive, joints: openArray[Mat4], index: int
): Vec3 =
  ## Evaluates one vertex with the source renderer's skinning formula.
  var point = primitive.points[index]
  if node.skin != nil:
    point = vec3(0)
    for component in 0 ..< 4:
      point += joints[primitive.jointIds[index][component].int] *
        primitive.points[index] * primitive.jointWeights[index][component]
  node.mat * point

proc checkMerged(model: CharacterModel, kind: UnitKind) =
  ## Checks merged geometry against every original part throughout animation.
  doAssert model.mergedMeshes.len == 1
  let
    root = model.file.root
    merged = model.mergedMeshes[0]
    scene = CharacterScene(shading: ToonCharacters)
  doAssert merged.mesh.primitives.len in 1 .. 2
  var
    ownNodes: HashSet[pointer]
    draws = 0
    pose: CharacterPose
  for node in root.walkNodes:
    ownNodes.incl cast[pointer](node)
    if node.visible and node.mesh != nil:
      draws += node.mesh.primitives.len
  for joint in merged.skin.joints:
    doAssert cast[pointer](joint) in ownNodes
  for slot in AnimationSlot:
    let clip = model.clipIndex(kind.unitClip(slot))
    for fraction in [0'f, 0.5'f, 1'f]:
      scene.prepareCharacter(
        pose,
        model,
        vec3(3, 1, -2),
        0.7'f,
        clip,
        model.clipDuration(clip) * fraction
      )
      doAssert pose.toon.meshCount == 1
      doAssert pose.toon.meshes[0].packedParts
      doAssert pose.toon.meshes[0].node == merged
      let matrices = root.skinMatrices(merged)
      var offsets: array[2, int]
      for node in root.walkNodes:
        if not node.visible or node.mesh == nil:
          continue
        let sourceMatrices = root.skinMatrices(node)
        for source in node.mesh.primitives:
          let
            group = (source.material.alphaMode == BlendAlphaMode).ord
            combined = merged.mesh.primitives[group]
          for i in 0 ..< source.points.len:
            doAssert length(
              vertex(node, source, sourceMatrices, i) -
                vertex(merged, combined, matrices, offsets[group])
            ) < 0.0001, $kind & " " & $slot & " " & node.name
            inc offsets[group]
      for i, primitive in merged.mesh.primitives:
        doAssert offsets[i] == primitive.points.len
  echo kind, ": ", draws, " part draws -> ",
    merged.mesh.primitives.len, " merged draws; all animation slots match"

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([Emerald, WetAsphalt])
var cache: UnitModelCache
for kind in UnitKind:
  let original = roster.players[0][kind.ord]
  var recolored = original
  recolored.skinRgb = [0.2'f, 0.4'f, 0.7'f]
  let
    first = cache.loadUnitModel(manifest, original, kind)
    second = cache.loadUnitModel(manifest, recolored, kind)
    fresh = loadUnitModel(manifest, recolored, kind)
    firstParts = partNodes(first.file.root)
    secondParts = partNodes(second.file.root)
    freshParts = partNodes(fresh.file.root)
  doAssert first != second
  doAssert first.file.root != second.file.root
  doAssert first.baseTransform == second.baseTransform
  doAssert second.baseTransform == fresh.baseTransform
  doAssert cache.loadUnitModel(manifest, original, kind) == first
  doAssert cache.loadUnitModel(manifest, recolored, kind) == second
  for model in [first, second, fresh]:
    checkMerged(model, kind)
  let
    merged = second.mergedMeshes[0]
    reference = fresh.mergedMeshes[0]
  doAssert merged != first.mergedMeshes[0]
  for i, primitive in merged.mesh.primitives:
    doAssert primitive.colors == reference.mesh.primitives[i].colors
    doAssert primitive.uvs == reference.mesh.primitives[i].uvs
  for name, node in secondParts:
    let
      firstNode = firstParts[name]
      freshNode = freshParts[name]
    doAssert node != firstNode
    doAssert node.visible == freshNode.visible
    for i, primitive in node.mesh.primitives:
      let
        firstPrimitive = firstNode.mesh.primitives[i]
        freshPrimitive = freshNode.mesh.primitives[i]
      doAssert primitive != firstPrimitive
      doAssert primitive.data == firstPrimitive.data
      doAssert primitive.data != nil
      doAssert primitive.material != firstPrimitive.material
      doAssert primitive.material.baseColorFactor ==
        freshPrimitive.material.baseColorFactor
      doAssert primitive.points == freshPrimitive.points
      doAssert primitive.normals == freshPrimitive.normals
      doAssert primitive.jointWeights == freshPrimitive.jointWeights
  let inventory = manifest.presetManifest(original.preset)
  for name in inventory.skinNodes:
    let tint = firstParts[name].mesh.primitives[0].material.baseColorFactor
    doAssert tint.r == original.skinRgb[0]
    doAssert tint.g == original.skinRgb[1]
    doAssert tint.b == original.skinRgb[2]
  var ownNodes: HashSet[pointer]
  for node in second.file.root.walkNodes:
    ownNodes.incl cast[pointer](node)
  for node in second.file.root.walkNodes:
    if node.skin != nil:
      for joint in node.skin.joints:
        doAssert cast[pointer](joint) in ownNodes
    for clip in node.animations:
      for channel in clip.channels:
        if channel.target != nil:
          doAssert cast[pointer](channel.target) in ownNodes
  for slot in AnimationSlot:
    let clip = second.clipIndex(kind.unitClip(slot))
    for model in [second, fresh]:
      model.file.root.activeClips = @[clip]
      model.file.root.animTime = model.clipDuration(clip) * 0.3'f
      model.file.root.updateAnimation(0)
      model.file.root.updateTransforms(model.baseTransform)
    for name, node in secondParts:
      doAssert node.mat == freshParts[name].mat
      doAssert second.file.root.skinMatrices(node) ==
        fresh.file.root.skinMatrices(freshParts[name])
  echo kind, ": cached colors, geometry, and animations match fresh loading"

for kind in UnitKind:
  let model = cache.loadUnitModel(
    manifest, roster.players[1][kind.ord], kind
  )
  checkMerged(model, kind)
