## Verify the unit loop uses authoritative inputs, without replacing tooltips.
import std/[os, strutils, unittest]

suite "LvD training command integration":
  test "faction and queue count come from the current player and primary producer":
    let source = readFile(currentSourcePath().parentDir / "../ui.nim")
    let start = source.find("  elif commandTab == 1:")
    let finish = source.find("  else:", start)
    let units = source[start ..< finish]
    check units.contains("sk.drawTrainPortrait(")
    check units.contains("teamColors[player]")
    check units.contains("run.world.trainingQueueCount(player, primaryId, kind)")
    check units.contains("queueTrain(player, primaryId, int32(kind.ord))")
    check units.contains("unitTooltipTarget(kind, player)")
    check units.contains("sk.drawTrainCosts(")
