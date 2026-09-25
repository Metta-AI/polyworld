## Explicit, journaled hosted mutations for the RowDaBoat GotA campaign.
## Compile: nim c -d:ssl -o:/tmp/hosted_mutate tools/hosted_mutate.nim
## This program never retries a request. Inspect saved evidence before recovery.
import std/[httpclient, json, os, strutils, times, uri]
import crunchy

const
  ApiRoot = "https://softmax.com/api/observatory"
  ExpectedUser = "yfz2cgpl1a32eoxx2um1gojm"
  ExpectedPlayer = "ply_eeb732fa-5f40-4fa1-beac-6571738f8108"

proc fail(message: string) {.noreturn.} =
  stderr.writeLine(message)
  quit(1)

proc ensure(condition: bool, message: string) =
  if not condition: fail(message)

proc unquote(value: string): string =
  result = value.strip()
  if result.len >= 2 and ((result[0] == '"' and result[^1] == '"') or
                        (result[0] == '\'' and result[^1] == '\'')):
    result = result[1 ..< result.high]

proc readToken(): string =
  ## Reads only the known account-token mapping, never prints its value.
  let path = getHomeDir() / ".softmax" / "credentials.yaml"
  ensure(fileExists(path), "Credential file is not present.")
  var inTokens = false
  for line in readFile(path).splitLines():
    let clean = line.strip()
    if clean.len == 0 or clean.startsWith("#"): continue
    if line[0] notin {' ', '\t'}:
      inTokens = clean == "tokens:"
      continue
    if not inTokens: continue
    let colon = clean.find(": ")
    if colon < 0: continue
    let key = unquote(clean[0 ..< colon])
    if key in ["https://softmax.com/api", "https://softmax.com"]:
      result = unquote(clean[colon + 1 .. ^1])
      ensure(result.len > 0 and '\r' notin result and '\n' notin result,
        "Invalid saved account token.")
      return
  fail("No saved Softmax account token for the known origin.")

proc save(path: string, value: JsonNode) =
  let parent = parentDir(path)
  if parent.len > 0: createDir(parent)
  writeFile(path, value.pretty() & "\n")

proc nowText(): string = $now().utc

proc newApiClient(): HttpClient =
  result = newHttpClient(timeout = 60000, maxRedirects = 0)
  result.headers = newHttpHeaders({
    "Accept": "application/json", "Content-Type": "application/json",
    "Authorization": "Bearer " & readToken()})

proc verifyIdentity(client: HttpClient) =
  let response = client.request(ApiRoot & "/whoami", httpMethod = HttpGet)
  ensure(int(response.code) == 200, "Identity check failed; no mutation sent.")
  let identity = parseJson(response.body)
  let isExpected =
    (identity{"subject_type"}.getStr() == "user" and
      identity{"subject_id"}.getStr() == ExpectedUser) or
    (identity{"subject_type"}.getStr() == "player" and
      identity{"subject_id"}.getStr() == ExpectedPlayer)
  ensure(isExpected, "Credential identity differs from the verified RowDaBoat account.")

proc allowedPath(path: string): bool =
  if path in ["/stats/policies/files/upload", "/stats/policies/files/complete",
      "/v2/league-submissions", "/v2/experience-requests"]:
    return true
  if path.startsWith("/v2/league-policy-memberships/lpm_") and
      path.endsWith("/champion") and '?' notin path and '#' notin path:
    let id = path.split('/')[3]
    return id.len == 40 and id[4 .. ^1].allCharsInSet({'0'..'9', 'a'..'f', '-'})

proc publicResponse(value: JsonNode): JsonNode =
  ## The only signed upload URL stays in memory, never in logs or receipts.
  result = value.copy()
  if result.kind == JObject and result.hasKey("upload_url"):
    if result["upload_url"].kind == JString:
      result["upload_host"] = %parseUri(result["upload_url"].getStr()).hostname
      result["upload_url"] = %"[redacted signed upload URL]"

proc postOnce(client: HttpClient, path: string, body: JsonNode,
    output: string): JsonNode =
  ensure(allowedPath(path), "POST path is outside campaign mutation allowlist.")
  ensure(not fileExists(output) and not fileExists(output & ".attempt.json"),
    "An output or attempt journal exists. Inspect it; no automatic retry is allowed.")
  save(output & ".request.json", body)
  save(output & ".attempt.json", %*{"method": "POST", "path": path,
    "started_at": nowText(), "state": "sent_or_uncertain"})
  let response = client.request(ApiRoot & path, httpMethod = HttpPost, body = $body)
  let status = int(response.code)
  var decoded: JsonNode
  try: decoded = parseJson(response.body)
  except JsonParsingError:
    decoded = %*{"unparsed_response": true, "response_bytes": response.body.len}
  save(output, publicResponse(decoded))
  save(output & ".attempt.json", %*{"method": "POST", "path": path,
    "finished_at": nowText(), "http_status": status,
    "state": (if status in 200..299: "response_received" else: "http_error")})
  ensure(status in 200..299,
    "POST failed with HTTP " & $status & ". Response saved; no retry sent.")
  result = decoded

proc uploadBody(filePath, name, player: string): tuple[bytes: string, body: JsonNode] =
  ensure(player == ExpectedPlayer, "Upload player must be the verified RowDaBoat player.")
  ensure(name.len > 0, "Policy name is required.")
  ensure(fileExists(filePath), "Policy file does not exist.")
  ensure(getFileSize(filePath) > 0 and getFileSize(filePath) <= 104857600,
    "Policy file must be nonempty and at most 100 MiB.")
  result.bytes = readFile(filePath)
  let digest = sha256(result.bytes).toHex().toLowerAscii()
  result.body = %*{"name": name, "player_id": player,
    "content_hash": digest, "size_bytes": result.bytes.len}

proc upload(filePath, name, player, folder: string) =
  let prepared = uploadBody(filePath, name, player)
  ensure(not dirExists(folder) and not fileExists(folder),
    "Upload journal folder already exists. Inspect it before any recovery.")
  let client = newApiClient()
  defer: client.close()
  verifyIdentity(client)
  createDir(folder)
  save(folder / "artifact.json", %*{"path": absolutePath(filePath),
    "name": name, "player_id": player,
    "content_hash": prepared.body["content_hash"], "size_bytes": prepared.bytes.len})
  let staged = postOnce(client, "/stats/policies/files/upload", prepared.body,
    folder / "upload-response.json")
  var version: JsonNode
  if staged.hasKey("existing_policy_version") and
      staged["existing_policy_version"].kind == JObject:
    version = staged["existing_policy_version"]
  else:
    let signed = staged{"upload_url"}.getStr()
    let url = parseUri(signed)
    ensure(url.scheme == "https" and url.hostname.len > 0 and
      url.username.len == 0 and url.password.len == 0,
      "Upload response did not supply a valid HTTPS staging URL.")
    save(folder / "put-attempt.json", %*{"method": "PUT", "host": url.hostname,
      "started_at": nowText(), "state": "sent_or_uncertain"})
    # A fresh client deliberately has no Softmax Authorization header.
    let storage = newHttpClient(timeout = 60000, maxRedirects = 0)
    defer: storage.close()
    storage.headers = newHttpHeaders({"Content-Type": "application/octet-stream"})
    let response = storage.request(signed, httpMethod = HttpPut, body = prepared.bytes)
    let status = int(response.code)
    save(folder / "put-attempt.json", %*{"method": "PUT", "host": url.hostname,
      "finished_at": nowText(), "http_status": status,
      "state": (if status in 200..299: "response_received" else: "http_error")})
    ensure(status in 200..299, "Staging PUT failed. No completion or retry sent.")
    version = postOnce(client, "/stats/policies/files/complete", prepared.body,
      folder / "complete-response.json")
  ensure(version{"id"}.getStr().len > 0 and version{"name"}.getStr() == name and
    version{"version"}.getInt() > 0, "Upload response lacks a usable policy version.")
  save(folder / "policy-version.json", version)
  echo "Uploaded ", version["name"].getStr(), ":v", version["version"].getInt(),
    " (", version["id"].getStr(), "). Receipt: ", folder / "policy-version.json"

proc main() =
  let args = commandLineParams()
  if args.len == 0 or args == @["--help"]:
    echo "prepare-upload FILE NAME PLAYER_ID OUTPUT_JSON (offline)"
    echo "upload FILE NAME PLAYER_ID NEW_JOURNAL_DIR"
    echo "post API_PATH REQUEST_JSON OUTPUT_JSON"
    echo "All writes are single attempts; existing attempt journals block repeats."
    return
  if args.len == 5 and args[0] == "prepare-upload":
    let prepared = uploadBody(args[1], args[2], args[3])
    ensure(not fileExists(args[4]), "Preparation output already exists.")
    save(args[4], prepared.body)
    echo "Prepared upload metadata offline: ", args[4]
  elif args.len == 5 and args[0] == "upload":
    upload(args[1], args[2], args[3], args[4])
  elif args.len == 4 and args[0] == "post":
    ensure(allowedPath(args[1]), "POST path is outside campaign mutation allowlist.")
    let body = parseFile(args[2])
    if args[1] == "/v2/experience-requests":
      ensure(body{"idempotency_key"}.getStr().len >= 5,
        "XP creation requires a saved idempotency_key.")
      ensure(body{"num_episodes"}.getInt() >= 10,
        "Campaign XP requests require at least ten episodes.")
    if args[1] == "/v2/league-submissions":
      ensure(body{"player_id"}.getStr() == ExpectedPlayer,
        "Submission requires explicit verified RowDaBoat player_id.")
      ensure(body.hasKey("auto_champion"), "Submission must state auto_champion explicitly.")
    let client = newApiClient()
    defer: client.close()
    verifyIdentity(client)
    let response = postOnce(client, args[1], body, args[3])
    echo "Saved response: ", args[3]
    if response.kind == JObject and response.hasKey("id"):
      echo "Response ID: ", response["id"].getStr()
  else:
    fail("Invalid arguments; use --help.")

when isMainModule:
  try:
    main()
  except CatchableError as error:
    stderr.writeLine("Operation stopped (", error.name,
      "). Inspect journals before recovery; no retries were sent. Secrets omitted.")
    quit(1)
