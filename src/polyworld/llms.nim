import
  std/[json, os, strutils, uri],
  jsony,
  requests

const
  MaxRequestBytes* = 64 * 1024
  MaxReplies* = 4
  DefaultOracleModel* = "typesafe/jev-1.13"

type
  LlmError* = object of CatchableError
  LlmConfig* = object
    baseUrl*, key*, model*, oracleModel*: string
    sidecar*: bool
    interval*: int32
    timeoutMs*: int
  LlmReply* = object
    id*, status*: int32
    body*, error*: string
  LlmClient* = ref object
    config*: LlmConfig
    slot*: int
    tick, lastAsk, nextId, pending: int32
    asked: bool
    request: Request
    replies: seq[LlmReply]

proc parseDocument*(body: string): JsonNode {.raises: [LlmError].} =
  ## Parses bounded LLM JSON with jsony and reports LlmError on failure.
  if body.len > MaxResponseBytes:
    raise newException(LlmError, "LLM JSON exceeds the byte limit")
  var
    depth = 0
    quoted, escaped: bool
  for character in body:
    if quoted:
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == '"':
        quoted = false
    else:
      case character
      of '"':
        quoted = true
      of '{', '[':
        inc depth
        if depth > 64:
          raise newException(LlmError, "LLM JSON nesting exceeds 64 levels")
      of '}', ']':
        dec depth
      else:
        discard
  try:
    result = body.fromJson(JsonNode)
  except ValueError:
    raise newException(LlmError, "Invalid LLM JSON: " & getCurrentExceptionMsg())

proc environmentInt(name: string, fallback, maximum: int): int =
  ## Reads a bounded host setting without silently ignoring bad values.
  try:
    result = parseInt(getEnv(name, $fallback))
  except ValueError:
    raise newException(LlmError, name & " must be an integer")
  if result < 1 or result > maximum:
    raise newException(LlmError, name & " is outside the supported range")

proc llmConfig*(): LlmConfig =
  ## Uses the platform sidecar first, or explicit local OpenRouter access.
  if not NativeRequests or getEnv("COGAME_LLM").toLowerAscii == "off":
    return
  result.baseUrl = getEnv("AWS_ENDPOINT_URL_BEDROCK_RUNTIME").strip()
  result.sidecar = result.baseUrl.len > 0
  if not result.sidecar:
    result.key = getEnv("COGAME_LLM_KEY", getEnv("OPENROUTER_API_KEY"))
    result.baseUrl = getEnv("COGAME_LLM_BASE_URL")
    if result.baseUrl.len == 0 and result.key.len > 0:
      result.baseUrl = "https://openrouter.ai/api"
  if result.baseUrl.len == 0:
    return
  result.baseUrl = result.baseUrl.strip(trailing = true, chars = {'/'})
  var url: Uri
  try:
    url = parseUri(result.baseUrl)
  except ValueError:
    raise newException(LlmError, "Invalid host LLM base URL")
  if url.hostname.len == 0 or url.username.len > 0 or
    url.password.len > 0 or url.query.len > 0 or url.anchor.len > 0 or
    (url.scheme != "https" and not (result.sidecar and url.scheme == "http")):
      raise newException(LlmError, "Invalid host LLM base URL")
  result.model = getEnv("COGAME_LLM_MODEL")
  result.oracleModel = getEnv("COGAME_ORACLE_MODEL", DefaultOracleModel)
  result.interval = int32(environmentInt("COGAME_LLM_INTERVAL", 1, 100000))
  result.timeoutMs = environmentInt("COGAME_LLM_TIMEOUT_MS", 30000, 120000)

proc newLlmClient*(slot: int, config: LlmConfig): LlmClient =
  ## Creates one isolated seat without opening a network connection.
  if slot < 0 or config.interval < 0 or config.timeoutMs < 0:
    raise newException(LlmError, "Invalid LLM client configuration")
  LlmClient(config: config, slot: slot, tick: -1)

proc close*(client: LlmClient) {.raises: [].} =
  ## Cancels pending work and forgets all private answers.
  if client == nil:
    return
  client.request.close()
  client.request = nil
  client.pending = 0
  client.replies.setLen(0)

proc available*(client: LlmClient): bool {.raises: [].} =
  ## Reports whether the host configured a native inference endpoint.
  NativeRequests and client != nil and client.config.baseUrl.len > 0

proc hasPending*(client: LlmClient): bool {.raises: [].} =
  ## Reports requests that must settle before a barrier may advance.
  client != nil and client.pending != 0

proc ready*(client: LlmClient): int32 {.raises: [].} =
  ## Returns zero when ready, remaining spacing ticks, or minus one.
  if not client.available or client.pending != 0:
    return -1
  if client.asked:
    return int32(max(0'i64,
      int64(client.config.interval) - (int64(client.tick) - client.lastAsk)))

proc beginTick*(client: LlmClient, tick: int32) =
  ## Polls ready network work at the decision boundary and detects resets.
  if tick < client.tick:
    client.close()
    client.asked = false
  client.tick = tick
  if client.request == nil:
    return
  client.request.poll()
  if not client.request.finished:
    return
  var reply = LlmReply(
    id: client.pending,
    status: int32(client.request.status),
    body: move(client.request.body),
    error: move(client.request.error)
  )
  if reply.error.len == 0 and reply.status notin 200 .. 299:
    reply.error = "LLM HTTP " & $reply.status
  if client.replies.len == MaxReplies:
    client.replies.delete(0)
  client.replies.add move(reply)
  client.pending = 0
  client.request = nil

proc ask*(client: LlmClient, verb, path, body: string): int32 =
  ## Forwards an inference API body unchanged and returns its request ID.
  if client.ready != 0 or body.len > MaxRequestBytes:
    return 0
  if verb notin ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"] or
    not path.startsWith("/v1/") or path.len > 2048 or
    path.find({'\x00' .. '\x1f', '\x7f', '\\', '#'}) >= 0:
      raise newException(LlmError, "Invalid LLM method or API path")
  let route = path.split('?', 1)[0]
  for segment in route.split('/'):
    if segment in [".", ".."] or segment.contains('%'):
      raise newException(LlmError, "LLM path must stay under /v1/")
  if client.nextId == int32.high:
    raise newException(LlmError, "LLM request ID limit reached")
  var headers = @[("Content-Type", "application/json")]
  if client.config.sidecar:
    headers.add ("X-Coworld-Player-Slot", $client.slot)
  elif client.config.key.len > 0:
    headers.add ("Authorization", "Bearer " & client.config.key)
  try:
    client.request = startRequest(
      client.config.baseUrl & path,
      verb,
      body,
      headers,
      client.config.timeoutMs
    )
  except RequestError as error:
    raise newException(LlmError, error.msg)
  inc client.nextId
  client.pending = client.nextId
  client.lastAsk = client.tick
  client.asked = true
  client.nextId

proc chat*(client: LlmClient, model, prompt: string): int32 =
  ## Sends one ordinary user message using a caller or host selected model.
  let selected = if model.len > 0: model else: client.config.model
  if selected.len == 0:
    raise newException(LlmError, "LLM model is required")
  client.ask("POST", "/v1/chat/completions", $(%*{
    "model": selected, "messages": [{"role": "user", "content": prompt}]
  }))

proc reply*(client: LlmClient, id: int32): LlmReply =
  ## Reads a retained response, including HTTP error bodies.
  for reply in client.replies:
    if reply.id == id:
      return reply
  LlmReply(id: id, error: "Unknown or expired LLM request")

proc poll*(client: LlmClient, id: int32): int32 =
  ## Returns zero while pending, one on success, or minus one on failure.
  if id > 0 and id == client.pending:
    return 0
  if client.reply(id).error.len > 0: -1 else: 1

proc response*(client: LlmClient, id: int32): string =
  ## Returns raw JSON or the SSE bytes received so far for a streaming call.
  if id > 0 and id == client.pending and client.request != nil:
    return client.request.body
  client.reply(id).body

proc contentText(content: JsonNode): string =
  ## Reads text content while leaving non-text data in the raw response.
  if content == nil:
    return
  case content.kind
  of JString:
    result = content.getStr()
  of JArray:
    for part in content:
      if part.kind == JObject and part.hasKey("text") and
        part["text"].kind == JString:
          result.add part["text"].getStr()
  else:
    discard

proc documentText(document: JsonNode): string =
  ## Reads Chat Completions or Responses API text from a JSON document.
  let choices = document{"choices"}
  if choices != nil and choices.kind == JArray and choices.len > 0:
    result = contentText(choices[0]{"message", "content"})
    if result.len == 0:
      result = contentText(choices[0]{"delta", "content"})
  let output = document{"output"}
  if output != nil and output.kind == JArray:
    for item in output:
      result.add contentText(item{"content"})
  if document{"type"}.getStr() == "response.output_text.delta":
    result.add document{"delta"}.getStr()

proc text*(client: LlmClient, id: int32): string =
  ## Extracts ordinary text from completed JSON or received SSE events.
  let body = client.response(id)
  if body.strip().startsWith("{"):
    return documentText(parseDocument(body))
  for line in body.splitLines():
    if line.startsWith("data:"):
      let data = line[5 .. ^1].strip()
      if data.len == 0 or data == "[DONE]":
        continue
      try:
        result.add documentText(parseDocument(data))
      except LlmError:
        discard # An incomplete streaming event is retried next tick.
