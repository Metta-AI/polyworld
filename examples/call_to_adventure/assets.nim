import
  polyworld/[assets, common],
  content

const
  LogoPath* = DataRoot & "/themes/cta/cta_logo.png"
  HeroClips* = ["Idle", "Run", "Attack01"]
  GolemClips* = ["Idle", "Walk", "Attack01"]
  CtaWebTerrainAssets* = TerrainAssets(
    size: 256,
    materials: @["grass", "sand", "cliff", "marsh", "stone", "dirt", "volcanic"],
    compressed: not defined(webPng)
  )
  # Portraits show the same presets as the rendered heroes.
  HeroPortraitPaths*: array[HeroClass, string] = [
    DataRoot & "/characters/modular_chars/character.preset_5.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_18.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_11.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_9.profile.png"
  ]

proc speciesClips*(species: Species): seq[string] =
  ## Declares the three clips used by each monster's state selection.
  if SpeciesModels[species] == DataRoot & "/characters/rock_golem.glb":
    @GolemClips
  else:
    @HeroClips

proc browserAssets*(): seq[Asset] =
  ## Declares the art used by all party classes and dungeon levels.
  result = hudAssets(LogoPath)
  result.add terrainAssets(
    NoTrees, CartoonTerrain, NoRocks, CtaWebTerrainAssets
  )
  result.add modelAsset(
    HeroModelPath,
    clips = @HeroClips,
    manifest = HeroManifestPath,
    presets = @ClassPresets
  )
  result.add fileAsset(HeroManifestPath)
  for species in Species:
    result.add modelAsset(SpeciesModels[species], clips = speciesClips(species))
  for path in HeroPortraitPaths:
    result.add fileAsset(path)
  for name in AbilityIconFiles:
    if name.len > 0:
      result.add fileAsset("abilities/" & name & ".png")
