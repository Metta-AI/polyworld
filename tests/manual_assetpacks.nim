import
  std/[os, strformat],
  gltf,
  polyworld/assets,
  ../examples/call_to_adventure/assets as ctaAssets,
  ../examples/gods_of_the_arena/assets as gotaAssets,
  ../examples/light_vs_dark/assets as lvdAssets

proc compareNodes(original, packed: Node, originalRoot, packedRoot: Node): int =
  ## Checks transforms, selected geometry, palette pixels, and posed skinning.
  doAssert original.name == packed.name
  doAssert original.mat == packed.mat, original.name
  doAssert original.nodes.len == packed.nodes.len
  if packed.mesh != nil:
    inc result
    doAssert original.mesh != nil
    doAssert original.mesh.primitives.len == packed.mesh.primitives.len
    for i, primitive in packed.mesh.primitives:
      let expected = original.mesh.primitives[i]
      doAssert primitive.points == expected.points
      doAssert primitive.normals == expected.normals
      doAssert primitive.uvs == expected.uvs
      doAssert primitive.colors == expected.colors
      doAssert primitive.jointIds == expected.jointIds
      doAssert primitive.jointWeights == expected.jointWeights
      doAssert primitive.indices16 == expected.indices16
      doAssert primitive.indices32 == expected.indices32
      doAssert primitive.material.baseColor.data ==
        expected.material.baseColor.data
    if original.skin != nil:
      doAssert packed.skin != nil
      doAssert original.skin.inverseBindMatrices == packed.skin.inverseBindMatrices
      doAssert originalRoot.skinMatrices(original) == packedRoot.skinMatrices(packed)
  for i, child in packed.nodes:
    result += compareNodes(original.nodes[i], child, originalRoot, packedRoot)

proc checkModels(game: string, declarations: seq[Asset], source: string) =
  ## Exercises all declared props and character parts against their originals.
  let stage = "tmp/webassets" / (game & "-ktx2") / "stage"
  var models, meshes, poses: int
  for asset in declarations:
    if asset.kind != ModelAsset:
      continue
    let
      original = readGltfFile(source / asset.source).root
      packed = readGltfFile(stage / asset.output).root
    original.updateTransforms()
    packed.updateTransforms()
    let count = compareNodes(original, packed, original, packed)
    meshes += count
    inc models
    if asset.presets.len > 0:
      doAssert count == 44
    elif asset.nodes.len > 1:
      doAssert count == asset.nodes.len
    if asset.clips.len > 0:
      doAssert packed.animations.len == asset.clips.len
    else:
      doAssert packed.animations.len == original.animations.len
    for clip in packed.animations:
      var expected: AnimationClip
      for candidate in original.animations:
        if candidate.name == clip.name:
          expected = candidate
      doAssert expected != nil
      doAssert clip.duration == expected.duration
      doAssert clip.channels.len == expected.channels.len
      for fraction in [0.0'f, 0.37'f, 0.79'f]:
        expected.applyClipAt(clip.duration * fraction)
        clip.applyClipAt(clip.duration * fraction)
        original.updateTransforms()
        packed.updateTransforms()
        discard compareNodes(original, packed, original, packed)
        inc poses
  echo &"{game}: {models} models, {meshes} meshes, {poses} poses unchanged"

block:
  let source = getEnv("POLYWORLD_ART", "../polyworld_art")
  checkModels("cta", ctaAssets.browserAssets(), source)
  checkModels("gota", gotaAssets.browserAssets(), source)
  checkModels("lvd", lvdAssets.browserAssets(), source)
