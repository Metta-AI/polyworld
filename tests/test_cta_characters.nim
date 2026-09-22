import
  std/[math, os, strutils],
  chroma, gltf, vmath,
  polyworld/[assets, characters, chargen, common],
  ../examples/call_to_adventure/[assets, content],
  ../tools/posedbounds

proc checkCharacter(
  manifest: Manifest,
  preset: Preset,
  height: float32,
  clips: array[3, string],
  skin: seq[float32] = @[]
) =
  ## Checks equipped meshes, grounding and animated bounds for one recipe.
  let
    inventory = manifest.presetManifest(preset)
    file = readPresetCharacter(ChargenLibrary, manifest, preset, CharacterClips)
    model = loadCharacterModel(file, height)
  var armed = false
  for category in inventory.categories:
    if category.key == "Right hand":
      for item in category.items:
        if item.files.len > 0:
          armed = true
  doAssert armed, preset.name & " is missing its weapon."
  if skin.len > 0:
    partNodes(file.root).applySkin(
      inventory, color(skin[0], skin[1], skin[2], 1)
    )
  model.fitCharacterHeight(height, model.clipIndex("Idle_Loop"))
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
  echo preset.name, ": weapon, scale and animation verified."

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster()

for class in HeroClass:
  checkCharacter(
    manifest,
    manifest.namedPreset(HeroPresets[class]),
    HeroTargetHeight,
    class.heroClips()
  )
  doAssert fileExists(HeroPortraitPaths[class])

for species in Species:
  let entry = roster.mobs[species.ord]
  checkCharacter(
    manifest,
    entry.preset,
    HeroTargetHeight * RankScales[species.monsterRank],
    species.speciesClips(),
    @(entry.skinRgb)
  )
  doAssert entry.skinRgb == roster.mobs[species.ord div 4 * 4].skinRgb

for clip in manifest.clips:
  if clip.name in CharacterClips:
    doAssert clip.kind == "universal", "A legacy clip is still selected."

for asset in browserAssets():
  doAssert "modular_chars" notin asset.source
  for name in ["orc", "footman", "lich", "rock_golem"]:
    doAssert asset.source != "characters/" & name & ".glb"
  if asset.kind in {FileAsset, ModelAsset, ImageAsset}:
    doAssert fileExists(DataRoot / asset.source), asset.source
  if asset.kind in {ModelAsset, ImageAsset}:
    for name in ["original2", "neutral", "happy", "angry"]:
      doAssert "/eyes/" & name & "." notin asset.source

echo "CTA generated character integration passed."
