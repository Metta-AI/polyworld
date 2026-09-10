import
  std/[algorithm, monotimes, times],
  jsony, opengl, silky, vmath, windy,
  polyworld/[gameuis, metrics, player, stats, viewers]

type DrawingMeasurement = object
  game: string
  players, samples, frames: int
  visible: bool
  drawMedianMs, drawP95Ms, completeMedianMs: float64

proc median(values: seq[float64]): float64 =
  ## Returns the middle observation from one completed sample set.
  var ordered = values
  ordered.sort()
  ordered[ordered.len div 2]

proc measureOverlay*(game: string, kind: StatsKind, source: MetricHistory) =
  ## Times the real overlay renderer with a resimulated metric history.
  var history = source
  let
    (window, sk) = initGameWindow(
      "Stats benchmark",
      "tmp/" & game & ".atlas.png",
      ivec2(1920, 1080),
      vsync = false
    )
    layout = initGameUiLayout(vec2(1920, 1080), TransportHeight)
    original = history
  defer:
    window.close()
  glDisable(GL_DEPTH_TEST)
  glDisable(GL_CULL_FACE)
  glDisable(GL_BLEND)
  for count in [original.frames.len, MaxMetricSamples]:
    history = original
    if count != original.frames.len:
      history.frames = newSeq[MetricFrame](count)
      for i in 0 ..< count:
        history.frames[i] = original.frames[
          i * (original.frames.len - 1) div (count - 1)
        ]
        history.frames[i].tick = int32(i) * history.tickRate
    var table = StatsTable(kind: kind, tick: history.frames[^1].tick)
    for slot, row in history.frames[^1].rows:
      let
        portrait =
          case kind
          of GotaStats: "gota_vanguard_knight"
          of RtsStats: "lvd_u" & $(slot mod 2) & "_0"
          of AdventureStats: "hero_fighter"
        team =
          if kind == GotaStats: slot div 5
          else: slot
      table.rows.add StatsRow(
        slot: slot,
        name: "base",
        subtitle: "PLAYER " & $(slot + 1),
        portrait: portrait,
        team: team,
        metrics: row
      )
    for shown in [false, true]:
      var
        state = StatsState(toggled: shown)
        drawing: seq[float64]
        completed: seq[float64]
      for frame in 0 ..< 600:
        pollEvents()
        sk.beginUi(window, window.size)
        let started = getMonoTime()
        sk.drawStats(window, layout, state, table, history)
        let drawn = getMonoTime()
        sk.endUi()
        glFinish()
        let finished = getMonoTime()
        if frame >= 100:
          drawing.add (drawn - started).inNanoseconds.float64 / 1_000_000
          completed.add (finished - started).inNanoseconds.float64 /
            1_000_000
      drawing.sort()
      echo "BENCH_UI ", DrawingMeasurement(
        game: game,
        players: table.rows.len,
        samples: count,
        frames: drawing.len,
        visible: shown,
        drawMedianMs: drawing.median(),
        drawP95Ms: drawing[drawing.len * 95 div 100],
        completeMedianMs: completed.median()
      ).toJson()

