## A solid destination keeps intent, not recurring whole-map A* work.
import trafficfixture
import ../[controls, replays], polyworld/tapes

block retainedBlockedEndpoint:
  let f = trafficFixture(1, "opposing")
  let w = f.world
  let u = w.units[0]
  u.kind = PeonUnit
  doAssert w.applyMove(0, u.id, 58, 40)
  doAssert w.applyMove(0, u.id, 48, 35, append=true)
  pathSearches = 0
  pathExpansions = 0
  for tick in 0 ..< 900: w.tickWorld(nil)
  echo "Blocked target searches=", pathSearches, " expansions=", pathExpansions
  doAssert pathExpansions <= MaxPathExpansions,
    "Unchanged solid target must retain its partial endpoint, not search the map again"
  doAssert u.goal == tile2(58,40) and u.hasGoal
  doAssert u.orderQueue.len == 1 and not u.orderFailed
  doAssert tileDistance(u.tile,u.goal) <= 2
  # Displacement is not a reason to forget the proven partial endpoint.
  w.place(u,tile2(50,40))
  let expansions = pathExpansions
  for tick in 0 ..< 300: w.tickWorld(nil)
  doAssert tileDistance(u.tile,u.goal) <= 2
  doAssert pathExpansions-expansions < 100
  doAssert u.goal == tile2(58,40) and u.orderQueue.len == 1
  # Real building destruction opens the original destination. Both peers must
  # discard the cached partial result and finish the exact order before Shift.
  # Neutral mines are indestructible; use the same footprint as an owned
  # structure so the production damage/raze/release path is exercised.
  w.buildings[w.buildingIndex(FirstMineId)].owner = 0
  let peer = w.clone()
  w.damageEntity(FirstMineId,1000000)
  peer.damageEntity(FirstMineId,1000000)
  var reachedOriginal = false
  for tick in 0 ..< 900:
    w.tickWorld(nil)
    peer.tickWorld(nil)
    if u.tile == tile2(58,40): reachedOriginal = true
    doAssert Game(world:w).stateHash() == Game(world:peer).stateHash()
  doAssert reachedOriginal
  doAssert u.orderQueue.len == 0 and u.state == UnitIdle
  doAssert length(u.body.pos-fixedVec2(48.5'fx,35.5'fx)) <= 0.4'fx

block partialEndpointIsAuthoritativeState:
  let w = trafficFixture(1, "opposing").world
  let u = w.units[0]
  doAssert w.applyMove(0,u.id,58,40)
  for tick in 0 ..< 900: w.tickWorld(nil)
  doAssert u.blockedEndpointValid
  let saved = w.clone()
  let original = Game(world:w).stateHash()
  u.blockedEndpointValid = false
  doAssert Game(world:w).stateHash() != original
  w.restore(saved)
  doAssert Game(world:w).stateHash() == original
  inc w.pathTerrainRevision
  doAssert Game(world:w).stateHash() != original
  w.restore(saved)
  doAssert w.applyMove(0,w.units[0].id,48,35, fixedVec2(0.2'fx,0.1'fx))
  doAssert not w.units[0].blockedEndpointValid
  for tick in 0 ..< 900: w.tickWorld(nil)
  doAssert length(w.units[0].body.pos-fixedVec2(48.7'fx,35.6'fx)) <= 0.001'fx

block unknownPartialRouteIsNotAProof:
  let w = trafficFixture(1, "opposing").world
  # An inaccessible mine behind a wall has a closer legal tile on the far
  # side. The bounded partial route must not be mistaken for a nearest proof.
  for y in 0'i32 ..< w.map.side: w.blocker[w.map.tileIndex(50,y)] = TreeBlocker
  let u = w.units[0]
  doAssert w.applyMove(0,u.id,58,40)
  for tick in 0 ..< 900: w.tickWorld(nil)
  doAssert not u.blockedEndpointValid and u.goal == tile2(58,40)
  # A later replacement is still immediate, not swallowed by partial state.
  doAssert w.applyMove(0,u.id,45,35)
  for tick in 0 ..< 900: w.tickWorld(nil)
  doAssert u.state == UnitIdle and u.tile == tile2(45,35)

block blockedGoalSerializedReplay:
  let map = trafficFixture(0,"opposing").world.map
  const Duration = 2700'i32
  let game = newGame(map,Duration)
  var setup = Setup(mapSeed: map.seed, tickRate: uint16(TickRate),
    gridTiles: uint16(map.side), decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(Duration), mapHash: 1, contentHash: contentHash())
  for i,origin in map.hallOrigin:
    setup.players.add ReplayPlayerSetup(id:i.int32,startX:origin.x,startY:origin.y)
  game.recorder = initReplayRecorder(setup)
  let unit = game.world.units[0]
  clearPlayerCommands()
  queueMove(0,unit.id,58,40)
  queueMove(0,unit.id,48,35,append=true)
  proc decide(w: World) = game.flushPlayerCommands()
  var sawRetained = false
  for tick in 0 ..< Duration:
    if tick == 1800:
      doAssert unit.goal == tile2(58,40) and unit.orderQueue.len == 1
      queueMove(0,unit.id,48,35)
    game.world.tickWorld(decide)
    if unit.blockedEndpointValid: sawRetained = true
    game.recorder.recordHash(game.stateHash())
  doAssert sawRetained and unit.state == UnitIdle and unit.tile == tile2(48,35)
  let data = decodeReplay(encodeReplay(game.recorder.data))
  doAssert data.actions.len == 3 and data.actions[1].append
  let playback = newGame(map,Duration)
  let cursor = initReplayPlayer(data)
  proc replay(w: World) =
    var action: ReplayAction
    while cursor.takeActionAt(uint32(w.tick),action):
      doAssert w.applyReplayAction(action)
  for tick in 0 ..< data.hashes.len:
    playback.world.tickWorld(replay)
    doAssert playback.stateHash() == data.hashes[tick]
  echo "Blocked destination serialized replay hashes=", data.hashes.len

echo "Blocked destination retention/removal/Shift tests passed"
