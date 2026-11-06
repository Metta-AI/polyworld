## Read-only presentation visibility, deliberately distinct from targeting rules.
import trafficfixture
import ../diplomacies
when defined(legacyRenderVisibility):
  proc renderBuildingVisible(w: World, mode: int32, b: Building): bool =
    mode == 0 or w.buildingVisible(mode - 1, b)
  proc renderUnitVisible(w: World, mode: int32, u: Unit): bool =
    u.state != UnitInMine and (mode == 0 or w.unitVisible(mode - 1, u))
else:
  import ../rendervisibility

let w = trafficFixture(0, "open").world
block currentUnitSight:
  let id = w.spawnUnit(0, SoldierUnit, tile2(40, 20))
  let unit = w.units[w.unitIndex(id)]
  w.rebuildVision()
  doAssert renderUnitVisible(w, 1, unit)
  unit.state = UnitDying
  w.rebuildVision()
  doAssert not w.visible(0, unit.tile)
  doAssert renderUnitVisible(w, 1, unit), "Owned units remain visible"
  unit.state = UnitInMine
  doAssert not renderUnitVisible(w, 0, unit)
  unit.state = UnitIdle
  w.rebuildVision()
  doAssert renderUnitVisible(w, 1, unit)
var ownIndex = -1
for i, b in w.buildings:
  if b.owner == 0: ownIndex = i
assert ownIndex >= 0
template own: untyped = w.buildings[ownIndex]
doAssert own.owner == 0
w.rebuildVision()
doAssert w.visible(0, own.origin)
doAssert renderBuildingVisible(w, 1, own)
own.state = BuildingDying
w.rebuildVision()
doAssert not w.visible(0, own.origin)
doAssert w.explored(0, own.origin.x.int32, own.origin.y.int32)
doAssert renderBuildingVisible(w, 1, own),
  "Owned buildings remain visible even without current sight"
when not defined(legacyRenderVisibility):
  let before = Game(world: w).stateHash()
  doAssert renderBuildingVisible(w, 0, own), "Designated omniscient retains view"
  doAssert not renderBuildingVisible(w, -1, own)
  doAssert not renderBuildingVisible(w, 99, own)
  let idx = w.map.tileIndex(own.origin.x.int32, own.origin.y.int32)
  doAssert renderVisibilityValues(w, 1, CurrentSightMask)[idx] == 0
  doAssert renderVisibilityValues(w, 1, TerrainMemoryMask)[idx] == 48
  doAssert renderVisibilityValues(w, 0, CurrentSightMask)[idx] == 255
  doAssert not renderTileVisible(w, 1, -1, 0)
  doAssert Game(world: w).stateHash() == before
  own.state = BuildingComplete
  w.rebuildVision()
  doAssert renderBuildingVisible(w, 1, own)
  doAssert renderVisibilityValues(w, 1, CurrentSightMask)[idx] == 255
  doAssert renderAreaVisible(w, 1, own.origin.x.float32 + 0.5,
    own.origin.y.float32 + 0.5, 0.2)
  doAssert not renderAreaVisible(w, 1, -0.1, 0.5, 0.2)
  echo "Owned entities remain visible; fog masks remain read-only"

  var enemyIndex = -1
  for i, b in w.buildings:
    if b.owner == 1: enemyIndex = i
  doAssert enemyIndex >= 0
  template enemy: untyped = w.buildings[enemyIndex]
  doAssert not renderBuildingVisible(w, 1, enemy)
  w.diplomacy = initDiplomacy(2, DiplomacySettings(neutralStart: true,
    warGraceSeconds: 1))
  doAssert w.applyDiplomacy(0, 1, OfferAlliance)
  doAssert w.applyDiplomacy(1, 0, AcceptOffer, w.diplomacy.relation(0, 1).offerId)
  w.rebuildVision()
  doAssert renderBuildingVisible(w, 1, enemy)
  let allied = w.clone()
  doAssert w.applyDiplomacy(0, 1, EndAlliance)
  doAssert renderBuildingVisible(w, 1, enemy), "Grace period retains allied vision"
  for _ in 1 .. TickRate * 2: w.tickWorld(nil)
  w.rebuildVision()
  doAssert not renderBuildingVisible(w, 1, enemy)
  doAssert w.explored(0, enemy.origin.x.int32, enemy.origin.y.int32)
  doAssert renderBuildingVisible(allied, 1, allied.buildings[enemyIndex])
  w.restore(allied)
  doAssert renderBuildingVisible(w, 1, enemy)
  echo "Authoritative allied sight -> alliance withdrawal -> explored hidden -> restored passed"

block resourcesAndWholeBuildings:
  let world = trafficFixture(0, "open").world
  for stamp in world.visibleStamp[0].mitems:
    stamp = 0
  var mineIndex = -1
  var enemyIndex = -1
  for i, building in world.buildings:
    if building.kind == GoldMineBuilding:
      mineIndex = i
    elif building.owner == 1:
      enemyIndex = i
  doAssert mineIndex >= 0 and enemyIndex >= 0
  let
    mine = world.buildings[mineIndex]
    enemy = world.buildings[enemyIndex]
  doAssert world.renderBuildingVisible(1, mine)
  doAssert not world.renderBuildingVisible(1, enemy)
  let corner = world.map.tileIndex(enemy.origin)
  world.visibleStamp[0][corner] = world.visionGeneration[0]
  doAssert world.renderBuildingVisible(1, enemy)
  world.visibleStamp[0][corner] = 0
  doAssert not world.renderBuildingVisible(1, enemy)
  doAssert world.renderBuildingVisible(1, mine)
  echo "Mines ignore fog; one visible building cell reveals the whole object"
