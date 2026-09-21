import
  gltf,
  brows, clothes, eyes, hairs, models, parts

proc namedPreset*(manifest: Manifest, name: string): Preset =
  ## Finds an authored character preset by its exact name.
  for preset in manifest.presets:
    if preset.name == name:
      return preset
  raise newException(ChargenError, "Unknown character preset: " & name)

proc readPresetCharacter*(
  directory: string,
  manifest: Manifest,
  preset: Preset,
  clips: openArray[string]
): GltfFile =
  ## Assembles only the preset's parts and clips with its authored colors.
  var inventory = manifest.presetManifest(preset)
  for name in clips:
    var found = false
    for clip in manifest.clips:
      if clip.name == name:
        inventory.clips.add clip
        found = true
        break
    if not found:
      raise newException(ChargenError, "Unknown character clip: " & name)
  result = readCharacter(directory, inventory)
  let nodes = partNodes(result.root)
  nodes.applySelection(inventory, inventory.defaultSelection())
  nodes.applySkin(inventory, preset.skin)
  var clothes = initClothMaterials(nodes, inventory)
  clothes.applyClothPreset(preset)
  let hair = manifest.hairColors[manifest.hairColors.colorIndex(
    preset.hairColor
  )].rgb
  initHairMaterials(nodes, inventory).applyHairTint(hair)
  initBrowMaterials(result.root, inventory).applyBrowTint(hair)
  let hat = manifest.hatColors.colorIndex(
    if preset.hatColor.len > 0: preset.hatColor
    else: manifest.defaultHatColor
  )
  initHatMaterials(nodes, inventory).applyHatTint(manifest.hatColors[hat].rgb)
  var eyes = readEyeTextures(result.root, directory, inventory)
  eyes.applyPupilTint(
    manifest.pupilColors[manifest.pupilColors.colorIndex(preset.pupilColor)].rgb
  )
