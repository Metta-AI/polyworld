## Interpolates one accepted cardinal step for presentation only.

type
  GridPoint* = object
    x*, y*: int
  GridMotion* = object
    position*, target*: GridPoint
    started*, duration*: float64
    moving*: bool

proc start*(motion: var GridMotion, fromPoint, toPoint: GridPoint,
    now, duration: float64): bool =
  ## Nonadjacent moves and nonpositive durations snap to the target.
  ## Callers supply finite times and begin each step from its accepted origin.
  let dx = abs(toPoint.x.float64 - fromPoint.x.float64)
  let dy = abs(toPoint.y.float64 - fromPoint.y.float64)
  motion = GridMotion(position: toPoint, target: toPoint)
  if dx + dy != 1 or duration <= 0:
    return false
  motion.position = fromPoint
  motion.started = now
  motion.duration = duration
  motion.moving = true
  true

proc update*(motion: var GridMotion, now: float64): tuple[x, y: float64] =
  ## Returns fractional grid coordinates; a backward clock snaps to the target.
  if motion.moving:
    let amount = (now - motion.started) / motion.duration
    if amount < 0 or amount >= 1:
      motion.position = motion.target
      motion.moving = false
    else:
      return (
        motion.position.x.float64 +
          (motion.target.x.float64 - motion.position.x.float64) * amount,
        motion.position.y.float64 +
          (motion.target.y.float64 - motion.position.y.float64) * amount
      )
  (motion.position.x.float64, motion.position.y.float64)
