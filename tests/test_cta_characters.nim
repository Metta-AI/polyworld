import
  std/[math, os, strutils],
  chroma, gltf, vmath,
  polyworld/[assets, characters, chargen, common],
  ../examples/call_to_adventure/[appearances, assets, content],
  ../tools/posedbounds

proc vertex(
  owner: Node, primitive: Primitive, matrices: openArray[Mat4], i: int
): Vec3 =
  ## Evaluates a vertex with the renderer's skinning and world transforms.
  var point = primitive.points[i]
  if owner.skin != nil:
    point = vec3(0)
    for j in 0 ..< 4:
      point += matrices[primitive.jointIds[i][j].int] *
        primitive.points[i] * primitive.jointWeights[i][j]
  owner.mat * point

proc normal(
  owner: Node, primitive: Primitive, matrices: openArray[Mat4], i: int
): Vec3 =
  ## Evaluates an animated normal in world space for lighting comparisons.
  var value = primitive.normals[i]
  if owner.skin != nil:
    value = vec3(0)
    for j in 0 ..< 4:
      value += (matrices[primitive.jointIds[i][j].int] *
        vec4(primitive.normals[i], 0)).xyz * primitive.jointWeights[i][j]
  normalize(owner.mat.normalMatrix * value)

proc checkMaterials(model: CharacterModel) =
  ## Checks baked outfit colors and per-part lighting and transparency flags.
  let merged = model.mergedMeshes[0]
  var offsets: array[2, int]
  for owner in model.file.root.walkNodes:
    if not owner.visible or owner.mesh == nil:
      continue
    for source in owner.mesh.primitives:
      let
        material = source.material
        group = (material.alphaMode == BlendAlphaMode).ord
        combined = merged.mesh.primitives[group]
        unlit = owner.name in model.unlitParts or material.unlit
        cutoff =
          if material.alphaMode == MaskAlphaMode:
            material.alphaCutoff
          else:
            -1'f
      for i in 0 ..< source.points.len:
        let index = offsets[group]
        var expected = material.baseColorFactor
        if material.baseColor != nil and
          material.baseColor.width == 1 and material.baseColor.height == 1:
            let pixel = material.baseColor.data[0]
            expected.r *= pixel.r.float32 / 255
            expected.g *= pixel.g.float32 / 255
            expected.b *= pixel.b.float32 / 255
            expected.a *= pixel.a.float32 / 255
        if source.colors.len > 0:
          let pixel = source.colors[i]
          expected.r *= pixel.r.float32 / 255
          expected.g *= pixel.g.float32 / 255
          expected.b *= pixel.b.float32 / 255
          expected.a *= pixel.a.float32 / 255
        let bytes = expected.rgba
        doAssert combined.colors[index] ==
          rgbx(bytes.r, bytes.g, bytes.b, bytes.a), owner.name & " color"
        doAssert combined.uvs1[index] == vec2(unlit.ord.float32, cutoff)
        doAssert combined.tangents[index].w == material.doubleSided.ord.float32
        inc offsets[group]

proc checkGeometry(model: CharacterModel, label: string) =
  ## Compares every merged vertex and normal against its original part.
  let
    root = model.file.root
    merged = model.mergedMeshes[0]
  merged.mat = root.mat
  let mergedMatrices = root.skinMatrices(merged)
  var offsets: array[2, int]
  for owner in root.walkNodes:
    if not owner.visible or owner.mesh == nil:
      continue
    let matrices = root.skinMatrices(owner)
    for source in owner.mesh.primitives:
      let
        group = (source.material.alphaMode == BlendAlphaMode).ord
        combined = merged.mesh.primitives[group]
      for i in 0 ..< source.points.len:
        let index = offsets[group]
        doAssert length(vertex(owner, source, matrices, i) -
          vertex(merged, combined, mergedMatrices, index)) < 0.0001,
          label & " " & owner.name & " position"
        doAssert length(normal(owner, source, matrices, i) -
          normal(merged, combined, mergedMatrices, index)) < 0.0001,
          label & " " & owner.name & " normal"
        inc offsets[group]
  for group, primitive in merged.mesh.primitives:
    doAssert offsets[group] == primitive.points.len

proc checkCharacter(
  model: CharacterModel,
  manifest: Manifest,
  preset: Preset,
  height: float32,
  clips: array[3, string],
  skin: seq[float32] = @[]
) =
  ## Checks production outfits, merged drawing and animations for one recipe.
  let
    inventory = manifest.presetManifest(preset)
    file = model.file
  var
    armed = false
    originalDraws = 0
  doAssert model.mergedMeshes.len == 1
  doAssert model.mergedMesh == 0
  let merged = model.mergedMeshes[0]
  doAssert merged.mesh.primitives.len in 1 .. 2
  doAssert merged.skin.joints.len > 0
  for category in inventory.categories:
    if category.key == "Right hand":
      for item in category.items:
        if item.files.len > 0:
          armed = true
    if category.key in ["Eyes", "Mouth", "Brow"]:
      for item in category.items:
        for name in item.nodes:
          doAssert name in model.unlitParts, preset.name & " " & name
  doAssert armed, preset.name & " is missing its weapon."
  for owner in file.root.walkNodes:
    if not owner.visible or owner.mesh == nil:
      continue
    originalDraws += owner.mesh.primitives.len
    if skin.len > 0 and owner.name in inventory.skinNodes:
      for primitive in owner.mesh.primitives:
        doAssert primitive.material.baseColorFactor ==
          color(skin[0], skin[1], skin[2], 1)
  doAssert merged.mesh.primitives.len < originalDraws
  model.checkMaterials()
  file.root.activeClips = @[model.clipIndex("Idle_Loop")]
  file.root.animTime = 0
  file.root.updateAnimation(0)
  file.root.updateTransforms(model.baseTransform)
  let standing = posedBounds(file.root, visibleOnly = true)
  doAssert abs(standing.min.y) < 0.001, preset.name & " is not grounded."
  doAssert abs(standing.max.y - height) < 0.001
  for name in clips:
    let clip = model.clipIndex(name)
    doAssert model.clipDuration(clip) > 0, preset.name & ": " & name
    for time in [0'f, model.clipDuration(clip) / 2, model.clipDuration(clip)]:
      file.root.activeClips = @[clip]
      file.root.animTime = time
      file.root.updateAnimation(0)
      file.root.updateTransforms(model.baseTransform)
      let bounds = posedBounds(file.root, visibleOnly = true)
      for axis in 0 ..< 3:
        doAssert classify(bounds.min[axis]) notin {fcNan, fcInf, fcNegInf}
        doAssert classify(bounds.max[axis]) notin {fcNan, fcInf, fcNegInf}
        doAssert bounds.max[axis] > bounds.min[axis]
      file.root.updateTransforms(
        translate(vec3(3, 1, -2)) * rotateY(0.7'f) * model.baseTransform
      )
      model.checkGeometry(preset.name & " " & name)
  echo preset.name, ": weapon, color, scale and animation verified; ",
    originalDraws, " -> ", merged.mesh.primitives.len, " draws."

block:
  let
    manifest = readManifest(ChargenLibrary)
    roster = readCharacterRoster()
    models = loadCharacterModels()

  for class in HeroClass:
    checkCharacter(
      models.heroes[class],
      manifest,
      manifest.namedPreset(HeroPresets[class]),
      HeroTargetHeight,
      class.heroClips()
    )
    doAssert fileExists(HeroPortraitPaths[class])

  for species in Species:
    let entry = roster.mobs[species.ord]
    checkCharacter(
      models.monsters[species],
      manifest,
      entry.preset,
      HeroTargetHeight * RankScales[species.monsterRank],
      species.speciesClips(),
      @(entry.skinRgb)
    )
    doAssert entry.skinRgb == roster.mobs[species.ord div 4 * 4].skinRgb

  echo "Shared CTA meshes retain independent prepared actor poses."
  let
    scene = CharacterScene(shading: ToonCharacters)
    model = models.heroes[FighterClass]
  var
    first, second: CharacterPose
    joints: seq[Mat4]
  scene.prepareCharacter(
    first, model, vec3(1, 2, 3), 0, model.clipIndex("Sword_Idle"), 0
  )
  let transform = first.toon.meshes[0].transform
  for matrix in first.toon.meshes[0].joints:
    joints.add matrix
  scene.prepareCharacter(
    second, model, vec3(-4, 1, 2), 1, model.clipIndex("Jog_Fwd_Loop"), 0.4'f
  )
  doAssert first.toon.meshCount == 1 and second.toon.meshCount == 1
  doAssert first.toon.meshes[0].packedParts
  doAssert second.toon.meshes[0].packedParts
  doAssert first.toon.meshes[0].node == model.mergedMeshes[0]
  doAssert second.toon.meshes[0].node == first.toon.meshes[0].node
  doAssert first.toon.meshes[0].transform == transform
  doAssert first.toon.meshes[0].joints == joints
  doAssert second.toon.meshes[0].transform != transform
  doAssert second.toon.meshes[0].joints != joints

  for clip in manifest.clips:
    if clip.name in CharacterClips:
      doAssert clip.kind == "universal", "A legacy clip is still selected."

  for asset in browserAssets():
    doAssert "modular_chars" notin asset.source
    doAssert "cartoon_textures" notin asset.source
    doAssert "handpainted_trees" notin asset.source
    doAssert "toon_enchanted_meadow" notin asset.source
    for name in ["orc", "footman", "lich", "rock_golem"]:
      doAssert asset.source != "characters/" & name & ".glb"
    if asset.kind in {FileAsset, ModelAsset, ImageAsset}:
      doAssert fileExists(DataRoot / asset.source), asset.source
    if asset.kind in {ModelAsset, ImageAsset}:
      for name in ["original2", "neutral", "happy", "angry"]:
        doAssert "/eyes/" & name & "." notin asset.source

echo "CTA generated character integration passed."
