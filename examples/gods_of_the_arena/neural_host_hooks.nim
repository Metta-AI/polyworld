## GotA neural seats: the hosted package seat, the native trainer's learner
## seat, and the scripted seats whose commands are captured (BC labels) or
## routed through the contract (mapping ceiling). Included by bots.nim.
##
## The generic parts (package loading, actor, recurrent-state lifecycle,
## budget, telemetry, decoders, the neural BASIC functions) are the shared
## tier in src/polyworld/neural_host.nim; this file is GotA's NeuralContract
## (observation builder, decoder, mask and defer options) and its seat modes.
##
## A seat without a NeuralSeat is untouched by everything here, so plain
## BASIC matches stay byte-identical.

type
  NeuralMode* = enum
    NeuralLearner ## native trainer supplies the heads
    NeuralHosted ## hosted neural package, network inside
    NeuralOverride ## scripted seat, contract commands re-routed (ceiling)
    NeuralCapture ## scripted seat, contract commands captured as labels
  NeuralSeat* = ref object of NeuralBrain
    ## A GotA seat: the shared brain plus the GotA frame, heads and modes.
    mode*: NeuralMode
    goal*: array[GoalSize, float32]
    frame*: DecisionFrame
    heads*: Heads
    command*: NeuralCommand
    issuedTick*: int32
    captured*: seq[NeuralCommand]
    label*: array[16, int32]
    lastLabel*: array[16, int32]
      ## The label of the previous decision window (what gota_seat_orders reports).
    labelInstant: bool
    decisions*, invalid*: int
    shadow*: HeroVm
      ## Learner seats only: an expert script run on the same frame whose
      ## commands become labels and are never executed (DAgger).
    deferEnabled*: bool
      ## Defer seat: verb 0 = defer to the seat's own script (its BASIC
      ## program); any other verb overrides it for the decision window.
    absorbing*: bool
      ## Inside an override window: the script's contract commands are absorbed.
    deferDecisions*, overrideDecisions*: int
    maskMode*: MaskMode
      ## decoder.mask_empty_targets / mask_mode (package seats): the mask
      ## applied before decode.
    mask*: ActionMask
      ## The mask of the current decision frame (package seats with a mask).

var shadowRunning {.threadvar.}: bool
  ## True while a shadow expert script runs: its host calls change nothing.

var neuralTelemetryEnabled* = true

proc neuralSeat*(game: Game, index: int): NeuralSeat =
  if index >= 0 and index < game.heroVms.len and game.heroVms[index] != nil and
      game.heroVms[index].neural != nil:
    result = NeuralSeat(game.heroVms[index].neural)

proc isDecisionTick*(world: World, period: int32): bool =
  ## Battle ticks 1, 1 + period, ... (the heroes' turn of that tick).
  world.phase == Playing and decisionDue(world.battleTick(), period)

proc seatLog(game: Game, index: int, text: string) =
  when defined(coworld):
    playerLog(index, text & "\n")
  else:
    if neuralTelemetryEnabled:
      echo "seat ", index, " ", text

proc sampleHeads*(logits: openArray[float32], temperature: float32,
    state: var uint64): Heads =
  ## One categorical draw per head, in head order, from softmax(logits / T),
  ## using 53 random bits per draw (neural_basic.md, "Decisions, state and
  ## telemetry").
  sampleHeads(logits, HeadSizes, temperature, state, result)

proc staticTargets*(mask: ActionMask): array[ObjectSlots, bool] =
  ## mask_mode "static": the union of the target rows of every allowed
  ## target-reading verb (independent per-head masks, as PufferLib samples).
  for s in 0 ..< ObjectSlots:
    if mask[MaskVerb + 3] != 0 and mask[MaskTarget + s] != 0: result[s] = true
    for a in 0 ..< 4:
      if mask[MaskVerb + 4] != 0 and mask[MaskTarget + (1 + a) * ObjectSlots + s] != 0:
        result[s] = true
    if mask[MaskVerb + 5] != 0 and mask[MaskTarget + 5 * ObjectSlots + s] != 0: result[s] = true
    if mask[MaskVerb + 7] != 0 and mask[MaskTarget + 6 * ObjectSlots + s] != 0: result[s] = true

proc maskedHeads*(logits: openArray[float32], mask: ActionMask,
    sampling: bool, temperature: float32, state: var uint64,
    staticMode = false): Heads =
  ## decoder.mask_empty_targets. Conditional (default): verb, then ability
  ## (masked when verb is castTarget), then target by the (verb, ability)
  ## row. Static: verb, and target by the union of the allowed verbs' rows.
  ## Point and item are never masked. Sampling draws one uniform per head in
  ## head order first (the same RNG use as sampleHeads), then resolves heads
  ## in dependency order. Argmax: first maximum among allowed choices.
  var offsets: array[ActionHeads, int]
  var o = 0
  for h in 0 ..< ActionHeads:
    offsets[h] = o
    o += HeadSizes[h]
  var draws: array[ActionHeads, float64]
  if sampling:
    for h in 0 ..< ActionHeads:
      draws[h] = unitDraw(state)
  var allowed: array[64, bool]
  template pick(h: int): int32 =
    pickHead(logits, offsets[h], HeadSizes[h], allowed, sampling, temperature,
      draws[h])
  for i in 0 ..< 8: allowed[i] = mask[MaskVerb + i] != 0
  result[0] = pick(0)
  let verb = result[0]
  for i in 0 ..< 64: allowed[i] = true
  if staticMode:
    result[3] = pick(3)
    let targets = staticTargets(mask)
    for i in 0 ..< ObjectSlots: allowed[i] = targets[i]
    result[1] = pick(1)
  else:
    if verb == 4:
      for i in 0 ..< 4: allowed[i] = mask[MaskAbility + i] != 0
    result[3] = pick(3)
    for i in 0 ..< 64: allowed[i] = true
    let row = maskTargetRow(verb, result[3])
    if row >= 0:
      for i in 0 ..< ObjectSlots:
        allowed[i] = mask[MaskTarget + row * ObjectSlots + i] != 0
    result[1] = pick(1)
  for i in 0 ..< 64: allowed[i] = true
  result[2] = pick(2)
  result[4] = pick(4)

# GotA's NeuralContract: the callbacks the shared tier calls on GotA seats.
# They run inside a tick of activeGame (neuralPrelude, BASIC host calls).

proc gotaObserve(brain: NeuralBrain): bool {.nimcall.} =
  ## Observation contract v1 plus the decision frame (slot ids, positions).
  let
    seat = NeuralSeat(brain)
    world = activeGame.world
  buildObservation(world, seat.seat, seat.goal, seat.maxTicks, world.stats,
    seat.obs, seat.frame)
  seat.frame.alive and not world.gameOver

proc gotaDecode(brain: NeuralBrain) {.nimcall.} =
  ## Package seats: heads from the logits (mask, sample or argmax), then the
  ## decoded command gota_act or the defer consult issues.
  let seat = NeuralSeat(brain)
  if seat.maskMode != NoMask:
    seat.mask = actionMask(activeGame.world, seat.seat, seat.frame)
    seat.heads = maskedHeads(seat.logits, seat.mask, seat.sampling,
      seat.temperature, seat.rng, seat.maskMode == StaticMask)
  else:
    seat.heads =
      if seat.sampling: sampleHeads(seat.logits, seat.temperature, seat.rng)
      else: argmaxHeads(seat.logits)
  seat.command = decodeAction(seat.frame, seat.heads)

proc gotaHead(brain: NeuralBrain, index: int): int32 {.nimcall.} =
  NeuralSeat(brain).heads[index]

proc gotaTick(brain: NeuralBrain): int32 {.nimcall.} =
  activeGame.world.tick

proc gotaLog(brain: NeuralBrain, text: string) {.nimcall.} =
  activeGame.seatLog(brain.seat, text)

proc gotaTelemetry(brain: NeuralBrain): string {.nimcall.} =
  ## GotA counters after the tier's telemetry line.
  let seat = NeuralSeat(brain)
  result = " decisions=" & $seat.decisions & " invalid=" & $seat.invalid
  if seat.deferEnabled:
    result.add " defer=" & $seat.deferDecisions & " override=" &
      $seat.overrideDecisions

proc gotaActionMask(brain: NeuralBrain, mask: var openArray[uint8]) {.nimcall.} =
  ## The current frame's validity mask (layout: neural_basic.md, Action mask).
  let seat = NeuralSeat(brain)
  let computed = actionMask(activeGame.world, seat.seat, seat.frame)
  for i in 0 ..< MaskSize:
    mask[i] = computed[i]

let GotaContract* = initNeuralContract("gota", PackageSchema,
  observationContractText(), actionContractText(), ObservationSize, HeadSizes,
  ActionOutputs, gotaObserve, gotaDecode, gotaHead, gotaTick, log = gotaLog,
  telemetryExtra = gotaTelemetry,
  maskSize = MaskSize, actionMask = gotaActionMask,
  maxDecisionPeriod = MaxDecisionPeriod, opBudget = DefaultNeuralOpBudget,
  manifestKeys = GotaManifestKeys, decoderKeys = GotaDecoderKeys,
  parseOptions = parseGotaOptions)
  ## gota-neural-basic/1: observation v1 (1407 floats), action v1 heads
  ## [8, 25, 49, 4, 6], decision_period 1..24, 4,000,000 ops per inference.
doAssert GotaContract.observationHash == ObservationContractHash and
  GotaContract.actionHash == ActionContractHash

proc parseGotaPackage*(bytes: string): NeuralPackage =
  ## Validates a gota-neural-basic/1 package; raises ValueError.
  parsePackage(bytes, GotaContract)

proc gotaOptions*(package: NeuralPackage): GotaPackageOptions =
  GotaPackageOptions(package.options)

proc newNeuralSeat*(mode: NeuralMode, period: int32, maxTicks: int32): NeuralSeat =
  result = NeuralSeat(mode: mode, issuedTick: -1)
  result.initBrain(GotaContract, period, maxTicks)
  result.goal[0] = 1

proc resetEpisode*(seat: NeuralSeat, matchSeed: int32, index: int) =
  ## Clears per-match state (a new match or a native reset).
  seat.resetBrain(matchSeed, index)
  seat.issuedTick = -1
  seat.captured.setLen(0)
  seat.label = default(typeof(seat.label))
  seat.lastLabel = default(typeof(seat.lastLabel))
  seat.command = NeuralCommand()
  seat.decisions = 0
  seat.invalid = 0
  seat.absorbing = false
  seat.deferDecisions = 0
  seat.overrideDecisions = 0

proc beginDecision*(game: Game, index: int, seat: NeuralSeat) =
  ## Captures the decision frame (observation, slots, resets) once per tick;
  ## a package seat also infers and decodes (neural_host.think).
  let world = game.world
  if not seat.beginFrame(world.tick):
    return
  seat.command = NeuralCommand(tick: world.tick)
  case seat.mode
  of NeuralHosted:
    if seat.acting:
      seat.think(world.battleTick())
  of NeuralCapture, NeuralOverride:
    seat.lastLabel = seat.label
    seat.label = default(typeof(seat.label))
    seat.labelInstant = false
    if seat.mode == NeuralCapture:
      seat.captured.setLen(0)
  of NeuralLearner:
    if seat.shadow != nil or seat.deferEnabled:
      seat.lastLabel = seat.label
      seat.label = default(typeof(seat.label))
      seat.labelInstant = false

proc setLearnerHeads*(seat: NeuralSeat, heads: Heads) =
  ## The native trainer's action for the paused decision.
  seat.heads = heads
  seat.headsReady = true
  seat.command = if seat.acting: decodeAction(seat.frame, heads)
    else: NeuralCommand(tick: seat.frameTick)

proc writeLabel(seat: NeuralSeat, world: World, command: NeuralCommand) =
  ## Folds one script command into the window's label (first instant wins,
  ## otherwise the last movement/attack order).
  let instant = command.kind in {CastTargetCommand, CastPointCommand,
    UseItemCommand, UseItemAtCommand}
  if seat.labelInstant:
    inc seat.label[13]
    return
  let encoded = encodeCommand(seat.frame, world, command)
  let count = seat.label[13] + 1
  seat.label = default(typeof(seat.label))
  seat.label[13] = count
  seat.labelInstant = instant
  seat.label[0] = int32(encoded.represented and encoded.heads[0] != 0)
  if encoded.represented:
    for h in 0 ..< ActionHeads:
      seat.label[1 + h] = encoded.heads[h]
  seat.label[6] = int32(encoded.exact)
  seat.label[7] = int32(command.kind.ord)
  seat.label[8] = command.objectId
  seat.label[9] = command.ability
  seat.label[10] = command.item
  let
    wp = worldPointOf(command.point)
    s = (if seat.frame.team == RedTeam: 1'i64 else: -1'i64)
  if command.kind in {WalkCommand, AttackMoveCommand, CastPointCommand, UseItemAtCommand}:
    seat.label[11] = int32(s * int64(wp.x) * 1000 div WorldScale)
    seat.label[12] = int32(s * int64(wp.z) * 1000 div WorldScale)
  seat.label[14] = encoded.errorMilli
  seat.label[15] = command.tick

proc interceptCommand*(game: Game, heroId: int32, command: NeuralCommand): bool =
  ## Called by every contract host function before it applies an order.
  ## True = the order was absorbed (override mode) and must not run.
  if game.heroVms.len == 0:
    return false
  let index = game.world.heroIndex(heroId)
  let seat = game.neuralSeat(index)
  if seat == nil:
    return false
  var tagged = command
  tagged.tick = game.world.tick
  if shadowRunning:
    if seat.frameTick >= 0:
      seat.writeLabel(game.world, tagged)
    return true
  if seat.deferEnabled:
    # Defer seat: the script is the seat's program. Its contract commands
    # run live in a defer window and are absorbed in an override window.
    if seat.mode == NeuralLearner and seat.frameTick >= 0:
      seat.writeLabel(game.world, tagged)
    return seat.absorbing
  case seat.mode
  of NeuralOverride:
    seat.captured.add tagged
    true
  of NeuralCapture:
    if seat.frameTick >= 0:
      seat.writeLabel(game.world, tagged)
    false
  else:
    false

proc issueDecoded*(game: Game, heroId: int32, command: NeuralCommand): bool =
  ## Executes a decoded contract command through the recorded host path.
  let (x, y, offset) = splitTilePoint(command.point)
  case command.kind
  of NoCommand: false
  of WalkCommand: game.issueWalkTo(heroId, x, y, offset)
  of AttackMoveCommand: game.issueAttackMove(heroId, x, y, offset)
  of AttackTargetCommand: game.issueAttackTarget(heroId, command.objectId)
  of CastTargetCommand: game.issueCastTarget(heroId, command.ability, command.objectId)
  of CastPointCommand: game.issueCastPoint(heroId, command.ability, x, y, offset)
  of UseItemCommand: game.issueUseItem(heroId, command.item)
  of UseItemAtCommand: game.issueUseItemAt(heroId, command.item, x, y, offset)

proc actNow*(game: Game, index: int): int32 =
  ## gota_act: issues the seat's decoded command once, on its decision tick.
  let seat = game.neuralSeat(index)
  if seat == nil or seat.mode notin {NeuralLearner, NeuralHosted}:
    return 0
  let world = game.world
  if seat.frameTick != world.tick or seat.issuedTick == world.tick or
      not seat.acting or not seat.headsReady:
    return 0
  seat.issuedTick = world.tick
  inc seat.decisions
  if isInvalid(seat.frame, seat.heads):
    inc seat.invalid
  int32(game.issueDecoded(world.heroes[index].id, seat.command))

proc deferConsult*(game: Game, index: int) =
  ## Defer seats: once per decision tick, before the seat's script runs,
  ## verb 0 opens a defer window (the script's contract commands execute) and
  ## any other verb issues the decoded command and opens an override window
  ## (the script's contract commands are absorbed until the next decision).
  ## Shared by the native learner seat and the hosted package seat.
  let seat = game.neuralSeat(index)
  if seat == nil or not seat.deferEnabled:
    return
  let world = game.world
  if seat.frameTick != world.tick or seat.issuedTick == world.tick:
    return
  seat.issuedTick = world.tick
  if not seat.acting or not seat.headsReady:
    seat.absorbing = false
    return
  inc seat.decisions
  if seat.heads[0] != 0 and isInvalid(seat.frame, seat.heads):
    # An override that decodes to nothing would absorb the script for the
    # whole window and idle the hero: fall back to the script instead.
    inc seat.invalid
    seat.absorbing = false
    inc seat.deferDecisions
    return
  if seat.heads[0] == 0:
    seat.absorbing = false
    inc seat.deferDecisions
    return
  seat.absorbing = true
  inc seat.overrideDecisions
  discard game.issueDecoded(world.heroes[index].id, seat.command)

proc runOverride*(game: Game, index: int, seat: NeuralSeat) =
  ## Mapping ceiling: route the script's queued orders through the contract.
  let world = game.world
  if seat.frameTick != world.tick:
    return
  if seat.captured.len == 0 or not seat.acting:
    seat.captured.setLen(0)
    return
  for command in seat.captured:
    seat.writeLabel(world, command)
  seat.captured.setLen(0)
  if seat.label[0] == 0:
    return
  var heads: Heads
  for h in 0 ..< ActionHeads:
    heads[h] = seat.label[1 + h]
  seat.heads = heads
  let decoded = decodeAction(seat.frame, heads)
  inc seat.decisions
  discard game.issueDecoded(world.heroes[index].id, decoded)

proc neuralPrelude*(game: Game) =
  ## Start of the heroes' turn: every neural seat observes the same frame.
  let world = game.world
  for index in 0 ..< game.heroVms.len:
    let seat = game.neuralSeat(index)
    if seat != nil and world.isDecisionTick(seat.period):
      let vm = game.heroVms[index]
      if vm.failed:
        continue
      try:
        game.beginDecision(index, seat)
      except BasicError as error:
        vm.failed = true
        vm.lastError = error.msg
        when defined(coworld):
          playerError(index, error.msg)
        else:
          echo "hero ", world.heroes[index].id, " neural error: ", error.msg

proc addNeuralSeatFunctions*(host: var Host, heroId: int32) =
  ## The policy.bas surface of a neural seat (package or learner): gota_act
  ## plus the shared tier's run_neural_net / neuralObservation /
  ## neuralLogits / neuralState / neuralModel.
  let actProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Issues the network's decoded command on a decision tick.
    activeGame.actNow(activeGame.world.heroIndex(heroId))
  discard host.addFunction("gota_act", 0, actProc, 800)
  host.addNeuralHostFunctions(proc(): NeuralBrain =
    activeGame.neuralSeat(activeGame.world.heroIndex(heroId)))

proc neuralVmLimits*(): Limits =
  ## Neural seats (package, learner, defer): the plain hero per-tick budget
  ## (instructions, work units: fairness with .bas seats; the network runs on
  ## its own separate op budget) with room for the neural host functions.
  result = heroVmLimits()
  result.maxHostFunctions = 160

proc deferVmLimits*(): Limits =
  ## Defer-script seats: the same limits as every neural seat.
  neuralVmLimits()
