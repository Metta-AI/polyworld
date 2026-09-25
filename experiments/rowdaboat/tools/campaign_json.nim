## Inspect hosted responses without printing signed URLs or credentials.
import std/[json, os, sequtils, strutils, tables]

proc describe(n: JsonNode) =
  if n.kind == JArray:
    var counts = initCountTable[string]()
    for row in n:
      counts.inc(row{"status"}.getStr("unknown"))
      echo row{"id"}.getStr, " ", row{"status"}.getStr,
        " episode=", row{"episode_id"}.getStr
    echo "records=", n.len, " statuses=", counts
  elif n.kind == JObject:
    for key in ["id", "status", "name", "version", "num_episodes",
                "episode_count", "completed_count", "running_count", "pending_count", "failed_count",
                "completed_episodes", "failed_episodes", "league_id",
                "coworld_id", "policy_version_id", "player_id"]:
      if n.hasKey(key): echo key, "=", n[key]
    for key in ["error", "error_message", "failure_reason"]:
      if n.hasKey(key) and n[key].kind == JString:
        echo key, "=", n[key].getStr[0 ..< min(500, n[key].getStr.len)]
    echo "keys=", n.keys.toSeq.join(",")

when isMainModule:
  if paramCount() == 2:
    let rows = parseFile(paramStr(1))
    doAssert rows.kind == JArray
    for row in rows:
      if row{"player", "id"}.getStr == paramStr(2):
        echo (%*{"membership_id": row["id"], "status": row["status"],
          "is_champion": row["is_champion"], "end_time": row["end_time"],
          "player": row["player"]["name"],
          "policy_version_id": row["policy_version"]["id"],
          "policy_label": row["policy_version"]["label"]}).pretty
    quit(0)
  if paramCount() != 1:
    quit("Usage: campaign_json RESPONSE.json [PLAYER_ID_FOR_MEMBERSHIPS]", 1)
  describe(parseFile(paramStr(1)))
