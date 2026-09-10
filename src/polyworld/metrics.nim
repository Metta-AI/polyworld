const
  MaxMetricSamples* = 4096
  MaxMetricPlayers* = 256
  MetricSeconds = 60

type
  MetricsError* = object of CatchableError
  MetricKind* = enum
    GoldMetric, ArmyMetric, KillsMetric, LossesMetric, AssistsMetric,
    BankedMetric, DamageMetric, HealingMetric, LevelMetric,
    StructuresMetric, CpuMetric, ApmMetric
  MetricValues* = array[MetricKind, int64]
  CombatStats* = ref object
    values*: seq[MetricValues]
    teams*: seq[int]
    hits*: seq[int32]
  MetricRow* = object
    values*: MetricValues
    instructions*, budget*, commands*: int64
    hasCpu*, hasApm*: bool
  TelemetryRow* = object
    cpu*: int32
      ## Negative one marks a rate that was unavailable in the live game.
  TelemetryFrame* = object
    tick*: int32
    rows*: seq[TelemetryRow]
  ReplayMetrics* = object
    tickRate*, interval*: int32
    frames*: seq[TelemetryFrame]
    final*: seq[TelemetryRow]
  LegacyTelemetryRow* = object
    cpu*, apm*: int32
  LegacyTelemetryFrame* = object
    tick*: int32
    rows*: seq[LegacyTelemetryRow]
  LegacyReplayMetrics* = object
    tickRate*, interval*: int32
    frames*: seq[LegacyTelemetryFrame]
    final*: seq[LegacyTelemetryRow]
  MetricBucket = object
    second: int32
    instructions, budget, commands: int64
  MetricPlayer = object
    row: MetricRow
    buckets: array[MetricSeconds, MetricBucket]
  MatchMetrics* = ref object
    tickRate*: int32
    players: seq[MetricPlayer]
    completedTick: int32
  MetricFrame* = object
    tick*: int32
    rows*: seq[MetricRow]
  MetricHistory* = object
    tickRate*: int32
    interval*: int32
    frames*: seq[MetricFrame]

proc fail(message: string) {.noreturn, raises: [MetricsError].} =
  ## Raises a statistics-specific boundary error.
  raise newException(MetricsError, message)

proc newCombatStats*(count: int): CombatStats =
  ## Creates deterministic counters that belong to simulation state.
  assert count >= 0 and count <= MaxMetricPlayers
  result = CombatStats()
  result.values.setLen(count)
  result.teams.setLen(count)
  result.hits = newSeq[int32](count * count)
  for hit in result.hits.mitems:
    hit = -1

proc clone*(stats: CombatStats): CombatStats =
  ## Copies counters and assist attribution for simulation checkpoints.
  if stats == nil:
    return nil
  result = CombatStats()
  for value in stats.values:
    result.values.add value
  for team in stats.teams:
    result.teams.add team
  for hit in stats.hits:
    result.hits.add hit

proc add*(stats: CombatStats, slot: int, kind: MetricKind,
    amount = 1'i64) =
  ## Credits a simulation event to a valid player seat.
  if stats != nil and slot >= 0 and slot < stats.values.len:
    stats.values[slot][kind] += amount

proc hitHero*(stats: CombatStats, attacker, victim: int,
    tick, tickRate: int32, killed: bool) =
  ## Tracks enemy damage and awards a death, finishing blow, and assists.
  if stats == nil or victim < 0 or victim >= stats.values.len:
    return
  let count = stats.values.len
  if attacker >= 0 and attacker < count and
    stats.teams[attacker] != stats.teams[victim]:
      stats.hits[victim * count + attacker] = tick
  if not killed:
    return
  stats.add(victim, LossesMetric)
  if attacker >= 0 and attacker < count and
    stats.teams[attacker] != stats.teams[victim]:
      stats.add(attacker, KillsMetric)
  for slot in 0 ..< count:
    let hit = stats.hits[victim * count + slot]
    if slot != attacker and hit >= 0 and tick - hit <= tickRate * 10 and
      stats.teams[slot] != stats.teams[victim]:
        stats.add(slot, AssistsMetric)
    stats.hits[victim * count + slot] = -1

proc newMetrics*(count: int, tickRate: int32): MatchMetrics =
  ## Creates bounded integer counters for the configured seats.
  assert count >= 0 and count <= MaxMetricPlayers and tickRate > 0
  result = MatchMetrics(tickRate: tickRate, completedTick: -1)
  result.players.setLen(count)
  for player in result.players.mitems:
    player.row.hasApm = true
    for bucket in player.buckets.mitems:
      bucket.second = -1

proc len*(metrics: MatchMetrics): int =
  ## Returns the number of tracked seats.
  if metrics == nil: 0 else: metrics.players.len

proc valid(metrics: MatchMetrics, slot: int): bool =
  ## Checks a seat without requiring telemetry in standalone simulations.
  metrics != nil and slot >= 0 and slot < metrics.players.len

proc set*(metrics: MatchMetrics, slot: int, kind: MetricKind,
    amount: int64) =
  ## Updates a current value derived from the world.
  if metrics.valid(slot):
    metrics.players[slot].row.values[kind] = amount

proc bucketIndex(metrics: MatchMetrics, slot: int, tick: int32): int =
  ## Rotates one second bucket without retaining an unbounded event log.
  let second = max(tick - 1, 0) div metrics.tickRate
  result = int(second mod MetricSeconds)
  if metrics.players[slot].buckets[result].second != second:
    metrics.players[slot].buckets[result] = MetricBucket(second: second)

proc command*(metrics: MatchMetrics, slot: int, tick: int32) =
  ## Counts one accepted command on the first traversal of its tick.
  if not metrics.valid(slot) or tick <= metrics.completedTick:
    return
  let index = metrics.bucketIndex(slot, tick)
  inc metrics.players[slot].row.commands
  inc metrics.players[slot].buckets[index].commands

proc finishTick*(metrics: MatchMetrics, tick: int32) =
  ## Prevents replay seeking from counting previously traversed actions again.
  if metrics != nil:
    metrics.completedTick = max(metrics.completedTick, tick)

proc decision*(metrics: MatchMetrics, slot: int, tick: int32,
    instructions, budget: int64) =
  ## Records consumed instructions and the allowance for one VM decision.
  if not metrics.valid(slot) or budget <= 0:
    return
  let index = metrics.bucketIndex(slot, tick)
  metrics.players[slot].row.hasCpu = true
  metrics.players[slot].row.instructions += max(instructions, 0)
  metrics.players[slot].row.budget += budget
  metrics.players[slot].buckets[index].instructions += max(instructions, 0)
  metrics.players[slot].buckets[index].budget += budget

proc finalRow*(row: MetricRow, tick, tickRate: int32): MetricRow =
  ## Converts lifetime totals into final CPU and command-rate averages.
  result = row
  result.values[CpuMetric] =
    if row.budget > 0: row.instructions * 100 div row.budget else: 0
  result.values[ApmMetric] =
    if tick > 0: row.commands * 60 * tickRate div tick else: 0

proc read*(metrics: MatchMetrics, slot: int, tick: int32,
    final = false): MetricRow =
  ## Reads lifetime values with second-bucketed live CPU and rolling APM.
  if not metrics.valid(slot):
    return
  result = metrics.players[slot].row
  if final:
    return result.finalRow(tick, metrics.tickRate)
  let second = max(tick - 1, 0) div metrics.tickRate
  var instructions, budget, commands: int64
  for bucket in metrics.players[slot].buckets:
    if bucket.second == second:
      instructions += bucket.instructions
      budget += bucket.budget
    if bucket.second >= 0 and bucket.second <= second and
      bucket.second > second - MetricSeconds:
        commands += bucket.commands
  result.values[CpuMetric] =
    if budget > 0: instructions * 100 div budget else: 0
  let elapsed = min(max(tick, 1), MetricSeconds * metrics.tickRate)
  result.values[ApmMetric] = commands * 60 * metrics.tickRate div elapsed

proc capture*(history: var MetricHistory, metrics: MatchMetrics,
    tick: int32, force = false) =
  ## Samples all seats together and coarsens long histories deterministically.
  if metrics == nil:
    return
  if history.frames.len > 0 and tick <= history.frames[^1].tick:
    return
  if history.interval == 0:
    history.tickRate = metrics.tickRate
    history.interval = metrics.tickRate
  if not force and history.frames.len > 0 and tick mod history.interval != 0:
    return
  if history.frames.len >= MaxMetricSamples:
    var write = 1
    for i in countup(2, history.frames.high, 2):
      history.frames[write] = history.frames[i]
      inc write
    history.frames[write] = history.frames[^1]
    history.frames.setLen(write + 1)
    history.interval *= 2
  var frame = MetricFrame(tick: tick)
  for slot in 0 ..< metrics.len:
    frame.rows.add metrics.read(slot, tick)
  history.frames.add frame

proc frameIndex*(history: MetricHistory, tick: int32): int =
  ## Finds the newest sample at or before a displayed replay tick.
  var low = 0
  var high = history.frames.len
  while low < high:
    let middle = (low + high) div 2
    if history.frames[middle].tick <= tick:
      low = middle + 1
    else:
      high = middle
  low - 1

proc withTelemetry*(row: MetricRow, history: MetricHistory,
    slot: int, tick: int32, final = false): MetricRow =
  ## Restores live CPU and APM when seeking an in-memory match.
  result = row
  result.hasCpu = false
  result.hasApm = false
  let index = history.frameIndex(tick)
  if index < 0 or slot < 0 or slot >= history.frames[index].rows.len:
    return
  let source =
    if final:
      history.frames[index].rows[slot].finalRow(
        history.frames[index].tick, history.tickRate
      )
    else:
      history.frames[index].rows[slot]
  result.hasCpu = source.hasCpu
  result.hasApm = source.hasApm
  result.values[CpuMetric] = source.values[CpuMetric]
  result.values[ApmMetric] = source.values[ApmMetric]

proc rate(value: int64, available: bool): int32 =
  ## Encodes an available rate without silently narrowing its value.
  if not available:
    return -1
  if value < 0 or value > int32.high:
    fail("CPU rate exceeds the supported range")
  int32(value)

proc telemetryRow(row: MetricRow): TelemetryRow =
  ## Retains the CPU rate that action resimulation cannot recover.
  TelemetryRow(cpu: rate(row.values[CpuMetric], row.hasCpu))

proc replayMetrics*(history: MetricHistory): ReplayMetrics =
  ## Projects local history into replay CPU samples and final averages.
  if history.frames.len == 0:
    return
  result.tickRate = history.tickRate
  result.interval = history.interval
  for frame in history.frames:
    var sample = TelemetryFrame(tick: frame.tick)
    for row in frame.rows:
      sample.rows.add row.telemetryRow()
    result.frames.add sample
  let last = history.frames[^1]
  for row in last.rows:
    result.final.add row.finalRow(last.tick, history.tickRate).telemetryRow()

proc cpuMetrics*(legacy: LegacyReplayMetrics): ReplayMetrics =
  ## Reads CPU from older recordings and discards their attempted-command APM.
  result.tickRate = legacy.tickRate
  result.interval = legacy.interval
  for frame in legacy.frames:
    var sample = TelemetryFrame(tick: frame.tick)
    for row in frame.rows:
      sample.rows.add TelemetryRow(cpu: row.cpu)
    result.frames.add sample
  for row in legacy.final:
    result.final.add TelemetryRow(cpu: row.cpu)

proc validate*(metrics: ReplayMetrics, players: int, tickRate: int32,
    lastTick: int) =
  ## Checks replay telemetry against its owning roster and action timeline.
  if metrics.frames.len == 0:
    if metrics != ReplayMetrics():
      fail("empty replay telemetry has unexpected data")
    return
  if players <= 0 or players > MaxMetricPlayers or
    metrics.tickRate != tickRate or tickRate <= 0 or tickRate > 1000 or
    metrics.interval < tickRate or metrics.frames.len > MaxMetricSamples or
    metrics.final.len != players:
      fail("replay telemetry dimensions do not match the recording")
  var previous = -1'i32
  for frame in metrics.frames:
    if frame.tick <= previous or frame.tick > lastTick or
      frame.rows.len != players:
        fail("replay telemetry samples do not match the recording")
    previous = frame.tick
    for row in frame.rows:
      if row.cpu < -1:
        fail("replay telemetry contains an invalid CPU rate")
  if metrics.frames[0].tick != 0 or previous != lastTick:
    fail("replay telemetry does not cover the complete recording")
  for row in metrics.final:
    if row.cpu < -1:
      fail("replay telemetry contains an invalid final rate")

proc withTelemetry*(row: MetricRow, metrics: ReplayMetrics,
    slot: int, tick: int32, final = false): MetricRow =
  ## Adds recorded CPU while preserving resimulated gameplay and APM.
  result = row
  result.hasCpu = false
  if metrics.frames.len == 0 or slot < 0 or slot >= metrics.final.len:
    return
  var
    low = 0
    high = metrics.frames.len
  while low < high:
    let middle = (low + high) div 2
    if metrics.frames[middle].tick <= tick:
      low = middle + 1
    else:
      high = middle
  if low == 0:
    return
  let source =
    if final and tick >= metrics.frames[^1].tick:
      metrics.final[slot]
    else:
      metrics.frames[low - 1].rows[slot]
  result.hasCpu = source.cpu >= 0
  result.values[CpuMetric] = max(source.cpu, 0)
