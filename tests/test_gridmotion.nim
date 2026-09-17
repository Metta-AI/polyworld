import std/unittest
import polyworld/gridmotion

suite "grid motion":
  test "interpolates an accepted cardinal move":
    var motion: GridMotion
    check motion.start(GridPoint(x: 2, y: 3), GridPoint(x: 3, y: 3), 10, 1)
    check motion.update(10.5) == GridPoint(x: 3, y: 3)
    check motion.moving
    check motion.update(11) == GridPoint(x: 3, y: 3)
    check not motion.moving
  test "snaps invalid moves to the authoritative target":
    var motion: GridMotion
    check not motion.start(GridPoint(x: 2, y: 3), GridPoint(x: 4, y: 3), 10, 1)
    check motion.position == GridPoint(x: 4, y: 3)
