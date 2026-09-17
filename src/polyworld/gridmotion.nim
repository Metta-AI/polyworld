## Interpolates accepted cardinal grid moves without inventing simulation state.
import std/math

type
  GridPoint* = object
    x*, y*: int
  GridMotion* = object
    position*: GridPoint
    target*: GridPoint
    started*, duration*: float64
    moving*: bool

proc adjacent(a, b: GridPoint): bool =
  abs(a.x - b.x) + abs(a.y - b.y) == 1

proc start*(motion: var GridMotion, fromPoint, toPoint: GridPoint,
    now, duration: float64): bool =
  if not adjacent(fromPoint, toPoint) or duration <= 0:
    motion.position = toPoint
    motion.target = toPoint
    motion.moving = false
    return false
  motion.position = fromPoint
  motion.target = toPoint
  motion.started = now
  motion.duration = duration
  motion.moving = true
  true

proc update*(motion: var GridMotion, now: float64): GridPoint =
  if not motion.moving:
    return motion.position
  let amount = clamp((now - motion.started) / motion.duration, 0.0, 1.0)
  result = GridPoint(
    x: int(round(motion.position.x.float64 + (motion.target.x - motion.position.x).float64 * amount)),
    y: int(round(motion.position.y.float64 + (motion.target.y - motion.position.y).float64 * amount)))
  if amount >= 1:
    motion.position = motion.target
    motion.moving = false
