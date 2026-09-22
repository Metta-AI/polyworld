import
  std/tables,
  gltf, vmath,
  polyworld/chargen

const CreepStrikeTime* = 19'f / 30

type
  LineupView* = enum
    FrontView, SideView, TopView

  LineupActor* = object
    name*: string
    root*: Node
    transform*: Mat4
    joints: seq[tuple[source, target: Node]]

proc poseCreeps*(actors: var seq[LineupActor], view = FrontView) =
  ## Keeps both creep poses side by side while exposing the same view angle.
  let rotation =
    case view
    of FrontView: mat4()
    of SideView: rotateY(-PI.float32 / 2)
    of TopView: rotateX(PI.float32 / 2)
  for i, actor in actors.mpairs:
    actor.transform = translate(vec3((i.float32 - 0.5) * 3.8, 1.7, 0)) *
      rotation * translate(vec3(0, -1.7, 0))

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
    if group == "Creeps":
      if preset.group != "Gota" or
        preset.name notin ["Blue Creep", "Purple Creep"]:
          continue
    elif preset.group != group or preset.lineupHidden:
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
      elif group == "Gota Gods": (index.float32 - 0.5) * 4.6
      else: (index mod 3 - 1).float32 * 3.45,
      if group == "Gota": (1 - index div 5).float32 * 4.1
      elif group == "Gota Gods": 0'f
      else: (2 - index div 3).float32 * 4.05,
      0
    ))
    result.add actor
  if group == "Creeps":
    result.poseCreeps()

proc sync*(actors: openArray[LineupActor]) =
  ## Copies the evaluated pose, including cross-fades and scrubbing, once.
  for actor in actors:
    for joint in actor.joints:
      joint.target.pos = joint.source.pos
      joint.target.rot = joint.source.rot
      joint.target.scale = joint.source.scale
    actor.root.updateTransforms(actor.transform)
