import std/strutils, jsony, bassy, cli

type
  PlayerDiagnostics* = object
    text*: string
    failed*: bool

var
  config*: GameConfig
  sources: seq[string]
  logs*: seq[PlayerDiagnostics]

const
  PlayerLogLimit = 10 * 1024 * 1024
  Truncation = "\n[Player log truncated at 10 MiB.]\n"

proc playerLog(slot: int, text: string) =
  if logs[slot].text.len >= PlayerLogLimit:
    return
  let remaining = PlayerLogLimit - Truncation.len - logs[slot].text.len
  if text.len <= remaining:
    logs[slot].text.add text
  else:
    if remaining > 0:
      logs[slot].text.add text[0 ..< remaining]
    logs[slot].text.add Truncation

proc playerError*(slot: int, message: string) =
  logs[slot].failed = true
  playerLog(slot, "\nBASIC error: " & message & "\n")

proc playerPrinter*(slot: int): PrintProc =
  result = proc(event: PrintEvent) =
    case event.kind
    of TextPrint: playerLog(slot, event.text)
    of ValuePrint: playerLog(slot, $event.value)
    of FixedPrint: playerLog(slot, $event.fixedValue)
    of NewlinePrint: playerLog(slot, "\n")

proc compilePlayer*(source: string, host: Host, limits: Limits, slot: int): Program =
  try:
    result = compile(source, host, limits)
  except BasicError as error:
    playerError(slot, error.msg)
    raise newException(ValueError, "BASIC compilation failed for player slot " & $slot)

proc readPlayerSource*(slot: string): string =
  sources[parseInt(slot)]

proc initialize*(bytes: string, policies: seq[string], slotCount: int): GameOptions =
  config = bytes.fromJson(GameConfig)
  if policies.len != slotCount or config.players.len != slotCount:
    raise newException(ValueError, "Coworld roster does not match the game")
  if config.maxTicks <= 0 or config.maxTicks > DefaultDurationTicks or
      config.spawnIntervalTicks <= 0:
    raise newException(ValueError, "Coworld tick limits are invalid")
  sources = policies
  logs.setLen(slotCount)
  result = GameOptions(seed: config.seed, maximumTicks: config.maxTicks,
    seconds: config.maxTicks div SharedTickRate,
    spawnIntervalTicks: config.spawnIntervalTicks)
  for slot, source in sources:
    if source.len > 256 * 1024:
      raise newException(ValueError, "Player source exceeds 256 KiB")
    result.botGroups.add BotGroup(path: $slot, count: 1)
    playerLog(slot, "Player slot " & $slot & " started.\n")

proc finishLogs*() =
  for slot in 0 ..< logs.len:
    playerLog(slot, "\nPlayer slot " & $slot & " completed.\n")
