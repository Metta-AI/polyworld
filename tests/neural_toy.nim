## A synthetic neural contract ("toy-neural/1": 3 observation floats, heads
## [2, 3]) and package helpers, shared by the neural tier tests. The toy
## contract is the same one tests/neural_cases.py builds in Python.

import
  std/[json, math, strutils],
  zippy, zippy/crc,
  polyworld/neural_host

const
  ToySchema* = "toy-neural/1"
  ToyObservationText* = "toy-neural/1 observation v1 float32[3]: bias,x,alive"
  ToyActionText* = "toy-neural/1 action v1 heads move2,aim3"
  ToyObservation* = 3
  ToyHeads* = [2, 3]
  ToyOutputs* = 5
  ToyBudget* = 200_000

type
  ToyOptions* = ref object of RootObj
    tag*: string
    hold*: bool
  ToySeat* = ref object of NeuralBrain
    ## The toy game's seat: what it observes and what it last decided.
    x*: float32
    alive*: bool
    heads*: array[2, int32]
    decoded*: int
  ToyWorld* = object
    tick*: int32
    log*: seq[string]

var toyWorld*: ToyWorld

proc parseToyOptions*(manifest: JsonNode): RootRef {.nimcall.} =
  ## Toy extension keys: manifest.tag (a short string), decoder.hold (bool).
  let options = ToyOptions()
  if manifest.hasKey("tag"):
    if manifest["tag"].kind != JString or manifest["tag"].getStr.len > 32:
      raise newException(ValueError, "tag must be a string of at most 32 bytes")
    options.tag = manifest["tag"].getStr
  if manifest.hasKey("decoder"):
    options.hold = manifest["decoder"].requireBool("hold", "decoder")
  options

proc toyObserve(brain: NeuralBrain): bool {.nimcall.} =
  let seat = ToySeat(brain)
  seat.obs[0] = 1
  seat.obs[1] = seat.x
  seat.obs[2] = (if seat.alive: 1 else: 0)
  seat.alive

proc toyDecode(brain: NeuralBrain) {.nimcall.} =
  let seat = ToySeat(brain)
  if seat.sampling:
    sampleHeads(seat.logits, ToyHeads, seat.temperature, seat.rng, seat.heads)
  else:
    argmaxHeads(seat.logits, ToyHeads, seat.heads)
  inc seat.decoded

proc toyHead(brain: NeuralBrain, index: int): int32 {.nimcall.} =
  ToySeat(brain).heads[index]

proc toyTick(brain: NeuralBrain): int32 {.nimcall.} = toyWorld.tick

proc toyLog(brain: NeuralBrain, text: string) {.nimcall.} =
  toyWorld.log.add("seat " & $brain.seat & " " & text)

proc toyContract*(budget = ToyBudget): NeuralContract =
  initNeuralContract("toy", ToySchema, ToyObservationText, ToyActionText,
    ToyObservation, ToyHeads, ToyOutputs, toyObserve, toyDecode, toyHead,
    toyTick, log = toyLog, maxDecisionPeriod = 8, opBudget = budget,
    manifestKeys = ["tag"], decoderKeys = ["hold"],
    parseOptions = parseToyOptions)

proc weightCount*(hidden: int, inputs = ToyObservation, outputs = ToyOutputs): int =
  inputs * hidden + 3 * hidden * hidden + outputs * hidden

proc toyWeights*(hidden: int, seed: uint32): seq[float32] =
  ## Deterministic small weights (an LCG), different per seed.
  var s = seed * 2654435761'u32 + 1
  result = newSeq[float32](weightCount(hidden))
  for w in result.mitems:
    s = s * 1664525'u32 + 1013904223'u32
    w = (float32(s shr 8) / 16777216'f32 - 0.5'f32) * 0.5'f32

proc toyModel*(hidden = 64, seed = 1'u32, contract = toyContract()): string =
  encodeActor(ToyObservation, hidden, ToyHeads, contract.observationHash,
    contract.actionHash, toyWeights(hidden, seed))

const ToyPolicy* = """
' toy policy glue: reads the tier's neural host functions
if run_neural_net() then
  fresh = 1
  move = neuralModel(5)
  aim = neuralModel(6)
  width = neuralModel(0)
end if
inputs = neuralModel(1)
outputs = neuralModel(2)
period = neuralModel(3)
beyond = neuralModel(7)
"""

proc u16(s: var string, v: int) =
  s.add char(v and 0xff)
  s.add char((v shr 8) and 0xff)

proc u32(s: var string, v: int) =
  for i in 0..3:
    s.add char((v shr (8 * i)) and 0xff)

type ZipEntry* = object
  name*, data*: string
  deflate*: bool
  flags*: int
  methodOverride*: int ## -1 = stored/deflate from `deflate`
  declaredSize*: int ## -1 = the real size

proc entry*(name, data: string, deflate = true): ZipEntry =
  ZipEntry(name: name, data: data, deflate: deflate, methodOverride: -1,
    declaredSize: -1)

proc writeZip*(entries: openArray[ZipEntry]): string =
  ## A minimal single-disk ZIP writer (stored or deflate) with knobs for
  ## corrupting flags, the method and the declared size.
  var central: string
  for e in entries:
    let
      payload = if e.deflate: compress(e.data, DefaultCompression, dfDeflate) else: e.data
      methodId = if e.methodOverride >= 0: e.methodOverride elif e.deflate: 8 else: 0
      size = if e.declaredSize >= 0: e.declaredSize else: e.data.len
      crc = int(crc32(e.data))
      offset = result.len
    result.u32(0x04034b50)
    result.u16(20); result.u16(e.flags); result.u16(methodId)
    result.u16(0); result.u16(0)
    result.u32(crc); result.u32(payload.len); result.u32(size)
    result.u16(e.name.len); result.u16(0)
    result.add e.name
    result.add payload
    central.u32(0x02014b50)
    central.u16(20); central.u16(20); central.u16(e.flags); central.u16(methodId)
    central.u16(0); central.u16(0)
    central.u32(crc); central.u32(payload.len); central.u32(size)
    central.u16(e.name.len); central.u16(0); central.u16(0)
    central.u16(0); central.u16(0); central.u32(0); central.u32(offset)
    central.add e.name
  let cdOffset = result.len
  result.add central
  result.u32(0x06054b50)
  result.u16(0); result.u16(0)
  result.u16(entries.len); result.u16(entries.len)
  result.u32(central.len); result.u32(cdOffset)
  result.u16(0)

proc toyManifest*(policy, model: string, contract = toyContract(),
    period = 2, hidden = 64): JsonNode =
  %*{
    "schema": ToySchema,
    "observation_contract": contract.observationHash,
    "action_contract": contract.actionHash,
    "decision_period": period,
    "files": {"policy.bas": sha256Hex(policy), "model.bin": sha256Hex(model)},
    "model": {"format": "GOTANET1", "inputs": ToyObservation, "hidden": hidden,
      "heads": ToyHeads}
  }

proc toyPackage*(manifest: JsonNode, policy = ToyPolicy, model = toyModel()): string =
  writeZip([entry("manifest.json", $manifest), entry("policy.bas", policy),
    entry("model.bin", model)])

proc goodToyPackage*(): string =
  let model = toyModel()
  toyPackage(toyManifest(ToyPolicy, model), ToyPolicy, model)

proc newToySeat*(actor: Actor, seat = 0, period = 2'i32,
    maxTicks = 100'i32, contract = toyContract()): ToySeat =
  result = ToySeat(alive: true)
  result.initBrain(contract, period, maxTicks)
  result.actor = actor
  result.resetBrain(7, seat)

proc isFiniteVector*(values: openArray[float32]): bool =
  for v in values:
    if classify(v) in {fcNan, fcInf, fcNegInf}:
      return false
  true

proc hasPrefix*(text, prefix: string): bool = text.startsWith(prefix)
