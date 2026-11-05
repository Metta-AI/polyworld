## Importing the graphical frontend must not allocate a match or a window.
import std/unittest
import ../[game, graphics]

suite "LvD graphics lifecycle":
  test "menus do not require a hidden simulation or window at import":
    check run == nil
    check window == nil
    check transport.durationTicks == 0
