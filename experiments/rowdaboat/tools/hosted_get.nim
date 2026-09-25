## Read-only HTTPS retrieval for hosted league research.
## Compile: nim c -d:ssl -o:/tmp/hosted_get tools/hosted_get.nim
## Public: /tmp/hosted_get https://softmax.com/play.md research/play.md
## Inspect credential key names (never values): /tmp/hosted_get --credential-keys
## Authenticated API GET: /tmp/hosted_get --auth URL OUTPUT
## OpenAPI: --api-paths FILE SUBSTRING; --api-detail FILE PATH; --api-schema FILE NAME
## JSON inspection: --json-get FILE /PATH; --json-keys FILE /PATH
## Current opponents: --top-three LEADERBOARD_FILE CHAMPIONS_FILE EXCLUDED_PLAYER_ID
import std/[httpclient, json, os, sets, strutils, uri]

proc fail(message: string) {.noreturn.} =
  stderr.writeLine(message)
  quit(1)

proc unquote(value: string): string =
  result = value.strip()
  if result.len >= 2 and ((result[0] == '"' and result[^1] == '"') or
                        (result[0] == '\'' and result[^1] == '\'')):
    result = result[1 ..< result.high]

proc credentialFields(): seq[(string, string)] =
  let path = getHomeDir() / ".softmax" / "credentials.yaml"
  if not fileExists(path):
    fail("Credential file is not present.")
  for line in readFile(path).splitLines():
    let clean = line.strip()
    if clean.len == 0 or clean.startsWith("#"): continue
    var colon = clean.find(": ")
    if colon < 0 and clean.endsWith(":"): colon = clean.high
    if colon <= 0: continue
    let key = unquote(clean[0 ..< colon])
    let origin = parseUri(key)
    let safeOrigin = origin.scheme in ["http", "https"] and origin.hostname.len > 0 and
      origin.username.len == 0 and origin.password.len == 0 and origin.query.len == 0 and
      origin.anchor.len == 0
    if not safeOrigin and (key.len > 48 or
        not key.allCharsInSet({'a'..'z', 'A'..'Z', '0'..'9', '_', '-'})):
      continue
    let value = unquote(clean[colon + 1 .. ^1])
    result.add((key, value))

proc readToken(): string =
  for (key, value) in credentialFields():
    if key in ["https://softmax.com/api", "https://softmax.com", "api_key", "apiKey", "token", "access_token", "accessToken"] and value.len > 0:
      if '\r' in value or '\n' in value:
        fail("Credential contains an invalid newline.")
      return value
  fail("No recognized API token field exists; inspect key names with --credential-keys.")

proc main() =
  var args = commandLineParams()
  if args.len == 4 and args[0] == "--top-three":
    let standings = parseFile(args[1])
    let champions = parseFile(args[2])
    var seen: HashSet[string]
    var selected = newJArray()
    for entry in standings:
      let playerId = entry["player_id"].getStr()
      if playerId == args[3] or playerId in seen: continue
      seen.incl(playerId)
      var matches: seq[JsonNode]
      for membership in champions:
        if membership{"player", "id"}.getStr() == playerId and
            membership{"is_champion"}.getBool() and membership{"end_time"}.kind == JNull:
          matches.add(membership)
      if matches.len != 1:
        fail("Expected exactly one current champion for ranked player " & playerId)
      selected.add(%*{
        "rank": entry["rank"], "player_id": playerId,
        "player_name": entry["player_name"],
        "policy_version_id": matches[0]["policy_version"]["id"],
        "policy_ref": matches[0]["policy_version"]["label"],
        "membership_id": matches[0]["id"]})
      if selected.len == 3: break
    if selected.len != 3: fail("Fewer than three unique opponent champions found.")
    echo selected.pretty()
    return
  if args.len == 3 and args[0] in ["--json-get", "--json-keys"]:
    var node = parseFile(args[1])
    for segment in args[2].split('/'):
      if segment.len > 0:
        node = if node.kind == JArray: node[parseInt(segment)] else: node[segment]
    if args[0] == "--json-get":
      echo node.pretty()
    elif node.kind == JObject:
      for key, value in node: echo key, " ", value.kind
    else:
      echo node.kind, " ", node.len
    return
  if args.len == 3 and args[0] == "--api-paths":
    let doc = parseFile(args[1])
    for path, operations in doc["paths"]:
      if args[2] in path:
        for verb, operation in operations:
          echo verb.toUpperAscii(), " ", path, " ", operation{"summary"}.getStr()
    return
  if args.len == 3 and args[0] == "--api-detail":
    let doc = parseFile(args[1])
    let operations = doc["paths"][args[2]]
    for verb, operation in operations:
      echo verb.toUpperAscii(), " ", args[2]
      for key in ["summary", "description", "parameters", "requestBody", "x-softmax-authorization"]:
        if operation.hasKey(key): echo key, ": ", operation[key].pretty()
      for status, response in operation{"responses"}:
        if status.startsWith("2"): echo status, " response: ", response{"content"}.pretty()
    return
  if args.len == 3 and args[0] == "--api-schema":
    let doc = parseFile(args[1])
    echo doc["components"]["schemas"][args[2]].pretty()
    return
  if args == @["--credential-keys"]:
    for (key, value) in credentialFields():
      echo key, (if value.len == 0: " (mapping or empty)" else: " (value redacted)")
    return
  var authenticated = false
  if args.len > 0 and args[0] == "--auth":
    authenticated = true
    args.delete(0)
  if args.len != 2:
    fail("Usage: hosted_get [--auth] HTTPS_URL OUTPUT; --credential-keys; --api-paths FILE QUERY; --api-detail FILE PATH; --api-schema FILE NAME; --json-get FILE /PATH; --json-keys FILE /PATH; --top-three LEADERBOARD CHAMPIONS EXCLUDED_PLAYER")
  let url = parseUri(args[0])
  if url.scheme != "https" or url.username.len > 0 or url.password.len > 0:
    fail("Only HTTPS URLs without embedded credentials are allowed.")
  if authenticated and (url.hostname != "softmax.com" or
      (url.port.len > 0 and url.port != "443") or
      not (url.path == "/api" or url.path.startsWith("/api/"))):
    fail("Authenticated reads are restricted to https://softmax.com/api/.")
  let client = newHttpClient(timeout = 60000, maxRedirects = 0)
  defer: client.close()
  client.headers = newHttpHeaders({"Accept": "application/json, text/plain, */*"})
  if authenticated:
    client.headers["Authorization"] = "Bearer " & readToken()
  let response = client.request(args[0], httpMethod = HttpGet)
  let status = int(response.code)
  if status < 200 or status >= 300:
    fail("GET failed with HTTP " & $status & "; redirects are intentionally disabled.")
  let data = response.body
  let parent = parentDir(args[1])
  if parent.len > 0: createDir(parent)
  writeFile(args[1], data)
  echo "Saved ", data.len, " bytes to ", args[1], " (HTTP ", status, ")."

when isMainModule:
  try:
    main()
  except CatchableError as error:
    # Never include arbitrary error messages that could contain request secrets.
    stderr.writeLine("Read failed (", error.name, "). No credentials were printed.")
    quit(1)
