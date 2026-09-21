import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, rngs, tapes],
  ../examples/gods_of_the_arena/[bots, content, controls, maps, replays, sim]

const
  BasePolicy = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/players/base.bas"
  RusherPolicy = currentSourcePath().parentDir.parentDir /
    "examples/gods_of_the_arena/players/rusher.bas"

proc draftGame(): Game =
  ## Creates a live draft on a compact arena with a fresh recording.
  var preset = defaultConfig()
  preset.mapSize = 64
  result = newGame(generateMap(54, preset), 240, 10, false, ReplayData())
  result.recorder = initReplayRecorder(result.currentSetup(1000), preset)

proc decide(game: Game) =
  ## Shares the live human and BASIC decision ordering.
  let turn = game.world.draftHeroId()
  game.flushPlayerCommands()
  if turn == 0 or turn == game.world.draftHeroId():
    game.runBotDecisions()

echo "Testing random first team and alternating spawn order"
block:
  let
    game = draftGame()
    world = game.world
  var rng = initRng(game.map.seed)
  discard rng.below(10)
  let first = rng.below(2).int
  for i, index in world.draftOrder:
    let hero = world.heroes[index]
    doAssert hero.team.ord == (first + i) mod 2
    doAssert hero.slot == i div 2
    doAssert not hero.drafted
    doAssert world.draftedClass(hero.id) == -1
  let original = game.stateHash()
  let snapshot = world.clone()
  inc world.draftTurn
  doAssert game.stateHash() != original
  world.restore(snapshot)
  doAssert game.stateHash() == original
  world.draftOrder[0] = world.draftOrder[1]
  doAssert game.stateHash() != original
  world.restore(snapshot)
  doAssert game.stateHash() == original
  inc world.draftTurnTicks
  doAssert game.stateHash() != original
  world.restore(snapshot)
  doAssert game.stateHash() == original
  doAssert world.draftedClass(-1) == -1
  doAssert not world.heroAvailable(-1)
  doAssert not world.heroAvailable(10)

echo "Testing draft validation and a frozen battlefield"
block:
  let
    game = draftGame()
    world = game.world
    hero = world.heroById(world.draftHeroId())
    other = world.heroes[world.draftOrder[1]]
    position = hero.position
    gold = hero.gold
  doAssert not world.applyDraft(other.id, 0)
  doAssert other.lastActionError == ActionNotDraftTurn
  doAssert not world.applyDraft(hero.id, -1)
  doAssert hero.lastActionError == ActionUnknownHero
  doAssert not world.applyDraft(hero.id, 10)
  doAssert not world.applyWalkTo(hero.id, 32, 32)
  doAssert not world.applyAttackMove(hero.id, 32, 32)
  doAssert not world.applyAttackTarget(hero.id, other.id)
  doAssert not world.applyBuyItem(hero.id, 1)
  doAssert not world.applyUseItem(hero.id, 0)
  doAssert not world.applyUseItemAt(hero.id, 0, 32, 32)
  doAssert hero.lastActionError == ActionDrafting
  doAssert not world.applyLevelAbility(hero.id, PrimaryAbility.ord)
  doAssert hero.lastActionError == ActionDrafting
  doAssert hero.abilityPoints == 1
  doAssert not world.applyBuyback(hero.id)
  doAssert hero.lastActionError == ActionDrafting
  doAssert not world.applyCastTarget(hero.id, 0, hero.id)
  doAssert not world.applyCastPoint(hero.id, 1, 32, 32)
  doAssert hero.lastActionError == ActionDrafting
  doAssert world.draftTurn == 0
  for i in 0 ..< 100:
    game.tickWorld(nil)
  doAssert world.phase == Drafting
  doAssert world.battleTick() == 0
  doAssert world.spawnTimerTicks == 0
  doAssert world.footmen.len == 0 and world.casts.len == 0
  doAssert hero.position == position and hero.gold == gold
  doAssert hero.hp == hero.maxHp
  doAssert world.applyDraft(hero.id, Lich.ord.int32)
  when defined(replayEvents):
    doAssert world.events[^1].kind == HeroDrafted
    doAssert world.events[^1].actor.id == hero.id
    doAssert world.events[^1].detail == Lich.ord
  doAssert hero.class == Lich and hero.drafted
  doAssert hero.hp == heroMaxHp(Lich, 1)
  doAssert hero.mana == heroMaxMana(Lich, 1)
  for slot in HeroAbilitySlot:
    doAssert hero.abilityLevels[slot] == 0 and hero.charges[slot] == 0
  doAssert hero.abilityPoints == 1
  doAssert world.draftedClass(hero.id) == Lich.ord
  doAssert not world.heroAvailable(Lich.ord.int32)
  doAssert not world.applyDraft(other.id, Lich.ord.int32)
  doAssert other.lastActionError == ActionHeroTaken
  doAssert not world.applyDraft(hero.id, Ranger.ord.int32)
  for class in HeroClass:
    if world.heroAvailable(class.ord.int32):
      doAssert world.applyDraft(world.draftHeroId(), class.ord.int32)
  doAssert world.phase == Playing
  doAssert world.draftHeroId() == 0
  doAssert not world.applyDraft(hero.id, 0)
  doAssert hero.lastActionError == ActionNotDrafting
  game.tickWorld(nil)
  doAssert world.battleTick() == 1
  doAssert world.footmen.len > 0

echo "Testing teams may draft multiple supports and carries"
block:
  let
    game = draftGame()
    world = game.world
    red = [DruidWarden, Warlock, Ranger, Crossbowman, Lich]
    blue = [VanguardKnight, DeathKnight, Arcanist, DemonHunter, Berserker]
  while world.phase == Drafting:
    let
      hero = world.heroById(world.draftHeroId())
      class = if hero.team == RedTeam: red[hero.slot] else: blue[hero.slot]
    doAssert world.applyDraft(hero.id, class.ord.int32)
  var roles: array[HeroRole, int]
  for hero in world.heroes:
    if hero.team == RedTeam:
      inc roles[hero.class.heroRole]
  doAssert roles[Support] == 2 and roles[Carry] == 2
  doAssert roles[Frontline] == 0 and roles[Fighter] == 0

echo "Testing public BASIC draft queries and rejection feedback"
block:
  let
    directory = createTempDir("gota-draft-", "")
    path = directory / "probe.bas"
    game = draftGame()
    index = game.world.draftOrder[0]
  defer:
    removeDir(directory)
  writeFile(path, """
phase = drafting
cannotLevel = canLevelAbility(1) = 0
cannotShop = canShop() = 0
unpicked = selfClass = -1 and draftedClass(selfId) = -1
turn = draftTurnId = selfId
roster = draftPlayerCount() = 10
bounds = draftPlayerId(-1) = 0 and draftPlayerId(10) = 0
bounds = bounds and draftPlayerTeam(-1) = -1
bounds = bounds and draftPlayerTeam(10) = -1
bounds = bounds and draftedClass(-1) = -1
bounds = bounds and heroRole(-1) = -1 and heroRole(10) = -1
bounds = bounds and heroAvailable(-1) = 0 and heroAvailable(10) = 0
bad = draftHero(10) = 0 and lastActionError() = ActionUnknownHero
accepted = draftHero(Warlock)
updated = draftedClass(selfId) = Warlock and heroAvailable(Warlock) = 0
unchanged = selfClass = -1
repeat = draftHero(Ranger) = 0
repeat = repeat and lastActionError() = ActionNotDraftTurn
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  game.tickWorld(proc() =
    ## Executes the probe only for the active drafting player.
    game.runBotDecisions()
  )
  let vm = game.heroVms[index]
  doAssert not vm.failed, vm.lastError
  for name in ["phase", "cannotLevel", "cannotShop", "unpicked", "turn", "roster",
    "bounds", "bad", "accepted", "updated", "unchanged", "repeat"]:
      doAssert vm.runtime.getGlobal(name) != 0, name

echo "Testing BASIC composition picks and exact replay through combat"
for policy in [BasePolicy, RusherPolicy]:
  let game = draftGame()
  game.loadBots([BotGroup(path: policy, count: 10)])
  var checkpoint: World
  for i in 0 ..< 160:
    game.tickWorld(proc() =
      ## Runs the live controller callback for this recorded tick.
      game.decide()
    )
    if i == 49:
      checkpoint = game.world.clone()
      doAssert checkpoint.phase == Drafting and checkpoint.draftTurn == 5
  doAssert game.world.phase == Playing
  for vm in game.heroVms:
    doAssert not vm.failed, vm.lastError
  for team in Team:
    var roles: set[HeroRole]
    for hero in game.world.heroes:
      if hero.team == team:
        doAssert hero.drafted
        roles.incl hero.class.heroRole
    doAssert roles == {HeroRole.low .. HeroRole.high}
  let
    expected = game.stateHash()
    data = decodeReplay(encodeReplay(game.recorder.data))
    replay = newGame(game.map, 240, 0, true, data)
  doAssert data.header.setup.drafting
  replay.historyPlayback = true
  replay.replayPlayer = initReplayPlayer(data)
  for i in 0 ..< data.hashes.len:
    replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
  doAssert replay.stateHash() == expected
  doAssert replay.replayPlayer.finished
  replay.world.restore(checkpoint)
  replay.replayPlayer.syncCursor(checkpoint.tick.uint32)
  for i in checkpoint.tick.int ..< data.hashes.len:
    replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
  doAssert replay.stateHash() == expected
  doAssert replay.replayPlayer.finished

echo "Testing a human pick within the deadline resumes BASIC drafting"
block:
  let
    game = draftGame()
    humanIndex = game.world.draftOrder[0]
    human = game.world.heroes[humanIndex]
  game.loadBots([BotGroup(path: BasePolicy, count: 9)],
    playerSlot = humanIndex.int32 + 1)
  game.recorder.record ReplayAction(
    tick: 1, heroId: human.id, kind: ActionManualSpells, first: 1
  )
  for i in 0 ..< 24:
    game.tickWorld(proc() =
      ## Leaves the active human slot waiting for its queued choice.
      game.decide()
    )
  doAssert game.world.draftHeroId() == human.id
  doAssert game.world.battleTick() == 0
  queueDraft(human.id, Warlock.ord.int32)
  for i in 0 ..< 160:
    game.tickWorld(proc() =
      ## Applies the human pick and lets later bots fill missing roles.
      game.decide()
    )
  doAssert game.world.phase == Playing
  doAssert human.class == Warlock
  for vm in game.heroVms:
    if vm != nil:
      doAssert not vm.failed, vm.lastError
  let
    expected = game.stateHash()
    data = decodeReplay(encodeReplay(game.recorder.data))
    replay = newGame(game.map, 240, 0, true, data)
  replay.historyPlayback = true
  replay.replayPlayer = initReplayPlayer(data)
  for i in 0 ..< data.hashes.len:
    replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
  doAssert replay.stateHash() == expected

echo "Testing exact pick deadlines and a separate full battle budget"
block:
  let
    game = draftGame()
    world = game.world
    hero = world.heroById(world.draftHeroId())
    battleTicks = 24'i32
  game.recorder = initReplayRecorder(game.currentSetup(battleTicks.uint32),
    game.map.preset)
  doAssert world.draftTicksLeft() == DraftPickTicks
  doAssert game.durationTicks() == battleTicks + DraftPickTicks * 10
  for i in 1 ..< DraftPickTicks:
    game.tickWorld(nil)
  doAssert world.draftTurn == 0 and not hero.drafted
  doAssert world.draftTicksLeft() == 1
  doAssert not game.finished()
  let checkpoint = world.clone()
  game.tickWorld(nil)
  doAssert hero.drafted and world.draftTurn == 1
  doAssert world.draftTicksLeft() == DraftPickTicks
  when defined(replayEvents):
    doAssert world.events[^1].kind == HeroDrafted
    doAssert world.events[^1].cause == TimeLimit
    doAssert world.events[^1].actor.id == hero.id
  for turn in 1 ..< 10:
    for i in 0 ..< DraftPickTicks:
      game.tickWorld(nil)
    doAssert world.draftTurn == turn + 1
  doAssert world.phase == Playing and world.draftTicksLeft() == 0
  doAssert world.draftTicks == 10 * DraftPickTicks
  doAssert world.battleTick() == 0 and not game.finished()
  doAssert world.footmen.len == 0
  var classes: set[HeroClass]
  for hero in world.heroes:
    doAssert hero.drafted and hero.class notin classes
    classes.incl hero.class
  for i in 1 ..< battleTicks:
    game.tickWorld(proc() =
      ## Keeps normal decision ordering with no controllers installed.
      game.runBotDecisions()
    )
    doAssert not game.finished()
  game.tickWorld(proc() =
    ## Finishes the full battle budget after every timed-out pick.
    game.runBotDecisions()
  )
  doAssert world.battleTick() == battleTicks
  doAssert game.finished() and not world.gameOver
  doAssert world.tick == game.durationTicks()
  doAssert game.recordingError.len == 0, game.recordingError
  when defined(replayEvents):
    doAssert world.events[^1].kind == MatchEnded
    doAssert world.events[^1].cause == TimeLimit
  let expected = game.stateHash()
  game.tickWorld(nil)
  doAssert game.stateHash() == expected
  let
    data = decodeReplay(encodeReplay(game.recorder.data))
    replay = newGame(game.map, 240, 0, true, data)
  doAssert data.config.maxTicks == battleTicks
  doAssert data.hashes.len == battleTicks + 10 * DraftPickTicks
  doAssert data.actions.len == 0
  replay.historyPlayback = true
  replay.replayPlayer = initReplayPlayer(data)
  for i in 0 ..< data.hashes.len:
    replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
  doAssert replay.stateHash() == expected
  replay.world.restore(checkpoint)
  replay.replayPlayer.syncCursor(checkpoint.tick.uint32)
  for i in checkpoint.tick.int ..< data.hashes.len:
    replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0, replay.hashCheck.error
  doAssert replay.stateHash() == expected

echo "Testing rejected picks do not extend the deadline"
block:
  let game = draftGame()
  for i in 0 ..< DraftPickTicks:
    game.tickWorld(proc() =
      ## Keeps submitting an invalid choice until this pick times out.
      discard game.world.applyDraft(game.world.draftHeroId(), -1)
    )
  doAssert game.world.draftTurn == 1
  doAssert game.world.draftTicks == DraftPickTicks

echo "Testing a valid command on the deadline wins before automatic picking"
block:
  let
    game = draftGame()
    hero = game.world.heroById(game.world.draftHeroId())
  for i in 1 ..< DraftPickTicks:
    game.tickWorld(nil)
  game.world.heroTurnTicks = 1
  let rng = game.world.rng
  game.tickWorld(proc() =
    ## Accepts a choice before enforcing this tick's deadline.
    doAssert game.world.applyDraft(hero.id, Warlock.ord.int32)
  )
  doAssert hero.class == Warlock and game.world.draftTurn == 1
  doAssert game.world.rng == rng
  doAssert game.world.draftTicksLeft() == DraftPickTicks
  doAssert game.durationTicks() == game.config.maxTicks + 10 * DraftPickTicks

echo "Testing an idle human times out and the bots finish drafting"
block:
  let
    game = draftGame()
    humanIndex = game.world.draftOrder[0]
    human = game.world.heroes[humanIndex]
  game.loadBots([BotGroup(path: BasePolicy, count: 9)],
    playerSlot = humanIndex.int32 + 1)
  for i in 1 ..< DraftPickTicks:
    game.tickWorld(proc() =
      ## Advances bot scheduling while the human leaves their pick idle.
      game.decide()
    )
  doAssert not human.drafted
  game.tickWorld(proc() =
    ## Applies the same deadline to the human's empty controller slot.
    game.decide()
  )
  doAssert human.drafted
  while game.world.phase == Drafting:
    game.tickWorld(proc() =
      ## Allows the remaining bots to make their normal picks.
      game.decide()
    )
  doAssert game.world.draftTicks < 2 * DraftPickTicks
  doAssert game.world.battleTick() == 0
  doAssert game.durationTicks() == game.config.maxTicks + game.world.draftTicks

echo "Gota drafting passed"
