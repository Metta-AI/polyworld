## Converts elapsed wall time into bounded fixed-rate simulation steps.
const
  DefaultStepMillis* = 100
  DefaultMaxSteps* = 10

type
  FrameClock* = object
    lastMillis*: int64

proc dueSteps*(clock: var FrameClock, nowMillis: int64,
    stepMillis: Positive = DefaultStepMillis,
    maxSteps: Positive = DefaultMaxSteps): int =
  ## Returns whole steps since the previous call and keeps the fractional part.
  ## Initialize lastMillis to the first timestamp. Use nonnegative milliseconds
  ## and a constant stepMillis. Reassign lastMillis when resuming a paused game.
  if nowMillis < clock.lastMillis:
    clock.lastMillis = nowMillis
    return 0
  let elapsed = nowMillis - clock.lastMillis
  result = int(min(elapsed div stepMillis, maxSteps.int64))
  clock.lastMillis = nowMillis - elapsed mod stepMillis
