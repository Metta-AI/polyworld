## Selection details read the live primary unit, never player stockpiles.
import std/[os, strutils, unittest]
import ../[content, maps, sim, hudpresentation]

suite "LvD cargo HUD integration":
  test "primary portrait cargo is drawn every frame with reserved grid space":
    let source = readFile(currentSourcePath().parentDir / "../ui.nim")
    check source.contains("sk.drawWorkerCargo(")
    check source.contains("selectionPanels(portraitWorker != nil)")

  test "build styling uses authoritative affordability and prerequisites, not UI guesses":
    let source = readFile(currentSourcePath().parentDir / "../ui.nim")
    check source.contains("sk.drawBuildPortrait(")
    check source.contains("run.world.canBuild(player, kind)")
    check source.contains("sk.drawSlotCosts(slot, stats.gold, stats.wood)")
    check source.contains("pendingBuild = int32(kind.ord)")
    check source.contains("buildingTooltipTarget(kind, player)")
    let world = newWorld(generateMap(DefaultSeed), TickRate * 120)
    world.players[0].gold = BuildingTable[FarmBuilding].gold
    world.players[0].wood = BuildingTable[FarmBuilding].wood
    check world.canBuild(0, FarmBuilding)
    dec world.players[0].gold
    check not world.canBuild(0, FarmBuilding)
    inc world.players[0].gold
    dec world.players[0].wood
    check not world.canBuild(0, FarmBuilding)
    world.players[0].gold = 10000
    world.players[0].wood = 10000
    check not world.canBuild(0, TowerBuilding)
    # Complete the actual required structure without inventing a UI tech flag.
    for building in world.buildings.mitems:
      if building.owner == 0 and building.kind == TownHallBuilding:
        building.kind = LumberMillBuilding
    check world.canBuild(0, TowerBuilding)

suite "LvD selected worker cargo":
  test "type and amount follow the current worker, including empty":
    let worker = Unit(kind: PeonUnit)
    check worker.cargoLabel == "CARGO: EMPTY"
    worker.carryGold = 37
    check worker.cargoLabel == "GOLD 37"
    worker.carryGold = 0
    worker.carryWood = 24
    check worker.cargoLabel == "WOOD 24"
    worker.carryGold = 10
    check worker.cargoLabel == "GOLD 10 / WOOD 24"
    worker.carryGold = 0
    worker.carryWood = 0
    check worker.cargoLabel == "CARGO: EMPTY"
    let soldier = Unit(kind: SoldierUnit, carryGold: 50)
    check soldier.cargoLabel == ""
    check cargoLabel(nil) == ""

  test "actual gold harvest and deposit change the label without selection changes":
    let world = newWorld(generateMap(DefaultSeed), TickRate * 120)
    let worker = world.units[0]
    check worker.cargoLabel == "CARGO: EMPTY"
    check world.applyHarvest(worker.owner, worker.id, world.buildings[0].id, 0)
    var sawCargo, sawDeposit: bool
    for tick in 0 ..< TickRate * 100:
      world.tickWorld(nil)
      if worker.carryGold > 0:
        sawCargo = true
        check worker.cargoLabel == "GOLD " & $worker.carryGold
      elif sawCargo:
        sawDeposit = true
        check worker.cargoLabel == "CARGO: EMPTY"
        break
    check sawCargo
    check sawDeposit

  test "actual wood harvest and deposit update the same selected worker":
    let world = newWorld(generateMap(DefaultSeed), TickRate * 120)
    let worker = world.units[0]
    var nearest = -1'i32
    var distance = high(int32)
    for i, wood in world.treeWood:
      if wood <= 0: continue
      let tile = tile2(i.int32 mod world.map.side, i.int32 div world.map.side)
      let d = tileDistance(worker.tile, tile)
      if d < distance:
        distance = d
        nearest = i.int32
    check nearest >= 0
    check world.applyHarvest(worker.owner, worker.id, nearest, 1)
    var sawCargo, sawDeposit: bool
    let before = world.players[worker.owner].wood
    for tick in 0 ..< TickRate * 100:
      world.tickWorld(nil)
      if worker.carryWood > 0:
        sawCargo = true
        check worker.cargoLabel == "WOOD " & $worker.carryWood
      elif sawCargo:
        sawDeposit = true
        check worker.cargoLabel == "CARGO: EMPTY"
        break
    check sawCargo
    check sawDeposit
    check world.players[worker.owner].wood > before
