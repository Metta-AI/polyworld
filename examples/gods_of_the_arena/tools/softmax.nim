import
  std/[algorithm, json, os, strutils, tables, times, uri],
  curly, jsony, yaml/tojson,
  tournaments

type
  Softmax* = object
    http*: Curly
    server*: string
    token: string

proc tokenFromCredentials*(credentials: JsonNode, server: string): string =
  ## Uses the active unexpired player session, then the saved user login.
  let
    sessions = credentials{"player_sessions", server}
    active = sessions{"active"}.getStr
  if active.len > 0:
    let cached = sessions{"cache", active}
    if cached != nil:
      var expiry = cached{"expires_at"}.getStr
      let fraction = expiry.find('.')
      if fraction >= 0:
        var last = fraction + 1
        while last < expiry.len and expiry[last] in Digits:
          inc last
        expiry.delete(fraction ..< last)
      try:
        if parseTime(expiry, "yyyy-MM-dd'T'HH:mm:sszzz", utc()) > getTime():
          return cached{"token"}.getStr
      except TimeParseError:
        raise newException(TournamentError, "Invalid Softmax session expiry")
  result = credentials{"tokens", server}.getStr
  require(result.len > 0, "No Softmax login for " & server &
    ". Authenticate with softmax login first.")

proc connect*(server: string): Softmax =
  ## Opens Nim HTTP transport using the existing Softmax credentials file.
  let path = getHomeDir() / ".softmax/credentials.yaml"
  require(fileExists(path), "Authenticate with softmax login first")
  var documents: seq[JsonNode]
  try:
    documents = loadToJson(readFile(path))
  except CatchableError:
    raise newException(TournamentError, "Cannot parse Softmax credentials")
  require(documents.len == 1, "Expected one Softmax credentials document")
  result.server = server.strip(leading = false, chars = {'/'})
  result.token = tokenFromCredentials(documents[0], result.server)
  result.http = newCurly()

proc close*(client: Softmax) =
  ## Releases local HTTP resources without cancelling submitted games.
  client.http.close()

proc response(client: Softmax, verb, path: string,
    body: JsonNode): Response =
  ## Sends authenticated API calls while keeping credentials out of records.
  let headers = @[("Authorization", "Bearer " & client.token),
    ("Content-Type", "application/json")]
  let url = client.server & "/observatory" & path
  try:
    case verb
    of "GET":
      result = client.http.get(url, headers, timeout = 60)
    of "POST":
      result = client.http.post(url, headers,
        body.toJson, timeout = 60)
    else:
      raise newException(TournamentError, "Unsupported HTTP method: " & verb)
  except CatchableError as error:
    raise newException(
      TournamentError,
      "Softmax transport failed: " & error.msg
    )
  require(result.code in 200 .. 299,
    "Softmax " & verb & " " & path &
    " returned HTTP " & $result.code & ": " & result.body[0 ..< min(600,
      result.body.len)])

proc request*(client: Softmax, verb, path: string,
    body: JsonNode = nil): JsonNode =
  ## Reads API JSON, including original result artifacts without aggregation.
  tournaments.parseJson(client.response(verb, path, body).body)

proc transport*(client: Softmax): Client =
  ## Exposes the HTTP boundary used by the explicit tournament state loop.
  result.request = proc(verb, path: string, body: JsonNode): JsonNode =
    ## Preserves the saved request payload exactly on every retry.
    client.request(verb, path, body)
  result.download = proc(url: string): string =
    ## Fetches public replay artifacts without forwarding Softmax credentials.
    require(url.startsWith("https://"), "Replay URL must use HTTPS")
    try:
      let response = client.http.get(url, timeout = 60)
      require(response.code == 200,
        "Replay download returned HTTP " & $response.code)
      result = response.body
    except CatchableError as error:
      raise newException(TournamentError, "Replay download: " & error.msg)

proc entries(client: Softmax, path: string): seq[JsonNode] =
  ## Exhausts a cursor-paginated API listing without dropping later entrants.
  var cursor = ""
  while true:
    let
      suffix = if cursor.len > 0: "&cursor=" & encodeUrl(cursor) else: ""
      reply = client.response("GET", path & suffix, nil)
      page = tournaments.parseJson(reply.body)
    if page.kind == JArray:
      result.add(page.elems)
      cursor = reply.headers["X-Next-Cursor"]
    else:
      require(page{"entries"} != nil, "Invalid Softmax listing: " & path)
      result.add(page["entries"].elems)
      cursor = page{"next_cursor"}.getStr
    if cursor.len == 0:
      break

proc snapshot*(client: Softmax, settings: JsonNode): JsonNode =
  ## Freezes the active ranked roster and the league's exact game release.
  var division: JsonNode
  if settings["division"].kind != JNull:
    division = client.request("GET", "/v2/divisions/" &
      settings["division"].getStr)
  else:
    for candidate in client.request("GET", "/v2/divisions?league_id=" &
        encodeUrl(settings["league"].getStr)):
      if candidate["name"].getStr == "Competition" and
        candidate{"archived_at"}.getStr.len == 0:
          require(
            division == nil,
            "Select one Competition division with --division"
          )
          division = candidate
  require(division != nil, "No active Competition division found")
  require(division["league"]["id"] == settings["league"],
    "Division does not belong to the selected league")
  let
    league = division["league"]
    divisionId = division["id"].getStr
  var members: Table[string, JsonNode]
  for member in client.entries("/v2/league-policy-memberships?division_id=" &
      encodeUrl(divisionId) &
      "&active_only=true&champions_only=true&limit=100"):
    if member{"player"} == nil or member["player"].kind == JNull:
      continue
    let player = member["player"]["id"].getStr
    if not members.hasKey(player) or member["created_at"].getStr >
      members[player]["created_at"].getStr:
        members[player] = member
  let roster = newJArray()
  var leaderboard = client.request("GET", "/v2/divisions/" &
    divisionId & "/leaderboard").getElems
  leaderboard.sort(proc(a, b: JsonNode): int =
    ## Keeps selection deterministic when leaderboard ranks are equal.
    result = cmp(a["rank"].kind == JNull, b["rank"].kind == JNull)
    if result == 0:
      result = cmp(a["rank"].getInt, b["rank"].getInt)
    if result == 0:
      result = cmp(a["player_id"].getStr, b["player_id"].getStr))
  var seen: Table[string, bool]
  for row in leaderboard:
    let player = row["player_id"].getStr
    if not members.hasKey(player) or row["rank"].kind == JNull:
      continue
    let
      policy = members[player]["policy_version"]
      id = policy["id"].getStr
      policyName = policy["policy"]["name"].getStr
    if seen.hasKey(id):
      continue
    seen[id] = true
    roster.add %*{"id": id, "player_id": player,
      "name": row{"player_name"}.getStr(policyName),
      "version": policyName & ":v" & $policy["version"].getInt,
      "league_rank": row["rank"]}
    if roster.len == settings["top"].getInt:
      break
  require(roster.len >= (if settings["format"].getStr == "mono": 2 else: 10),
    "Not enough eligible policies: " & $roster.len)
  let
    locks = client.request(
      "GET",
      "/v2/leagues/" & league["id"].getStr & "/locks"
    )
    version = locks[if locks["game_version_locked"].getBool:
      "locked_game_version" else: "canonical_game_version"].getStr
  var world: JsonNode
  for candidate in client.entries("/v2/coworlds?limit=200"):
    if candidate["name"] == league["game"]["coworld_name"] and
      candidate["version"].getStr == version:
        require(world == nil, "Ambiguous game release")
        world = candidate
  require(world != nil, "Cannot resolve frozen game release")
  let manifest = world["manifest"]
  require(%"total_xp" in manifest["game"]["results_schema"]["required"].elems,
    "The hosted GotA release must emit total_xp")
  var config: JsonNode
  for variant in manifest["variants"]:
    if variant["id"].getStr == "competition":
      config = variant["game_config"].copy()
  require(config != nil, "The release needs a competition variant")
  if config.hasKey("tokens"):
    config.delete("tokens")
  result = %*{"roster": roster, "game_config": config,
    "release": {"id": world["id"], "version": version,
      "variant": "competition", "league": league["id"],
      "division": divisionId, "manifest_hash": world["manifest_hash"]}}
