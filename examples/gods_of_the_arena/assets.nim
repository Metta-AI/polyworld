import
  std/os,
  polyworld/[assets, chargen, common],
  content

const
  LogoPath* = DataRoot & "/themes/gota/gota_logo.png"
  FortTextures* = ["mossy-building-stone-1", "courtyard-stone-1"]
  CryptTextures* = [
    "crypt-rock-1", "crypt-rock-2", "crypt-stone-1", "crypt-flagstone-1",
    "crypt-grate-2"
  ]
  ArenaTextures* = @FortTextures & @CryptTextures
  FortModelRoot = DataRoot & "/terrain/blender_forts/models/"
  FortFactions = ["dark", "light"]
  FortModelNames* = [
    "tower_level1", "tower_level2", "tower_level3", "barracks", "pillar", "wall"
  ]
  FortTextureSize* =
    when defined(emscripten): 512
    else: 1024
  ArenaDecorPacks* = [
    DataRoot & "/terrain/toon_enchanted_meadow/props.glb",
    DataRoot & "/terrain/toon_enchanted_meadow/vegetation.glb"
  ]
  ArenaDecorNodes*: array[2, seq[string]] = [
    @["lamp_post_01a", "wood_barrel_01a", "wood_crate_01a",
      "wood_fence_pole_01a", "pier_bollard_01a", "pier_bollard_02a",
      "boat_01a", "boat_wreck_01a", "rope_01a", "wood_cart_01a",
      "wood_fence_01a", "wood_wheel_01a"],
    @["flowers_patch_01a", "flowers_patch_02a", "flowers_patch_03a",
      "flower_bush_01a", "flower_bush_02a",
      "grass_patch_01a", "grass_patch_02a", "grass_patch_03a",
      "grass_patch_04a", "grass_patch_05a", "lily_flower_01a",
      "lily_flower_02a", "lily_flower_03a", "plant_01a", "plant_02a",
      "plant_03a", "plant_04a", "plant_05a", "plant_06a", "plant_07a",
      "mushroom_01a", "mushroom_03a", "mushroom_06a"]
  ]
  GotaTerrainAssets* =
    when defined(emscripten): WebTerrainAssets
    else: DefaultTerrainAssets
  GotaTreeStyle* = NoTrees
  GotaDecorTextureSize* =
    when defined(emscripten): 256
    else: 512
  CreepPresets* = ["Purple Creep", "Blue Creep"]
  CreepClips* = [
    "Jog_Fwd_Loop", "Sword_Idle", "Death01", "Dance_Loop", "Sword_Attack",
    "Spell_Simple_Idle_Loop", "Spell_Simple_Shoot"
  ]
  CreepTargetHeight* = 2.25'f
  GodPresets* = ["Hades", "Zeus"]
  GodClips* = ["Idle_Loop", "Death01", "Dance_Loop"]
  HeroTargetHeight* = 1.7'f
  GodTargetHeight* = HeroTargetHeight * 1.5'f
  HeroPortraitKeys*: array[HeroClass, string] = [
    "gota_vanguard_knight",
    "gota_ranger",
    "gota_arcanist",
    "gota_druid_warden",
    "gota_demon_hunter",
    "gota_death_knight",
    "gota_crossbowman",
    "gota_lich",
    "gota_warlock",
    "gota_berserker"
  ]
  HeroPresets*: array[HeroClass, string] = [
    "Vanguard Knight", "Ranger", "Arcanist", "Druid Warden", "Demon Hunter",
    "Death Knight", "Crossbowman", "Lich", "Warlock", "Berserker"
  ]
  HeroClips* = [
    "Jog_Fwd_Loop", "Idle_Loop", "Death01", "Sword_Idle", "Sword_Attack",
    "Pistol_Idle_Loop", "Pistol_Shoot",
    "Spell_Simple_Idle_Loop", "Spell_Simple_Shoot"
  ]
  HeroPortraitRoot = DataRoot & "/characters/chargen/portraits/"
  HeroPortraitPaths*: array[HeroClass, string] = [
    HeroPortraitRoot & "vanguard_knight.profile.png",
    HeroPortraitRoot & "ranger.profile.png",
    HeroPortraitRoot & "arcanist.profile.png",
    HeroPortraitRoot & "druid_warden.profile.png",
    HeroPortraitRoot & "demon_hunter.profile.png",
    HeroPortraitRoot & "death_knight.profile.png",
    HeroPortraitRoot & "crossbowman.profile.png",
    HeroPortraitRoot & "lich.profile.png",
    HeroPortraitRoot & "warlock.profile.png",
    HeroPortraitRoot & "berserker.profile.png"
  ]

proc draftedPortraitKey*(class: HeroClass): string {.raises: [].} =
  ## Names the desaturated portrait used for unavailable draft choices.
  HeroPortraitKeys[class] & ".drafted"

proc creepPreset*(manifest: Manifest, team: int, kind: CreepKind): Preset =
  ## Equips ranged creeps with an existing staff while preserving team colors.
  result = manifest.namedPreset(CreepPresets[team])
  if kind == RangedCreep:
    result.pose = "Spell_Simple_Idle_Loop"
    for part in result.parts.mitems:
      if part.category == "Right hand":
        part.item = "Arcanist staff"

proc creepAnimationNames*(kind: CreepKind): array[6, string] =
  ## Maps creep simulation slots to sword swings or staff spell releases.
  result = [
    "Jog_Fwd_Loop", "Sword_Idle", "Death01", "Dance_Loop",
    "Sword_Attack", "Sword_Attack"
  ]
  if kind == RangedCreep:
    result[1] = "Spell_Simple_Idle_Loop"
    result[4] = "Spell_Simple_Shoot"
    result[5] = "Spell_Simple_Shoot"

proc creepStrikeTime*(kind: CreepKind): float32 =
  ## Returns the authored sword impact or staff spell release time.
  case kind
  of MeleeCreep:
    19'f / 30
  of RangedCreep:
    6'f / 30

proc heroAnimationNames*(class: HeroClass): array[5, string] =
  ## Maps deterministic animation slots to each class's weapon style.
  result[0] = "Jog_Fwd_Loop"
  result[2] = "Death01"
  case class.heroSpec.attackStyle
  of MeleeAttack:
    result[1] = "Sword_Idle"
    result[3] = "Sword_Attack"
  of RangedAttack:
    result[1] = "Pistol_Idle_Loop"
    result[3] = "Pistol_Shoot"
  of MagicAttack:
    result[1] = "Spell_Simple_Idle_Loop"
    result[3] = "Spell_Simple_Shoot"
  result[4] = result[3]

proc heroStrikeTime*(class: HeroClass): float32 =
  ## Returns the authored contact or release time in the attack clip.
  case class.heroSpec.attackStyle
  of MeleeAttack: 19'f / 30
  of RangedAttack: 3'f / 30
  of MagicAttack: 6'f / 30

proc fortModelPaths*(team: int): seq[string] =
  ## Returns complete fort assets in red/dark and blue/light team order.
  for name in FortModelNames:
    result.add FortModelRoot & FortFactions[team] & "/" & name & ".glb"

proc arenaDecorPaths*(): seq[string] =
  ## Uses whole packs natively and independently packed nodes in browsers.
  for i, pack in ArenaDecorPacks:
    result.add propPaths(pack, ArenaDecorNodes[i])

proc deathEyesPart*(manifest: Manifest): PartItem =
  ## Finds the authored death expression used by all arena characters.
  for category in manifest.categories:
    if category.key == "Eyes":
      for item in category.items:
        if item.name == "Dead X":
          return item
  raise newException(ChargenError, "Missing Dead X eyes.")

proc generatedCharacterAssets*(): seq[Asset] =
  ## Packs generated characters with only their selected meshes and clips.
  let
    directory = DataRoot / "characters/chargen"
    manifest = readManifest(directory)
  for path in ["manifest.json", manifest.skinPalette, manifest.hairPalette,
      manifest.pupilPalette, manifest.hatPalette]:
    result.add fileAsset(directory / path)
  # Discovery reads part descriptors, but only selected meshes are loaded.
  for category in manifest.categories:
    for path in walkFiles(directory / category.directory / "*.json"):
      result.add fileAsset(path)
  result.add modelAsset(directory / manifest.rig)
  for path in manifest.deathEyesPart().files:
    result.add modelAsset(directory / path, textureSize = 512)
  var presets: seq[Preset]
  for team in 0 ..< CreepPresets.len:
    for kind in CreepKind:
      presets.add manifest.creepPreset(team, kind)
  for name in @GodPresets & @HeroPresets:
    presets.add manifest.namedPreset(name)
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
    if clip.name in CreepClips or clip.name in GodClips or
      clip.name in HeroClips:
        result.add modelAsset(directory / clip.file)

proc browserAssets*(): seq[Asset] =
  ## Declares every presentation asset reachable by an arena match.
  result = hudAssets(LogoPath)
  result.add terrainAssets(
    GotaTreeStyle, GeneratedTerrain, NoRocks, WebTerrainAssets, ArenaTextures
  )
  for path in TreegenTextures:
    result.add imageAsset(path, GeneratorTextureSize)
  result.add imageAsset(RockgenTexture, GeneratorTextureSize)
  for team in 0 ..< FortFactions.len:
    for path in fortModelPaths(team):
      result.add modelAsset(path, textureSize = 512)
  for i, pack in ArenaDecorPacks:
    result.add propAssets(pack, ArenaDecorNodes[i], textureSize = 256)
  result.add generatedCharacterAssets()
  for path in HeroPortraitPaths:
    result.add fileAsset(path)
  for hero in HeroClass:
    for slot in HeroAbilitySlot:
      result.add fileAsset(
        "abilities/" & heroAbility(hero, slot).abilitySpec.icon & ".png"
      )
  for item in Item:
    if item != NoItem:
      result.add fileAsset("items/" & item.itemSpec.icon & ".png")
