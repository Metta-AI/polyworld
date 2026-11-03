import std/[json, os, osproc, strutils]
import tournaments

proc collectStats*(client: Client, directory: string, run, game,
    record: JsonNode, controls: Controls, detail: JsonNode = nil) =
  ## Saves verified replay counters without changing completed game outcomes.
  if record["state"].getStr != "completed" or
    record.hasKey("player_stats") or controls.statsWorker.len == 0 or stopping:
      return
  try:
    let
      id = game["id"].getStr
      replay = directory / "replays" / (id & ".replay")
      metadata = directory / "replays" / (id & "-metadata.json")
      output = directory / "replays" / (id & "-stats.json")
      attempt = record["attempts"][record["attempts"].len - 1]
    let refresh = not fileExists(metadata) or
      (not fileExists(replay) and
      readJson(metadata){"replay_url"}.getStr.len == 0)
    if detail != nil or refresh:
      let response = if detail != nil: detail else:
        client.request("GET", "/v2/experience-requests/" &
          attempt["request_id"].getStr, nil)
      require(response{"episodes"} != nil and response["episodes"].len == 1,
        "Missing replay episode")
      saveJson(metadata, response["episodes"][0], controls)
    let episode = readJson(metadata)
    require(episode{"id"} == attempt["episode_id"] and
      episode{"coworld_id"} == run["release"]["id"] and
      episode{"game_config", "seed"} == game["seed"],
      "Replay metadata differs from saved game")
    if not fileExists(replay):
      let url = episode{"replay_url"}.getStr
      require(url.startsWith("https://"), "No HTTPS replay artifact available")
      require(client.download != nil, "Replay downloads are unavailable")
      saveBytes(replay, client.download(url), controls)
    if stopping:
      return
    if not fileExists(output):
      require(fileExists(controls.statsWorker),
        "Missing player statistics worker: " & controls.statsWorker)
      let command = quoteShell(controls.statsWorker) & " " &
        quoteShell(replay) & " " & quoteShell(metadata) & " " &
        quoteShell(output)
      let response = execCmdEx(command)
      require(response.exitCode == 0,
        "Replay inspection failed: " & response.output.strip())
    let stats = readJson(output)
    validatePlayerStats(stats, record["result"], game, run)
    record["player_stats"] = stats
    if record.hasKey("stats_error"):
      record.delete("stats_error")
    saveRecord(directory, record, controls)
    echo "Player stats: ", id
  except CatchableError as error:
    record["stats_error"] = %error.msg
    saveRecord(directory, record, controls)
    stderr.writeLine("Player stats " & game["id"].getStr & ": " & error.msg)
