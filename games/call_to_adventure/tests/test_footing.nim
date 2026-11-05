## Call to Adventure footing: run clips against the ground bodies cover.

import
  std/math,
  gltf, vmath,
  polyworld/characters,
  ../[appearances, assets, content]

const
  FrameStep = 1'f32 / 60
  PlantedShare = 0.15'f32
    ## How far up its full lift a toe still counts as on the ground.

proc toeDrift(
  model: CharacterModel, clip: int, stride, speed: float32
): float32 =
  ## Runs a body down a straight line at `speed` and returns the furthest
  ## any toe wandered from where it landed.
  var toes: array[2, Node]
  for node in model.file.root.walkNodes:
    if node.name == "LeftToeBase":
      toes[0] = node
    elif node.name == "RightToeBase":
      toes[1] = node
  var
    gait: Gait
    time = 0'f32
    place = vec3(0)
    landed: array[2, Vec3]
    down: array[2, bool]
    lowest = float32.high
    highest = float32.low
  let root = model.file.root
  root.activeClips.setLen(1)
  root.activeClips[0] = clip
  for sample in 0 ..< 64:
    root.animTime = model.clipDuration(clip) * sample.float32 / 64
    root.updateAnimation(0)
    root.updateTransforms(model.baseTransform)
    for toe in toes:
      lowest = min(lowest, toe.mat.pos.y)
      highest = max(highest, toe.mat.pos.y)
  let ceiling = lowest + (highest - lowest) * PlantedShare
  for frame in 0 ..< 300:
    gait.track(speed, FrameStep)
    time += FrameStep * gait.runRate(stride, model.clipDuration(clip))
    place.z += speed * FrameStep
    root.animTime = time
    root.updateAnimation(0)
    root.updateTransforms(translate(place) * model.baseTransform)
    if frame < 30:
      continue
    for foot, toe in toes:
      let spot = toe.mat.pos
      if spot.y > ceiling:
        down[foot] = false
      elif not down[foot]:
        down[foot] = true
        landed[foot] = spot
      else:
        result = max(result, length(vec2(spot.x - landed[foot].x,
          spot.z - landed[foot].z)))

proc checkStrides(models: CharacterModels) =
  ## Each model's stride comes from its own clip and scale.
  for class in HeroClass:
    let
      model = models.heroes[class]
      clip = model.clipIndex(class.heroClips()[1])
      stride = models.heroStrides[class]
    doAssert stride > HeroTargetHeight, "a hero's jog loop covers two steps"
    doAssert toeDrift(model, clip, stride, ClassSpeeds[class].float32 / 100) <
      0.02 * HeroTargetHeight, $class
  for species in Species:
    let
      model = models.monsters[species]
      clip = model.clipIndex(speciesClips(species)[1])
      height = HeroTargetHeight * RankScales[species.monsterRank]
    doAssert toeDrift(model, clip, models.monsterStrides[species],
      SpeciesSpeeds[species].float32 / 100) < 0.02 * height, $species
  doAssert models.monsterStrides[BoneMiteSpecies] <
    models.monsterStrides[DustlingSpecies], "smaller bodies step shorter"
  doAssert models.monsterStrides[DustlingSpecies] <
    models.monsterStrides[BarrowWardenSpecies], "bigger bodies step longer"

proc settled(speed: float32, step = FrameStep): Gait =
  ## A gait that has followed one ground speed for a second of game time.
  for _ in 0 ..< int(1 / step):
    result.track(speed, step)

proc checkRates() =
  ## The rate follows the ground, not the clock.
  const
    Stride = 3'f32
    Duration = 0.9'f32
  doAssert abs(settled(2).runRate(Stride, Duration) - 0.6) < 0.001
  doAssert abs(settled(4).runRate(Stride, Duration) - 1.2) < 0.001
  doAssert abs(settled(2, 1 / 15).runRate(Stride, Duration) - 0.6) < 0.001,
    "fast replays take bigger steps of game time to the same rate"
  doAssert settled(0.1).runRate(Stride, Duration) > 0,
    "a crawl keeps the legs going"
  doAssert settled(90).runRate(Stride, Duration) <= 3,
    "a teleport doesn't blur the legs"

proc checkStanding() =
  ## A pivot keeps the run going, standing still for longer ends it.
  var gait = settled(2)
  doAssert gait.striding
  for tick in 1 .. 8:
    gait.track(0, 1 / TickRate.float32)
  doAssert gait.striding, "the longest pivot at a corner stays in the run"
  doAssert gait.runRate(3, 0.9) > 0, "and doesn't freeze the pose"
  for tick in 9 .. 12:
    gait.track(0, 1 / TickRate.float32)
  doAssert not gait.striding, "a blocked walker stops running on the spot"
  gait.track(2, FrameStep)
  doAssert gait.striding, "and sets off the moment it moves"

checkStrides(loadCharacterModels())
checkRates()
checkStanding()

echo "Footing tests passed"
