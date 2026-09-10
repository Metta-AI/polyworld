import
  flatty,
  polyworld/metrics

echo "Testing instruction budgets and accepted commands"
block:
  let metrics = newMetrics(2, 24)
  metrics.decision(0, 24, 500, 2000)
  metrics.decision(0, 24, 1000, 2000)
  metrics.command(0, 24)
  metrics.command(0, 24)
  let row = metrics.read(0, 24)
  doAssert row.hasCpu and row.hasApm
  doAssert row.values[CpuMetric] == 37
  doAssert row.values[ApmMetric] == 120
  doAssert not metrics.read(1, 24).hasCpu
  doAssert metrics.read(0, 24 * 62).values[ApmMetric] == 0
  doAssert metrics.read(0, 24 * 120, true).values[ApmMetric] == 1
  doAssert metrics.read(0, 24 * 120, true).values[CpuMetric] == 37
  metrics.command(-1, 1)
  metrics.decision(3, 1, 10, 100)
  doAssert metrics.read(-1, 1) == MetricRow()

echo "Testing finishing blows and recent enemy assists"
block:
  let stats = newCombatStats(4)
  stats.teams = @[0, 0, 1, 1]
  stats.hitHero(0, 2, 24, 24, false)
  stats.hitHero(1, 2, 48, 24, true)
  doAssert stats.values[0][AssistsMetric] == 1
  doAssert stats.values[1][KillsMetric] == 1
  doAssert stats.values[2][LossesMetric] == 1
  stats.hitHero(1, 2, 49, 24, true)
  doAssert stats.values[0][AssistsMetric] == 1
  stats.hitHero(0, 3, 50, 24, false)
  stats.hitHero(-1, 3, 300, 24, true)
  doAssert stats.values[0][AssistsMetric] == 1
  stats.hitHero(0, 2, 301, 24, false)
  stats.hitHero(3, 0, 302, 24, true)
  stats.hitHero(1, 2, 303, 24, true)
  doAssert stats.values[0][AssistsMetric] == 2,
    "a contributor still receives an assist after dying"
  let snapshot = stats.clone()
  stats.add(0, GoldMetric, 50)
  stats.hitHero(0, 2, 301, 24, false)
  doAssert snapshot.values[0][GoldMetric] == 0
  doAssert snapshot.hits != stats.hits

echo "Testing CPU replay samples, final averages, and rewinds"
block:
  let metrics = newMetrics(2, 24)
  var history: MetricHistory
  history.capture(metrics, 0, true)
  metrics.set(0, GoldMetric, 100)
  metrics.command(0, 24)
  metrics.decision(0, 24, 100, 1000)
  history.capture(metrics, 24)
  metrics.command(0, 25)
  metrics.decision(0, 25, 900, 1000)
  history.capture(metrics, 25, true)
  history.capture(metrics, 12, true)
  doAssert history.frames.len == 3
  let
    recorded = history.replayMetrics()
    bytes = recorded.toFlatty()
    decoded = bytes.fromFlatty(ReplayMetrics)
  doAssert decoded == recorded
  doAssert bytes.len == 24 + 3 * (12 + 2 * 4) + 2 * 4
  var row: MetricRow
  row.values[GoldMetric] = 13
  row.values[ApmMetric] = 42
  row.hasApm = true
  let shown = row.withTelemetry(decoded, 0, 24)
  doAssert shown.values[GoldMetric] == 13
  doAssert shown.values[CpuMetric] == 10
  doAssert shown.values[ApmMetric] == 42
  doAssert row.values[CpuMetric] == 0
  doAssert row.withTelemetry(decoded, 0, 25).values[CpuMetric] == 90
  let final = row.withTelemetry(decoded, 0, 25, true)
  doAssert final.values[CpuMetric] == 50
  doAssert final.values[ApmMetric] == 42
  doAssert final.values[GoldMetric] == 13
  doAssert row.withTelemetry(history, 0, 25, true).values[ApmMetric] == 115
  let initial = row.withTelemetry(decoded, 0, 0)
  doAssert not initial.hasCpu
  doAssert initial.values[ApmMetric] == 42
  let missing = row.withTelemetry(ReplayMetrics(), 0, 24)
  doAssert not missing.hasCpu and missing.hasApm
  doAssert missing.values[ApmMetric] == 42
  decoded.validate(2, 24, 25)
  for invalid in 0 ..< 5:
    var corrupt = decoded
    case invalid
    of 0:
      corrupt.final.setLen(1)
    of 1:
      corrupt.frames[^1].tick = 26
    of 2:
      corrupt.frames[1].rows[0].cpu = -2
    of 3:
      corrupt.frames[0].tick = 1
    else:
      corrupt.frames[^1].tick = 24
    try:
      corrupt.validate(2, 24, 25)
      doAssert false, "invalid CPU telemetry must fail"
    except MetricsError:
      discard
  try:
    decoded.validate(3, 24, 25)
    doAssert false, "different rosters must fail"
  except MetricsError:
    discard

echo "Testing revisited ticks do not duplicate accepted commands"
block:
  let metrics = newMetrics(1, 24)
  var history: MetricHistory
  history.capture(metrics, 0, true)
  for tick in 1'i32 .. 48:
    metrics.command(0, tick)
    history.capture(metrics, tick)
    metrics.finishTick(tick)
  let recorded = metrics.read(0, 48)
  for tick in 1'i32 .. 48:
    metrics.command(0, tick)
    metrics.finishTick(tick)
  doAssert metrics.read(0, 48) == recorded
  doAssert recorded.commands == 48
  doAssert recorded.withTelemetry(history, 0, 24).values[ApmMetric] == 1440
  metrics.command(0, 49)
  metrics.finishTick(49)
  doAssert metrics.read(0, 49).commands == 49

echo "Testing old CPU/APM recordings discard their attempted-command APM"
block:
  let previous = LegacyReplayMetrics(
    tickRate: 24,
    interval: 24,
    frames: @[
      LegacyTelemetryFrame(tick: 0, rows: @[
        LegacyTelemetryRow(cpu: -1, apm: 0)
      ]),
      LegacyTelemetryFrame(tick: 24, rows: @[
        LegacyTelemetryRow(cpu: 25, apm: 900)
      ])
    ],
    final: @[LegacyTelemetryRow(cpu: 20, apm: 800)]
  )
  let decoded = previous.toFlatty().fromFlatty(LegacyReplayMetrics).cpuMetrics()
  decoded.validate(1, 24, 24)
  doAssert decoded.frames[^1].rows[0].cpu == 25
  doAssert decoded.final[0].cpu == 20
  var row = MetricRow(hasApm: true)
  row.values[ApmMetric] = 60
  doAssert row.withTelemetry(decoded, 0, 24).values[ApmMetric] == 60

echo "Testing long histories retain bounded, ordered samples"
block:
  let metrics = newMetrics(1, 1)
  var history: MetricHistory
  for tick in 0'i32 .. 12_000:
    metrics.set(0, GoldMetric, tick)
    history.capture(metrics, tick)
    doAssert history.frames.len <= MaxMetricSamples
  history.capture(metrics, 12_001, true)
  doAssert history.frames[0].tick == 0
  doAssert history.frames[^1].tick == 12_001
  doAssert history.interval > 1
  history.replayMetrics().validate(1, 1, 12_001)
  doAssert history.frameIndex(-1) == -1
  doAssert history.frameIndex(0) == 0
