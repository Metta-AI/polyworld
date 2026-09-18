import
  std/times,
  vmath, polyworld/[player, chrome, tapes],
  ../examples/heartleaf/[content, maps, sim, scorecard, seeking, replays]

let gameMap = generateMap(DefaultSeed)

block dailyReports:
  let w = newWorld(gameMap, 2)
  w.villagers[0].score = 10
  w.villagers[0].inventory[0] = 8
  w.villagers[0].inHouse = 0
  w.villagers[1].inHouse = 0
  let before = w.clone()
  w.runDinnerTally()
  doAssert w.dailyReports[0].hostingPoints == 8
  doAssert w.dailyReports[0].startingScore == 10
  for slot in 0 .. 1:
    let report = w.dailyReports[slot]
    doAssert report.dinnerHost == 0
    doAssert report.biteCount == 3
    doAssert report.bites[0].points == 3
    doAssert report.bites[1].points == 1
    doAssert report.bites[2].points == 1
    doAssert report.eatingText == "Carrot +3 / Carrot +1 / Carrot +1"
  doAssert dinnerRoleText(w, 0) == "Host +8"
  doAssert hostingCalculation(w, 0) == "8 veg x 1 guests = +8"
  doAssert dinnerRoleText(w, 1) == "Guest at Ivan's"
  doAssert hostingCalculation(w, 1) == ""
  doAssert dinnerRoleText(w, 2) == "-"
  doAssert w.dailyReports[2].eatingText == "No dinner"
  doAssert w.dailyGain(0) == 13
  let dinner = w.clone()
  w.dayTick = DayTicks - 1
  w.phase = EveningPhase
  w.tickWorld(nil)
  doAssert w.phase == ScorePhase
  doAssert w.dailyReports[0].penalty == 0
  doAssert w.dailyReports[1].penalty == 3
  doAssert w.dailyGain(1) == 2
  doAssert w.dailyGain(2) == -3
  for slot in 0 ..< VillagerCount:
    let report = w.dailyReports[slot]
    var sum = report.hostingPoints - report.penalty
    for i in 0 ..< report.biteCount:
      sum += report.bites[i].points
    doAssert sum == w.dailyGain(slot)
  let fingerprint = Game(world: w).stateHash()
  let saved = w.clone()
  w.dailyReports[0].startingScore = -999
  doAssert Game(world: w).stateHash() == fingerprint
  w.restore(saved)
  doAssert w.dailyReports == saved.dailyReports
  w.restore(before)
  w.runDinnerTally()
  doAssert w.dailyReports == dinner.dailyReports
  w.dayTick = DayTicks - 1
  w.phase = EveningPhase
  w.tickWorld(nil)
  for i in 0 ..< ScoreScreenTicks:
    w.tickWorld(nil)
  doAssert w.day == 2
  for slot, report in w.dailyReports:
    doAssert report.startingScore == w.villagers[slot].score
    doAssert report.biteCount == 0
    doAssert report.dinnerHost == NoHouse
  w.villagers[0].inventory[0] = 2
  w.villagers[0].inHouse = 0
  w.villagers[1].inHouse = 0
  w.runDinnerTally()
  doAssert w.dailyReports[0].biteCount == 1
  doAssert w.dailyReports[1].biteCount == 1
  doAssert w.dailyReports[0].bites[0].points == 1
  doAssert w.dailyReports[1].bites[0].points == 1

block noGuests:
  let w = newWorld(gameMap, 1)
  w.villagers[0].inHouse = 0
  w.villagers[0].inventory[0] = 10
  w.runDinnerTally()
  doAssert w.dailyGain(0) == 0
  doAssert dinnerRoleText(w, 0) == "-"

block reveal:
  let w = newWorld(gameMap, 1)
  w.phase = ScorePhase
  var presentation: ScorePresentation
  presentation.update(w, 10)
  doAssert presentation.shown(1)
  doAssert not presentation.shown(2)
  presentation.update(w, 1)
  doAssert presentation.shown(2)
  doAssert not presentation.shown(3)
  presentation.update(w, 1)
  doAssert presentation.shown(3)
  doAssert not presentation.shown(4)
  presentation.update(w, 1)
  doAssert presentation.shown(5)
  w.day = 2
  w.phase = GameOverPhase
  presentation.update(w, 0)
  doAssert presentation.shown(5)
  w.day = 1
  w.phase = DaytimePhase
  presentation.update(w, 0)
  w.phase = ScorePhase
  presentation.update(w, 0)
  doAssert not presentation.shown(5)

block layout:
  doAssert ScoreRowsTop + VillagerCount.float32 * ScoreRowHeight <= 540
  for column in 0 ..< ScoreColumns.high:
    doAssert ScoreColumns[column] + ScoreColumnWidths[column] <= ScoreColumns[column + 1]
  doAssert ScoreColumns[^1] + ScoreColumnWidths[^1] <= ScorecardWidth - 40

block seekTargets:
  let w = newWorld(gameMap, 2)
  doAssert parseSeekTarget("--seek-tick", "0").reached(w)
  doAssert parseSeekTarget("--seek-event", "day:1:morning").reached(w)
  for value in ["day:0:morning", "day:1:other", "day:1", "x:1:dinner"]:
    var rejected = false
    try: discard parseSeekTarget("--seek-event", value)
    except ValueError: rejected = true
    doAssert rejected
  let dinner = parseSeekTarget("--seek-event", "day:1:dinner")
  while not dinner.reached(w):
    w.tickWorld(nil)
  doAssert w.minuteOfDay == DinnerMinute
  let night = parseSeekTarget("--seek-event", "day:1:scorecard")
  while not night.reached(w):
    w.tickWorld(nil)
  doAssert w.dayTick == DayTicks
  doAssert w.phaseTicks == ScoreScreenTicks
  let morning = parseSeekTarget("--seek-event", "day:2:morning")
  while not morning.reached(w):
    w.tickWorld(nil)
  doAssert w.dayTick == 0
  doAssert w.tick == DayTicks + ScoreScreenTicks
  var rejected = false
  try: parseSeekTarget("--seek-event", "day:3:morning").validate(2, w.maximumTicks)
  except ValueError: rejected = true
  doAssert rejected

block negativeTicks:
  for value in ["-1", "abc", "2147483648", ""]:
    var rejected = false
    try: discard parseSeekTarget("--seek-tick", value)
    except ValueError: rejected = true
    doAssert rejected

block playbackPacing:
  for speed in [1'i32, 2'i32, 4'i32, 16'i32]:
    let w = newWorld(gameMap, 1)
    w.phase = EveningPhase
    w.dayTick = DayTicks - 1
    var transport = initPlayer(live = true, durationTicks = w.maximumTicks,
      speed = speed)
    transport.startScoreFrame(w, 0.1)
    let prior = w.phase
    doAssert transport.shouldScoreTick(epochTime())
    w.tickWorld(nil)
    transport.sync(w.tick, w.tick, w.over)
    doAssert transport.stopAtScoreBoundary(prior, w)
    doAssert w.phaseTicks == ScoreScreenTicks
    doAssert not transport.shouldScoreTick(epochTime())
    var frames = 0
    while w.phase == ScorePhase:
      transport.startScoreFrame(w, 1'f32 / 60)
      while transport.shouldScoreTick(epochTime()):
        w.tickWorld(nil)
        transport.sync(w.tick, w.tick, w.over)
      inc frames
      doAssert frames <= 602
    doAssert frames >= 599
    doAssert transport.speed == speed
    doAssert w.over

block pauseAndSkip:
  let w = newWorld(gameMap, 2)
  w.phase = ScorePhase
  w.phaseTicks = ScoreScreenTicks
  var transport = initPlayer(live = true, durationTicks = w.maximumTicks,
    playing = false, speed = 16)
  transport.startScoreFrame(w, 100)
  doAssert not transport.shouldScoreTick(epochTime())
  doAssert w.phaseTicks == ScoreScreenTicks
  transport.seekTo(w.tick + w.phaseTicks, play = false)
  while transport.shouldScoreTick(epochTime()):
    w.tickWorld(nil)
    transport.sync(w.tick, w.tick, w.over)
  doAssert w.day == 2
  doAssert w.dayTick == 0
  doAssert not transport.playing
  doAssert transport.speed == 16

block screenBounds:
  for size in [vec2(800, 400), vec2(1024, 576), vec2(1920, 1080)]:
    let scale = fitUiScale(size, scoreLayoutFits, ScoreUiScales)
    doAssert scoreLayoutFits(size / scale)
    doAssert scale >= 0.5
block replayReports:
  let data = loadReplay("examples/heartleaf/replays/demo.replay")
  let game = newGame(generateMap(data.header.setup.mapSeed), int32(data.header.setup.dayCount))
  var tape = initReplayPlayer(data)
  proc decide(w: World) =
    var action: ReplayAction
    while tape.takeActionAt(uint32(w.tick), action):
      w.applyReplayAction(action)
  let destination = parseSeekTarget("--seek-event", "day:3:scorecard")
  var checkpoint: World
  while not destination.reached(game.world):
    game.world.tickWorld(decide)
    doAssert game.stateHash() == data.hashes[game.world.tick - 1]
    if game.world.day == 2 and game.world.phase == ScorePhase and checkpoint == nil:
      checkpoint = game.world.clone()
  let expected = game.world.dailyReports
  let fingerprint = game.stateHash()
  game.world.restore(checkpoint)
  tape.syncCursor(uint32(game.world.tick))
  while not destination.reached(game.world):
    game.world.tickWorld(decide)
    doAssert game.stateHash() == data.hashes[game.world.tick - 1]
  doAssert game.world.dailyReports == expected
  doAssert game.stateHash() == fingerprint

block finalLoop:
  var transport = initPlayer(live = false, durationTicks = 10,
    playing = true, repeating = true)
  transport.sync(10, 10, true)
  doAssert not transport.shouldScoreTick(epochTime())
  doAssert transport.takeRestore() == 0
  doAssert transport.playing
  transport = initPlayer(live = false, durationTicks = 10,
    playing = false, repeating = true)
  transport.sync(10, 10, true)
  doAssert not transport.shouldScoreTick(epochTime())
  doAssert transport.takeRestore() == -1
  doAssert not transport.playing
  transport = initPlayer(live = false, durationTicks = 10,
    playing = true, repeating = false)
  transport.sync(10, 10, true)
  doAssert not transport.shouldScoreTick(epochTime())
  doAssert transport.takeRestore() == -1
  doAssert not transport.playing
