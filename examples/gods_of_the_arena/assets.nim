import
  polyworld/[assets, common],
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
  FootmanModels*: array[2, string] = [
    # Red/Dire uses undead; blue/Radiant uses humans, including nexus creeps.
    DataRoot & "/characters/mini_legion/undead/skeleton_warrior.glb",
    DataRoot & "/characters/mini_legion/human/footman.glb"
  ]
  HeroModelPath* = DataRoot & "/characters/modular_chars/character.glb"
  HeroTargetHeight* = 1.7'f
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
  HeroPortraitPaths*: array[HeroClass, string] = [
    DataRoot & "/characters/modular_chars/character.preset_1.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_13.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_16.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_17.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_2.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_3.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_11.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_12.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_6.profile.png",
    DataRoot & "/characters/modular_chars/character.preset_14.profile.png"
  ]
  HeroLooks*: array[HeroClass, seq[string]] = [
    @[
      "Back_1", "Body_White_1", "Body_White_Head_1", "Chest_1",
      "Eye_Black_1", "Foot_1", "Hand_1", "Head_1", "Leg_1",
      "Wield_Gear_Left_1", "Wield_Gear_Right_1"
    ],
    @[
      "Body_Yellow_1", "Body_Yellow_Head_1", "Brow_Brown_3", "Chest_13",
      "Eye_Brown_7", "Foot_13", "Hand_13", "Head_13", "Leg_13",
      "Mouth_Yellow_3", "Wield_Gear_Right_13"
    ],
    @[
      "Back_16", "Body_White_1", "Body_White_Head_2", "Chest_16",
      "Earring_4", "Eye_BlueB_1", "Foot_16", "Hand_16", "Head_16",
      "Leg_16", "Mouth_White_3", "Wield_Gear_Right_12"
    ],
    @[
      "Back_17", "Body_Yellow_1", "Body_Yellow_Head_3", "Chest_17",
      "Eye_Brown_4", "Foot_17", "Hand_17", "Head_17", "Leg_17",
      "Wield_Gear_Left_17"
    ],
    @[
      "Back_2", "Body_White_1", "Body_White_Head_1", "Brow_Blue_8",
      "Chest_2", "Eye_BlueB_4", "Foot_2", "Hand_2", "Head_2", "Leg_2",
      "Mouth_White_2", "Wield_Gear_Right_2"
    ],
    @[
      "Back_3", "Body_White_1", "Body_White_Head_3", "Brow_Blue_8",
      "Chest_3", "Eye_BlueB_1", "Foot_3", "Hand_3", "Head_3", "Leg_3",
      "Mouth_Brown_2", "Wield_Gear_Right_3"
    ],
    @[
      "Body_White_1", "Body_White_Head_2", "Chest_11", "Eye_Brown_11",
      "Foot_11", "Hand_11", "Head_11", "Leg_11", "Mouth_Brown_4",
      "Wield_Gear_Right_11"
    ],
    @[
      "Back_12", "Body_Yellow_1", "Body_Yellow_Head_2", "Brow_Brown_3",
      "Chest_12", "Eye_Brown_4", "Foot_12", "Hand_12", "Head_12",
      "Leg_12", "Mouth_Brown_10", "Wield_Gear_Right_12"
    ],
    @[
      "Back_6", "Body_Yellow_1", "Body_Yellow_Head_3", "Chest_6",
      "Eye_Purple_1", "Foot_6", "Hand_6", "Head_6", "Leg_6",
      "Mouth_Purple_9", "Wield_Gear_Left_6"
    ],
    @[
      "Back_14", "Body_Yellow_1", "Body_Yellow_Head_3", "Chest_14",
      "Eye_BlueB_1", "Foot_14", "Hand_14", "Head_14", "Leg_14",
      "Mouth_Yellow_2", "Wield_Gear_Left_14", "Wield_Gear_Right_7"
    ]
  ]

proc fortModelPaths*(team: int): seq[string] =
  ## Returns complete fort assets in red/dark and blue/light team order.
  for name in FortModelNames:
    result.add FortModelRoot & FortFactions[team] & "/" & name & ".glb"

proc arenaDecorPaths*(): seq[string] =
  ## Uses whole packs natively and independently packed nodes in browsers.
  for i, pack in ArenaDecorPacks:
    result.add propPaths(pack, ArenaDecorNodes[i])

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
  var parts: seq[string]
  for look in HeroLooks:
    for part in look:
      if part notin parts:
        parts.add part
  result.add modelAsset(HeroModelPath, parts, textureSize = 512)
  for path in FootmanModels:
    result.add modelAsset(path, textureSize = 512)
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
