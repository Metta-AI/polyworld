import
  std/strutils,
  content, sim

type
  SeekKind* = enum
    NoSeek, TickSeek, MorningSeek, DinnerSeek, ScorecardSeek
  SeekTarget* = object
    kind*: SeekKind
    value*: int32

proc parseSeekTarget*(flag, value: string): SeekTarget =
  proc number(text: string, allowZero: bool): int32 =
    if text.len == 0 or text.find(AllChars - Digits) >= 0:
      raise newException(ValueError, flag & " requires a non-negative integer")
    let n = parseBiggestInt(text)
    if n > int32.high or (n == 0 and not allowZero):
      raise newException(ValueError, flag & " target is out of range")
    int32(n)
  if flag == "--seek-tick":
    return SeekTarget(kind: TickSeek, value: number(value, true))
  let parts = value.split(':')
  if parts.len != 3 or parts[0] != "day":
    raise newException(ValueError, "--seek-event expects day:N:morning|dinner|scorecard")
  result.value = number(parts[1], false)
  case parts[2]
  of "morning": result.kind = MorningSeek
  of "dinner": result.kind = DinnerSeek
  of "scorecard": result.kind = ScorecardSeek
  else:
    raise newException(ValueError, "unknown seek event: " & parts[2])

proc reached*(target: SeekTarget, world: World): bool =
  case target.kind
  of NoSeek: true
  of TickSeek: world.tick == target.value
  of MorningSeek:
    world.day == target.value and world.phase == DaytimePhase
  of DinnerSeek:
    world.day == target.value and world.phase == EveningPhase
  of ScorecardSeek:
    world.day == target.value and world.phase == ScorePhase

proc validate*(target: SeekTarget, days, maximumTicks: int32) =
  if (target.kind == TickSeek and target.value > maximumTicks) or
      (target.kind in {MorningSeek, DinnerSeek, ScorecardSeek} and
       target.value > days):
    raise newException(ValueError, "seek target is outside this match")
