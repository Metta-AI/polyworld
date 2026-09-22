import content

const
  ScoreXpPerMinute* = 200
  TicksPerMinute = int64(TickRate * 60)

proc score*(xp, ticks: int, xpPerMinute = ScoreXpPerMinute): int =
  ## Returns nonnegative whole points, rounding down after the time penalty.
  let scaled = int64(xp) * TicksPerMinute -
    int64(xpPerMinute) * int64(ticks)
  int(max(0'i64, scaled) div TicksPerMinute)

proc scores*(totalXp: openArray[int], ticks: int): seq[int] =
  ## Returns tournament scores in platform seat order.
  for xp in totalXp:
    result.add score(xp, ticks)
