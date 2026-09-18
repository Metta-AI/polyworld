import
  std/[sets, tables],
  gltf, vmath,
  polyworld/chargen

type
  LineupActor* = object
    name*: string
    root*: Node
    transform*: Mat4
    joints: seq[tuple[source, target: Node]]

proc presetManifest*(manifest: Manifest, preset: Preset): Manifest =
  ## Keeps only the parts needed by one preset and omits animation copies.
  var selection: seq[int]
  manifest.applyPreset(selection, preset)
  result = manifest
  result.categories = @[]
  result.clips = @[]
  result.skinNodes = @[]
  result.hairShades = @[]
  result.hatShades = @[]
  var kept = manifest.base.toHashSet()
  for i, category in manifest.categories:
    if selection[i] < 0:
      continue
    let item = category.items[selection[i]]
    result.categories.add Category(
      key: category.key, selected: 0, items: @[item]
    )
    for name in item.nodes:
      kept.incl name
  for name in manifest.skinNodes:
    if name in kept:
      result.skinNodes.add name
  for shade in manifest.hairShades:
    if shade.node in kept:
      result.hairShades.add shade

  for shade in manifest.hatShades:
    if shade.node in kept:
      result.hatShades.add shade

proc readLineup*(
  directory: string,
  manifest: Manifest,
  source: Node,
  group: string
): seq[LineupActor] =
  ## Loads compact preset models with independent materials and shared poses.
  var joints: Table[string, Node]
  for node in source.walkNodes:
    if node.mesh == nil:
      joints[node.name] = node
  for preset in manifest.presets:
    if preset.group != group or preset.lineupHidden:
      continue
    let
      inventory = manifest.presetManifest(preset)
      model = readCharacter(directory, inventory)
      nodes = partNodes(model.root)
      hair = manifest.hairColors.colorIndex(preset.hairColor)
      pupil = manifest.pupilColors.colorIndex(preset.pupilColor)
    nodes.applySelection(inventory, inventory.defaultSelection())
    nodes.applySkin(inventory, preset.skin)
    var clothes = initClothMaterials(nodes, inventory)
    clothes.applyClothPreset(preset)
    initHairMaterials(nodes, inventory).applyHairTint(
      manifest.hairColors[hair].rgb
    )
    initBrowMaterials(model.root, inventory).applyBrowTint(
      manifest.hairColors[hair].rgb
    )
    let hat = manifest.hatColors.colorIndex(
      if preset.hatColor.len > 0: preset.hatColor else: manifest.defaultHatColor
    )
    initHatMaterials(nodes, inventory).applyHatTint(
      manifest.hatColors[hat].rgb
    )
    var eyes = readEyeTextures(model.root, directory, inventory)
    eyes.applyPupilTint(manifest.pupilColors[pupil].rgb)
    var actor = LineupActor(name: preset.name, root: model.root)
    for node in model.root.walkNodes:
      if node.mesh == nil:
        if node.name notin joints:
          raise newException(ChargenError, "Missing lineup joint: " & node.name)
        actor.joints.add (joints[node.name], node)
    let index = result.len
    actor.transform = translate(vec3(
      if group == "Gota": (index mod 5 - 2).float32 * 3.7
      else: (index mod 3 - 1).float32 * 3.45,
      if group == "Gota": (1 - index div 5).float32 * 4.1
      else: (2 - index div 3).float32 * 4.05,
      0
    ))
    result.add actor

proc sync*(actors: openArray[LineupActor]) =
  ## Copies the evaluated pose, including cross-fades and scrubbing, once.
  for actor in actors:
    for joint in actor.joints:
      joint.target.pos = joint.source.pos
      joint.target.rot = joint.source.rot
      joint.target.scale = joint.source.scale
    actor.root.updateTransforms(actor.transform)
