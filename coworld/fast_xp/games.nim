import
  std/[os, strutils]

type Game* = enum
  Gota, Paintbot

proc configuredGame(): Game =
  ## Selects one game for this server process.
  case getEnv("FAST_XP_GAME", "gota")
  of "gota": Gota
  of "paintbot-pw": Paintbot
  else: raise newException(ValueError, "FAST_XP_GAME must be gota or paintbot-pw")

let SelectedGame* = configuredGame()

proc gameName*(): string =
  ## Returns the selected public game identifier.
  if SelectedGame == Paintbot: "paintbot-pw" else: "gota"

proc seatCount*(): int =
  ## Returns the league roster size.
  if SelectedGame == Paintbot: 16 else: 10

proc sourceLimit*(): int =
  ## Returns the game's BASIC source limit in bytes.
  if SelectedGame == Paintbot: 128 * 1024 else: 64 * 1024

proc packageLimit*(): int =
  ## Includes the complete production package, not only its model.
  16 * 1024 * 1024 + (if SelectedGame == Paintbot: 128 * 1024 + 8192 + 4096 else: 0)

proc bodyLimit*(): int =
  ## Bounds a complete base64 roster plus JSON overhead.
  if SelectedGame == Paintbot: 352 * 1024 * 1024 else: 224 * 1024 * 1024

proc defaultTicks*(): int =
  ## Uses the selected league's default duration.
  if SelectedGame == Paintbot: 14400 else: 28800

proc workerPath*(): string =
  ## Resolves the selected game's native executable.
  if SelectedGame == Paintbot:
    getEnv("FAST_XP_PAINTBOT_WORKER", getAppDir() / "paintbot_worker")
  else:
    getEnv("FAST_XP_GOTA_WORKER", getAppDir() / "gota_worker")

proc executionSeconds*(): int =
  ## Bounds game execution independently of queue time.
  result = parseInt(getEnv("FAST_XP_EXECUTION_SECONDS", if SelectedGame == Paintbot: "300" else: "120"))
  if result < 1 or result > 3600:
    raise newException(ValueError, "FAST_XP_EXECUTION_SECONDS must be 1–3600")

proc runPath*(): string =
  ## Returns the enabled run endpoint.
  "/v1/games/" & gameName() & "/run"
