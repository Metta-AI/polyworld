## Converts elapsed wall time into bounded fixed-rate simulation steps.
const
  DefaultStepMillis* = 100
  DefaultMaxSteps* = 10

type
  FrameClock* = object
    lastMillis*: int64

proc dueSteps*(clock: var FrameClock, nowMillis: int64,
    stepMillis = DefaultStepMillis, maxSteps = DefaultMaxSteps): int =
  ## Returns whole steps since the previous call and keeps the fractional part.
  if stepMillis <= 0 or maxSteps <= 0:
    return 0
  let elapsed = nowMillis - clock.lastMillis
  if elapsed < 0:
    clock.lastMillis = nowMillis
    return 0
  result = int(min(elapsed div stepMillis, maxSteps.int64))
  clock.lastMillis = nowMillis - elapsed mod stepMillis
