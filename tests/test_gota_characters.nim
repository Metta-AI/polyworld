import
  std/[math, os],
  gltf, vmath,
  polyworld/[characters, chargen],
  ../examples/gods_of_the_arena/[assets, content],
  ../tools/posedbounds

let
  directory = getEnv("GOTA_CHARACTER_DATA", ChargenLibrary)
  manifest = readManifest(directory)

for class in HeroClass:
  let
    name = HeroPresets[class]
    file = readPresetCharacter(
      directory, manifest, manifest.namedPreset(name), HeroClips
    )
    model = loadCharacterModel(file, HeroTargetHeight)
    idle = model.clipIndex("Idle_Loop")
  model.fitCharacterHeight(HeroTargetHeight, idle)
  file.root.updateTransforms(model.baseTransform)
  let standing = posedBounds(file.root, visibleOnly = true)
  doAssert abs(standing.min.y) < 0.001, name & " is not grounded."
  doAssert abs(standing.max.y - HeroTargetHeight) < 0.001,
    name & " has the wrong standing height."
  for animation in class.heroAnimationNames():
    let clip = model.clipIndex(animation)
    doAssert model.clipDuration(clip) > 0, name & ": " & animation
  let attack = model.clipIndex(class.heroAnimationNames()[3])
  doAssert class.heroStrikeTime() < model.clipDuration(attack)
  for animation in HeroClips:
    let clip = model.clipIndex(animation)
    for time in [0'f, model.clipDuration(clip) / 2, model.clipDuration(clip)]:
      file.root.activeClips = @[clip]
      file.root.animTime = time
      file.root.updateAnimation(0)
      file.root.updateTransforms(model.baseTransform)
      let bounds = posedBounds(file.root, visibleOnly = true)
      for axis in 0 ..< 3:
        doAssert classify(bounds.min[axis]) notin {fcNan, fcInf, fcNegInf}
        doAssert classify(bounds.max[axis]) notin {fcNan, fcInf, fcNegInf}
        doAssert bounds.max[axis] > bounds.min[axis], name & ": " & animation
  echo name, ": outfit, scale, and animations verified."

for team in 0 ..< CreepPresets.len:
  let original = manifest.namedPreset(CreepPresets[team])
  for kind in CreepKind:
    let
      preset = manifest.creepPreset(team, kind)
      inventory = manifest.presetManifest(preset)
      file = readPresetCharacter(directory, manifest, preset, CreepClips)
      model = loadCharacterModel(file, CreepTargetHeight)
      names = kind.creepAnimationNames()
    var weapon = ""
    for category in inventory.categories:
      if category.key == "Right hand":
        doAssert category.items.len == 1
        weapon = category.items[0].name
    doAssert weapon.len > 0
    doAssert (weapon == "Arcanist staff") == (kind == RangedCreep)
    for name in names:
      let clip = model.clipIndex(name)
      doAssert model.clipDuration(clip) > 0
    let attack = model.clipIndex(names[4])
    doAssert kind.creepStrikeTime() < model.clipDuration(attack)
    file.root.activeClips = @[attack]
    file.root.animTime = kind.creepStrikeTime()
    file.root.updateAnimation(0)
    file.root.updateTransforms(model.baseTransform)
    let bounds = posedBounds(file.root, visibleOnly = true)
    for axis in 0 ..< 3:
      doAssert classify(bounds.min[axis]) notin {fcNan, fcInf, fcNegInf}
      doAssert classify(bounds.max[axis]) notin {fcNan, fcInf, fcNegInf}
      doAssert bounds.max[axis] > bounds.min[axis]
    echo preset.name, " ", kind, ": weapon and animation verified."
  doAssert manifest.namedPreset(CreepPresets[team]) == original,
    "Equipping a caster must not change the shared melee preset."

echo "GotA generated character integration passed: ", directory
