import std/unittest
import windy
import polyworld/inputs
import ../games/light_vs_dark/lobbies

suite "LvD Stop binding migration":
  test "S stops and never pans by default; X retains cancel alias":
    check LvdControlProfile.defaults[StopInput] == [KeyS, KeyX]
    check LvdControlProfile.defaults[PanInput] == [MouseMiddle, ButtonUnknown]

  test "exact old defaults upgrade independently and idempotently":
    var bindings = LvdControlProfile.defaults
    bindings[StopInput] = [KeyX, ButtonUnknown]
    bindings[PanInput] = [MouseMiddle, KeyS]
    bindings[CameraInput] = [KeyJ, KeyK]
    bindings.migrateLvdBindings()
    check bindings[StopInput] == [KeyS, KeyX]
    check bindings[PanInput] == [MouseMiddle, ButtonUnknown]
    check bindings[CameraInput] == [KeyJ, KeyK]
    let once = bindings
    bindings.migrateLvdBindings()
    check bindings == once

  test "custom stop and pan bindings survive migration":
    var bindings = LvdControlProfile.defaults
    bindings[StopInput] = [KeyH, KeyJ]
    bindings[PanInput] = [KeyS, KeyK]
    let custom = bindings
    bindings.migrateLvdBindings()
    check bindings == custom
