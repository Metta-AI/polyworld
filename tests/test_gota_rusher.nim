import
  std/os,
  polyworld/cli,
  ../examples/gods_of_the_arena/[bots, maps, replays, sim]

const Policy = currentSourcePath().parentDir.parentDir /
  "examples/gods_of_the_arena/players/rusher.bas"

proc offset(point: WorldPoint, tiles: int32): WorldPoint =
  ## Offsets a test unit by an exact horizontal tile distance.
  result = point
  result.x += tiles * WorldScale

proc policyGame(team: Team): Game =
  ## Runs one rusher while keeping every other hero under test control.
  result = newGame(
    generateMap(54),
    100_000,
    10,
    false,
    ReplayData(),
    drafting = false
  )
  result.loadBots([BotGroup(path: Policy, count: 10)])
  result.recorder = initReplayRecorder(result.currentSetup(1000))
  for i, hero in result.world.heroes:
    if i != team.ord * 5:
      result.heroVms[i] = nil
    hero.place(WorldPoint(x: -10 * WorldScale, z: 10 * WorldScale))
    if hero.team != team:
      hero.hp = 0
      hero.state = Dying
  for building in result.world.buildings.mitems:
    building.hp = 0
  for fort in result.world.forts.mitems:
    fort.hp = 0
  result.world.syncBuildings()
  for cells in result.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255

proc decide(game: Game): ReplayAction =
  ## Reads the policy's actual recorded order after one bounded VM decision.
  inc game.world.tick
  let before = game.recorder.data.actions.len
  game.runBotDecisions()
  for vm in game.heroVms:
    if vm != nil:
      doAssert not vm.failed, vm.lastError
  var orders = 0
  for i in before ..< game.recorder.data.actions.len:
    if game.recorder.data.actions[i].kind != ActionLevelAbility:
      inc orders
  doAssert orders == 1
  game.recorder.data.actions[^1]

echo "Testing rusher cohesion, radius boundaries, vision, and middle routing"
for team in Team:
  let
    game = policyGame(team)
    hero = game.world.heroes[team.ord * 5]
    ally = game.world.heroes[team.ord * 5 + 1]
    enemy = game.world.heroes[(1 - team.ord) * 5]
    origin = hero.position
  ally.place(origin.offset(10))
  var action = game.decide()
  doAssert action.kind == ActionAttackMove
  doAssert hero.attackMoving
  doAssert action.first == mapTiles() div 2 - team.ord
  doAssert action.second == mapTiles() div 2 - team.ord

  ally.place(origin.offset(11))
  action = game.decide()
  doAssert action.kind == ActionWalkTo
  doAssert not hero.attackMoving
  doAssert action.first == mapCoordinate(origin.x, team) + 2 + team.ord
  doAssert action.second == mapCoordinate(origin.z, team)
  ally.place(origin.offset(9))
  doAssert game.decide().kind == ActionWalkTo
  ally.place(origin.offset(8))
  doAssert game.decide().kind == ActionAttackMove

  enemy.hp = enemy.maxHp
  enemy.state = Marching
  enemy.place(origin.offset(20))
  action = game.decide()
  doAssert action.kind == ActionAttackTarget
  doAssert action.first == enemy.id
  enemy.place(origin.offset(21))
  doAssert game.decide().kind == ActionAttackMove
  enemy.place(origin.offset(20))
  for cell in game.world.teamVisible[team.ord].mitems:
    cell = 0
  doAssert game.decide().kind == ActionAttackMove

  ally.place(origin.offset(30))
  ally.hp = 0
  ally.state = Dying
  doAssert game.decide().kind == ActionAttackMove
  ally.hp = ally.maxHp
  ally.state = Marching
  doAssert game.decide().kind == ActionWalkTo

  for other in game.world.heroes:
    if other.team == team:
      other.place(WorldPoint())
  action = game.decide()
  doAssert action.kind == ActionAttackMove
  doAssert action.first == mapTiles() - 1 -
    mapCoordinate(game.world.forts[team.ord].center.x)
  doAssert action.second == mapTiles() - 1 -
    mapCoordinate(game.world.forts[team.ord].center.z)

echo "Rusher policy passed"
