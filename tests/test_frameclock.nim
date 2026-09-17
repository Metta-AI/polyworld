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
