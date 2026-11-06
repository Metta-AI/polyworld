import
  polyworld/[characters, chargen],
  appearances, assets, content, resourcepacks

proc resourcePackPreset*(preset: Preset, pack: ResourcePack): Preset =
  ## Replaces only the back slot while preserving the approved worker outfit.
  result = preset
  if pack == NoPack:
    return
  result.parts = @[]
  for part in preset.parts:
    if part.category != "Back":
      result.parts.add part
  let name =
    case pack
    of WoodPack:
      "Wood stack backpack"
    of GoldPack:
      "Gold sack backpack"
    of NoPack:
      "None"
  result.parts.add PresetPart(category: "Back", item: name)

proc loadBackpackModel*(
  cache: var UnitModelCache,
  manifest: Manifest,
  entry: UnitPreset,
  pack: ResourcePack
): CharacterModel =
  ## Builds each cargo outfit once through the existing merged model cache.
  var variant = entry
  variant.preset = resourcePackPreset(entry.preset, pack)
  cache.loadUnitModel(manifest, variant, PeonUnit)
