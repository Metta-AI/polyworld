import
  std/[os, sets, strutils, tables],
  chroma, gltf, vmath,
  polyworld/animblend, brows, eyes, hairs, parts, references, weights

const AssetDir = currentSourcePath().parentDir / "assets"

proc testParts() =
  ## Checks face and ear choices while animations reset and blend the model.
  let
    manifest = readManifest(AssetDir)
    model = readGltfFile(AssetDir / manifest.model)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
  var selection = manifest.defaultSelection()
  nodes.applySelection(manifest, selection)
  doAssert nodes["Nose_Tiny"].visible
  doAssert nodes["Head"].visible
  doAssert nodes["Eyes_Atlas02"].visible
  doAssert nodes["Mouth_Atlas01"].visible
  doAssert nodes["Brow_Atlas01"].visible
  doAssert nodes["Hair_01"].visible
  let
    eyeColor = nodes["Eyes_Atlas02"].mesh.primitives[0].material.baseColorFactor
    mouthColor = nodes["Mouth_Atlas01"].mesh.primitives[0].material.baseColorFactor
    hairColor = nodes["Hair_01"].mesh.primitives[0].material.baseColorFactor
    browColor = nodes["Brow_Atlas01"].mesh.primitives[0].material.baseColorFactor
  for skin in 0 ..< manifest.skins.len:
    nodes.applySkin(manifest, skin)
    let tint = manifest.skins[skin].color
    for name in manifest.skinNodes:
      doAssert nodes[name].mesh.primitives[0].material.baseColorFactor ==
        color(tint[0], tint[1], tint[2], tint[3])
    doAssert nodes["Eyes_Atlas02"].mesh.primitives[0].material.baseColorFactor ==
      eyeColor
    doAssert nodes["Mouth_Atlas01"].mesh.primitives[0].material.baseColorFactor ==
      mouthColor
    doAssert nodes["Hair_01"].mesh.primitives[0].material.baseColorFactor ==
      hairColor
    doAssert nodes["Brow_Atlas01"].mesh.primitives[0].material.baseColorFactor ==
      browColor
  for name in ["Neutral", "Happy", "Angry", "Original2"]:
    let primitives = nodes["Eyes_" & name].mesh.primitives
    doAssert primitives.len == 1
    let material = primitives[0].material
    doAssert material.alphaMode == MaskAlphaMode
    doAssert material.unlit
    doAssert not material.baseColorPlaceholder
    doAssert material.baseColor.width == 1024
    doAssert material.baseColor.height == 512
  for name, node in nodes:
    if name in ["Ears_Round_Left", "Ears_Round_Right",
                "Ears_Elf_Left", "Ears_Elf_Right"]:
      doAssert not node.visible
  for clip in manifest.clips:
    doAssert player.clipIndex(clip.name) >= 0
    player.setRule(clip.name, ClipRule(loop: clip.loop, next: clip.next))
  for category in manifest.categories:
    for item in category.items:
      manifest.selectPart(selection, category.key, item.name)
      nodes.applySelection(manifest, selection)
      for clip in manifest.clips:
        player.play(clip.name, 0.2)
        player.update(0.1)
        for name in item.nodes:
          doAssert nodes[name].visible and nodes[name].baseVisible
        for other in category.items:
          if other.name != item.name:
            for name in other.nodes:
              doAssert not nodes[name].visible
  for category in manifest.categories:
    manifest.selectPart(selection, category.key, "None")
  nodes.applySelection(manifest, selection)
  player.update(0.2)
  for name, node in nodes:
    doAssert node.visible == (name in manifest.base)
  var failed = false
  try:
    manifest.selectPart(selection, "Ears", "Missing")
  except BlenderCharsError:
    failed = true
  doAssert failed
  player.play("Walk", 0)
  player.seek(0)
  var rotations: seq[Quat]
  for node in model.root.walkNodes:
    rotations.add node.rot
  player.seek(0.3)
  var moved = false
  for i, node in model.root.walkNodes:
    if node.rot != rotations[i]:
      moved = true
  doAssert moved, "The animation must move the skeleton."
  player.play("Victory", 0.2)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Walk"
  player.play("Attack04Start", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "Attack04Spin"
  player.play("Death", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "DeathStay"
  player.play("JumpStart", 0)
  player.update(10)
  doAssert model.root.animations[player.current].name == "JumpAir"
  for preset in manifest.presets:
    manifest.applyPreset(selection, preset)
    nodes.applySelection(manifest, selection)
  doAssert nodes["Ears_Elf_Left"].visible
  manifest.applyPreset(selection, manifest.presets[0])
  nodes.applySelection(manifest, selection)
  doAssert not nodes["Ears_Elf_Left"].visible

proc testEyes() =
  ## Checks tint isolation, retained shading, atlas UVs, and head attachment.
  let model = readGltfFile(AssetDir / "character.glb")
  var textures = readEyeTextures(model.root, AssetDir)
  let
    black = tintPupils(textures.art, textures.mask, PupilColors[1].rgb)
    teal = tintPupils(textures.art, textures.mask, PupilColors[2].rgb)
  var
    shades: HashSet[uint8]
    protected, tinted = 0
  for i, pixel in textures.art.data:
    doAssert black.data[i].a == pixel.a
    doAssert teal.data[i].a == pixel.a
    if textures.mask.data[i].r == 0:
      doAssert black.data[i] == pixel
      doAssert teal.data[i] == pixel
      inc protected
    elif textures.mask.data[i].r == 255:
      doAssert black.data[i].r == 0
      doAssert black.data[i].g == 0
      doAssert black.data[i].b == 0
      if pixel.a >= 240:
        shades.incl teal.data[i].g
        inc tinted
  doAssert protected > 100_000 and tinted > 10_000
  doAssert shades.len > 20, "Tinting must retain iris shading."
  textures.applyPupilTint(PupilColors[2].rgb)
  var count = 0
  for node in model.root.walkNodes:
    if node.mesh == nil or not node.name.startsWith("Eyes_Atlas"):
      continue
    inc count
    let primitive = node.mesh.primitives[0]
    doAssert primitive.material.unlit
    doAssert primitive.material.alphaMode == MaskAlphaMode
    doAssert primitive.material.baseColor.data == teal.data
    for uv in primitive.uvs:
      doAssert uv.x >= 0 and uv.x <= 1
      doAssert uv.y >= 0 and uv.y <= 1
    for i, ids in primitive.jointIds:
      let weights = primitive.jointWeights[i]
      for j in 0 ..< 4:
        if weights[j] > 0:
          doAssert node.skin.joints[ids[j].int].name == "Head"
  doAssert count == 16
  textures.applyPupilTint(PupilColors[0].rgb)
  for node in model.root.walkNodes:
    if node.mesh != nil and node.name.startsWith("Eyes_Atlas"):
      doAssert node.mesh.primitives[0].material.baseColor.data ==
        textures.art.data

proc testMouths() =
  ## Checks atlas cells, alpha cutouts, unlit materials, and head attachment.
  let model = readGltfFile(AssetDir / "character.glb")
  var count = 0
  for node in model.root.walkNodes:
    if node.mesh == nil or not node.name.startsWith("Mouth_Atlas"):
      continue
    inc count
    doAssert node.mesh.primitives.len == 1
    let
      index = node.name["Mouth_Atlas".len .. ^1].parseInt - 1
      column = index mod 4
      row = index div 4
      primitive = node.mesh.primitives[0]
      material = primitive.material
    doAssert material.unlit
    doAssert material.alphaMode == MaskAlphaMode
    doAssert not material.baseColorPlaceholder
    doAssert material.baseColor.width == 1254
    doAssert material.baseColor.height == 1254
    doAssert material.baseColor.data[0].a == 0
    for uv in primitive.uvs:
      doAssert uv.x > column.float32 / 4
      doAssert uv.x < (column + 1).float32 / 4
      doAssert uv.y > row.float32 / 4
      doAssert uv.y < (row + 1).float32 / 4
    for i, ids in primitive.jointIds:
      for j in 0 ..< 4:
        if primitive.jointWeights[i][j] > 0:
          doAssert node.skin.joints[ids[j].int].name == "Head"
  doAssert count == 16

proc testBrows() =
  ## Checks eyebrow cutouts, atlas selection, isolated tint, and head weights.
  let
    model = readGltfFile(AssetDir / "character.glb")
    nodes = partNodes(model.root)
    brows = initBrowMaterials(model.root)
    protected = ["Head", "Eyes_Atlas02", "Mouth_Atlas01", "Hair_01"]
  var originals: seq[Color]
  for name in protected:
    originals.add nodes[name].mesh.primitives[0].material.baseColorFactor
  for tint in [WhiteBrows, HairColors[0].rgb, HairColors[22].rgb]:
    brows.applyBrowTint(tint)
    var count = 0
    for node in model.root.walkNodes:
      if node.mesh == nil or not node.name.startsWith("Brow_Atlas"):
        continue
      inc count
      doAssert node.mesh.primitives.len == 1
      let
        index = node.name["Brow_Atlas".len .. ^1].parseInt - 1
        column = index mod 4
        row = index div 4
        primitive = node.mesh.primitives[0]
        material = primitive.material
      doAssert material.unlit
      doAssert material.alphaMode == MaskAlphaMode
      doAssert material.baseColorFactor == color(tint[0], tint[1], tint[2], 1)
      doAssert not material.baseColorPlaceholder
      doAssert material.baseColor.width == 1254
      doAssert material.baseColor.height == 1254
      doAssert material.baseColor.data[0].a == 0
      for uv in primitive.uvs:
        doAssert uv.x > column.float32 / 4
        doAssert uv.x < (column + 1).float32 / 4
        doAssert uv.y > row.float32 / 4
        doAssert uv.y < (row + 1).float32 / 4
      for i, ids in primitive.jointIds:
        for j in 0 ..< 4:
          if primitive.jointWeights[i][j] > 0:
            doAssert node.skin.joints[ids[j].int].name == "Head"
    doAssert count == 16
    for i, name in protected:
      doAssert nodes[name].mesh.primitives[0].material.baseColorFactor ==
        originals[i]

proc testHair() =
  ## Checks all hair meshes follow the head and remain independently shaded.
  let model = readGltfFile(AssetDir / "character.glb")
  var count = 0
  for node in model.root.walkNodes:
    if node.mesh == nil or not node.name.startsWith("Hair_"):
      continue
    inc count
    doAssert node.skin != nil
    for primitive in node.mesh.primitives:
      doAssert not primitive.material.unlit
      doAssert primitive.jointIds.len == primitive.jointWeights.len
      doAssert primitive.jointIds.len > 0
      for i, ids in primitive.jointIds:
        var total = 0.0'f
        for j in 0 ..< 4:
          let weight = primitive.jointWeights[i][j]
          total += weight
          if weight > 0:
            doAssert node.skin.joints[ids[j].int].name == "Head"
        doAssert abs(total - 1) < 0.00001
  doAssert count == 16

proc testHairColors() =
  ## Verifies tint isolation and restores custom shades after weight mode.
  let
    manifest = readManifest(AssetDir)
    model = readGltfFile(AssetDir / manifest.model)
    nodes = partNodes(model.root)
    hair = initHairMaterials(nodes, manifest)
    head = nodes["Head"].mesh.primitives[0].material
    eyes = nodes["Eyes_Atlas02"].mesh.primitives[0].material
    mouth = nodes["Mouth_Atlas01"].mesh.primitives[0].material
    headTint = head.baseColorFactor
    eyeTint = eyes.baseColorFactor
    mouthTint = mouth.baseColorFactor
  var
    untouched: seq[Material]
    originalTints: seq[Color]
    hairNodes: HashSet[string]
  for surface in manifest.hairShades:
    hairNodes.incl surface.node
  doAssert hairNodes.len == 16
  for node in model.root.walkNodes:
    if node.mesh == nil or not node.name.startsWith("Hair_"):
      continue
    for i, primitive in node.mesh.primitives:
      var tinted = false
      for surface in manifest.hairShades:
        if surface.node == node.name and surface.primitive == i:
          tinted = true
      if not tinted:
        untouched.add primitive.material
        originalTints.add primitive.material.baseColorFactor
  doAssert untouched.len > 0
  for preset in HairColors:
    doAssert HairColors[hairColor(preset.name.toUpperAscii())] == preset
    hair.applyHairTint(preset.rgb)
    for surface in manifest.hairShades:
      let material = nodes[surface.node].mesh.primitives[
        surface.primitive
      ].material
      doAssert material.baseColorFactor == color(
        clamp(preset.rgb[0] * surface.shade, 0, 1),
        clamp(preset.rgb[1] * surface.shade, 0, 1),
        clamp(preset.rgb[2] * surface.shade, 0, 1),
        1
      )
    doAssert head.baseColorFactor == headTint
    doAssert eyes.baseColorFactor == eyeTint
    doAssert mouth.baseColorFactor == mouthTint
    for i, material in untouched:
      doAssert material.baseColorFactor == originalTints[i]
  var preview = initWeightPreview(model.root, AssetDir)
  let
    selected = preview.boneIndex("Head")
    custom = [0.16'f, 0.73'f, 0.42'f]
  hair.applyHairTint(custom)
  preview.updateWeights(true, selected)
  preview.updateWeights(false, selected)
  hair.applyHairTint(custom)
  for primitive in nodes["Hair_01"].mesh.primitives:
    doAssert primitive.material.baseColorFactor ==
      color(custom[0], custom[1], custom[2], 1)
    doAssert not primitive.material.unlit

proc testOutfits() =
  ## Checks future clothing colors and replacement meshes without new assets.
  let category = Category(key: "Chest", items: @[
    PartItem(name: "Red shirt", style: 0, color: "Red"),
    PartItem(name: "Blue coat", style: 1, color: "Blue"),
    PartItem(name: "Blue shirt", style: 0, color: "Blue")
  ])
  var selected = 0
  category.cycleColor(selected)
  doAssert selected == 2
  category.cycleColor(selected)
  doAssert selected == 0
  let
    manifest = Manifest(base: @["Body"], categories: @[
      Category(key: "Chest", items: @[
        PartItem(nodes: @["Shirt"], hides: @["Body"])
      ])
    ])
    nodes = {"Body": Node(), "Shirt": Node()}.toTable
  nodes.applySelection(manifest, [0])
  doAssert not nodes["Body"].visible and nodes["Shirt"].visible
  nodes.applySelection(manifest, [-1])
  doAssert nodes["Body"].visible and not nodes["Shirt"].visible

proc testWeights() =
  ## Checks runtime bone attachments and reversible weight preview colors.
  let
    model = readGltfFile(AssetDir / "character.glb")
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
    hand = nodes["Hand.Left"].mesh.primitives[0]
    originalWeights = hand.jointWeights
    originalPoints = hand.points
    originalColors = hand.colors
    eye = nodes["Eyes_Neutral"].mesh.primitives[0]
    eyeTint = eye.material.baseColorFactor
  var preview = initWeightPreview(model.root, AssetDir)
  let left = preview.boneIndex("LeftHand")
  doAssert preview.bones.len == 22 and left >= 0
  doAssert preview.boneIndex("Missing") == -1
  preview.updateWeights(true, left)
  doAssert hand.material.unlit
  var fullWeight = false
  for i, tint in hand.colors:
    let weight = nodes["Hand.Left"].influence(hand, i, "LeftHand")
    doAssert tint == weightColor(weight)
    if weight > 0.99:
      fullWeight = true
  doAssert fullWeight
  for tint in nodes["Hand.Right"].mesh.primitives[0].colors:
    doAssert tint == weightColor(0)
  model.root.updateTransforms()
  for bone in preview.bones:
    let ends = bone.endpoints()
    doAssert length(ends.head - bone.restHead) < 0.00001
    doAssert length(ends.tail - bone.restTail) < 0.00001
  for clip in model.root.animations:
    player.play(clip.name, 0)
    for fraction in [0.0'f, 0.35'f, 0.8'f]:
      player.seek(clip.duration * fraction)
      model.root.updateTransforms()
      for side in ["Left", "Right"]:
        for suffix in ["ForeArm", "Hand", "Leg", "Foot"]:
          doAssert preview.jointGap(preview.boneIndex(side & suffix)) < 0.00001
  preview.updateWeights(false, left)
  doAssert hand.jointWeights == originalWeights
  doAssert hand.points == originalPoints
  doAssert hand.colors == originalColors
  doAssert not hand.material.unlit
  doAssert eye.material.baseColorFactor == eyeTint

proc testReference() =
  ## Checks that comparison uses the real original rig and follows scrubbing.
  let
    manifest = readManifest(AssetDir)
    model = readGltfFile(AssetDir / manifest.model)
    player = newClipPlayer(model.root)
    reference = readReference(manifest.clips)
    originals = partNodes(reference.root)
  doAssert reference.root != model.root
  doAssert "Body_White_1" in originals and "Body" notin originals
  doAssert reference.root.animations.len == manifest.clips.len
  for clip in manifest.clips:
    player.setRule(clip.name, ClipRule(loop: clip.loop, next: clip.next))
  var wrist: Node
  for node in reference.root.walkNodes:
    if node.name == "QuickRigCharacter2_LeftHand":
      wrist = node
    if node.mesh != nil:
      doAssert node.visible ==
        (node.name in ["Body_White_1", "Body_White_Head_1", OriginalEyes])
  doAssert wrist != nil
  for clip in manifest.clips:
    player.play(clip.name, 0)
    player.seek(0.17)
    reference.sync(player)
    let original = reference.root.animations[reference.player.current]
    doAssert original.name == clip.name
    let expected =
      if clip.loop:
        player.currentTime
      else:
        min(player.currentTime, original.duration)
    doAssert reference.player.currentTime == expected
  player.play("Walk", 0)
  player.seek(0)
  reference.sync(player)
  let initial = wrist.mat
  player.seek(0.2)
  reference.sync(player)
  doAssert wrist.mat != initial
  let beforeOutfit = wrist.mat
  reference.setOutfit(true)
  reference.sync(player)
  doAssert originals["Wield_Gear_Left_1"].visible
  doAssert originals["Wield_Gear_Right_1"].visible
  doAssert originals["Hand_1"].visible
  doAssert wrist.mat == beforeOutfit
  reference.setOutfit(false)
  reference.sync(player)
  doAssert not originals["Wield_Gear_Left_1"].visible
  doAssert not originals["Hand_1"].visible
  doAssert wrist.mat == beforeOutfit
  player.play("", 0)
  reference.sync(player)
  doAssert reference.player.current == -1
  for i, preset in reference.manifest.presets:
    reference.loadPreset(i)
    for j, category in reference.manifest.categories:
      let selected = reference.selection[j]
      if selected >= 0:
        for name in category.items[selected].nodes:
          doAssert originals[name].visible
  for skin in 0 ..< reference.manifest.skins.len:
    reference.clearParts()
    reference.skin = skin
    reference.applyParts()
    let prefix = "Body_" & reference.manifest.skins[skin].name & "_"
    doAssert originals[prefix & "1"].visible
    doAssert originals[prefix & "Head_1"].visible
  reference.clearParts()
  player.play("Walk", 0)
  reference.sync(player)
  for name in ["Run", "Attack01", "Victory"]:
    player.play(name, 0.2)
    reference.player.play(name, 0.2)
    for frame in 0 ..< 120:
      player.update(1.0'f / 60)
      reference.player.update(1.0'f / 60)
      doAssert player.rootNode.animations[player.current].name ==
        reference.root.animations[reference.player.current].name
      doAssert abs(player.currentTime - reference.player.currentTime) < 0.0001
      doAssert player.fading == reference.player.fading

echo "Testing Blender character parts and animations"
testParts()
testEyes()
testMouths()
testBrows()
testHair()
testHairColors()
testOutfits()
testWeights()
testReference()
echo "Blender character tests passed"
