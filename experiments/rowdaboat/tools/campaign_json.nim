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
  if paramCount() != 1:
    quit("Usage: campaign_json RESPONSE.json", 1)
  describe(parseFile(paramStr(1)))
