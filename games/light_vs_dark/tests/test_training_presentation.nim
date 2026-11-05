## Counts come from the same primary producer targeted by the train button.
import std/unittest
import ../[content, maps, sim, hudpresentation]

proc fixture(): tuple[world: World, producer: int32] =
  result.world = newWorld(generateMap(DefaultSeed), TickRate * 120)
  result.world.players[0].gold = 100000
  result.world.players[0].wood = 100000
  result.world.players[0].foodCap = 100
  for building in result.world.buildings:
    if building.owner == 0 and building.kind == TownHallBuilding:
      result.producer = building.id
      break

suite "LvD training queue badge counts":
  test "includes active slot and counts only the requested unit kind":
    let (world, producer) = fixture()
    check world.applyTrain(0, producer, PeonUnit.ord.int32)
    check world.applyTrain(0, producer, PeonUnit.ord.int32)
    check world.buildings[world.buildingIndex(producer)].trainTicks > 0
    check world.trainingQueueCount(0, producer, PeonUnit) == 2
    check world.trainingQueueCount(0, producer, SoldierUnit) == 0
    check world.trainingQueueCount(0, producer, ArcherUnit) == 0

  test "completion and cancel update the live count without changing selection":
    let (world, producer) = fixture()
    check world.applyTrain(0, producer, PeonUnit.ord.int32)
    check world.applyTrain(0, producer, PeonUnit.ord.int32)
    check world.applyTrain(0, producer, PeonUnit.ord.int32)
    check world.trainingQueueCount(0, producer, PeonUnit) == 3
    check world.applyCancel(0, producer)
    check world.trainingQueueCount(0, producer, PeonUnit) == 2
    let before = world.players[0].unitsTrained
    world.buildings[world.buildingIndex(producer)].trainTicks = 1
    world.tickWorld(nil)
    check world.players[0].unitsTrained == before + 1
    check world.trainingQueueCount(0, producer, PeonUnit) == 1
    check world.applyCancel(0, producer)
    check world.trainingQueueCount(0, producer, PeonUnit) == 0
    check world.players[0].unitsTrained == before + 1

  test "no selection, units, enemy, dead and incompatible buildings show zero":
    let (world, producer) = fixture()
    check world.applyTrain(0, producer, PeonUnit.ord.int32)
    check world.trainingQueueCount(0, NoEntity, PeonUnit) == 0
    check world.trainingQueueCount(0, world.units[0].id, PeonUnit) == 0
    check world.trainingQueueCount(1, producer, PeonUnit) == 0
    let index = world.buildingIndex(producer)
    world.buildings[index].kind = BarracksBuilding
    check world.trainingQueueCount(0, producer, PeonUnit) == 0
    world.buildings[index].kind = TownHallBuilding
    world.buildings[index].state = BuildingUnderConstruction
    check world.trainingQueueCount(0, producer, PeonUnit) == 0
    world.buildings[index].state = BuildingDying
    check world.trainingQueueCount(0, producer, PeonUnit) == 0
    world.buildings[index].state = BuildingComplete
    world.buildings[index].hp = 0
    check world.trainingQueueCount(0, producer, PeonUnit) == 0

  test "count remains visible when resources, food or queue capacity prevent another order":
    let (world, producer) = fixture()
    for i in 0 ..< QueueSlots:
      check world.applyTrain(0, producer, PeonUnit.ord.int32)
    check not world.canTrain(producer, PeonUnit)
    check world.trainingQueueCount(0, producer, PeonUnit) == QueueSlots
    world.players[0].gold = 0
    world.players[0].foodCap = 0
    check world.trainingQueueCount(0, producer, PeonUnit) == QueueSlots

  test "mixed queue counts only the matching kind and never another producer":
    let (world, producer) = fixture()
    let index = world.buildingIndex(producer)
    world.buildings[index].kind = BarracksBuilding
    # The queue is authoritative; inject two compatible kinds without building
    # a lumber mill solely to satisfy archer admission prerequisites.
    world.buildings[index].queueLength = 3
    world.buildings[index].queue[0] = uint8(SoldierUnit.ord + 1)
    world.buildings[index].queue[1] = uint8(ArcherUnit.ord + 1)
    world.buildings[index].queue[2] = uint8(SoldierUnit.ord + 1)
    check world.trainingQueueCount(0, producer, SoldierUnit) == 2
    check world.trainingQueueCount(0, producer, ArcherUnit) == 1
    for building in world.buildings:
      if building.id != producer:
        check world.trainingQueueCount(0, building.id, SoldierUnit) == 0
    # Old storage beyond queueLength must never count, even before it is cleared.
    world.buildings[index].queueLength = 1
    check world.trainingQueueCount(0, producer, SoldierUnit) == 1
    check world.trainingQueueCount(0, producer, ArcherUnit) == 0
