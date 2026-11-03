import
  chroma,
  polyworld/[characters, chargen],
  assets, attackclips, content

type
  CharacterModels* = object
    heroes*: array[HeroClass, CharacterModel]
    monsters*: array[Species, CharacterModel]

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
    if clips[2] in AuthoredClips:
      var held: seq[string]
      for category in library.presetManifest(preset).categories:
        if category.key == "Right hand":
          for item in category.items:
            held.add item.nodes
      discard model.addAttackClip(clips[2], clips[0], held)
    discard model.mergeCharacterParts()
    result.heroes[class] = model
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
