import
  std/[json, os, strutils, tables],
  bassy, jsony,
  llms, oracles, timings

export llms.LlmConfig

type
  Advisor* = ref object
    runtime {.cursor.}: Runtime
    oracle*: Oracle
    tick: int32
  AdvisorFunction = enum
    LlmAvailable, LlmReady, LlmAsk, LlmRequest, LlmPoll, LlmStatus,
    LlmResponse, LlmRead, LlmText, LlmErrorText, JsonQuote, JsonGet,
    OracleAvailable, OracleReady, OracleState, OracleStateText, OracleNote,
    OracleQuestion, OracleCriterion, OracleCriterionField, OracleAsk,
    OraclePoll, OracleAnswer, OracleConfidence, OracleProbability

const
  FunctionNames: array[AdvisorFunction, string] = [
    "llmAvailable", "llmReady", "llmAsk", "llmRequest", "llmPoll", "llmStatus",
    "llmResponse$", "llmRead$", "llmText$", "llmError$", "jsonQuote$", "jsonGet$",
    "oracleAvailable", "oracleReady", "oracleState", "oracleStateText",
    "oracleNote", "oracleQuestion", "oracleCriterion", "oracleCriterionField",
    "oracleAsk", "oraclePoll", "oracleAnswer", "oracleConfidence",
    "oracleProbability"
  ]
  FunctionParameters: array[AdvisorFunction, int] = [
    0, 0, 2, 3, 1, 1, 1, 3, 1, 1, 1, 2,
    0, 0, 2, 2, 1, 3, 3, 4, 0, 1, 2, 2, 3
  ]

proc newAdvisor*(slot: int, config: LlmConfig): Advisor =
  ## Creates a seat-local advisor without owning its BASIC runtime.
  Advisor(oracle: newOracle(newLlmClient(slot, config)))

proc newAdvisor*(slot: int): Advisor =
  ## Reads host configuration once when constructing a player's VM.
  result = newAdvisor(slot, llmConfig())
  result.oracle.enabled = getEnv("COGAME_ORACLE").toLowerAscii != "off"

proc bindRuntime*(advisor: Advisor, runtime: Runtime) =
  ## Borrows the runtime that owns these callbacks, avoiding a ref cycle.
  advisor.runtime = runtime

proc beginTick*(advisor: Advisor, tick: int32) =
  ## Advances asynchronous replies at a deterministic decision boundary.
  advisor.oracle.beginTick(tick)
  advisor.tick = tick

proc requestPoller*(advisor: Advisor): RequestPoll =
  ## Polls this seat during the shared barrier without rerunning BASIC.
  result = proc(): bool =
    ## Delivers completed replies while keeping the simulation tick fixed.
    advisor.oracle.beginTick(advisor.tick)
    advisor.oracle.client.hasPending()

proc decisionCallback*(advisor: Advisor): proc(tick: int32) =
  ## Keeps inference state outside the deterministic simulation modules.
  result = proc(tick: int32) =
    ## Advances the state belonging to this VM only.
    advisor.beginTick(tick)

proc jsonGet(document: JsonNode, path: string): string =
  ## Reads an RFC 6901 pointer as text or serialized JSON for non-strings.
  var current = document
  if path.len > 0:
    if path[0] != '/':
      raise newException(LlmError, "JSON pointer must start with a slash")
    for part in path[1 .. ^1].split('/'):
      if current == nil:
        return ""
      let key = part.replace("~1", "/").replace("~0", "~")
      case current.kind
      of JObject:
        current = current{key}
      of JArray:
        var index: int
        try:
          index = parseInt(key)
        except ValueError:
          return ""
        if index < 0 or index >= current.len:
          return ""
        current = current[index]
      else:
        return ""
  if current == nil:
    return ""
  if current.kind == JString: current.getStr() else: $current

proc callback(advisor: Advisor, kind: AdvisorFunction): NumericHostProc =
  ## Binds one explicit operation to a single player's state.
  result = proc(arguments: openArray[Value]): Value =
    ## Converts script values at the BASIC boundary.
    template text(index: int): string =
      ## Reads a string from this runtime's bounded string store.
      advisor.runtime.getString(arguments[index])
    template integer(index: int): int32 =
      ## Rejects fractional values where the API requires an integer.
      arguments[index].asInt()
    template output(value: string): Value =
      ## Allocates a result in BASIC's bounded string store.
      advisor.runtime.putString(value)
    let
      oracle = advisor.oracle
      client = oracle.client
    try:
      case kind
      of LlmAvailable:
        result = int32(client.available)
      of LlmReady:
        result = client.ready
      of LlmAsk:
        result = client.chat(text(0), text(1))
      of LlmRequest:
        result = client.ask(text(0), text(1), text(2))
      of LlmPoll:
        result = client.poll(integer(0))
      of LlmStatus:
        result = client.reply(integer(0)).status
      of LlmResponse:
        result = output(client.response(integer(0)))
      of LlmRead:
        let
          body = client.response(integer(0))
          offset = integer(1)
          count = integer(2)
        if offset < 0 or count < 0:
          raise newException(LlmError, "LLM slice must be nonnegative")
        let start = min(int(offset), body.len)
        result = output(body[start ..< start + min(int(count), body.len - start)])
      of LlmText:
        result = output(client.text(integer(0)))
      of LlmErrorText:
        result = output(client.reply(integer(0)).error)
      of JsonQuote:
        result = output(text(0).toJson())
      of JsonGet:
        result = output(jsonGet(parseDocument(text(0)), text(1)))
      of OracleAvailable:
        result = int32(oracle.available)
      of OracleReady:
        result = oracle.ready
      of OracleState:
        result = oracle.state(text(0), %integer(1))
      of OracleStateText:
        result = oracle.state(text(0), %text(1))
      of OracleNote:
        result = oracle.note(text(0))
      of OracleQuestion:
        result = oracle.question(text(0), integer(1), text(2))
      of OracleCriterion:
        result = oracle.criterion(text(0), text(1), text(2))
      of OracleCriterionField:
        result = oracle.criterionField(text(0), text(1), text(2), text(3))
      of OracleAsk:
        result = oracle.ask()
      of OraclePoll:
        result = oracle.poll(integer(0))
      of OracleAnswer:
        result = oracle.answer(integer(0), text(1)).value
      of OracleConfidence:
        result = oracle.answer(integer(0), text(1)).confidence
      of OracleProbability:
        result = oracle.answer(integer(0), text(1)).probabilities.getOrDefault(
          text(2), -1'i32
        )
    except LlmError, OracleError:
      raise newException(BasicError, getCurrentExceptionMsg())

proc addFunctions*(advisor: Advisor, host: var Host) =
  ## Registers typed Jev helpers and lossless OpenRouter request access.
  for kind in AdvisorFunction:
    discard host.addFunction(
      FunctionNames[kind],
      FunctionParameters[kind],
      advisor.callback(kind),
      256
    )
