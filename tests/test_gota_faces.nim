import
  std/os,
  gltf,
  polyworld/[characters, chargen],
  ../examples/gods_of_the_arena/[assets, faces]

let
  directory = getEnv("GOTA_CHARACTER_DATA", ChargenLibrary)
  manifest = readManifest(directory)
  replacement = manifest.deathEyesPart()

for name in @CreepPresets & @GodPresets & @HeroPresets:
  let
    preset = manifest.namedPreset(name)
    file = readPresetCharacter(directory, manifest, preset, ["Death01"])
    model = loadCharacterModel(file, HeroTargetHeight)
    eyes = initDeathEyes(
      model, directory, manifest.presetManifest(preset), replacement
    )
  doAssert eyes.living.len > 0, name & " has no living eyes."
  doAssert eyes.dead.len > 0, name & " has no death eyes."
  for node in eyes.dead:
    doAssert node.name in model.unlitParts
    doAssert node.skin != nil
    for primitive in node.mesh.primitives:
      doAssert primitive.material.baseColor != nil
  # Alternate instances, respawns, and seeks through the same shared model.
  for dead in [false, true, false, true, true, false]:
    eyes.setDead(dead)
    file.root.activeClips = @[0]
    file.root.animTime = 0.5
    file.root.updateAnimation(0)
    for node in eyes.living:
      doAssert node.visible == not dead, name & " kept the wrong living eyes."
    for node in eyes.dead:
      doAssert node.visible == dead, name & " kept the wrong death eyes."
  echo name, ": death eyes and restoration verified."

echo "GotA death eyes integration passed: ", directory
