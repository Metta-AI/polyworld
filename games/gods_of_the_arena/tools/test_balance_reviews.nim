import
  std/[json, os],
  balances, balance_reviews

proc main() =
  ## Checks pair enforcement, reviewed values, and frozen validation.
  let
    directory = getTempDir() / ("gota-review-test-" & $getCurrentProcessId())
    source = readFile(currentSourcePath().parentDir.parentDir / "content.nim")
  createDir(directory / "round-01")
  defer: removeDir(directory)
  writeFile(directory / "round-01/content.nim", source)
  let rounds = %*[{"round": 1, "changes": []}]
  doAssert not reviewBatch(directory, rounds)
  let decision = %*{"base_batch": 1, "role": 4,
    "diagnosis": "Test a reviewed fighter pair.", "changes": [
      {"hero_id": 4, "anchor": "name: \"Demon Hunter\"",
       "field": "baseMovePerTick", "before": 7200, "after": 9000},
      {"hero_id": 9, "anchor": "name: \"Berserker\"",
       "field": "baseMovePerTick", "before": 6800, "after": 5100}]}
  for change in decision["changes"]:
    change["before"] = %source.value(Lever(anchor: change["anchor"].getStr,
      field: change["field"].getStr))
  saveJson(directory / "round-01/decision.json", decision)
  doAssert reviewBatch(directory, rounds)
  doAssert readFile(directory / "round-01/next-content.nim") != source
  decision["changes"][1]["hero_id"] = %2
  saveJson(directory / "round-01/decision.json", decision)
  var rejected = false
  try:
    discard reviewBatch(directory, rounds)
  except BalanceError:
    rejected = true
  doAssert rejected
  createDir(directory / "round-08")
  writeFile(directory / "round-08/content.nim", source)
  let validation = %*[{"round": 8, "changes": []}]
  decision["changes"][1]["hero_id"] = %9
  saveJson(directory / "round-08/decision.json", decision)
  rejected = false
  try:
    discard reviewBatch(directory, validation)
  except BalanceError:
    rejected = true
  doAssert rejected
  decision["changes"] = newJArray()
  saveJson(directory / "round-08/decision.json", decision)
  doAssert reviewBatch(directory, validation)
  createDir(directory / "round-09")
  writeFile(directory / "round-09/content.nim", source)
  validation[0]["round"] = %9
  saveJson(directory / "round-09/decision.json", decision)
  doAssert reviewBatch(directory, validation)
  writeFile(directory / "validation-content.nim", source & "\n")
  rejected = false
  try:
    discard reviewBatch(directory, validation)
  except BalanceError:
    rejected = true
  doAssert rejected
  removeFile(directory / "validation.json")
  removeFile(directory / "validation-content.nim")
  decision["validation"] = %true
  saveJson(directory / "round-01/decision.json", decision)
  doAssert reviewBatch(directory, rounds)
  doAssert readJson(directory / "validation.json")["start_batch"].getInt == 2
  echo "Reviewed pair validation passed."

main()
