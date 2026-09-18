import std/unittest
import polyworld/frameclock

suite "frame clock":
  test "keeps fractional elapsed time":
    var clock: FrameClock
    check clock.dueSteps(99) == 0
    check clock.dueSteps(116) == 1
    check clock.dueSteps(250) == 1
    check clock.dueSteps(300) == 1
  test "bounds catch-up and rebases backward time":
    var clock: FrameClock
    check clock.dueSteps(86_400_073) == 10
    check clock.lastMillis == 86_400_000
    check clock.dueSteps(200) == 0
    check clock.lastMillis == 200
  test "accepts explicit step and batch limits":
    var clock: FrameClock
    check clock.dueSteps(25, 10, 2) == 2
    check clock.dueSteps(30, 10, 2) == 1

  test "different display rates emit the same simulation time":
    for fps in [24, 60, 144, 250]:
      var clock = FrameClock(lastMillis: 1000)
      var steps = 0
      for frame in 1..fps * 60:
        steps += clock.dueSteps(1000 + frame.int64 * 1000 div fps)
      check steps == 600

  test "long stalls discard whole-step debt but retain the remainder":
    var clock: FrameClock
    check clock.dueSteps(1073) == 10
    check clock.dueSteps(1099) == 0
    check clock.dueSteps(1100) == 1
