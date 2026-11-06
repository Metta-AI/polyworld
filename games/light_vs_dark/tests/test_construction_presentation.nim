## Render-only builder placement, exercised through actual queued construction.
import std/unittest
import fixxy, vmath
import ../[content, maps, sim, controls, constructionpresentation]

let arenaMap = generateMap(DefaultSeed)
proc arena(x, y: int32): Tile2 =
  tile2(arenaMap.side div 2 + x, arenaMap.side div 2 + y)
proc fixture(): Game =
  clearPlayerCommands()
  result = newGame(arenaMap, TickRate * 180)
  result.world.players[0].gold = 10000
  result.world.players[0].wood = 10000
  result.world.place(result.world.units[0], arena(-10, 0))
proc step(game: Game, ticks = 1'i32) =
  for _ in 0 ..< ticks:
    game.world.tickWorld(proc(w: World) = game.flushPlayerCommands())
proc startSite(game: Game, origin = arena(-4, 0)): int32 =
  let worker = game.world.units[0]
  queueBuild(0, worker.id, FarmBuilding.ord.int32,
    origin.x.int32, origin.y.int32)
  game.step(DecisionTicks)
  result = game.world.buildingIndex(worker.targetId)
  doAssert result >= 0
  for _ in 0 ..< TickRate * 30:
    if worker.state == UnitBuilding: break
    game.step()
  doAssert worker.state == UnitBuilding

suite "construction presentation":
  test "real active builder works inside its site without moving its body":
    let game = fixture()
    let siteIndex = game.startSite()
    let w = game.world
    let worker = w.units[0]
    let site = w.buildings[siteIndex]
    let beforeBody = worker.body
    let beforePath = worker.path
    let beforeProgress = site.buildTicks
    let pose = w.constructionPresentation(worker)
    check pose.active
    check pose.siteId == site.id
    check pose.tilePoint.x > site.origin.x.float32
    check pose.tilePoint.x < site.origin.x.float32 + site.footprint.width.float32
    check pose.tilePoint.y > site.origin.y.float32
    check pose.tilePoint.y < site.origin.y.float32 + site.footprint.depth.float32
    check pose.tilePoint != vec2(toFloat32(worker.body.pos.x), toFloat32(worker.body.pos.y))
    check pose.animation == AttackAnimation # existing Peon Interact work clip
    check pose.floorLift >= 0.08'f32 # feet clear raised authored foundations
    check worker.body == beforeBody
    check worker.path == beforePath
    check w.buildings[siteIndex].buildTicks == beforeProgress

  test "only the exact living owned in-range active builder gets an interior pose":
    let game = fixture()
    let siteIndex = game.startSite()
    let w = game.world
    let worker = w.units[0]
    let originalTarget = worker.targetId
    let originalOwner = worker.owner
    let originalHp = worker.hp
    let originalKind = worker.kind
    let originalTile = worker.tile
    for state in UnitState:
      if state == UnitBuilding: continue
      worker.state = state
      check not w.constructionPresentation(worker).active
    worker.state = UnitBuilding
    worker.targetId = NoEntity
    check not w.constructionPresentation(worker).active
    worker.targetId = originalTarget
    w.buildings[siteIndex].builderId = w.units[1].id
    check not w.constructionPresentation(worker).active
    w.buildings[siteIndex].builderId = worker.id
    worker.owner = originalOwner + 1
    check not w.constructionPresentation(worker).active
    worker.owner = originalOwner
    worker.kind = SoldierUnit
    check not w.constructionPresentation(worker).active
    worker.kind = originalKind
    worker.hp = 0
    check not w.constructionPresentation(worker).active
    worker.hp = originalHp
    w.place(worker, arena(-10, -5))
    check not w.constructionPresentation(worker).active
    w.place(worker, w.buildings[siteIndex].origin)
    require w.buildings[siteIndex].constructionInRange(worker)
    check w.constructionPresentation(worker).active
    w.place(worker, originalTile)
    for state in [BuildingComplete, BuildingDying]:
      w.buildings[siteIndex].state = state
      check not w.constructionPresentation(worker).active
    w.buildings[siteIndex].state = BuildingUnderConstruction
    check w.constructionPresentation(worker).active

  test "real cancel resume completion and harvesting restore ordinary presentation":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let siteIndex = game.startSite()
    let origin = w.buildings[siteIndex].origin
    queueCancel(0, worker.id)
    game.step(DecisionTicks)
    check not w.constructionPresentation(worker).active
    discard game.startSite(origin)
    check w.constructionPresentation(worker).active
    while w.buildings[siteIndex].state == BuildingUnderConstruction:
      let before = game.stateHash()
      discard w.constructionPresentation(worker)
      check game.stateHash() == before
      game.step()
    check not w.constructionPresentation(worker).active
    check worker.state == UnitIdle
    discard game.startSite(arena(6, 0))
    check w.constructionPresentation(worker).active
    var mineId = NoEntity
    for structure in w.buildings:
      if structure.kind == GoldMineBuilding:
        mineId = structure.id
        break
    require mineId != NoEntity
    queueHarvest(0, worker.id, mineId, 0)
    game.step(DecisionTicks)
    check worker.state notin {UnitBuilding, UnitToBuild}
    check not w.constructionPresentation(worker).active

  test "retargeting and destruction never retain the old site's work pose":
    let game = fixture()
    let w = game.world
    let worker = w.units[0]
    let first = game.startSite()
    let second = game.startSite(arena(6, 0))
    check w.constructionPresentation(worker).siteId == w.buildings[second].id
    w.damageEntity(w.buildings[first].id, w.buildings[first].hp)
    check w.constructionPresentation(worker).siteId == w.buildings[second].id
    w.damageEntity(w.buildings[second].id, w.buildings[second].hp)
    check not w.constructionPresentation(worker).active
