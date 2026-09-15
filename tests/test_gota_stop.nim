import
  ../examples/gods_of_the_arena/[controls, maps, replays, sim]

proc stopGame(): Game =
  ## Isolates one living hero so stop and acquire can be measured.
  var preset = defaultConfig()
  preset.mapSize = 128
  result = newGame(generateMap(2026, preset), 240, 10, false, ReplayData())
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.manualSpells = true
    hero.hp = 0
    hero.state = Dying
    hero.deathTicks = -100_000
  for tower in result.world.towers.mitems:
    tower.hp = 0
  let hero = result.world.heroes[0]
  hero.hp = hero.maxHp
  hero.state = Marching

echo "Testing stop clears a walk and holds auto-acquire"
block:
  let
    game = stopGame()
    hero = game.world.heroes[0]
  doAssert applyWalkTo(
    game.world, hero.id,
    mapCoordinate(hero.position.x) + 6,
    mapCoordinate(hero.position.z)
  )
  doAssert hero.hasMoveTarget and not hero.holding
  queueStop(hero.id)
  flushPlayerCommands(game)
  doAssert hero.holding
  doAssert not hero.hasMoveTarget
  doAssert hero.attackObjectId == 0
  var creep = Footman(
    id: 1000, team: BlueTeam, hp: 10_000, state: Marching
  )
  creep.place(hero.position)
  game.world.footmen.add creep
  game.tickWorld(nil)
  doAssert hero.attackObjectId == 0
  doAssert applyWalkTo(
    game.world, hero.id,
    mapCoordinate(hero.position.x) + 2,
    mapCoordinate(hero.position.z)
  )
  doAssert not hero.holding

echo "Testing stop reaches the state hash and is a valid replay action"
block:
  let
    live = stopGame()
    hero = live.world.heroes[0]
    before = live.stateHash
  doAssert applyStop(live.world, hero.id)
  doAssert hero.holding
  doAssert live.stateHash != before
  let copy = stopGame()
  doAssert applyStop(copy.world, copy.world.heroes[0].id)
  doAssert live.stateHash == copy.stateHash
  let recorder = initReplayRecorder(currentSetup(live, 20), live.map.preset)
  recorder.record ReplayAction(tick: 1, heroId: hero.id, kind: ActionStop)
  for tick in 1'u64 .. 20'u64:
    recorder.recordHash(tick)
  let tape = decodeReplay(recorder.data.encodeReplay())
  doAssert tape.actions.len == 1
  doAssert tape.actions[0].kind == ActionStop
  tape.validate()

echo "GotA stop tests passed"
