## Confirm rapid same-target hits with intervening walk/attack in hosted logs.
import std/[os, json, tables]
import ../content
if paramCount() != 2:
  quit("Usage: attack_recovery_audit <replay-audit-prefix> <output.json>", 1)
let prefix = paramStr(1)
let summary = parseFile(prefix & ".summary.json")
var actions = initTable[int, seq[JsonNode]]()
for line in lines(prefix & ".actions.jsonl"):
  let item = parseJson(line)
  actions.mgetOrPut(item["seat"].getInt, @[]).add item
var previous = initTable[int, JsonNode]()
var records = newJArray()
var totals = initCountTable[int]()
for line in lines(prefix & ".events.jsonl"):
  let event = parseJson(line)
  if event["kind"].getStr != "Damage" or event["cause"].getStr != "BasicAttack":
    continue
  let seat = event["actor"]["player"].getInt
  if seat < 0: continue
  totals.inc(seat)
  let period = heroAttackTicks(HeroClass(event["actor"]["class"].getInt))
  if previous.hasKey(seat):
    let first = previous[seat]
    let gap = event["tick"].getInt - first["tick"].getInt
    if gap > 0 and gap < period and first["target"]["id"] == event["target"]["id"]:
      var relevant = newJArray()
      var walked = false
      var reattacked = false
      for action in actions[seat]:
        let tick = action["tick"].getInt
        if tick <= first["tick"].getInt: continue
        if tick > event["tick"].getInt: break
        if action["kind"].getStr == "walk": walked = true
        if walked and action["kind"].getStr == "attackTarget": reattacked = true
        relevant.add action
      if walked and reattacked:
        records.add %*{"seat": seat, "player": summary["players"][seat]["player"],
          "class": $HeroClass(event["actor"]["class"].getInt),
          "nativePeriod": period, "observedGap": gap,
          "firstHit": first, "commands": relevant, "secondHit": event}
  previous[seat] = event
var counts = newJObject()
for record in records:
  let key = record["player"].getStr
  counts[key] = %(counts{key}.getInt + 1)
var hitCounts = newJObject()
for seat, count in totals:
  hitCounts[summary["players"][seat]["player"].getStr] = %count
let output = %*{"note": "Hosted replay mechanism evidence only; no score comparison.",
  "verifiedHashes": summary["verifiedHashes"], "mismatches": summary["mismatches"],
  "totalBasicHits": hitCounts, "rapidSameTargetHitPairsWithWalkAttack": counts,
  "records": records}
createDir(paramStr(2).parentDir)
writeFile(paramStr(2), output.pretty & "\n")
echo "basic hits: ", hitCounts
echo "rapid same-target pairs with walk/attack: ", counts
echo "details: ", paramStr(2)
