## The shared neural tier on a synthetic contract (tests/neural_toy.nim):
## package loading, corruption and budget rejection, strict keys, the
## recurrent-state lifecycle, telemetry and the BASIC host functions. No
## game is involved, which is the point: the tier is game-agnostic.

import
  std/[json, strutils],
  bassy,
  polyworld/neural_host,
  neural_toy

proc rejects(bytes: string, message: string, contract = toyContract()) =
  ## The package must be rejected with a ValueError naming `message`.
  var caught = false
  try:
    discard parsePackage(bytes, contract)
  except ValueError as error:
    caught = true
    doAssert message in error.msg, "want '" & message & "', got: " & error.msg
  doAssert caught, "package accepted, expected rejection: " & message

proc withManifest(edit: proc(m: JsonNode)): string =
  let model = toyModel()
  var m = toyManifest(ToyPolicy, model)
  edit(m)
  toyPackage(m, ToyPolicy, model)

echo "Testing a toy package loads through the shared tier"
block:
  let contract = toyContract()
  doAssert contract.observationHash == contractHash(ToyObservationText)
  doAssert contract.actionHash == sha256Hex(ToyActionText)
  doAssert contract.headOutputs == ToyOutputs
  let package = parsePackage(goodToyPackage(), contract)
  doAssert package.decisionPeriod == 2
  doAssert package.policy == ToyPolicy
  doAssert package.actor.inputSize == ToyObservation
  doAssert package.actor.hiddenSize == 64
  doAssert package.actor.outputSize == ToyOutputs
  doAssert package.actor.headSizes == @ToyHeads
  doAssert package.decoder.mode == ArgmaxDecoder
  doAssert not package.decoder.sampling
  doAssert package.decoder.temperatureOf == 1
  let options = ToyOptions(package.options)
  doAssert options.tag == "" and not options.hold
  let sampled = parsePackage(withManifest(proc(m: JsonNode) =
    m["tag"] = %"v1"
    m["decoder"] = %*{"mode": "sample", "temperature": 0.5, "hold": true}),
    contract)
  doAssert sampled.decoder.mode == SampleDecoder
  doAssert sampled.decoder.temperature == 0.5
  doAssert ToyOptions(sampled.options).tag == "v1"
  doAssert ToyOptions(sampled.options).hold
  let stored = writeZip([entry("manifest.json", $toyManifest(ToyPolicy, toyModel()), false),
    entry("policy.bas", ToyPolicy, false), entry("model.bin", toyModel(), false)])
  doAssert parsePackage(stored, contract).actor.hiddenSize == 64

echo "Testing unknown keys and wrong JSON kinds are rejected"
block:
  rejects(withManifest(proc(m: JsonNode) = m["extra"] = %1), "unknown manifest key manifest.extra")
  rejects(withManifest(proc(m: JsonNode) = m["decoder"] = %*{"fire": 1}),
    "unknown manifest key decoder.fire")
  rejects(withManifest(proc(m: JsonNode) = m["model"]["layers"] = %1),
    "unknown manifest key model.layers")
  rejects(withManifest(proc(m: JsonNode) = m["files"]["notes.txt"] = %"x"),
    "unknown manifest key files.notes.txt")
  rejects(withManifest(proc(m: JsonNode) = m["decoder"] = %*{"hold": 1}),
    "decoder.hold must be true or false")
  rejects(withManifest(proc(m: JsonNode) = m["tag"] = %7), "tag must be a string")
  rejects(withManifest(proc(m: JsonNode) = m["decoder"] = %"argmax"),
    "decoder must be an object")
  rejects(withManifest(proc(m: JsonNode) = m["model"]["heads"] = %3),
    "model.heads must be a list of integers")
  rejects(withManifest(proc(m: JsonNode) = m["model"]["heads"] = %*[2.0, 3]),
    "model.heads must be a list of integers")
  rejects(withManifest(proc(m: JsonNode) = m["model"]["inputs"] = %3.0),
    "model.inputs must be an integer")
  rejects(withManifest(proc(m: JsonNode) = m["decision_period"] = %true),
    "decision_period must be an integer")
  rejects(withManifest(proc(m: JsonNode) = m["decision_period"] = %9),
    "decision_period must be an integer 1..8")
  rejects(withManifest(proc(m: JsonNode) = m["schema"] = %1), "schema must be a string")
  rejects(withManifest(proc(m: JsonNode) = m["schema"] = %"other/1"),
    "manifest schema must be toy-neural/1")
  rejects(withManifest(proc(m: JsonNode) = m["observation_contract"] = %(
    "0".repeat(64))), "observation contract mismatch")
  rejects(withManifest(proc(m: JsonNode) = m.delete("model")), "manifest is missing model")
  rejects(withManifest(proc(m: JsonNode) =
    m["decoder"] = %*{"mode": "sample", "temperature": true}),
    "decoder.temperature must be a number")
  rejects(withManifest(proc(m: JsonNode) =
    m["decoder"] = %*{"mode": "sample", "temperature": 20}),
    "decoder.temperature must be 0.01..10")
  rejects(withManifest(proc(m: JsonNode) = m["decoder"] = %*{"temperature": 1}),
    "decoder.temperature needs mode sample")
  rejects(withManifest(proc(m: JsonNode) = m["decoder"] = %*{"mode": "beam"}),
    "decoder.mode must be argmax or sample")
  let model = toyModel()
  let manifest = ($toyManifest(ToyPolicy, model)).replace("\"decision_period\":2",
    "\"decision_period\":2,\"tag\":1e999")
  rejects(writeZip([entry("manifest.json", "{not json"), entry("policy.bas", ToyPolicy),
    entry("model.bin", model)]), "manifest.json is not JSON")
  rejects(writeZip([entry("manifest.json", manifest), entry("policy.bas", ToyPolicy),
    entry("model.bin", model)]), "non-finite number")
  rejects(writeZip([entry("manifest.json", "[1, 2]"), entry("policy.bas", ToyPolicy),
    entry("model.bin", model)]), "manifest must be an object")
  rejects(writeZip([entry("manifest.json", "{\"schema\": NaN}"),
    entry("policy.bas", ToyPolicy), entry("model.bin", model)]),
    "manifest.json is not JSON")

echo "Testing ZIP and model corruption is rejected before use"
block:
  let
    model = toyModel()
    manifest = $toyManifest(ToyPolicy, model)
  rejects(writeZip([entry("manifest.json", manifest), entry("policy.bas", ToyPolicy)]),
    "exactly manifest.json, policy.bas and model.bin")
  rejects(writeZip([entry("manifest.json", manifest), entry("policy.bas", ToyPolicy),
    entry("model.bin", model), entry("notes.txt", "hi")]), "unexpected package entry notes.txt")
  rejects(writeZip([entry("manifest.json", manifest), entry("policy.bas", ToyPolicy),
    entry("policy.bas", ToyPolicy)]), "unexpected package entry policy.bas")
  var encrypted = entry("model.bin", model)
  encrypted.flags = 1
  rejects(writeZip([entry("manifest.json", manifest), entry("policy.bas", ToyPolicy),
    encrypted]), "encrypted zip entry")
  var bzip = entry("model.bin", model, false)
  bzip.methodOverride = 12
  rejects(writeZip([entry("manifest.json", manifest), entry("policy.bas", ToyPolicy),
    bzip]), "unsupported zip compression 12")
  # Zip bomb: a tiny deflate stream declaring 1 KiB that inflates to 8 MiB
  # is stopped at its declared size, never inflated in full.
  var bomb = entry("model.bin", "\0".repeat(8 * 1024 * 1024))
  bomb.declaredSize = 1024
  rejects(writeZip([entry("manifest.json", manifest), entry("policy.bas", ToyPolicy),
    bomb]), "inflated data exceeds its limit")
  var oversized = entry("policy.bas", ToyPolicy)
  oversized.declaredSize = MaxPolicyBytes + 1
  rejects(writeZip([entry("manifest.json", manifest), oversized,
    entry("model.bin", model)]), "policy.bas exceeds its")
  var lying = entry("policy.bas", ToyPolicy, false)
  lying.declaredSize = ToyPolicy.len + 1
  rejects(writeZip([entry("manifest.json", manifest), lying,
    entry("model.bin", model)]), "zip size mismatch for policy.bas")
  let good = goodToyPackage()
  rejects(good[0 ..< good.len div 2], "zip")
  rejects("PK\x03\x04" & "\0".repeat(MaxPackageBytes), "package exceeds 16 MiB")
  var badMagic = model
  badMagic[0] = 'X'
  rejects(toyPackage(toyManifest(ToyPolicy, badMagic), ToyPolicy, badMagic),
    "invalid neural actor magic")
  var nonfinite = model
  let at = headerSize(ToyHeads.len) + 4 * 5
  nonfinite[at ..< at + 4] = "\0\0\xc0\x7f" # NaN
  rejects(toyPackage(toyManifest(ToyPolicy, nonfinite), ToyPolicy, nonfinite),
    "nonfinite neural weight")
  let truncated = model[0 ..< model.len - 4]
  rejects(toyPackage(toyManifest(ToyPolicy, truncated), ToyPolicy, truncated),
    "invalid neural actor length")
  rejects(toyPackage(toyManifest(ToyPolicy, model), ToyPolicy & "' edit\n", model),
    "policy.bas sha256 mismatch")
  let other = toyModel(seed = 2)
  rejects(toyPackage(toyManifest(ToyPolicy, model), ToyPolicy, other),
    "model.bin sha256 mismatch")
  let foreign = encodeActor(ToyObservation, 64, ToyHeads, "a".repeat(64),
    toyContract().actionHash, toyWeights(64, 1))
  rejects(toyPackage(toyManifest(ToyPolicy, foreign), ToyPolicy, foreign),
    "model.bin contract hashes do not match")
  let wide = encodeActor(4, 64, ToyHeads, toyContract().observationHash,
    toyContract().actionHash, newSeq[float32](weightCount(64, inputs = 4)))
  rejects(toyPackage(toyManifest(ToyPolicy, wide), ToyPolicy, wide),
    "model.inputs must be 3")
  let reheaded = encodeActor(ToyObservation, 64, [3, 2], toyContract().observationHash,
    toyContract().actionHash, toyWeights(64, 1))
  rejects(toyPackage(toyManifest(ToyPolicy, reheaded), ToyPolicy, reheaded),
    "model.heads must be [2,3]")

echo "Testing the per-seat operation budget rejects over-budget models"
block:
  let
    model = toyModel(hidden = 128)
    ops = 2 * weightCount(128) + 32 * 128
  doAssert loadActor(model, toyContract()).operationCount == ops
  let tight = toyContract(budget = ops - 1)
  var caught = false
  try:
    discard loadActor(model, tight)
  except ValueError as error:
    caught = true
    doAssert "needs " & $ops & " operations per inference, over the " &
      $(ops - 1) & " budget" in error.msg, error.msg
  doAssert caught
  rejects(toyPackage(toyManifest(ToyPolicy, model, tight, hidden = 128),
    ToyPolicy, model), "budget", tight)
  doAssert parsePackage(toyPackage(toyManifest(ToyPolicy, model, hidden = 128),
    ToyPolicy, model), toyContract(budget = ops)).actor.hiddenSize == 128

echo "Testing the recurrent state lifecycle and resets"
block:
  let actor = loadActor(toyModel(), toyContract())
  proc run(seat: ToySeat, ticks: int, deathAt = -1): seq[seq[float32]] =
    for t in 1 .. ticks:
      seat.alive = t != deathAt
      seat.x = float32(t) * 0.25'f32
      toyWorld.tick = int32(t)
      if seat.decide(int32(t), int32(t)):
        result.add seat.logits & seat.state
      else:
        result.add @[]
  let seat = newToySeat(actor)
  discard seat.run(12, deathAt = 5)
  seat.resetBrain(7, 0)
  let again = seat.run(9)
  let fresh = newToySeat(actor).run(9)
  doAssert again == fresh, "a reset seat must replay a fresh seat exactly"
  # First frame resets; a death blanks the frame; the next frame resets again.
  let life = newToySeat(actor)
  life.x = 0.25
  toyWorld.tick = 1
  doAssert life.decide(1, 1) and life.resetState
  let first = life.logits
  life.x = 1
  toyWorld.tick = 2
  doAssert life.decide(2, 2) and not life.resetState
  doAssert life.state != newSeq[float32](64), "state carries over between frames"
  doAssert not life.decide(2, 2), "one frame per tick"
  life.alive = false
  doAssert not life.decide(3, 3) and not life.acting
  life.alive = true
  life.x = 0.25
  doAssert life.decide(4, 4) and life.resetState
  doAssert life.logits == first, "state restarts from zero after a death"
  doAssert isFiniteVector(life.state)
  doAssert decisionDue(1, 4) and not decisionDue(2, 4) and decisionDue(5, 4)
  doAssert not decisionDue(1, 0)

echo "Testing telemetry lines"
block:
  toyWorld.log.setLen(0)
  let seat = newToySeat(loadActor(toyModel(), toyContract()), seat = 3,
    period = 1, maxTicks = 3700)
  seat.telemetry = true
  for t in 1 .. 3700:
    toyWorld.tick = int32(t)
    discard seat.decide(int32(t), int32(t))
  let ops = seat.actor.operationCount
  doAssert toyWorld.log.len == 4, $toyWorld.log
  doAssert toyWorld.log[0] == "seat 3 neural: peak_ops=" & $ops &
    " budget=200000 model=w64 ticks=1 inferences=1"
  doAssert toyWorld.log[1].endsWith("ticks=1801 inferences=1801")
  doAssert toyWorld.log[2].endsWith("ticks=3601 inferences=3601")
  doAssert toyWorld.log[3].endsWith("ticks=3700 inferences=3700")
  let quiet = newToySeat(seat.actor)
  toyWorld.log.setLen(0)
  toyWorld.tick = 1
  discard quiet.decide(1, 1)
  doAssert toyWorld.log.len == 0, "telemetry is opt-in per seat"

echo "Testing decoders are deterministic and honour masks"
block:
  let logits = [0.1'f32, 0.9, 2.0, 2.0, -1.0]
  var heads: array[2, int32]
  argmaxHeads(logits, ToyHeads, heads)
  doAssert heads == [1'i32, 0], "first maximum wins"
  var a, b = 42'u64
  var ha, hb: array[2, int32]
  for _ in 0 ..< 50:
    sampleHeads(logits, ToyHeads, 1, a, ha)
    sampleHeads(logits, ToyHeads, 1, b, hb)
    doAssert ha == hb
  doAssert pickHead(logits, 2, 3, [false, false, true], false, 1, 0) == 2
  doAssert pickHead(logits, 2, 3, [false, false, false], false, 1, 0) == 0
  for draw in [0.0, 0.3, 0.99]:
    doAssert pickHead(logits, 2, 3, [false, true, false], true, 1, draw) == 1

echo "Testing the neural BASIC host functions"
block:
  let actor = loadActor(toyModel(), toyContract())
  var current: ToySeat = nil
  var schema = initHost()
  schema.addNeuralHostFunctions(proc(): NeuralBrain = current)
  let program = compile(ToyPolicy, schema)
  var host = initHost()
  host.addNeuralHostFunctions(proc(): NeuralBrain = current)
  var runtime = initRuntime(program, host)
  discard runtime.run()
  doAssert runtime.getGlobal("inputs") == 0, "no brain: every function returns 0"
  current = newToySeat(actor, period = 3)
  toyWorld.tick = 1
  doAssert current.decide(1, 1)
  runtime.restart()
  discard runtime.run()
  doAssert runtime.getGlobal("fresh") == 1
  doAssert runtime.getGlobal("move") == current.heads[0]
  doAssert runtime.getGlobal("aim") == current.heads[1]
  doAssert runtime.getGlobal("width") == 64
  doAssert runtime.getGlobal("inputs") == ToyObservation
  doAssert runtime.getGlobal("outputs") == ToyOutputs
  doAssert runtime.getGlobal("period") == 3
  doAssert runtime.getGlobal("beyond") == 0
  toyWorld.tick = 2
  var stale = initRuntime(program, host)
  discard stale.run()
  doAssert stale.getGlobal("fresh") == 0, "a decision is fresh only on its tick"
