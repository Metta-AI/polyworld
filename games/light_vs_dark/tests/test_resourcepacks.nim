import ../[content, maps, resourcepacks, sim]

proc pack(unit: Unit): ResourcePack =
  ## Reads cargo through the same presentation decision used by graphics.
  carriedPack(unit.kind, unit.hp, unit.carryGold, unit.carryWood)

for resource in 0 .. 1:
  let
    game = newGame(generateMap(DefaultSeed), TickRate * 180)
    world = game.world
    worker = world.units[0]
    expected = if resource == 0: GoldPack else: WoodPack
  var
    target = NoEntity
    nearest = int32.high
  if resource == 0:
    for mine in world.map.mines:
      let distance = tileDistance(worker.tile, mine.origin)
      if distance < nearest:
        target = mine.id
        nearest = distance
  else:
    for i, wood in world.treeWood:
      if wood > 0:
        let distance = tileDistance(
          worker.tile,
          tile2(i.int32 mod world.map.side, i.int32 div world.map.side)
        )
        if distance < nearest:
          target = i.int32
          nearest = distance
  doAssert worker.pack == NoPack
  doAssert world.applyHarvest(worker.owner, worker.id, target, resource.int32)
  var collected = false
  for tick in 0 ..< TickRate * 120:
    world.tickWorld(nil)
    if worker.carryGold + worker.carryWood > 0:
      doAssert worker.pack == expected
      collected = true
    elif collected:
      doAssert worker.pack == NoPack
      break
  doAssert collected and worker.carryGold + worker.carryWood == 0
  worker.carryGold = 25
  doAssert world.applyCancel(worker.owner, worker.id)
  let before = game.stateHash()
  doAssert worker.pack == GoldPack
  doAssert game.stateHash() == before
  worker.carryGold = 0
  doAssert worker.pack == NoPack
  worker.carryWood = 10
  doAssert worker.pack == WoodPack
  worker.hp = 0
  doAssert worker.pack == NoPack
  worker.kind = SoldierUnit
  worker.hp = 10
  doAssert worker.pack == NoPack

echo "Resource backpacks follow cargo, delivery, interrupted orders and death"
