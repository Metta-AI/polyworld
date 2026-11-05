import std/[unittest, sets]
import polyworld/assets
import ../assets as lvdassets

suite "LvD menu browser assets":
  test "browser bundle includes every home image":
    let declared = lvdassets.browserAssets()
    var names: HashSet[string]
    for asset in declared:
      names.incl asset.output
    for name in ["background", "logo", "button-single-player", "button-multiplayer", "button-settings", "button-exit"]:
      check "themes/lvd/menu/" & name & ".png" in names
