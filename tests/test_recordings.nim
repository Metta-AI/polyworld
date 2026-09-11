## Exercises saving and headless verification through each game's runner.
## Compile with -d:headless and a bot roster. The default is Call to Adventure;
## -d:recordGota, -d:recordHlf, or -d:recordLvd selects another game.

import
  std/[os, osproc, strutils],
  polyworld/tapes

when not defined(recordHlf):
  import polyworld/metrics

when defined(recordGota):
  import ../examples/gods_of_the_arena/[game, replays, sim]
elif defined(recordHlf):
  import ../examples/heartleaf/[game, replays, sim]
elif defined(recordLvd):
  import ../examples/light_vs_dark/[game, replays, sim]
else:
  import ../examples/call_to_adventure/[content, game, replays, sim]

when not defined(headless):
  {.error: "Recording tests require -d:headless.".}

proc playFile(path: string): tuple[output: string, exitCode: int] =
  ## Verifies a replay in a fresh process using the same game runner.
  execCmdEx(
    quoteShell(getAppFilename()) & " --replay " & quoteShell(path) &
    " --seed -123 --ticks 1"
  )

when not defined(recordHlf):
  proc apmSummary(): string =
    ## Compares each reconstructed command count and APM sample across runs.
    result = "APM"
    for frame in run.history.frames:
      result.add " " & $frame.tick & ":"
      for row in frame.rows:
        result.add $row.commands & "/" & $row.values[ApmMetric] & ","
    for slot in 0 ..< run.metrics.len:
      let row = run.metrics.read(slot, run.world.tick, true)
      result.add " " & $row.commands & "/" & $row.values[ApmMetric]

proc testRecording() =
  ## Covers empty tapes, partial recordings, rewinds, and failed verification.
  when defined(recordGota):
    startReplayRecording(96)
  let
    directory = getTempDir() / ("polyworld-recording-" & $getCurrentProcessId())
    path = directory / "test.replay"
    setup = run.recorder.data.header.setup
  createDir(directory)
  defer:
    removeDir(directory)

  echo "Testing saving before the first tick"
  let originalHash = run.stateHash()
  doAssert run.recorder.data.config.players.len > 0
  doAssert run.recorder.data.config.players[0].name == "base"
  run.recorder.data.config.players[0].name = "Dragon.BAS"
  doAssert run.stateHash() == originalHash
  let config = run.recorder.data.config
  saveRecording(path)
  let empty = loadReplay(path)
  doAssert empty.config == config
  doAssert empty.config.players[0].name == "Dragon.BAS"
  doAssert empty.header.setup == setup
  doAssert empty.hashes.len == 0
  let emptyPlayback = playFile(path)
  doAssert emptyPlayback.exitCode == 0, emptyPlayback.output

  echo "Testing replay config agrees with the recorded match"
  for check in 0 ..< 4:
    var invalid = empty
    case check
    of 0:
      inc invalid.config.seed
    of 1:
      inc invalid.config.maxTicks
    of 2:
      invalid.config.players.setLen(0)
    else:
      invalid.config.players[0].name = repeat('x', 4097)
    try:
      discard encodeReplay(invalid)
      doAssert false, "inconsistent replay configuration must fail"
    except ReplayError:
      discard

  echo "Testing partial recordings preserve the simulation setup"
  for i in 0 ..< 24:
    advanceGame()
  let snapshot = run.world.clone()
  for i in 0 ..< 24:
    advanceGame()
  saveRecording(path)
  let partial = loadReplay(path)
  doAssert partial.config == config
  doAssert partial.header.setup == setup
  doAssert partial.hashes.len == 48
  doAssert partial.actions.len > 0
  doAssert run.recorder.data.header.setup == setup
  when not defined(recordHlf):
    doAssert partial.metrics == run.history.replayMetrics()
    doAssert partial.metrics.frames[^1].tick == 48
    doAssert partial.metrics.frames[^1].rows[0].cpu >= 0
    doAssert readFile(path) == encodeReplay(partial)
    for invalid in 0 ..< 3:
      var corrupt = partial
      case invalid
      of 0:
        corrupt.metrics.frames[^1].tick = 49
      of 1:
        corrupt.metrics.final.setLen(0)
      else:
        corrupt.metrics.frames[0].rows.setLen(0)
      try:
        discard encodeReplay(corrupt)
        doAssert false, "invalid embedded telemetry must fail"
      except ReplayError:
        discard
  when not defined(recordHlf):
    let liveApm = apmSummary()
    doAssert run.metrics.read(0, run.world.tick).commands > 0, liveApm
  let partialPlayback = playFile(path)
  doAssert partialPlayback.exitCode == 0, partialPlayback.output
  when not defined(recordHlf):
    doAssert partialPlayback.output.contains(liveApm), partialPlayback.output

  echo "Testing a rewind does not shorten the saved recording"
  run.world.restore(snapshot)
  saveRecording(path)
  let rewound = loadReplay(path)
  doAssert rewound.config == config
  doAssert rewound == partial
  doAssert run.recorder.data == partial
  let rewoundPlayback = playFile(path)
  doAssert rewoundPlayback.exitCode == 0, rewoundPlayback.output

  when not defined(recordHlf):
    echo "Testing APM survives rewinding and continuing live play"
    run.replayPlayer.data = run.recorder.data
    run.replayPlayer.syncCursor(uint32(run.world.tick))
    run.historyPlayback = true
    while run.world.tick < 48:
      advanceGame()
    doAssert apmSummary() == liveApm
    run.historyPlayback = false
    for i in 0 ..< 31:
      advanceGame()
    saveRecording(path)
    let continuedPlayback = playFile(path)
    doAssert continuedPlayback.exitCode == 0, continuedPlayback.output
    doAssert continuedPlayback.output.contains(apmSummary()),
      continuedPlayback.output

    when not defined(recordLvd):
      echo "Testing older embedded CPU/APM recordings retain only CPU"
      var previous: ActionTape[Setup, ReplayAction, LegacyReplayMetrics]
      previous.header = partial.header
      previous.header.gameVersion = MetricsGameVersion
      previous.config = partial.config
      previous.actions = partial.actions
      previous.hashes = partial.hashes
      previous.metrics.tickRate = partial.metrics.tickRate
      previous.metrics.interval = partial.metrics.interval
      for frame in partial.metrics.frames:
        var sample = LegacyTelemetryFrame(tick: frame.tick)
        for row in frame.rows:
          sample.rows.add LegacyTelemetryRow(cpu: row.cpu, apm: 9999)
        previous.metrics.frames.add sample
      for row in partial.metrics.final:
        previous.metrics.final.add LegacyTelemetryRow(cpu: row.cpu, apm: 9999)
      let converted = decodeReplay(encodeReplayFile(
        ReplayGame, MetricsGameVersion, previous, MaxReplayBytes
      ))
      doAssert converted.metrics == partial.metrics
      doAssert decodeReplay(encodeReplay(converted)) == partial

  echo "Testing divergent replays exit with failure"
  var corrupt = partial
  corrupt.hashes[0] = corrupt.hashes[0] xor 1
  saveReplay(path, corrupt)
  let corruptPlayback = playFile(path)
  doAssert corruptPlayback.exitCode != 0, corruptPlayback.output
  doAssert corruptPlayback.output.contains("first at tick 1"),
    corruptPlayback.output
  echo "Recording tests passed"

if run.replayMode:
  doAssert run.replayData.config.players[0].name == "Dragon.BAS"
  runHeadless()
  when not defined(recordHlf):
    echo apmSummary()
else:
  testRecording()
