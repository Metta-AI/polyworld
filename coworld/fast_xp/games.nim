import
  std/[json, os, strutils]

type Game* = enum
  Gota, Paintbot, Awm

proc gameName*(game = Gota): string =
  ## Returns the public game identifier.
  case game
  of Gota: "gota"
  of Paintbot: "paintbot-pw"
  of Awm: "awm"

proc seatCount*(game = Gota): int =
  ## Returns the league roster size.
  case game
  of Gota: 10
  of Paintbot: 16
  of Awm: 5

proc sourceLimit*(game = Gota): int =
  ## Returns the game's BASIC source limit in bytes.
  case game
  of Gota: 64 * 1024
  of Paintbot: 128 * 1024
  of Awm: 256 * 1024

proc packageLimit*(game = Gota): int =
  ## Bounds the complete production package.
  16 * 1024 * 1024 + (if game == Paintbot: 128 * 1024 + 8192 + 4096 else: 0)

proc defaultTicks*(game = Gota): int =
  ## Uses the game's league duration.
  if game == Paintbot: 14400 else: 28800

proc workerCommand*(game: Game): seq[string] =
  ## Reads an argument array without interpreting caller-controlled shell text.
  let key = case game
    of Gota: "FAST_XP_GOTA_COMMAND"
    of Paintbot: "FAST_XP_PAINTBOT_COMMAND"
    of Awm: "FAST_XP_AWM_COMMAND"
  let value = getEnv(key)
  if value.len > 0:
    let command = parseJson(value)
    if command.kind != JArray or command.len == 0:
      raise newException(ValueError, "Game command must be a nonempty JSON argument array")
    for argument in command:
      if argument.kind != JString or '\0' in argument.getStr():
        raise newException(ValueError, "Game command arguments must be strings without NUL characters")
      result.add argument.getStr()
    if result[0].len == 0: raise newException(ValueError, "Game executable must not be empty")
  elif game == Gota:
    result = @[getEnv("FAST_XP_GOTA_WORKER", getAppDir() / "gota_worker")]
  elif game == Awm:
    result = @[getAppDir() / "awm"]

proc commandInstalled(game: Game): bool =
  ## Checks the executable before accepting requests for this game.
  let command = workerCommand(game)
  command.len > 0 and (fileExists(command[0]) or findExe(command[0]).len > 0)

proc configuredGames(): array[Game, bool] =
  ## Detects installed games or validates an explicit deployment selection.
  let selection = getEnv("FAST_XP_GAMES")
  if selection.len == 0:
    for game in Game: result[game] = commandInstalled(game)
  else:
    for name in selection.split(','):
      var found = false
      for game in Game:
        if name.strip() == gameName(game):
          if not commandInstalled(game):
            raise newException(ValueError, "Game command is not installed: " & name)
          result[game] = true
          found = true
      if not found: raise newException(ValueError, "Unknown FAST_XP_GAMES entry: " & name)
  if result == default(array[Game, bool]):
    raise newException(ValueError, "Install a game executable or configure a game command")

let EnabledGames* = configuredGames()

proc bodyLimit*(): int =
  ## Bounds the largest enabled game's base64 roster and JSON overhead.
  if EnabledGames[Paintbot]: 352 * 1024 * 1024 else: 224 * 1024 * 1024

proc executionSeconds*(game = Gota): int =
  ## Bounds execution independently of queue time.
  result = parseInt(getEnv("FAST_XP_EXECUTION_SECONDS", if game == Paintbot: "300" else: "120"))
  if result < 1 or result > 3600:
    raise newException(ValueError, "FAST_XP_EXECUTION_SECONDS must be 1–3600")

proc runPath*(game = Gota): string =
  ## Returns the game's run endpoint.
  "/v1/games/" & gameName(game) & "/run"
