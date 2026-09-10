import
  std/strformat,
  vmath, polyworld/[gameuis, player],
  content, sim

const
  ScoreUiScales* = [
    0.25'f32, 0.5'f32, 0.625'f32, 0.75'f32, 1'f32, 1.25'f32,
    1.5'f32, 2'f32, 2.5'f32, 3'f32, 4'f32]
  ScorecardWidth* = 1220'f32
  ScorecardHeight* = 620'f32
  ScoreRowHeight* = 48'f32
  ScoreRowsTop* = 96'f32
  ScoreColumns* = [0'f32, 170, 410, 820, 950, 1070]
  ScoreColumnWidths* = [160'f32, 230, 400, 120, 110, 100]

type ScorePresentation* = object
  day*: int32
  visible*: bool
  elapsed*: float32

proc update*(presentation: var ScorePresentation, world: World, dt: float32) =
  let day = min(world.day, world.dayCount)
  let visible = world.phase in {ScorePhase, GameOverPhase}
  if visible:
    if not presentation.visible or presentation.day != day:
      presentation.elapsed = 0
    else:
      presentation.elapsed = min(3'f32, presentation.elapsed + max(0'f32, dt))
  presentation.visible = visible
  presentation.day = day

proc shown*(presentation: ScorePresentation, column: int): bool =
  presentation.elapsed >= float32(min(max(column - 1, 0), 3))

proc hostingText*(world: World, slot: int): string =
  let tally = world.lastTally[slot]
  if tally.valid:
    &"{tally.pantry} veg x {tally.visitors} guests = +{tally.hostPoints}"
  elif not world.dailyReports[slot].hostHome:
    "Host absent"
  else:
    "No guests"

proc eatingText*(report: DailyReport): string =
  if report.biteCount == 0:
    return "No dinner"
  for i in 0 ..< report.biteCount:
    if i > 0:
      result.add " / "
    let bite = report.bites[i]
    result.add &"{VeggieNames[bite.veggie]} +{bite.points}"

proc dailyGain*(world: World, slot: int): int32 =
  world.villagers[slot].score - world.dailyReports[slot].startingScore

proc signedPoints*(points: int32): string =
  if points >= 0: "+" & $points else: $points

proc scoreLayoutFits*(size: Vec2): bool =
  let layout = initGameUiLayout(size, TransportHeight)
  layout.gameAreaSize.x >= ScorecardWidth + 20 and
    layout.gameAreaSize.y >= ScorecardHeight + 20

proc startScoreFrame*(transport: var Player, world: World, dt: float32) =
  let scorePacing = world.phase == ScorePhase and transport.targetTick < 0
  transport.startFrame(
    (if scorePacing: dt / float32(transport.speed) else: dt), TickRate)

proc stopAtScoreBoundary*(transport: var Player, previous: DayPhase,
    world: World): bool =
  if previous != world.phase and transport.targetTick < 0:
    transport.accumulator = 0
    return true

proc shouldScoreTick*(transport: var Player, frameStart: float64): bool =
  if not transport.playing and transport.targetTick < 0:
    return false
  transport.shouldTick(frameStart)
