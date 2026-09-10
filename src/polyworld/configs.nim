import
  std/strutils

const
  SharedTickRate* = 24'i32
    ## Simulation ticks per second used by every Polyworld game.
  DefaultMinutes* = 20'i32
    ## Default match length in minutes.
  DefaultDurationTicks* = DefaultMinutes * 60 * SharedTickRate
    ## Twenty minutes at the shared tick rate.

type
  PlayerConfig* = object
    name*: string

  GameConfig* = object
    players*: seq[PlayerConfig]
    seed*: int32 = 2026
    maxTicks*: int32 = DefaultDurationTicks
    spawnIntervalTicks*: int32 = 240
    playerSlot*: int32
    dayCount*: int32

proc renameHook*(value: var GameConfig, fieldName: var string) =
  ## Maps the platform's snake case config fields to Nim field names.
  var
    name: string
    upper = false
  for character in fieldName:
    if character == '_':
      upper = true
    else:
      name.add(if upper: character.toUpperAscii else: character)
      upper = false
  fieldName = name

proc displayName*(player: PlayerConfig, slot: int): string =
  ## Formats a player label without changing the recorded configuration.
  for character in player.name:
    result.add:
      if character.ord < 32 or character.ord == 127:
        ' '
      else:
        character
  result = result.strip()
  if result.toLowerAscii().endsWith(".bas"):
    result.setLen(result.len - 4)
    result = result.strip()
  if result.len == 0:
    result = "Player " & $(slot + 1)

proc unnamedPlayers*(count: int): seq[PlayerConfig] =
  ## Creates public records for slots without a bot file or hosted roster.
  for slot in 0 ..< count:
    result.add PlayerConfig(name: "Player " & $(slot + 1))
