import
  std/os,
  polyworld/[assets, common],
  content

const
  LogoPath* = DataRoot & "/themes/lvd/lvd_logo.png"
  LvdTerrainAssets* =
    when defined(emscripten): WebTerrainAssets
    else: DefaultTerrainAssets
  UnitModels* = [
    [
      PeonUnit: DataRoot & "/characters/mini_legion/human/worker.glb",
      SoldierUnit: DataRoot & "/characters/mini_legion/human/footman.glb",
      ArcherUnit: DataRoot & "/characters/mini_legion/human/archer.glb",
      MageUnit: DataRoot & "/characters/mini_legion/human/mage.glb",
      KnightUnit: DataRoot & "/characters/mini_legion/human/horseman.glb",
      CatapultUnit: DataRoot &
        "/characters/mini_legion/human/siege_engine.glb",
      ClericUnit: DataRoot & "/characters/mini_legion/sentinel/druid.glb",
      SummonUnit: DataRoot &
        "/characters/mini_legion/sentinel/rock_golem.glb"
    ],
    [
      PeonUnit: DataRoot & "/characters/mini_legion/warband/minion.glb",
      SoldierUnit: DataRoot & "/characters/mini_legion/warband/grunt.glb",
      ArcherUnit: DataRoot &
        "/characters/mini_legion/warband/head_hunter.glb",
      MageUnit: DataRoot & "/characters/mini_legion/warband/warlock.glb",
      KnightUnit: DataRoot &
        "/characters/mini_legion/warband/hog_rider.glb",
      CatapultUnit: DataRoot &
        "/characters/mini_legion/undead/siege_engine.glb",
      ClericUnit: DataRoot & "/characters/mini_legion/undead/lich.glb",
      SummonUnit: DataRoot & "/characters/rpg_monsters/demon_king.glb"
    ]
  ]
  UnitHeights* = [
    PeonUnit: 1.05'f,
    SoldierUnit: 1.15'f,
    ArcherUnit: 1.20'f,
    MageUnit: 1.25'f,
    KnightUnit: 1.55'f,
    CatapultUnit: 1.40'f,
    ClericUnit: 1.22'f,
    SummonUnit: 1.90'f
  ]
  LightPropPack* = DataRoot & "/terrain/low_poly_village.glb"
  DarkPropPack* = DataRoot & "/terrain/tower_defense_kit.glb"
  BuildingProps* = [
    [
      TownHallBuilding: "house_lvl7",
      FarmBuilding: "farm_lvl4",
      BarracksBuilding: "farm_house_lvl5",
      LumberMillBuilding: "farm_house_lvl3",
      TowerBuilding: "tower_lvl5",
      StablesBuilding: "farm_house_lvl6",
      ChurchBuilding: "house_lvl4",
      BlacksmithBuilding: "farm_house_lvl2",
      GoldMineBuilding: ""
    ],
    [
      TownHallBuilding: "building1",
      FarmBuilding: "farm_lvl2",
      BarracksBuilding: "building3",
      LumberMillBuilding: "building2",
      TowerBuilding: "tower_square_tall1",
      StablesBuilding: "tower_tall1",
      ChurchBuilding: "tower_square_tall2",
      BlacksmithBuilding: "tower_square_small1",
      GoldMineBuilding: ""
    ]
  ]
  BuildingPropHeights* = [
    TownHallBuilding: 3.0'f,
    FarmBuilding: 1.6'f,
    BarracksBuilding: 2.6'f,
    LumberMillBuilding: 2.4'f,
    TowerBuilding: 3.2'f,
    StablesBuilding: 2.5'f,
    ChurchBuilding: 2.8'f,
    BlacksmithBuilding: 2.2'f,
    GoldMineBuilding: 1.8'f
  ]
  MineProps* = ["mineral1", "mineral3", "rock2"]
  ConstructionProps* = ["box1", "barel1", "wall1"]
  RubbleProps* = ["rock1", "stump1"]

proc unitPortraitPath*(player: int32, kind: UnitKind): string =
  ## Returns the on-disk profile next to one unit model.
  UnitModels[player][kind].changeFileExt("profile.png")

proc buildingPack*(player: int32, kind: BuildingKind): string =
  ## Returns the GLB pack that holds this building's prop.
  if kind == GoldMineBuilding:
    DarkPropPack
  elif player == LightPlayer or kind == FarmBuilding:
    LightPropPack
  else:
    DarkPropPack

proc buildingPortraitPath*(player: int32, kind: BuildingKind): string =
  ## Returns the on-disk profile for one building prop.
  if kind == GoldMineBuilding:
    DarkPropPack.changeFileExt("mineral1.profile.png")
  else:
    buildingPack(player, kind).changeFileExt(
      BuildingProps[player][kind] & ".profile.png"
    )

proc lightProps*(): seq[string] =
  ## Returns all village props used by either faction.
  for player in 0'i32 ..< PlayerCount:
    for kind in BuildingKind:
      if kind != GoldMineBuilding and buildingPack(player, kind) == LightPropPack:
        let name = BuildingProps[player][kind]
        if name notin result:
          result.add name

proc darkProps*(): seq[string] =
  ## Includes completed, construction, rubble, and mine tower-kit props.
  result = @MineProps & @ConstructionProps & @RubbleProps
  for player in 0'i32 ..< PlayerCount:
    for kind in BuildingKind:
      if kind != GoldMineBuilding and buildingPack(player, kind) == DarkPropPack:
        let name = BuildingProps[player][kind]
        if name notin result:
          result.add name

proc browserAssets*(): seq[Asset] =
  ## Declares every presentation asset reachable by either faction.
  result = hudAssets(LogoPath)
  result.add terrainAssets(
    DenseTrees, GeneratedTerrain, PaintedRocks, WebTerrainAssets
  )
  result.add propAssets(LightPropPack, lightProps())
  result.add propAssets(DarkPropPack, darkProps())
  for player in 0'i32 ..< PlayerCount:
    for kind in UnitKind:
      result.add modelAsset(UnitModels[player][kind])
      result.add fileAsset(unitPortraitPath(player, kind))
    for kind in BuildingKind:
      result.add fileAsset(buildingPortraitPath(player, kind))
