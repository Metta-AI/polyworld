import std/unittest
import polyworld/webbackdrop

suite "web backdrop":
  test "retains a blocking backdrop":
    var backdrop: WebBackdrop
    check backdrop.drawWorld(visible, 960, 640, false)
    check backdrop.drawWorld(blocking, 960, 640, false)
    check not backdrop.drawWorld(blocking, 960, 640, false)
  test "hides and restores on revision":
    var backdrop: WebBackdrop
    check not backdrop.drawWorld(hidden, 960, 640, true)
    check backdrop.drawWorld(blocking, 960, 640, false, 2)
    check not backdrop.drawWorld(blocking, 960, 640, false, 2)
  test "throttles unfocused frames without catch-up":
    var backdrop: WebBackdrop
    check backdrop.drawWorld(unfocused, 960, 640, false, 0, 0)
    check not backdrop.drawWorld(unfocused, 960, 640, false, 0, 999)
    check backdrop.drawWorld(unfocused, 960, 640, false, 0, 1000)
    check backdrop.drawWorld(visible, 960, 640, false, 1, 1001)
