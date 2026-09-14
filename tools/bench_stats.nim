import
  std/[monotimes, strutils, times],
  jsony

when defined(benchGota):
  import ../examples/gods_of_the_arena/[game, replays, sim]
elif defined(benchLvd):
  import ../examples/light_vs_dark/[game, replays, sim]
else:
  import ../examples/call_to_adventure/[content, game, replays, sim]

when not defined(statsBaseline):
  import polyworld/metrics

when defined(benchUi):
  import polyworld/stats, bench_stats_ui

type Measurement = object
  seed, ticks, players, actions, samples: int
  seconds, encodeSeconds: float64
  baseBytes, statsBytes: int
  gameplayHash: string
  acceptedCommands, finalApm: seq[int64]

proc finished(): bool =
  ## Uses each game's normal end condition without timing setup or output.
  if run.world.tick >= options.maximumTicks:
    return true
  when defined(benchGota):
    run.world.gameOver
  elif defined(benchLvd):
    run.world.over
  else:
    run.world.phase in {EscapedPhase, WipedPhase}

proc measure() =
  ## Times real bot decisions, simulation, hashing, and metric collection.
  when defined(benchGota):
    startReplayRecording(uint32(options.maximumTicks))
  var measurement = Measurement(seed: int(options.seed))
  let started = getMonoTime()
  while not finished():
    advanceGame()
  measurement.seconds = (getMonoTime() - started).inNanoseconds.float64 /
    1_000_000_000
  measurement.ticks = int(run.world.tick)
  measurement.players = run.recorder.data.config.players.len
  measurement.actions = run.recorder.data.actions.len
  when not defined(statsBaseline):
    run.sampleMetrics(true)
    measurement.samples = run.history.frames.len
    run.recorder.data.metrics = run.history.replayMetrics()
    for slot in 0 ..< run.metrics.len:
      let row = run.metrics.read(slot, run.world.tick, true)
      measurement.acceptedCommands.add row.commands
      measurement.finalApm.add row.values[ApmMetric]
  measurement.gameplayHash = run.stateHash().toHex(16)
  var baseline = run.recorder.data
  when not defined(statsBaseline):
    baseline.metrics = ReplayMetrics()
  let
    base = encodeReplay(baseline)
    encodeStarted = getMonoTime()
    encoded = encodeReplay(run.recorder.data)
  measurement.baseBytes = base.len
  measurement.encodeSeconds =
    (getMonoTime() - encodeStarted).inNanoseconds.float64 / 1_000_000_000
  measurement.statsBytes = encoded.len
  if options.recordPath.len > 0:
    writeFile(options.recordPath, encoded)
  echo "BENCH_STATS ", measurement.toJson()
  when defined(benchUi):
    when defined(benchGota):
      measureOverlay("gota", GotaStats, run.history)
    elif defined(benchLvd):
      measureOverlay("lvd", RtsStats, run.history)
    else:
      measureOverlay("cta", AdventureStats, run.history)

measure()
