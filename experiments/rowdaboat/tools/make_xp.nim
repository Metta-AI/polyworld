## Build a hosted XP request from fresh leaderboard and active-champion responses.
import std/[algorithm, json, os, sets, tables]

const
  OurPlayer = "ply_eeb732fa-5f40-4fa1-beac-6571738f8108"
  League = "league_3c60897b-25cf-4b37-9d1a-8554c1198f28"

when isMainModule:
  if paramCount() != 6:
    quit("Usage: make_xp LEADERBOARD CHAMPIONS OWN_VERSION OUTPUT NOTES IDEMPOTENCY_KEY", 1)
  var rows = parseFile(paramStr(1)).getElems
  let memberships = parseFile(paramStr(2))
  var members: Table[string, JsonNode]
  var membershipCounts: CountTable[string]
  for m in memberships:
    let player = m{"player", "id"}.getStr
    if player.len == 0 or player == OurPlayer: continue
    if not m{"is_champion"}.getBool or m{"status"}.getStr != "competing": continue
    if m{"end_time"} != nil and m["end_time"].kind != JNull: continue
    membershipCounts.inc(player)
    if not members.hasKey(player) or m{"created_at"}.getStr > members[player]{"created_at"}.getStr:
      members[player] = m
  rows.sort(proc(a, b: JsonNode): int = cmp(a{"rank"}.getInt(high(int)), b{"rank"}.getInt(high(int))))
  var seen: HashSet[string]
  let opponents = newJArray()
  for row in rows:
    let player = row{"player_id"}.getStr
    if player == OurPlayer or player in seen or not members.hasKey(player): continue
    if row{"rank"} == nil or row["rank"].kind == JNull: continue
    doAssert membershipCounts[player] == 1, "Ambiguous live champions for a top player"
    seen.incl(player)
    let p = members[player]["policy_version"]
    opponents.add %*{"rank": row["rank"], "player_id": player,
      "player_name": row["player_name"], "policy_version_id": p["id"], "policy_label": p["label"]}
    if opponents.len == 3: break
  doAssert opponents.len == 3, "Need three distinct other live champions"
  let roster = newJArray()
  roster.add %*{"player": {"policy_ref": paramStr(3)}, "slot": -1}
  for opponent in opponents:
    doAssert opponent["policy_version_id"].getStr != paramStr(3)
    for seat in 0 ..< 3:
      roster.add %*{"player": {"policy_ref": opponent["policy_version_id"]}, "slot": -1}
  let request = %*{"private": false, "target": {"league_id": League},
    "roster": roster, "num_episodes": 10, "notes": paramStr(5),
    "idempotency_key": paramStr(6)}
  writeFile(paramStr(4), request.pretty & "\n")
  writeFile(paramStr(4) & ".roster.json", opponents.pretty & "\n")
  echo opponents.pretty
  echo "10 episodes; one own hero and three copies of each opponent's single live policy; all seats rotate."
