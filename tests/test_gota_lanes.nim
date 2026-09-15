import
  std/[math, sequtils],
  polyworld/pathing,
  ../examples/gods_of_the_arena/[content, maps, replays, sim]

echo "Testing lane segments clear tower collision footprints"
for size in [64, 96, 100, 116, 128, 192, 256]:
  var preset = defaultConfig()
  preset.mapSize = size
  let game = newGame(generateMap(2026, preset), 240, 0, false, ReplayData())
  for lane in 0 .. 2:
    let route = lanePathPoints[lane]
    for i in 1 ..< route.len:
      let
        a = route[i - 1]
        b = route[i]
        ax = a.x.float64 / PathUnitsPerTile.float64
        az = a.z.float64 / PathUnitsPerTile.float64
        dx = (b.x - a.x).float64 / PathUnitsPerTile.float64
        dz = (b.z - a.z).float64 / PathUnitsPerTile.float64
      for tower in game.world.towers:
        let
          tx = tower.position.x.float64 / WorldScale.float64
          tz = tower.position.z.float64 / WorldScale.float64
          t = clamp(((tx - ax) * dx + (tz - az) * dz) /
            (dx * dx + dz * dz), 0.0, 1.0)
          distance = hypot(ax + t * dx - tx, az + t * dz - tz)
          clearance = 0.22 + [0.42, 0.55, 0.70][tower.tier.ord]
        doAssert distance >= clearance,
          "lane " & $lane & " segment " & $i & " crosses tower " &
          $tower.id & " at distance " & $distance

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
