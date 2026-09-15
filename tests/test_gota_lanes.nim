import
  std/sequtils,
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

echo "Testing tower tiles block terrain paths across map sizes"
for size in [64, 96, 100, 116, 128, 192, 256]:
  var preset = defaultConfig()
  preset.mapSize = size
  let game = newGame(generateMap(2026, preset), 240, 0, false, ReplayData())
  for tower in game.world.towers:
    let
      x = int(mapCoordinate(tower.position.x))
      z = int(mapCoordinate(tower.position.z))
    doAssert layers[GroundLayer].tiles[z * size + x].impassable
    doAssert not isWalkable(GroundLayer, x, z)
  for lane in 0 .. 2:
    var previous: PathTile
    for i, point in lanePathPoints[lane]:
      let tile = PathTile(layer: GroundLayer,
        x: (point.x + int32(size div 2) * PathUnitsPerTile) div PathUnitsPerTile,
        z: (point.z + int32(size div 2) * PathUnitsPerTile) div PathUnitsPerTile)
      doAssert isWalkable(int(tile.layer), int(tile.x), int(tile.z))
      if i > 0:
        doAssert lineClear(previous, tile)
      previous = tile

echo "Testing both teams march past their towers in every lane"
for team in Team:
  let game = newGame(generateMap(2026), 100_000, 0, false, ReplayData())
  game.world.heroTurnTicks = 100_000
  game.world.spawnTimerTicks = 1
  game.tickWorld(nil)
  var wave: seq[Footman]
  for footman in game.world.footmen:
    if footman.team == team:
      wave.add footman
  game.world.footmen = wave
  doAssert wave.len > 0, "no creeps spawned"
  # Keep the opposing towers physical but prevent combat from interrupting
  # the march. Every creep must reach the middle of its lane.
  for tower in game.world.towers.mitems:
    tower.team = team
  var reached = newSeq[bool](wave.len)
  for tick in 0 ..< TickRate * 180:
    game.tickWorld(nil)
    doAssert game.world.footmen.len == wave.len
    for i, footman in game.world.footmen:
      if footman.waypointIndex >= lanePathPoints[footman.lane].len div 2:
        reached[i] = true
    if reached.allIt(it):
      break
  for i, passed in reached:
    doAssert passed, $team & " creep in lane " & $wave[i].lane &
      " stuck at waypoint " & $game.world.footmen[i].waypointIndex
