import
  std/math,
  chroma, gltf, vmath,
  polyworld/[characters, chargen],
  assets, attackclips, content

const
  ToeBones = ["LeftToeBase", "RightToeBase"]
    ## The last part of a foot to leave the ground.
  StrideSamples = 64
  PlantedShare = 0.15'f32
    ## How far up its full lift a toe still counts as on the ground.
  GroundFollowRate = 40'f32
    ## How fast a gait catches up with the ground speed, per game second.
    ## Any slower and the lag out of a corner shows up as a sliding foot.
  StandSpeed = 0.25'f32
    ## World units per second a body has to beat to count as moving.
  StallSeconds = 10'f32 / TickRate.float32
    ## How long a walker can stand before it drops to idle. The sim stops a
    ## body to finish a turn, for up to 8 ticks; longer than that it's stuck.
  MinimumRunRate = 0.25'f32
    ## Keeps the legs going through a pivot or a crawl, feet or no feet.
  MaximumRunRate = 3'f32

type
  CharacterModels* = object
    heroes*: array[HeroClass, CharacterModel]
    monsters*: array[Species, CharacterModel]
    loosedMeshes*: array[HeroClass, int]
      ## Each hero's merged mesh with the string hand empty, drawn from a
      ## shot's release until the archer nocks again. Characters draw as one
      ## baked mesh, so the bow clip cannot hide the arrow by itself.
    blazingBlade*: seq[BladePose]
      ## The Fighter's sword through his blazing slash.
    heroStrides*: array[HeroClass, float32]
    monsterStrides*: array[Species, float32]
      ## World units one loop of the run clip covers, measured on the model.

  Gait* = object
    ## A body's footing, followed from how fast it really moves.
    speed: float32  ## smoothed ground speed, world units per second
    stood: float32  ## game seconds since it last moved

proc track*(gait: var Gait, groundSpeed, dt: float32) =
  ## Follows a body's ground speed over `dt` seconds of game time.
  gait.speed += (groundSpeed - gait.speed) *
    (1 - exp(-GroundFollowRate * dt))
  gait.stood =
    if groundSpeed < StandSpeed: gait.stood + dt
    else: 0

proc striding*(gait: Gait): bool =
  ## False once a walker has stood too long to be just turning a corner.
  gait.stood < StallSeconds

proc runRate*(gait: Gait, stride, duration: float32): float32 =
  ## Clip seconds to play per game second: one loop for every `stride` of
  ## ground, which keeps a planted foot where it landed.
  clamp(
    gait.speed * duration / stride, MinimumRunRate, MaximumRunRate
  )

proc measureStride*(model: CharacterModel, clip: int): float32 =
  ## Returns the world units one loop of a running clip covers. The clips
  ## run on the spot, so a planted foot slides back under the body, and that
  ## slide is how fast the body has to travel for the foot to stay put.
  let
    root = model.file.root
    duration = model.clipDuration(clip)
  var
    toes: array[ToeBones.len, Node]
    paths: array[ToeBones.len, array[StrideSamples, Vec3]]
    slide, planted = 0'f32
  for node in root.walkNodes:
    let foot = ToeBones.find(node.name)
    if foot >= 0:
      toes[foot] = node
  root.activeClips.setLen(1)
  root.activeClips[0] = clip
  for sample in 0 ..< StrideSamples:
    root.animTime = duration * sample.float32 / StrideSamples.float32
    root.updateAnimation(0)
    root.updateTransforms(model.baseTransform)
    for foot, toe in toes:
      paths[foot][sample] = toe.mat.pos
  for path in paths:
    var lowest, highest = path[0].y
    for point in path:
      lowest = min(lowest, point.y)
      highest = max(highest, point.y)
    let ceiling = lowest + (highest - lowest) * PlantedShare
    for sample in 0 ..< StrideSamples:
      let next = path[(sample + 1) mod StrideSamples]
      if path[sample].y <= ceiling and next.y <= ceiling:
        slide += path[sample].z - next.z
        planted += 1
  doAssert planted > 0 and slide > 0, "Clip has no planted foot."
  slide / planted * StrideSamples.float32

proc mergeWithout(model: CharacterModel, hidden: openArray[string]): int =
  ## Bakes another merged mesh with the named nodes left out, and returns
  ## its index.
  for node in model.file.root.walkNodes:
    if node.name in hidden:
      node.baseVisible = false
      node.visible = false
  result = model.mergeCharacterParts()
  for node in model.file.root.walkNodes:
    if node.name in hidden:
      node.baseVisible = true
      node.visible = true

proc loadCharacterModels*(): CharacterModels =
  ## Loads finalized outfits as shared meshes with one animated skin each.
  let
    library = readManifest(ChargenLibrary)
    roster = readCharacterRoster()

  proc loadPresetModel(preset: Preset, height: float32): CharacterModel =
    ## Fits an equipped model and preserves its authored face lighting.
    result = loadCharacterModel(
      readPresetCharacter(ChargenLibrary, library, preset, CharacterClips),
      height
    )
    result.fitCharacterHeight(height, result.clipIndex("Idle_Loop"))
    for category in library.presetManifest(preset).categories:
      if category.key in ["Eyes", "Mouth", "Brow"]:
        for item in category.items:
          result.unlitParts.add item.nodes

  for class in HeroClass:
    let
      preset = library.namedPreset(HeroPresets[class])
      model = loadPresetModel(preset, HeroTargetHeight)
      clips = class.heroClips()
    var held: seq[string]
    for category in library.presetManifest(preset).categories:
      if category.key == "Right hand":
        for item in category.items:
          held.add item.nodes
    if clips[2] in AuthoredClips:
      discard model.addAttackClip(clips[2], clips[0], held)
    if class == FighterClass:
      discard model.addAttackClip(BlazingSlashClip, clips[0], held)
      discard model.addAttackClip(TauntRoarClip, clips[0], held)
    discard model.mergeCharacterParts()
    result.loosedMeshes[class] = model.mergedMesh
    if clips[2] == BowShotClip:
      result.loosedMeshes[class] = model.mergeWithout(held)
    if class == FighterClass:
      result.blazingBlade = model.measureBlade(
        model.clipIndex(BlazingSlashClip), held)
    result.heroes[class] = model
    result.heroStrides[class] = model.measureStride(model.clipIndex(clips[1]))
  for species in Species:
    let
      entry = roster.mobs[species.ord]
      model = loadPresetModel(
        entry.preset, HeroTargetHeight * RankScales[species.monsterRank]
      )
      rgb = entry.skinRgb
    partNodes(model.file.root).applySkin(
      library.presetManifest(entry.preset), color(rgb[0], rgb[1], rgb[2], 1)
    )
    discard model.mergeCharacterParts()
    result.monsters[species] = model
    result.monsterStrides[species] =
      model.measureStride(model.clipIndex(speciesClips(species)[1]))
