import
  std/[os, random, strutils, tables],
  gltf, jsony, vmath,
  polyworld/animblend, parts

const
  OriginalPath* = currentSourcePath().parentDir.parentDir.parentDir.
    parentDir / "polyworld_data/characters/modular_chars/character.glb"
  OriginalBodyParts = ["Body_White_1", "Body_White_Head_1"]
  OriginalEyes* = "Eye_Black_2"

type
  OriginalPreset = object
    name, pose: string
    parts: seq[string]

  OriginalBody = object
    skins, pieces: seq[string]

  OriginalManifest = object
    body: OriginalBody
    categories: seq[Category]
    presets: seq[OriginalPreset]

  Reference* = ref object
    root*: Node
    nodes*: Table[string, Node]
    player*: ClipPlayer
    transform*: Mat4
    manifest*: Manifest
    selection*: seq[int]
    skin*, preset*: int

proc applyParts*(reference: Reference) =
  ## Selects original meshes, including body pieces for the chosen skin.
  let skin = reference.manifest.skins[reference.skin].name
  for i in 0 ..< 2:
    for item in reference.manifest.categories[i].items.mitems:
      item.nodes = @["Body_" & skin & "_" & item.name]
  reference.nodes.applySelection(reference.manifest, reference.selection)

proc loadPreset*(reference: Reference, index: int) =
  ## Loads any original kit outfit without changing the shared playback.
  reference.preset = index
  let preset = reference.manifest.presets[index]
  reference.skin = preset.skin
  reference.manifest.applyPreset(reference.selection, preset)
  reference.applyParts()

proc clearParts*(reference: Reference) =
  ## Restores the plain original body and its default eyes.
  reference.selection = reference.manifest.defaultSelection()
  reference.skin = 4
  reference.applyParts()

proc setOutfit*(reference: Reference, equipped: bool) =
  ## Toggles the first original outfit for reproducible comparison captures.
  if equipped:
    reference.loadPreset(0)
  else:
    reference.clearParts()

proc randomize*(reference: Reference, rng: var Rand) =
  ## Rolls the original skin, face, accessories, clothing, and weapons.
  reference.skin = rng.rand(reference.manifest.skins.high)
  reference.selection[0] = 0
  reference.selection[1] = rng.rand(reference.manifest.categories[1].items.high)
  for i in 2 ..< reference.selection.len:
    let category = reference.manifest.categories[i]
    let chance =
      case category.key
      of "Eyes", "Mouth", "Brow", "Hair": 0.9
      of "Beard", "Earring", "Eyewear": 0.25
      of "Left hand": 0.5
      else: 0.8
    reference.selection[i] =
      if rng.rand(1.0) < chance:
        rng.rand(category.items.high)
      else:
        -1
  reference.applyParts()

proc readReference*(clips: seq[ClipInfo]): Reference =
  ## Adapts the complete purchased kit to the viewer's common part controls.
  if not fileExists(OriginalPath):
    raise newException(BlenderCharsError, "Missing original: " & OriginalPath)
  var source: OriginalManifest
  try:
    source = readFile(OriginalPath.parentDir / "manifest.json").
      fromJson(OriginalManifest)
  except IOError, JsonError:
    raise newException(
      BlenderCharsError, "Cannot read original: " & getCurrentExceptionMsg()
    )
  if source.presets.len == 0:
    raise newException(BlenderCharsError, "The original has no outfit presets.")
  new(result)
  result.root = readGltfFile(OriginalPath).root
  result.nodes = partNodes(result.root)
  result.root.updateTransforms()
  result.manifest.clips = clips
  for name in source.body.skins:
    result.manifest.skins.add parts.Skin(name: name)
  result.manifest.categories = @[
    Category(key: "Body", selected: 0),
    Category(key: "Face", selected: 0)
  ]
  for piece in source.body.pieces:
    let index = if piece.startsWith("Head_"): 1 else: 0
    result.manifest.categories[index].items.add PartItem(
      name: piece, nodes: @["Body_White_" & piece]
    )
  for category in source.categories:
    let key =
      case category.key
      of "Eye": "Eyes"
      of "Head": "Headgear"
      of "Wield_Gear_Left": "Left hand"
      of "Wield_Gear_Right": "Right hand"
      else: category.key
    var adapted = Category(key: key, selected: -1)
    for i, item in category.items:
      adapted.items.add PartItem(
        name: item.name[category.key.len + 1 .. ^1].replace("_", " "),
        color: item.color, style: item.style, nodes: @[item.name]
      )
      if item.name == OriginalEyes:
        adapted.selected = i
    result.manifest.categories.add adapted
  for preset in source.presets:
    var adapted = Preset(name: preset.name, pose: preset.pose, skin: 4)
    for category in result.manifest.categories:
      adapted.parts.add PresetPart(category: category.key, item: "None")
    for name in preset.parts:
      if name.startsWith("Body_"):
        let fields = name.split("_", 2)
        adapted.skin = source.body.skins.find(fields[1])
        let index = if fields[2].startsWith("Head_"): 1 else: 0
        adapted.parts[index].item = fields[2]
      else:
        for i, category in result.manifest.categories:
          for item in category.items:
            if name in item.nodes:
              adapted.parts[i].item = item.name
    result.manifest.presets.add adapted
  var
    low = float32.high
    high = float32.low
    meshes = 0
  for node in result.root.walkNodes:
    if node.mesh == nil or node.name notin OriginalBodyParts:
      continue
    inc meshes
    let matrices = result.root.skinMatrices(node)
    for primitive in node.mesh.primitives:
      for i, point in primitive.points:
        var skinned = vec4(0)
        for j in 0 ..< 4:
          skinned += matrices[primitive.jointIds[i][j].int] *
            vec4(point, 1) * primitive.jointWeights[i][j]
        let height = (node.mat * skinned).y
        low = min(low, height)
        high = max(high, height)
  if meshes != 2 or high <= low:
    raise newException(BlenderCharsError, "Original body meshes are missing.")
  let factor = 3.025'f / (high - low)
  result.transform = translate(vec3(-1.2, 0, 0)) *
    scale(vec3(factor)) * translate(vec3(0, -low, 0))
  result.clearParts()
  result.player = newClipPlayer(result.root)
  for clip in clips:
    if result.player.clipIndex(clip.name) < 0:
      raise newException(BlenderCharsError, "Original clip missing: " & clip.name)
    result.player.setRule(clip.name, ClipRule(loop: clip.loop, next: clip.next))

proc sync*(reference: Reference, player: ClipPlayer) =
  ## Aligns playback after seeking or first opening the original model.
  let name =
    if player.current < 0:
      ""
    else:
      player.rootNode.animations[player.current].name
  let index = reference.player.clipIndex(name)
  if reference.player.current != index:
    reference.player.play(index, 0)
  reference.player.seek(player.currentTime)
  reference.root.updateTransforms(reference.transform)
