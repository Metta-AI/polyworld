## Polyworld neural seats: the game-agnostic half of hosting a neural policy.
##
## A game supplies one NeuralContract (its package rules plus callbacks that
## build an observation and turn logits into the game's command). This module
## owns everything else: the per-seat brain (actor, observation, recurrent
## state, logits), the decision-frame and state-reset lifecycle, the per-seat
## operation budget and telemetry line, the categorical decoders and the
## BASIC host functions `run_neural_net`, `neuralObservation`,
## `neuralLogits`, `neuralState` and `neuralModel`. How to add a game:
## docs/neural-policies.md.

import
  std/[json, math],
  bassy, fixxy,
  neural_package

export neural_package

const
  MaxHeadSize* = 1024
    ## Largest categorical head a decoder here accepts (the model limit).

type
  BuildObservationProc* = proc(brain: NeuralBrain): bool {.nimcall.}
  DecodeActionProc* = proc(brain: NeuralBrain) {.nimcall.}
  HeadProc* = proc(brain: NeuralBrain, index: int): int32 {.nimcall.}
  TickProc* = proc(brain: NeuralBrain): int32 {.nimcall.}
  LogProc* = proc(brain: NeuralBrain, text: string) {.nimcall.}
  MaskProc* = proc(brain: NeuralBrain, mask: var openArray[uint8]) {.nimcall.}
  TelemetryProc* = proc(brain: NeuralBrain): string {.nimcall.}

  NeuralContract* = object of PackageContract
    ## A game's neural contract: package rules (PackageContract) plus the
    ## callbacks the host calls on that game's brains. Build it with
    ## initNeuralContract. Every callback gets the brain, whose `seat` is
    ## the game's seat index; a game that needs more per-seat data derives
    ## its own seat type from NeuralBrain.
    name*: string
      ## Short game id for logs, e.g. "gota".
    maskSize*: int
      ## Action-mask bytes (0 = the game has no action mask).
    buildObservation*: BuildObservationProc
      ## Fills brain.obs (observationSize floats) for the current tick and
      ## returns whether the seat acts this decision (alive, match running).
    decodeAction*: DecodeActionProc
      ## Turns brain.logits into the game's heads and pending command, after
      ## an inference (decoder options, masks and sampling live here).
    head*: HeadProc
      ## Head `index` of the seat's latest decision (neuralModel 5+).
    tick*: TickProc
      ## The game's current tick (a decision is fresh on its own tick).
    log*: LogProc
      ## Optional: the seat's log (telemetry lines). Nil = no telemetry.
    actionMask*: MaskProc
      ## Optional: writes the current frame's validity mask (maskSize bytes,
      ## 1 = allowed) for trainers and masked decoders.
    telemetryExtra*: TelemetryProc
      ## Optional: game counters appended to the telemetry line (" k=v ...").

  NeuralBrain* = ref object of RootObj
    ## Generic per-seat neural state. Games derive their seat type from it.
    contract*: NeuralContract
    seat*: int
    actor*: Actor
      ## Nil for seats whose actions come from elsewhere (a trainer).
    period*: int32
    maxTicks*: int32
    obs*, state*, logits*: seq[float32]
    frameTick*: int32
      ## Tick of the latest decision frame (-1 before the first).
    acting*, resetState*: bool
      ## acting: the seat acts this frame. resetState: the recurrent state
      ## restarts from zero this frame (first frame, or first after death).
    started, sawDeath: bool
    headsReady*: bool
    sampling*: bool
    temperature*: float32
    rng*: uint64
    inferences*, peakOps*: int
    telemetry*: bool
    lastTelemetry: int

proc contractHash*(text: string): string =
  ## A contract hash: lowercase SHA-256 hex of the contract's canonical text.
  sha256Hex(text)

proc headOutputs*(contract: PackageContract): int =
  ## Total logits (sum of head sizes).
  for size in contract.headSizes:
    result += size

proc initNeuralContract*(
    name, schema, observationText, actionText: string,
    observationSize: int, headSizes: openArray[int], actionOutputs: int,
    buildObservation: BuildObservationProc, decodeAction: DecodeActionProc,
    head: HeadProc, tick: TickProc,
    log: LogProc = nil, maskSize = 0, actionMask: MaskProc = nil,
    telemetryExtra: TelemetryProc = nil,
    maxDecisionPeriod = 24, opBudget = DefaultNeuralOpBudget,
    manifestKeys: openArray[string] = [], decoderKeys: openArray[string] = [],
    parseOptions: proc(manifest: JsonNode): RootRef {.nimcall.} = nil
): NeuralContract =
  ## The one way to build a contract. The hashes are computed from the
  ## contract texts; `actionOutputs` (the game's own logit count) must equal
  ## the sum of `headSizes`.
  doAssert observationSize in 1..MaxActorInputs, "observation size out of range"
  doAssert headSizes.len in 1..32, "a contract needs 1..32 heads"
  var outputs = 0
  for size in headSizes:
    doAssert size in 2..MaxHeadSize, "head size out of range"
    outputs += size
  doAssert outputs == actionOutputs,
    "action outputs " & $actionOutputs & " != sum of head sizes " & $outputs
  doAssert outputs <= 1024, "at most 1024 logits"
  doAssert buildObservation != nil and decodeAction != nil and head != nil and tick != nil
  doAssert (maskSize == 0) == (actionMask == nil),
    "maskSize and actionMask go together"
  doAssert maxDecisionPeriod >= 1 and opBudget > 0
  NeuralContract(
    name: name,
    schema: schema,
    observationHash: contractHash(observationText),
    actionHash: contractHash(actionText),
    observationSize: observationSize,
    headSizes: @headSizes,
    maxDecisionPeriod: maxDecisionPeriod,
    opBudget: opBudget,
    manifestKeys: @manifestKeys,
    decoderKeys: @decoderKeys,
    parseOptions: parseOptions,
    maskSize: maskSize,
    buildObservation: buildObservation,
    decodeAction: decodeAction,
    head: head,
    tick: tick,
    log: log,
    actionMask: actionMask,
    telemetryExtra: telemetryExtra)

proc initBrain*(brain: NeuralBrain, contract: NeuralContract,
    period, maxTicks: int32) =
  ## Sets up a new brain (call once, before resetBrain).
  brain.contract = contract
  brain.period = period
  brain.maxTicks = maxTicks
  brain.frameTick = -1
  brain.temperature = 1
  brain.obs = newSeq[float32](contract.observationSize)

proc resetBrain*(brain: NeuralBrain, matchSeed: int32, seat: int) =
  ## Clears per-match state (a new match or a native reset). The recurrent
  ## state and logits are reallocated at zero; peakOps is kept.
  brain.seat = seat
  brain.frameTick = -1
  brain.started = false
  brain.sawDeath = false
  brain.headsReady = false
  brain.inferences = 0
  brain.lastTelemetry = 0
  brain.rng = uint64(uint32(matchSeed)) * 1_000_003'u64 + uint64(seat) + 1
  if brain.actor != nil:
    brain.state = newSeq[float32](brain.actor.hiddenSize)
    brain.logits = newSeq[float32](brain.actor.outputSize)

proc decisionDue*(battleTick, period: int32): bool =
  ## Decision ticks are battle ticks 1, 1 + period, 1 + 2 * period, ...
  period > 0 and (battleTick - 1) mod period == 0

proc beginFrame*(brain: NeuralBrain, tick: int32): bool =
  ## Captures the decision frame once per tick: observation (contract
  ## callback) and the state-reset lifecycle. False if this tick's frame was
  ## already captured.
  if brain.frameTick == tick:
    return false
  brain.frameTick = tick
  brain.acting = brain.contract.buildObservation(brain)
  if not brain.started:
    brain.started = true
    brain.resetState = true
    if not brain.acting:
      brain.sawDeath = true
  elif not brain.acting:
    brain.sawDeath = true
    brain.resetState = false
  elif brain.sawDeath:
    brain.resetState = true
  else:
    brain.resetState = false
  if brain.acting and brain.resetState:
    brain.sawDeath = false
  brain.headsReady = false
  true

proc telemetryLine*(brain: NeuralBrain, battleTick: int32): string =
  ## The seat-log telemetry line.
  result = "neural: peak_ops=" & $brain.peakOps & " budget=" &
    $brain.contract.opBudget & " model=w" & $brain.actor.hiddenSize &
    " ticks=" & $battleTick & " inferences=" & $brain.inferences
  if brain.contract.telemetryExtra != nil:
    result.add brain.contract.telemetryExtra(brain)

proc think*(brain: NeuralBrain, battleTick: int32) =
  ## One decision of an acting seat with an actor: zero the state on a
  ## reset frame, infer, meter, decode (contract callback) and log
  ## telemetry on the first inference, every 1800 inferences and on the
  ## last decision of the match. A failed inference raises BasicError.
  if brain.resetState:
    for x in brain.state.mitems: x = 0
  try:
    brain.actor.infer(brain.obs, brain.state, brain.logits)
  except ValueError as error:
    raise newException(BasicError, "neural inference failed: " & error.msg)
  inc brain.inferences
  brain.peakOps = max(brain.peakOps, brain.actor.operationCount)
  brain.contract.decodeAction(brain)
  brain.headsReady = true
  if brain.telemetry and brain.contract.log != nil and (brain.inferences == 1 or
      brain.inferences - brain.lastTelemetry >= 1800 or
      battleTick + brain.period > brain.maxTicks):
    brain.lastTelemetry = brain.inferences
    brain.contract.log(brain, brain.telemetryLine(battleTick))

proc decide*(brain: NeuralBrain, tick, battleTick: int32): bool =
  ## beginFrame + think for a hosted seat. True when a fresh decision is
  ## ready (acting, with an actor).
  if not brain.beginFrame(tick):
    return false
  if brain.acting and brain.actor != nil:
    brain.think(battleTick)
  brain.headsReady

# Decoders ------------------------------------------------------------------

proc splitmix*(state: var uint64): uint64 =
  ## SplitMix64 step: the sampling decoders' only randomness.
  state += 0x9E3779B97F4A7C15'u64
  var z = state
  z = (z xor (z shr 30)) * 0xBF58476D1CE4E5B9'u64
  z = (z xor (z shr 27)) * 0x94D049BB133111EB'u64
  z xor (z shr 31)

proc unitDraw*(state: var uint64): float64 =
  ## A uniform in [0, 1) from 53 random bits.
  float64(splitmix(state) shr 11) / 9007199254740992.0

proc argmaxHeads*(logits: openArray[float32], headSizes: openArray[int],
    heads: var openArray[int32]) =
  ## Deterministic argmax per head (first maximum wins).
  var offset = 0
  for h in 0 ..< headSizes.len:
    var best = 0
    for i in 1 ..< headSizes[h]:
      if logits[offset + i] > logits[offset + best]:
        best = i
    heads[h] = int32(best)
    offset += headSizes[h]

proc sampleHeads*(logits: openArray[float32], headSizes: openArray[int],
    temperature: float32, state: var uint64, heads: var openArray[int32]) =
  ## One categorical draw per head, in head order, from softmax(logits / T),
  ## using one unitDraw per head.
  var offset = 0
  for h in 0 ..< headSizes.len:
    let n = headSizes[h]
    var top = logits[offset]
    for i in 1 ..< n:
      top = max(top, logits[offset + i])
    var weights: array[MaxHeadSize, float64]
    var total = 0.0
    for i in 0 ..< n:
      weights[i] = exp(float64(logits[offset + i] - top) / float64(temperature))
      total += weights[i]
    let u = float64(splitmix(state) shr 11) / 9007199254740992.0 * total
    var acc = 0.0
    var choice = n - 1
    for i in 0 ..< n:
      acc += weights[i]
      if u < acc:
        choice = i
        break
    heads[h] = int32(choice)
    offset += n

proc pickHead*(logits: openArray[float32], base, n: int, allowed: openArray[bool],
    sampling: bool, temperature: float32, draw: float64): int32 =
  ## One masked head: the first maximum (argmax) or a draw (`draw` in
  ## [0, 1)) among the allowed choices; all choices when none is allowed.
  var found = false
  for i in 0 ..< n:
    if allowed[i]: found = true
  template ok(i: int): bool = (not found) or allowed[i]
  if not sampling:
    var best = -1
    for i in 0 ..< n:
      if ok(i) and (best < 0 or logits[base + i] > logits[base + best]):
        best = i
    return int32(best)
  var top = float32(-Inf)
  for i in 0 ..< n:
    if ok(i): top = max(top, logits[base + i])
  var weights: array[MaxHeadSize, float64]
  var total = 0.0
  for i in 0 ..< n:
    weights[i] = if ok(i): exp(float64(logits[base + i] - top) /
      float64(temperature)) else: 0.0
    total += weights[i]
  let u = draw * total
  var acc = 0.0
  var last = 0
  for i in 0 ..< n:
    if weights[i] > 0:
      last = i
      acc += weights[i]
      if u < acc:
        return int32(i)
  int32(last)

# BASIC host functions ------------------------------------------------------

proc fixedRead(values: seq[float32], i: int): Value =
  if i < 0 or i >= values.len:
    return toValue(0'i32)
  toValue(toFixed(clamp(values[i], -30000'f32, 30000'f32)))

proc addNeuralHostFunctions*(host: var Host, lookup: proc(): NeuralBrain) =
  ## Registers the generic neural-seat BASIC surface, in this order:
  ## run_neural_net(), neuralObservation(i), neuralLogits(i), neuralState(i),
  ## neuralModel(k). `lookup` returns the calling seat's brain (nil for a
  ## seat without one: every function then returns 0). A game registers its
  ## own action function (e.g. GotA's gota_act) next to these.
  let runProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## 1 when this tick has a fresh decision (inference or trainer action).
    let brain = lookup()
    int32(brain != nil and brain.frameTick == brain.contract.tick(brain) and
      brain.headsReady)
  let observationProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Reads observation float i of the current decision (Q16.16).
    let brain = lookup()
    if brain == nil:
      return toValue(0'i32)
    fixedRead(brain.obs, int(arguments[0].asInt))
  let logitsProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Reads logit i of the last inference (Q16.16); 0 without an actor.
    let brain = lookup()
    if brain == nil:
      return toValue(0'i32)
    fixedRead(brain.logits, int(arguments[0].asInt))
  let stateProc: NumericHostProc = proc(arguments: openArray[Value]): Value =
    ## Reads recurrent state float i (Q16.16).
    let brain = lookup()
    if brain == nil:
      return toValue(0'i32)
    fixedRead(brain.state, int(arguments[0].asInt))
  let modelProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## 0 hidden width, 1 inputs, 2 outputs, 3 decision period, 5+h head h of
    ## the last decision.
    let brain = lookup()
    if brain == nil:
      return 0
    case arguments[0]
    of 0: (if brain.actor != nil: int32(brain.actor.hiddenSize) else: 0)
    of 1: int32(brain.contract.observationSize)
    of 2: int32(brain.contract.headOutputs)
    of 3: brain.period
    else:
      let h = int(arguments[0]) - 5
      if h >= 0 and h < brain.contract.headSizes.len:
        brain.contract.head(brain, h)
      else:
        0
  discard host.addFunction("run_neural_net", 0, runProc, 4)
  discard host.addFunction("neuralObservation", 1, observationProc, 4)
  discard host.addFunction("neuralLogits", 1, logitsProc, 4)
  discard host.addFunction("neuralState", 1, stateProc, 4)
  discard host.addFunction("neuralModel", 1, modelProc, 4)
