import
  std/[os, tempfiles],
  bassy,
  polyworld/[bodies, cli, pathing],
  ../examples/call_to_adventure/[bots, content, replays, sim]

proc flatFloor(width, depth: int): QuadLayer =
  ## Builds connected tiles for an isolated navigation scenario.
  result = QuadLayer(
    width: width,
    depth: depth,
    tiles: newSeq[Tile](width * depth)
  )
  for tile in result.tiles.mitems:
    tile = Tile(
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )

proc walker(world: World, tile: TileRef, speed: int32): int32 =
  ## Places a living walker with the requested navigation speed.
  world.addActor(Actor(home: tile, speed: speed, hp: 1, maxHp: 1))

proc finishPath(world: World, slot: int32, goal: TileRef, budget: int) =
  ## Requires a real path to complete on walkable tiles within a deadline.
  let actor = world.actors[slot]
  doAssert world.stepToward(slot, goal)
  for tick in 0 ..< budget:
    # Repeated bot commands must not restart turning or add movement.
    let before = actor.body
    doAssert world.stepToward(slot, goal)
    doAssert actor.body == before
    discard world.advancePath(slot)
    doAssert actor.home.walkable, "navigation left the walkable floor"
    if actor.home == goal and actor.path.len == 0:
      let arrived = actor.body
      for idle in 0 ..< 20:
        doAssert not world.advancePath(slot)
        doAssert actor.body == arrived
      return
  doAssert false, "CTA navigation missed its arrival deadline: goal=" &
    $goal & " position=" & $actor.body.pos & " pathIndex=" & $actor.pathIndex

echo "Testing CTA repathing from off-center cannot orbit the start waypoint"
block:
  layers = @[flatFloor(16, 16)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.addActor(Actor(
      home: TileRef(level: 0, x: 5, z: 5),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
    actor = world.actors[slot]
    goal = TileRef(level: 0, x: 10, z: 5)
  actor.body.pos = fixedVec2(5.5'fx - 0.36'fx, 5.5'fx)
  actor.body.facing = FixedPi * 7 / 8
  doAssert world.setPath(slot, goal)
  for tick in 0 ..< 600:
    discard world.advancePath(slot)
  doAssert actor.home == goal and actor.path.len == 0,
    "CTA never left its starting waypoint: " & $actor.body.pos

echo "Testing CTA off-center starts across hero speeds and headings"
block:
  layers = @[flatFloor(16, 16)]
  computeWalkable()
  for class in HeroClass:
    for scale in [50'i32, 100'i32, 150'i32]:
      for heading in 0 ..< 32:
        let
          world = newWorld(Setup(seed: 1988))
          slot = world.walker(
            TileRef(level: 0, x: 5, z: 5),
            ClassSpeeds[class] * scale div 100
          )
        world.actors[slot].body.pos = fixedVec2(5.14'fx, 5.5'fx)
        world.actors[slot].body.facing =
          wrapAngle(FixedPi * int32(heading) / 16)
        world.finishPath(slot, TileRef(level: 0, x: 10, z: 10), 400)

echo "Testing CTA navigation rounds narrow corners in both directions"
block:
  let floor = flatFloor(12, 12)
  for z in 0 ..< floor.depth:
    for x in 0 ..< floor.width:
      let corridor =
        (x == 2 and z in 2 .. 8) or
        (z == 8 and x in 2 .. 8) or
        (x == 8 and z in 2 .. 8)
      if not corridor:
        floor.tiles[z * floor.width + x].flags = 0
  layers = @[floor]
  computeWalkable()
  for class in HeroClass:
    let
      world = newWorld(Setup(seed: 1988))
      start = TileRef(level: 0, x: 2, z: 2)
      goal = TileRef(level: 0, x: 8, z: 2)
      slot = world.walker(start, ClassSpeeds[class])
    world.actors[slot].body.facing = -FixedHalfPi
    world.finishPath(slot, goal, 600)
    world.finishPath(slot, start, 600)

echo "Testing CTA navigation turns on connected ramp landings"
block:
  let
    lower = flatFloor(10, 10)
    upper = flatFloor(10, 10)
  for z in 0 ..< 10:
    for x in 0 ..< 10:
      if z == 5 and x in 2 .. 4:
        if x == 4:
          lower.tiles[z * 10 + x].tops = [0'i16, 8, 0, 8]
      else:
        lower.tiles[z * 10 + x].flags = 0
      if (z == 5 and x in 5 .. 7) or (x == 7 and z in 2 .. 5):
        upper.tiles[z * 10 + x].tops = [8'i16, 8, 8, 8]
      else:
        upper.tiles[z * 10 + x].flags = 0
  layers = @[lower, upper]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    start = TileRef(level: 0, x: 2, z: 5)
    goal = TileRef(level: 1, x: 7, z: 2)
    slot = world.walker(start, ClassSpeeds[RogueClass])
  world.actors[slot].body.facing = FixedPi
  world.finishPath(slot, goal, 300)
  world.finishPath(slot, start, 300)

echo "Testing CTA navigation recovers after a moving target reverses"
block:
  layers = @[flatFloor(16, 16)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.walker(
      TileRef(level: 0, x: 8, z: 8),
      ClassSpeeds[RogueClass]
    )
  for goal in [
    TileRef(level: 0, x: 13, z: 13),
    TileRef(level: 0, x: 3, z: 3),
    TileRef(level: 0, x: 13, z: 3)
  ]:
    doAssert world.stepToward(slot, goal)
    for tick in 0 ..< 7:
      discard world.advancePath(slot)
  world.finishPath(slot, TileRef(level: 0, x: 3, z: 13), 300)

echo "Testing CTA blocked routes stop turning and recover when reopened"
block:
  let floor = flatFloor(8, 1)
  layers = @[floor]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.walker(
      TileRef(level: 0, x: 1, z: 0),
      ClassSpeeds[RogueClass]
    )
    actor = world.actors[slot]
    goal = TileRef(level: 0, x: 6, z: 0)
  doAssert world.setPath(slot, goal)
  floor.tiles[3].flags = 0
  computeWalkable()
  for tick in 0 ..< 300:
    discard world.advancePath(slot)
    doAssert actor.home.x < 3
  doAssert actor.path.len == 0
  let stopped = actor.body
  for tick in 0 ..< 100:
    discard world.advancePath(slot)
    doAssert actor.body == stopped
  floor.tiles[3].flags = TileExists or TileConnectedEast or TileConnectedSouth
  computeWalkable()
  world.finishPath(slot, goal, 150)

echo "Testing CTA partial routes re-pathed every decision still advance"
block:
  ## A goal ringed by other actors has no way in, so every decision asks
  ## again for the same partial route. Re-pathing must not send the walker
  ## back to the middle of the tile it is leaving, or it never leaves.
  layers = @[flatFloor(16, 3)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.walker(TileRef(level: 0, x: 1, z: 1), ClassSpeeds[RogueClass])
    goal = TileRef(level: 0, x: 14, z: 1)
  for ring in [
    TileRef(level: 0, x: 13, z: 1),
    TileRef(level: 0, x: 15, z: 1),
    TileRef(level: 0, x: 14, z: 0),
    TileRef(level: 0, x: 14, z: 2)
  ]:
    doAssert world.walker(ring, 0) >= 0
  for tick in 0 ..< 600:
    discard world.stepToward(slot, goal)
    discard world.advancePath(slot)
  doAssert tileDistance(world.actors[slot].home, goal) <= 2,
    "the walker stalled short of the ring: " & $world.actors[slot].body.pos

echo "Testing CTA heroes crowded onto one tile all walk off it"
block:
  ## Bodies are too wide for three to stand within arrival range of one
  ## tile's middle. Fresh routes from a shared tile must not leave them all
  ## steering for that middle forever while separation holds them apart.
  layers = @[flatFloor(16, 9)]
  computeWalkable()
  proc onFloor(pos: FixedVec2): bool {.nimcall.} =
    let (x, z) = cell(pos)
    x >= 0 and x < 16 and z >= 0 and z < 9
  let
    world = newWorld(Setup(seed: 1988))
    shared = TileRef(level: 0, x: 8, z: 4)
    crowd = [
      (FighterClass, fixedVec2(8.918'fx, 4.293'fx), 5.34'fx),
      (FighterClass, fixedVec2(8.001'fx, 4.384'fx), 5.742'fx),
      (FighterClass, fixedVec2(8.146'fx, 4.218'fx), 5.784'fx),
      (WizardClass, fixedVec2(8.448'fx, 4.767'fx), 0.456'fx)
    ]
  var slots: seq[int32]
  for i, (class, spot, facing) in crowd:
    let slot = world.walker(
      TileRef(level: 0, x: 8, z: uint8(i + 1)),
      ClassSpeeds[class]
    )
    world.actors[slot].kind = HeroActor
    world.actors[slot].home = shared
    world.actors[slot].body.pos = spot
    world.actors[slot].body.facing = facing
    slots.add slot
  world.rebuildClaims()
  for i, slot in slots:
    doAssert world.setPath(slot, TileRef(level: 0, x: 1, z: uint8(i + 2)))
  for tick in 0 ..< 600:
    for slot in slots:
      discard world.advancePath(slot)
    for i in 0 ..< slots.len:
      for j in i + 1 ..< slots.len:
        separatePair(
          world.actors[slots[i]].body,
          world.actors[slots[j]].body,
          onFloor,
          world.actors[slots[i]].planted,
          world.actors[slots[j]].planted
        )
  for i, slot in slots:
    doAssert world.actors[slot].home ==
      TileRef(level: 0, x: 1, z: uint8(i + 2)),
      "a crowded hero never left the shared tile: " &
        $world.actors[slot].body.pos

echo "Testing CTA heroes route through a pack that walls off a corridor"
block:
  ## Pathing steers around occupied tiles, so monsters filling a corridor
  ## cut it. A hero must still head through them to the far side rather
  ## than settle for the nearest tile short, which can be on another floor.
  layers = @[flatFloor(16, 1)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    hero = world.walker(TileRef(level: 0, x: 1, z: 0), ClassSpeeds[RogueClass])
    monster = world.walker(TileRef(level: 0, x: 8, z: 0), 0)
    goal = TileRef(level: 0, x: 14, z: 0)
  world.actors[monster].kind = MonsterActor
  doAssert world.setPath(hero, goal)
  doAssert world.pathGoal(hero) == goal,
    "the route stopped short of the pack: " & $world.pathGoal(hero)
  world.actors[monster].kind = HeroActor
  doAssert world.setPath(hero, goal)
  doAssert world.pathGoal(hero).x < 8, "a hero must not route through allies"

echo "Testing CTA bodies wedged on a wall corner find a way around"
block:
  ## Two bodies side by side can each be shoved back across the line their
  ## steering takes, then creep a hair along a wall corner every tick. That
  ## is no progress, so it must count as stuck and earn a fresh route.
  let floor = flatFloor(12, 4)
  floor.tiles[1 * 12 + 5].flags = 0
  layers = @[floor]
  computeWalkable()
  proc onFloor(pos: FixedVec2): bool {.nimcall.} =
    let (x, z) = cell(pos)
    x >= 0 and x < 12 and z >= 0 and z < 4 and
      TileRef(level: 0, x: uint8(x), z: uint8(z)).walkable
  let
    world = newWorld(Setup(seed: 1988))
    goal = TileRef(level: 0, x: 0, z: 1)
    shared = TileRef(level: 0, x: 6, z: 1)
  var slots: seq[int32]
  for i, z in [1.21'fx, 1.87'fx]:
    let slot = world.walker(
      TileRef(level: 0, x: 9, z: uint8(i + 1)),
      ClassSpeeds[RogueClass]
    )
    world.actors[slot].kind = HeroActor
    world.actors[slot].home = shared
    world.actors[slot].body.pos = fixedVec2(6'fx, z)
    world.actors[slot].body.facing = FixedPi
    world.actors[slot].path = @[PathStep(tile: goal, direction: West)]
    slots.add slot
  world.rebuildClaims()
  for tick in 0 ..< 900:
    for slot in slots:
      discard world.advancePath(slot)
    separatePair(
      world.actors[slots[0]].body,
      world.actors[slots[1]].body,
      onFloor,
      world.actors[slots[0]].planted,
      world.actors[slots[1]].planted
    )
  for slot in slots:
    doAssert world.actors[slot].home.x <= 1,
      "a wedged body never got around the corner: " &
        $world.actors[slot].body.pos

echo "Testing CTA heroes judge a nearer monster by its route"
block:
  ## A monster just across a wall is nearer in a straight line than one down
  ## an open row, yet farther to walk. A hero already on its way to the open
  ## one must not turn back for it, though it does for one nearer by route.
  let floor = flatFloor(16, 9)
  for z in 0 ..< 8:
    floor.tiles[z * 16 + 8].flags = 0
  layers = @[floor]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    game = Game(world: world)
    hero = world.walker(TileRef(level: 0, x: 6, z: 1), ClassSpeeds[RogueClass])
    open = TileRef(level: 0, x: 2, z: 1)
    walled = TileRef(level: 0, x: 9, z: 1)
  world.actors[hero].kind = HeroActor
  for tile in [open, walled]:
    let monster = world.walker(tile, 0)
    world.actors[monster].kind = MonsterActor
  doAssert game.nearestMonsterHome(hero) == walled
  doAssert world.setPath(hero, open)
  doAssert game.nearestMonsterHome(hero) == open,
    "the hero turned back for a monster behind a wall"
  let near = world.walker(TileRef(level: 0, x: 4, z: 1), 0)
  world.actors[near].kind = MonsterActor
  doAssert game.nearestMonsterHome(hero) == TileRef(level: 0, x: 4, z: 1),
    "a monster nearer by route must win the hero over"

echo "CTA navigation tests passed"

echo "Testing CTA fractional destinations in the same cell and across routes"
block:
  layers = @[flatFloor(16, 16)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.walker(TileRef(level: 0, x: 5, z: 5), ClassSpeeds[RogueClass])
    offset = fixedVec2(0.25'fx, -0.25'fx)
  for goal in [TileRef(level: 0, x: 5, z: 5), TileRef(level: 0, x: 10, z: 10)]:
    doAssert world.stepToward(slot, goal, offset)
    let snapshot = world.clone()
    for pass in 0 .. 1:
      if pass == 1:
        world.restore(snapshot)
      for tick in 0 ..< 400:
        discard world.advancePath(slot)
      let expected = fixedVec2(fixed(goal.x.int32) + 0.75'fx,
        fixed(goal.z.int32) + 0.25'fx)
      doAssert world.actors[slot].path.len == 0
      doAssert length(world.actors[slot].body.pos - expected) <= fixed(1, 1000)


echo "Testing CTA numeric host arguments and replay coordinates"
block:
  let
    directory = createTempDir("cta-points-", "")
    path = directory / "points.bas"
    game = newGame(2026, 100)
  defer:
    removeDir(directory)
  writeFile(path,
    "accepted = walkTo(currentLevel, x + 0.25, y - 0.25)\n")
  game.loadBots([BotGroup(path: path, count: PartySize)])
  game.world.tick = 1
  game.recorder = initReplayRecorder(game.world.setup)
  game.runBotDecisions(0)
  let vm = game.heroVms[0]
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("accepted") == 1
  doAssert game.world.actors[0].path[^1].offset ==
    fixedVec2(0.25'fx, -0.25'fx)
  game.recorder.recordHash(game.stateHash())
  let replay = decodeReplay(game.recorder.data.encodeReplay())
  doAssert replay.actions.len == 1
  doAssert replay.actions[0].offset == fixedVec2(0.25'fx, -0.25'fx)
