import
  std/[json, os, strutils],
  balances

proc reviewBatch*(directory: string, rounds: JsonNode): bool =
  ## Applies an explicit role-pair review before allowing another batch.
  let
    summary = rounds[rounds.len - 1]
    number = summary["round"].getInt
    batch = directory / ("round-" & align($number, 2, '0'))
    path = batch / "decision.json"
  if not fileExists(path):
    return false
  let
    decision = readJson(path)
    base = decision["base_batch"].getInt
    changes = decision["changes"]
  require(base in 1 .. min(number, 8), "Review base must be a tested batch")
  require(decision["diagnosis"].getStr.len > 0, "Review needs a diagnosis")
  require(changes.len in [0, 2], "Review must change both role heroes or hold")
  if number >= 8:
    require(changes.len == 0, "Validation cannot introduce tuning changes")
  var next = readFile(directory /
    ("round-" & align($base, 2, '0')) / "content.nim")
  if changes.len == 2:
    let role = decision["role"].getInt
    require(role in 0 .. 4, "Invalid role pair")
    var changed: set[range[0 .. 9]]
    for change in changes:
      let hero = change["hero_id"].getInt
      require(hero in RolePairs[role] and hero notin changed,
        "Each hero in the selected pair must change once")
      changed.incl(hero)
      let lever = Lever(anchor: change["anchor"].getStr,
        field: change["field"].getStr)
      require(next.value(lever) == change["before"].getInt,
        "Review value differs from the selected base")
      require(change["after"].getInt > 0 and
        change["after"].getInt != change["before"].getInt,
        "Review needs a positive changed value")
      next.replaceValue(lever, change["after"].getInt)
  let lockPath = directory / "validation.json"
  if decision{"validation"}.getBool or number == 8:
    require(changes.len == 0, "Validation must freeze tested stats")
    if not fileExists(lockPath):
      saveJson(lockPath, %*{"start_batch": number + 1, "base_batch": base})
      writeFile(directory / "validation-content.nim", next)
  if fileExists(lockPath):
    let start = readJson(lockPath)["start_batch"].getInt
    if number >= start - 1:
      require(next == readFile(directory / "validation-content.nim"),
        "All validation batches must use identical stats")
  summary["decision"] = decision
  summary["changes"] = changes
  writeFile(batch / "next-content.nim", next)
  saveJson(batch / "summary.json", summary)
  true
