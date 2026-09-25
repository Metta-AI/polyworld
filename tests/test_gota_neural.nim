## GotA on the shared neural tier: the GotA contract's identity and its
## package options, with in-memory corruption cases for the GotA keys.
##   nim r -d:headless tests/test_gota_neural.nim

import
  std/[json, strutils],
  polyworld/neural_host,
  ../examples/gods_of_the_arena/[bots, neural_contract],
  neural_toy

proc gotaModel(hidden = 64, obsHash = ObservationContractHash): string =
  var weights = newSeq[float32](weightCount(hidden, ObservationSize, ActionOutputs))
  for i, w in weights.mpairs:
    w = float32((i * 7919) mod 1000) / 100000'f32 - 0.005'f32
  encodeActor(ObservationSize, hidden, HeadSizes, obsHash, ActionContractHash,
    weights)

let
  policy = "' glue\nx = gota_act()\n"
  model = gotaModel()

proc manifest(): JsonNode =
  %*{
    "schema": PackageSchema,
    "observation_contract": ObservationContractHash,
    "action_contract": ActionContractHash,
    "decision_period": 4,
    "files": {"policy.bas": sha256Hex(policy), "model.bin": sha256Hex(model)},
    "model": {"format": "GOTANET1", "inputs": ObservationSize, "hidden": 64,
      "heads": HeadSizes}
  }

proc pack(m: JsonNode, modelBytes = model): string =
  writeZip([entry("manifest.json", $m), entry("policy.bas", policy),
    entry("model.bin", modelBytes)])

proc rejects(bytes, message: string) =
  var caught = false
  try:
    discard parseGotaPackage(bytes)
  except ValueError as error:
    caught = true
    doAssert message in error.msg, "want '" & message & "', got: " & error.msg
  doAssert caught, "accepted, expected: " & message

echo "Testing the GotA contract identity"
block:
  doAssert GotaContract.observationHash == ObservationContractHash
  doAssert GotaContract.actionHash == ActionContractHash
  doAssert GotaContract.observationSize == 1407
  doAssert GotaContract.headSizes == @[8, 25, 49, 4, 6]
  doAssert GotaContract.headOutputs == ActionOutputs and ActionOutputs == 92
  doAssert GotaContract.maskSize == MaskSize and MaskSize == 187
  doAssert GotaContract.opBudget == 4_000_000
  doAssert GotaContract.schema == "gota-neural-basic/1"

echo "Testing GotA package options"
block:
  let plain = parseGotaPackage(pack(manifest()))
  let options = plain.gotaOptions
  doAssert options.goals[0] == defaultGoal() and options.goals[1] == defaultGoal()
  doAssert not options.deferScript and options.maskMode == NoMask
  var m = manifest()
  var red = newSeq[float](16)
  red[2] = 0.5
  m["goal"] = %*{"red": red, "blue": red}
  m["decoder"] = %*{"mode": "sample", "temperature": 2, "defer_script": true,
    "mask_empty_targets": true, "mask_mode": "static"}
  let full = parseGotaPackage(pack(m))
  doAssert full.gotaOptions.goals[0][2] == 0.5
  doAssert full.gotaOptions.deferScript
  doAssert full.gotaOptions.maskMode == StaticMask
  doAssert full.decoder.mode == SampleDecoder and full.decoder.temperature == 2
  m["decoder"] = %*{"mask_empty_targets": true}
  doAssert parseGotaPackage(pack(m)).gotaOptions.maskMode == ConditionalMask

echo "Testing GotA corruption cases"
block:
  proc edited(key: string, value: JsonNode): string =
    var m = manifest()
    m[key] = value
    pack(m)
  var zeros = newSeq[float](16)
  rejects(edited("decoder", %*{"fire_hold": 1}), "unknown manifest key decoder.fire_hold")
  rejects(edited("decoder", %*{"defer_script": 1}), "decoder.defer_script must be true or false")
  rejects(edited("decoder", %*{"mask_empty_targets": "yes"}),
    "decoder.mask_empty_targets must be true or false")
  rejects(edited("decoder", %*{"mask_mode": "static"}), "mask_mode needs mask_empty_targets true")
  rejects(edited("decoder", %*{"mask_empty_targets": true, "mask_mode": "greedy"}),
    "mask_mode must be conditional or static")
  rejects(edited("decoder", %*{"mode": "sample", "temperature": true}),
    "decoder.temperature must be a number")
  var reserved = zeros
  reserved[15] = 0.5
  rejects(edited("goal", %*{"red": zeros, "blue": reserved}), "w_reserved must be 0")
  rejects(edited("goal", %*{"red": zeros}), "goal needs red and blue")
  rejects(edited("goal", %*{"red": zeros, "blue": zeros, "green": zeros}),
    "unknown manifest key goal.green")
  let boolGoal = %zeros
  boolGoal.elems[0] = %true
  rejects(edited("goal", %*{"red": zeros, "blue": boolGoal}), "must be 16 numbers")
  let infinite = ($manifest()).replace("\"decision_period\":4",
    "\"decision_period\":4,\"goal\":{\"red\":[1e999" & ",0".repeat(15) &
    "],\"blue\":[0" & ",0".repeat(15) & "]}")
  rejects(writeZip([entry("manifest.json", infinite), entry("policy.bas", policy),
    entry("model.bin", model)]), "non-finite number")
  var m = manifest()
  m["model"]["inputs"] = %1407.0
  rejects(pack(m), "model.inputs must be an integer")
  m = manifest()
  m["decision_period"] = %25
  rejects(pack(m), "decision_period must be an integer 1..24")
  let foreign = gotaModel(obsHash = "0".repeat(64))
  var f = manifest()
  f["files"]["model.bin"] = %sha256Hex(foreign)
  rejects(pack(f, foreign), "model.bin contract hashes do not match")
  var bomb = entry("model.bin", "\0".repeat(16 * 1024 * 1024))
  bomb.declaredSize = model.len
  rejects(writeZip([entry("manifest.json", $manifest()), entry("policy.bas", policy),
    bomb]), "inflated data exceeds its limit")
  var caught = false
  try:
    discard loadActor(foreign, GotaContract)
  except ValueError:
    caught = true
  doAssert caught, "gota_net_load's loader must check the contract hashes"
