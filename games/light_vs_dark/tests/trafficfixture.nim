## Fixed, art/bot-free traffic workloads shared by regression and profiling.
import ../[content, maps, sim], fixxy, polyworld/pathing
export content, maps, sim, fixxy

type TrafficFixture* = object
  world*: World
  ids*: seq[int32]
  starts*, goals*: seq[FixedVec2]

proc trafficFixture*(count: int, scenario: string): TrafficFixture =
  const Side = 80'i32
  var map = MapData(seed: 73021, side: Side,
    passable: newSeq[uint8](Side * Side), kinds: newSeq[uint8](Side * Side),
    treeWood: newSeq[int16](Side * Side), heights: newSeq[int16](Side * Side),
    hallOrigin: @[tile2(3, 3), tile2(72, 72)],
    mines: @[MineSpot(id: FirstMineId, origin: tile2(57, 39), gold: 1000000)])
  let layer = QuadLayer(width: Side.int, depth: Side.int,
    tiles: newSeq[Tile](Side * Side))
  for i in 0 ..< map.passable.len:
    map.passable[i] = 1
    layer.tiles[i].flags = TileExists or TileConnectedEast or TileConnectedSouth
  map.terrain = @[layer]
  let w = newWorld(map, 100000)
  # Remove opening peons; retain real buildings, lookup tables and victory rules.
  w.units.setLen(0)
  for slot in w.unitSlot.mitems: slot = -1
  for tile in w.occupancy.mitems: tile = 0
  if scenario == "choke":
    for y in 10'i32 .. 69'i32:
      if y notin 37'i32 .. 43'i32:
        w.blocker[map.tileIndex(40, y)] = TreeBlocker
  if scenario == "miners":
    for b in w.buildings.mitems:
      if b.kind == TownHallBuilding and b.owner == 0:
        for tile in w.blocker.mitems:
          if tile == b.id: tile = 0
        b.origin = tile2(20, 39)
        for y in 0 ..< b.footprint.depth:
          for x in 0 ..< b.footprint.width:
            w.blocker[map.tileIndex(b.origin.x.int32+x, b.origin.y.int32+y)] = b.id
  result.world = w
  for i in 0 ..< count:
    let group = i mod 2
    let rank = i div 2
    let lane = int32(rank mod 15 - 7)
    let depth = int32(rank div 15)
    var start = if group == 0: tile2(28-depth, 40+lane) else: tile2(52+depth, 40+lane)
    var goal = if group == 0: tile2(52+depth, 40+lane) else: tile2(28-depth, 40+lane)
    if scenario == "crossing" and group == 1:
      start = tile2(40+lane, 28-depth)
      goal = tile2(40+lane, 52+depth)
    if count == 2 and scenario != "miners":
      start = if group == 0: tile2(37,40) else: tile2(43,40)
      goal = if group == 0: tile2(43,40) else: tile2(37,40)
      if scenario == "crossing" and group == 1:
        start = tile2(40,37)
        goal = tile2(40,43)
    let kind = if scenario == "miners": PeonUnit else: SoldierUnit
    let id = w.spawnUnit(0, kind, start)
    result.ids.add id
    result.starts.add w.units[w.unitIndex(id)].body.pos
    result.goals.add fixedVec2(fixed(goal.x.int32)+FixedHalf, fixed(goal.y.int32)+FixedHalf)
    if scenario == "miners":
      doAssert w.applyHarvest(0, id, FirstMineId, 0)
    else:
      doAssert w.applyMove(0, id, goal.x.int32, goal.y.int32)
