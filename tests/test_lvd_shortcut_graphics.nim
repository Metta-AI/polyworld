## Executes the actual graphics key callback, not a duplicate dispatcher.
import std/[unittest, macros, importutils]
import windy/internal
include ../games/light_vs_dark/graphics
privateAccess(Window)

macro keyHandler(): untyped =
  let source = parseStmt(staticRead("../games/light_vs_dark/graphics.nim"))
  for node in source:
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkAsgn and child[0].repr == "window.onButtonPress" and
            child[1].kind == nnkLambda:
          return child
  error("missing production key handler")

suite "LvD production shortcut routing":
  test "BB builds, TP trains, combat A wins over TA, menus and Ctrl stay isolated":
    window = newWindow("LvD shortcuts", ivec2(1600, 1000), visible = false)
    defer:
      window.close()
      window = nil
      run = nil
      clearPlayerCommands()
    sk = Silky(uiScale: 1)
    options.playerSlot = 1
    run = newGame(generateMap(DefaultSeed), TickRate * 60)
    run.world.players[0].gold = 10000
    run.world.players[0].wood = 10000
    run.world.players[0].foodCap = 100
    var
      matchMenu = HiddenMatchMenu
      preferences = Preferences()
      network: NetworkMatch
      scene: CharacterScene
      actionCam = initActionCam(subjectMode = true)
    proc playerMode(): bool = options.playerSlot > 0 and not run.replayMode
    keyHandler()
    inputBindings = LvdControlProfile.defaults
    bindingCapture = false
    selectedIds = @[run.world.units[0].id]
    commandTab = 1
    window.onButtonPress(KeyB)
    check commandTab == 0
    check pendingBuild == -1
    window.onButtonPress(KeyB)
    check pendingBuild == -1
    shortcutState.releaseShortcut('B')
    sleep(1400) # Former timeout must not close the actual production menu.
    window.onButtonPress(MouseLeft)
    window.onButtonPress(KeyB)
    check pendingBuild == BarracksBuilding.ord
    pendingBuild = -1
    shortcutState.resetShortcut()
    var hall = NoEntity
    for building in run.world.buildings:
      if building.owner == 0 and building.kind == TownHallBuilding: hall = building.id
    selectedIds = @[hall]
    window.onButtonPress(KeyT)
    check commandTab == 1
    shortcutState.releaseShortcut('T')
    sleep(1400)
    window.onButtonPress(KeyP)
    run.flushPlayerCommands()
    check run.world.buildings[run.world.buildingIndex(hall)].queueLength == 1
    shortcutState.resetShortcut()
    selectedIds = @[run.world.spawnUnit(0, SoldierUnit, tile2(30, 30))]
    window.onButtonPress(KeyT)
    shortcutState.releaseShortcut('T')
    window.onButtonPress(KeyA)
    check attackMoveArmed
    attackMoveArmed = false
    shortcutState.resetShortcut()
    matchMenu = MatchSettings
    window.onButtonPress(KeyB)
    shortcutState.releaseShortcut('B')
    window.onButtonPress(KeyB)
    check pendingBuild == -1
    matchMenu = HiddenMatchMenu
    shortcutState.resetShortcut()
    window.state.buttonDown = {KeyLeftSuper}
    window.onButtonPress(KeyT)
    shortcutState.releaseShortcut('T')
    window.state.buttonDown = {}
    window.onButtonPress(KeyP)
    run.flushPlayerCommands()
    check run.world.buildings[run.world.buildingIndex(hall)].queueLength == 1

    # T S must train, whereas standalone S stops current and queued moves.
    shortcutState.resetShortcut()
    let soldier = selectedIds[0]
    let worker = run.world.units[0].id
    let barracks = hall
    run.world.buildings[run.world.buildingIndex(hall)].kind = BarracksBuilding
    selectedIds = @[barracks, soldier, worker]
    for id in [soldier, worker]:
      require run.world.applyMove(0, id, 40, 40)
      require run.world.applyMove(0, id, 41, 40, append = true)
    window.onButtonPress(KeyT)
    shortcutState.releaseShortcut('T')
    window.onButtonPress(KeyS)
    run.flushPlayerCommands()
    check run.world.buildings[run.world.buildingIndex(barracks)].queueLength == 2
    for id in [soldier, worker]:
      check run.world.units[run.world.unitIndex(id)].state == UnitMoving
      check run.world.units[run.world.unitIndex(id)].orderQueue.len == 1
    shortcutState.resetShortcut()
    selectedIds = @[soldier, worker]
    window.onButtonPress(KeyS)
    run.flushPlayerCommands()
    for id in [soldier, worker]:
      check run.world.units[run.world.unitIndex(id)].state == UnitIdle
      check run.world.units[run.world.unitIndex(id)].orderQueue.len == 0
    shortcutState.resetShortcut()
    selectedIds = @[worker]
    window.onButtonPress(KeyA)
    check attackMoveArmed
    window.onButtonPress(KeyEscape)
    check not attackMoveArmed
    check matchMenu == HiddenMatchMenu
    shortcutState.resetShortcut()
    inputBindings[AttackMoveInput] = [KeyF, ButtonUnknown]
    window.onButtonPress(KeyA)
    check not attackMoveArmed
    window.onButtonPress(KeyF)
    check attackMoveArmed
    inputBindings[StopInput] = [KeyJ, ButtonUnknown]
    window.onButtonPress(KeyJ)
    check not attackMoveArmed
    inputBindings = LvdControlProfile.defaults

    # Producer-only selection retains Archer; combat selection owns A instead.
    shortcutState.resetShortcut()
    run.world.buildings.add Building(owner: 0, kind: LumberMillBuilding,
      state: BuildingComplete, hp: 100)
    require run.world.canTrain(barracks, ArcherUnit)
    selectedIds = @[barracks]
    window.onButtonPress(KeyT)
    shortcutState.releaseShortcut('T')
    window.onButtonPress(KeyA)
    run.flushPlayerCommands()
    check not attackMoveArmed
    check run.world.buildings[run.world.buildingIndex(barracks)].queueLength == 3

    # Text and modal owners precede both persistent menu and combat dispatch.
    resetHumanCommunication()
    shortcutState.resetShortcut()
    selectedIds = @[soldier]
    window.onButtonPress(KeyEnter)
    require humanCommunicationBlocksGameplay()
    for key in [KeyB, KeyT, KeyA]: window.onButtonPress(key)
    check not attackMoveArmed
    check pendingBuild == -1
    resetHumanCommunication()
    matchMenu = MatchSettings
    window.onButtonPress(KeyA)
    check not attackMoveArmed
    matchMenu = HiddenMatchMenu
    bindingCapture = true
    window.onButtonPress(KeyA)
    check not attackMoveArmed
    bindingCapture = false
