import
  std/os,
  jsony,
  polyworld/[assets, chargen, common, terrainsurfaces],
  content

const
  LogoPath* = DataRoot & "/themes/cta/cta_logo.png"
  RosterPath* = ChargenLibrary & "/cta.json"
  HeroTargetHeight* = 1.7'f
  CharacterClips* = [
    "Idle_Loop", "Jog_Fwd_Loop", "Sword_Idle", "Sword_Attack",
    "Pistol_Idle_Loop", "Pistol_Shoot",
    "Spell_Simple_Idle_Loop", "Spell_Simple_Shoot"
  ]
  CtaTerrainTiles* = [
    "crypt-rock-1", "crypt-rock-2", "crypt-stone-1", "crypt-flagstone-1",
    "crypt-lava-1", "crypt-lava-2", "cobble-tan-1"
  ]
  CryptRockSurface* = SurfaceNames.len.float32
  CryptRubbleSurface* = CryptRockSurface + 1
  CryptStoneSurface* = CryptRockSurface + 2
  CryptFloorSurface* = CryptRockSurface + 3
  CryptLavaSurface* = CryptRockSurface + 4
  CryptCrustSurface* = CryptRockSurface + 5
  VaultSurface* = CryptRockSurface + 6
  CtaTerrainAssets* = TerrainAssets(size: 256)
  HeroPortraitRoot = DataRoot & "/characters/chargen/portraits/"
  HeroPortraitPaths*: array[HeroClass, string] = [
    HeroPortraitRoot & "vanguard_knight.profile.png",
    HeroPortraitRoot & "arcanist.profile.png",
    HeroPortraitRoot & "ranger.profile.png",
    HeroPortraitRoot & "druid_warden.profile.png"
  ]
  MeleeClips = ["Sword_Idle", "Jog_Fwd_Loop", "Sword_Attack"]
  RangedClips = ["Pistol_Idle_Loop", "Jog_Fwd_Loop", "Pistol_Shoot"]
  MagicClips = [
    "Spell_Simple_Idle_Loop", "Jog_Fwd_Loop", "Spell_Simple_Shoot"
  ]

type
  MobPreset* = object
    preset*: Preset
    skinRgb*: array[3, float32]

  CharacterRoster* = object
    mobs*: seq[MobPreset]

proc readCharacterRoster*(): CharacterRoster =
  ## Reads the approved recipes and verifies their simulation species order.
  try:
    result = readFile(RosterPath).fromJson(CharacterRoster)
  except IOError, JsonError:
    raise newException(
      ChargenError, "Cannot read CTA roster: " & getCurrentExceptionMsg()
    )
  if result.mobs.len != SpeciesNames.len:
    raise newException(ChargenError, "CTA roster must contain 16 monsters.")
  for species in Species:
    let entry = result.mobs[species.ord]
    if entry.preset.name != SpeciesNames[species]:
      raise newException(
        ChargenError, "CTA roster is missing " & SpeciesNames[species]
      )
    for channel in entry.skinRgb:
      if not (channel >= 0 and channel <= 1):
        raise newException(ChargenError, "Invalid skin color in CTA roster.")

proc heroClips*(class: HeroClass): array[3, string] =
  ## Matches idle, movement and attack clips to the hero's equipped weapon.
  case class
  of FighterClass: MeleeClips
  of RogueClass: RangedClips
  of WizardClass, ClericClass: MagicClips

proc speciesClips*(species: Species): array[3, string] =
  ## Matches each monster's existing weapon to its animation style.
  if species == GraveStalkerSpecies:
    RangedClips
  elif species.monsterRank == CasterRank:
    MagicClips
  else:
    MeleeClips

proc generatedCharacterAssets*(): seq[Asset] =
  ## Packs the approved parts and CC0 clips without the former model packs.
  let
    directory = DataRoot / "characters/chargen"
    manifest = readManifest(directory)
    roster = readCharacterRoster()
  result.add fileAsset("characters/chargen/cta.json")
  for path in ["manifest.json", manifest.skinPalette, manifest.hairPalette,
      manifest.pupilPalette, manifest.hatPalette]:
    result.add fileAsset(directory / path)
  for category in manifest.categories:
    for path in walkFiles(directory / category.directory / "*.json"):
      result.add fileAsset(path)
  result.add modelAsset(directory / manifest.rig)
  var presets: seq[Preset]
  for name in HeroPresets:
    presets.add manifest.namedPreset(name)
  for mob in roster.mobs:
    presets.add mob.preset
  for preset in presets:
    let inventory = manifest.presetManifest(preset)
    for category in inventory.categories:
      for item in category.items:
        for path in item.files:
          result.add modelAsset(directory / path, textureSize = 512)
        for path in [item.texture, item.pupilMask]:
          if path.len > 0:
            result.add imageAsset(directory / path, 512)
  for clip in manifest.clips:
    if clip.name in CharacterClips:
      result.add modelAsset(directory / clip.file)

proc browserAssets*(): seq[Asset] =
  ## Declares the art used by all party classes and dungeon levels.
  result = hudAssets(LogoPath)
  for path in ["LICENSE", "licenses/cta.md", "fonts/OFL-Rubik.txt",
      "fonts/OFL-OverpassMono.txt",
      "animations/quaternius/universal_standard/README.txt"]:
    result.add fileAsset(path)
  result.add terrainAssets(
    NoTrees, GeneratedTerrain, NoRocks, CtaTerrainAssets, CtaTerrainTiles
  )
  result.add generatedCharacterAssets()
  for path in HeroPortraitPaths:
    result.add fileAsset(path)
  for name in AbilityIconFiles:
    if name.len > 0:
      result.add fileAsset("abilities/" & name & ".png")
