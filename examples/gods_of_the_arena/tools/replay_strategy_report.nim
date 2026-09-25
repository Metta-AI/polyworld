## Summarize the verified auditor output without treating replay counters as score.
import std/[os, json, strutils]
if paramCount() < 1 or paramCount() > 2:
  quit("Usage: replay_strategy_report <summary.json> [seat]", 1)
let report = parseFile(paramStr(1))
echo "source=", report["source"], " hashes=", report["verifiedHashes"],
  " mismatches=", report["mismatches"]
for p in report["players"]:
  if paramCount() == 2 and p["seat"].getInt != parseInt(paramStr(2)):
    continue
  echo "\nSEAT ", p["seat"], " PLAYER ", p["player"], " TEAM ", p["team"]
  echo "actions ", p["actions"]
  echo "rejections ", p["rejections"]
  echo "damage by target kind (1 god,2 hero,3 creep,4 tower,5 barracks,6 neutral) ", p["damageByTargetKind"]
  echo "damage by cause ", p["damageByCause"]
  echo "receivedXP by source kind/cause ", p{"receivedXpSources"}
  echo "receivedXP events by source kind/cause ", p{"receivedXpEvents"}
  echo "kills by target kind ", p{"killTargetKinds"}
  echo "healing received ", p{"healingReceived"}
  echo "casts ", p["casts"]
  echo "events ", p["events"]
  echo "purchases ", p["purchases"]
  echo "levels ", p["levels"]
  let snap = p["snapshots"]
  echo "first30secs ", snap[min(1, snap.len - 1)]
  echo "end ", snap[^1]
  echo "navigation samples every 60secs, world x,z in 60,000 units per tile"
  for i in 0 ..< snap.len:
    let item = snap[i]
    if i > 0 and i mod 2 == 0:
      echo "tick=", item["tick"], " pos=", item["x"], ",", item["z"],
        " goal=", item["moveX"], ",", item["moveY"],
        " hp=", item["hp"], "/", item["maxHp"], " level=", item["level"]
  echo "portal completions"
  if p.hasKey("portals"):
    for event in p["portals"]:
      if event["kind"].getStr == "PortalCompleted": echo event
  echo "opening "
  for i in 0 ..< min(8, p["openingActions"].len):
    echo p["openingActions"][i]
