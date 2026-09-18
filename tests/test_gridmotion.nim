import std/unittest
import polyworld/gridmotion

suite "grid motion":
  test "preserves fractional positions in all four directions":
    let origin = GridPoint(x: 2, y: 3)
    for target in [GridPoint(x: 3, y: 3), GridPoint(x: 1, y: 3),
        GridPoint(x: 2, y: 4), GridPoint(x: 2, y: 2)]:
      var motion: GridMotion
      check motion.start(origin, target, 10, 1)
      let quarter = motion.update(10.25)
      check quarter.x == 2.0 + (target.x - 2).float64 * 0.25
      check quarter.y == 3.0 + (target.y - 3).float64 * 0.25
      check motion.moving
      check motion.update(11) == (target.x.float64, target.y.float64)
      check not motion.moving
      check motion.update(12) == (target.x.float64, target.y.float64)

  test "teleports and zero duration snap to the target":
    var motion: GridMotion
    check not motion.start(GridPoint(), GridPoint(x: 2), 10, 1)
    check motion.update(10) == (2.0, 0.0)
    check not motion.start(GridPoint(), GridPoint(x: 1, y: 1), 10, 1)
    check motion.update(10) == (1.0, 1.0)
    check not motion.start(GridPoint(), GridPoint(x: 1), 10, 0)
    check motion.update(10) == (1.0, 0.0)

  test "backward time ends the step instead of leaving stale motion":
    var motion: GridMotion
    check motion.start(GridPoint(), GridPoint(x: 1), 10, 1)
    check motion.update(9) == (1.0, 0.0)
    check not motion.moving
