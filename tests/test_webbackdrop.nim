import std/unittest
import polyworld/webbackdrop

suite "browser frame scheduling":

  test "world animates continuously and a panel retains its first complete frame":
    var backdrop: WebBackdrop
    check backdrop.drawWorld(visible, 960, 640, false)
    check backdrop.drawWorld(visible, 960, 640, false)
    check backdrop.drawWorld(blocking, 960, 640, false)
    check not backdrop.drawWorld(blocking, 960, 640, false)
    check backdrop.drawWorld(visible, 960, 640, false)
    check backdrop.drawWorld(visible, 960, 640, false)

  test "scene changes and physical resize refresh the retained frame":
    var backdrop: WebBackdrop
    check backdrop.drawWorld(blocking, 960, 640, false)
    check backdrop.drawWorld(blocking, 960, 640, true)
    check not backdrop.drawWorld(blocking, 960, 640, false)
    check backdrop.drawWorld(blocking, 1920, 1280, false)
    check not backdrop.drawWorld(blocking, 1920, 1280, false)

  test "hidden pages never draw and restoration refreshes even a blocking panel":
    var backdrop: WebBackdrop
    check not backdrop.drawWorld(hidden, 960, 640, true)
    check backdrop.drawWorld(blocking, 960, 640, true)
    check not backdrop.drawWorld(hidden, 960, 640, false)
    check not backdrop.drawWorld(hidden, 1920, 1280, true)
    check backdrop.drawWorld(blocking, 1920, 1280, false)
    check not backdrop.drawWorld(blocking, 1920, 1280, false)

  test "visibility events force restoration even when rAF never observed hidden":
    var backdrop: WebBackdrop
    check backdrop.drawWorld(blocking, 960, 640, false, 0)
    check not backdrop.drawWorld(blocking, 960, 640, false, 0)
    check backdrop.drawWorld(blocking, 960, 640, false, 2)
    check not backdrop.drawWorld(blocking, 960, 640, false, 2)

  test "unfocused visible worlds draw at one Hz while focus restores immediately":
    var backdrop: WebBackdrop
    var frames = 0
    for milliseconds in 0'i64..<1000'i64:
      if backdrop.drawWorld(unfocused, 960, 640, false, 0, milliseconds):
        inc frames
    check frames == 1
    # Real focus changes must not wait for the pending background deadline.
    check backdrop.drawWorld(visible, 960, 640, false, 1, 1001)
    check backdrop.drawWorld(visible, 960, 640, false, 1, 1002)
    check backdrop.drawWorld(unfocused, 960, 640, false, 2, 1003)
    check not backdrop.drawWorld(unfocused, 960, 640, false, 2, 1004)

  test "background scene resize and focus events invalidate before the cadence deadline":
    var backdrop: WebBackdrop
    check backdrop.drawWorld(unfocused, 960, 640, false, 0, 0)
    check not backdrop.drawWorld(unfocused, 960, 640, false, 0, 20)
    check backdrop.drawWorld(unfocused, 960, 640, true, 0, 21)
    check backdrop.drawWorld(unfocused, 1920, 1280, false, 0, 22)
    check backdrop.drawWorld(unfocused, 1920, 1280, false, 2, 23)
    check not backdrop.drawWorld(unfocused, 1920, 1280, false, 2, 24)
    check backdrop.drawWorld(blocking, 1920, 1280, false, 2, 25)
    # Panels retain their backdrop even after the unfocused-world deadline.
    check not backdrop.drawWorld(blocking, 1920, 1280, false, 2, 1000)
    check backdrop.drawWorld(blocking, 1920, 1280, false, 4, 1001)
    check not backdrop.drawWorld(blocking, 1920, 1280, false, 4, 1002)

  test "hidden pages do not draw and long background gaps never catch up in a burst":
    var backdrop: WebBackdrop
    check backdrop.drawWorld(unfocused, 960, 640, false, 0, 0)
    check not backdrop.drawWorld(hidden, 1920, 1280, true, 1, 1000)
    check not backdrop.drawWorld(hidden, 1920, 1280, true, 1, 2000)
    check backdrop.drawWorld(unfocused, 1920, 1280, false, 2, 2001)
    check not backdrop.drawWorld(unfocused, 1920, 1280, false, 2, 2002)
    check backdrop.drawWorld(unfocused, 1920, 1280, false, 2, 10000)
    for milliseconds in 10001'i64..<11000'i64:
      check not backdrop.drawWorld(unfocused, 1920, 1280, false, 2, milliseconds)
    check backdrop.drawWorld(unfocused, 1920, 1280, false, 2, 11000)
