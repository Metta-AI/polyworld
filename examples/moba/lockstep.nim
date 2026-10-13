## The gota.h C API over the moba port (sim.nim), so PufferLib's GotA env
## trains moba unchanged: build with --app:lib and set gota.h's
## GOTA_MOBA_SHAPE and GOTA_MOBA_RAW (510 raw observation values, six
## heads). Each lane is one match of five learners (moba's Radiant)
## against moba's five scripted heroes. Like moba, no step is terminal; a
## lane reports its finished match in LaneStats and plays on.

import sim

const
  GotaSourceCommit {.strdefine.} = ""
  AgentsPerLane = 5

type
  LaneStats {.bycopy.} = object
    ## Mirrors GotaLaneStats in gota.h.
    finished, outcome, tick, selfPlay: int32
    played, level: int32
    potential: int64

  StepBatch = ref object
    lanes: seq[Moba]

proc seedFor(seed: int64, lane: int): uint32 =
  ## A nonzero xorshift seed per lane.
  let mixed = uint64(seed) * 0x9E3779B97F4A7C15'u64 + uint64(lane + 1) *
    0xBF58476D1CE4E5B9'u64
  uint32((mixed shr 32) xor (mixed and 0xffffffff'u64)) or 1

proc writeObservations(
  batch: StepBatch,
  observations, seats: ptr UncheckedArray[int32]
) =
  ## Copies every learner's observation and its seat.
  var buffer: array[ObservationSize, int32]
  for i, lane in batch.lanes:
    for pid in 0 ..< AgentsPerLane:
      let agent = i * AgentsPerLane + pid
      lane.observe(pid, buffer)
      copyMem(observations[agent * ObservationSize].addr, buffer[0].addr,
        ObservationSize * sizeof(int32))
      seats[agent] = int32(pid)

proc gota_source_commit(): cstring {.cdecl, exportc, dynlib.} =
  GotaSourceCommit.cstring

proc gota_stats_size(): cint {.cdecl, exportc, dynlib.} =
  cint(sizeof(LaneStats))

proc gota_observation_size(): cint {.cdecl, exportc, dynlib.} =
  cint(ObservationSize)

proc gota_action_count(): cint {.cdecl, exportc, dynlib.} =
  cint(ActionCount)

proc gota_create(
  config, bot, opponent, policy: cstring,
  count, maxTicks, selfPlay, rewardMode: cint
): pointer {.cdecl, exportc, dynlib.} =
  doAssert selfPlay == 0, "the moba port plays five learners vs scripts"
  let batch = StepBatch()
  for i in 0 ..< int(count):
    batch.lanes.add newMoba(seedFor(0, i))
  GC_ref(batch)
  cast[pointer](batch)

proc gota_agents(handle: pointer): cint {.cdecl, exportc, dynlib.} =
  cint(cast[StepBatch](handle).lanes.len * AgentsPerLane)

proc gota_reset(
  handle: pointer,
  seed: int64,
  observations, seats: ptr UncheckedArray[int32]
) {.cdecl, exportc, dynlib.} =
  let batch = cast[StepBatch](handle)
  for i in 0 ..< batch.lanes.len:
    batch.lanes[i] = newMoba(seedFor(seed, i))
  batch.writeObservations(observations, seats)

proc gota_step(
  handle: pointer,
  actions, observations, seats: ptr UncheckedArray[int32],
  rewards: ptr UncheckedArray[float32],
  terminals: ptr UncheckedArray[uint8],
  stats: ptr UncheckedArray[LaneStats]
) {.cdecl, exportc, dynlib.} =
  let batch = cast[StepBatch](handle)
  for i, lane in batch.lanes:
    for pid in 0 ..< AgentsPerLane:
      let agent = i * AgentsPerLane + pid
      for head in 0 ..< ActionCount:
        lane.actions[pid][head] = clamp(actions[agent * ActionCount + head],
          0'i32, ActionSizes[head] - 1)
    let tickRewards = lane.step()
    for pid in 0 ..< AgentsPerLane:
      let agent = i * AgentsPerLane + pid
      rewards[agent] = tickRewards[pid]
      terminals[agent] = 0
    stats[i] = LaneStats(level: -1)
    if lane.finished:
      stats[i] = LaneStats(
        finished: 1,
        outcome: if lane.radiantVictory: 1 else: -1,
        tick: int32(lane.finishedTick),
        level: -1
      )
  batch.writeObservations(observations, seats)

proc gota_close(handle: pointer) {.cdecl, exportc, dynlib.} =
  GC_unref(cast[StepBatch](handle))

proc gota_set_level(handle: pointer, level: cint) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_walk(handle: pointer, percent: cint) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_reach(handle: pointer, percent: cint) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_retreat(
  handle: pointer,
  percent: cint
) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_easier(
  handle: pointer,
  percent: cint
) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_build(handle: pointer, build: cint) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_win_bonus(
  handle: pointer,
  bonus: cfloat
) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_structure_weight(
  handle: pointer,
  weight: cfloat
) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_cuts(handle: pointer, cuts: cint) {.cdecl, exportc, dynlib.} =
  ## Reserved for the GotA traits of ladder rungs 11 to 19.
  discard

proc gota_set_simplify(
  handle: pointer,
  level: cint
) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_finish(handle: pointer, finish: cint) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_health_weight(
  handle: pointer,
  weight: cfloat
) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_death_weight(
  handle: pointer,
  weight: cfloat
) {.cdecl, exportc, dynlib.} =
  discard

proc gota_set_shaping(
  handle: pointer,
  weight, gamma: cfloat
) {.cdecl, exportc, dynlib.} =
  discard
