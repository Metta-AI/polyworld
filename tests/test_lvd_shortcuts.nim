import std/unittest
import ../games/light_vs_dark/[shortcuts, content, controls, maps, sim]

suite "LvD sequential shortcuts":
  test "B release B recognizes Barracks, not a simultaneous chord":
    var state: ShortcutState
    let first = state.pressShortcut(DefaultShortcuts, 'B', 1.0)
    check first.consumed
    check first.action == -1
    state.releaseShortcut('B')
    let second = state.pressShortcut(DefaultShortcuts, 'B', 1.1)
    check second.consumed
    check second.action == BuildBarracksShortcut.ord

  test "holding prefix never completes or refreshes its sequence":
    var state: ShortcutState
    discard state.pressShortcut(DefaultShortcuts, 'B', 1.0)
    let repeated = state.pressShortcut(DefaultShortcuts, 'B', 1.1)
    check repeated.consumed
    check repeated.action == -1
    state.releaseShortcut('B')
    check state.pressShortcut(DefaultShortcuts, 'B', 1.2).action == BuildBarracksShortcut.ord
    check state.pressShortcut(DefaultShortcuts, 'B', 1.3).action == -1

  test "menu stays open across arbitrary delays and repeated commands":
    var state: ShortcutState
    discard state.pressShortcut(DefaultShortcuts, 'B', 1.0)
    state.releaseShortcut('B')
    check state.pressShortcut(DefaultShortcuts, 'B', 3600.0).action == BuildBarracksShortcut.ord
    state.releaseShortcut('B')
    check state.pressShortcut(DefaultShortcuts, 'F', 7200.0).action == BuildFarmShortcut.ord
    state.releaseShortcut('F')
    # Unassigned keys do not eat unrelated gameplay shortcuts or close the menu.
    check not state.pressShortcut(DefaultShortcuts, 'Z', 8000.0).consumed
    state.releaseShortcut('Z')
    check state.pressShortcut(DefaultShortcuts, 'B', 9000.0).action == BuildBarracksShortcut.ord

  test "cancellation, modifiers and menus never leak a pending sequence":
    for reason in 1 .. 3:
      var state: ShortcutState
      discard state.pressShortcut(DefaultShortcuts, 'T', 1.0)
      state.releaseShortcut('T')
      case reason
      of 1:
        discard state.pressShortcut(DefaultShortcuts, '\e', 1.1)
      of 2:
        discard state.pressShortcut(DefaultShortcuts, 'X', 1.1, modified = true)
      of 3:
        discard state.pressShortcut(DefaultShortcuts, 'X', 1.1, gameplay = false)
      else:
        discard state.pressShortcut(DefaultShortcuts, 'Z', 1.1)
      check state.pressShortcut(DefaultShortcuts, 'S', 3.1).action == -1
    var state: ShortcutState
    check not state.pressShortcut(DefaultShortcuts, 'T', 1.0, modified = true).consumed
    state.releaseShortcut('T')
    check not state.pressShortcut(DefaultShortcuts, 'T', 1.1, gameplay = false).consumed

  test "recognized menu action consumes but unrelated keys fall through":
    var state: ShortcutState
    discard state.pressShortcut(DefaultShortcuts, 'T', 1.0)
    state.releaseShortcut('T')
    let archer = state.pressShortcut(DefaultShortcuts, 'A', 1.1)
    check archer.consumed
    check archer.action == TrainArcherShortcut.ord
    state.releaseShortcut('A')
    discard state.pressShortcut(DefaultShortcuts, 'B', 2.0)
    state.releaseShortcut('B')
    let mismatch = state.pressShortcut(DefaultShortcuts, 'A', 2.1)
    check not mismatch.consumed
    check mismatch.action == -1

  test "editing validates full sequences, rejects conflicts, persists and resets":
    var bindings = DefaultShortcuts
    check bindings.setShortcut(BuildBarracksShortcut, "b b") == ""
    check bindings == DefaultShortcuts
    check bindings.setShortcut(BuildBarracksShortcut, "T P").len > 0
    check bindings == DefaultShortcuts
    for invalid in ["", "B", "BBB", "B !", "Ctrl+B"]:
      check bindings.setShortcut(BuildBarracksShortcut, invalid).len > 0
      check bindings == DefaultShortcuts
    check bindings.setShortcut(BuildBarracksShortcut, "q 7") == ""
    check bindings[BuildBarracksShortcut] == "Q7"
    check decodeShortcuts(encodeShortcuts(bindings)) == bindings
    check decodeShortcuts("") == DefaultShortcuts
    expect ValueError:
      discard decodeShortcuts("not json")
    bindings.resetShortcuts()
    check bindings == DefaultShortcuts

  test "every content kind has an unambiguous build or train default":
    check DefaultShortcuts[BuildBarracksShortcut] == "BB"
    check DefaultShortcuts[TrainPeonShortcut] == "TP"
    check DefaultShortcuts[TrainSoldierShortcut] == "TS"
    check BuildBlacksmithShortcut.ord + 1 == BuildableHigh.ord + 1
    check TrainSummonShortcut.ord - TrainPeonShortcut.ord + 1 == UnitKind.high.ord + 1
    for action in ShortcutAction:
      check shortcutLabel(action).len > 0
      var state: ShortcutState
      let keys = DefaultShortcuts[action]
      check state.pressShortcut(DefaultShortcuts, keys[0], 1.0).consumed
      state.releaseShortcut(keys[0])
      check state.pressShortcut(DefaultShortcuts, keys[1], 1.1).action == action.ord

suite "LvD shortcut commands":
  setup:
    clearPlayerCommands()
    let world = newWorld(generateMap(DefaultSeed), TickRate * 60)
    let game = Game(world: world)
    world.players[LightPlayer].gold = 10000
    world.players[LightPlayer].wood = 10000
    world.players[LightPlayer].foodCap = 100
  teardown:
    clearPlayerCommands()

  test "build arms only with eligible owned selected worker and real prerequisites":
    let worker = world.units[0].id
    require world.units[0].kind == PeonUnit
    require world.units[0].owner == LightPlayer
    check world.performShortcut(LightPlayer, [worker], BuildFarmShortcut)
    check pendingBuild == FarmBuilding.ord
    pendingBuild = -1
    for player in [-1'i32, DarkPlayer, world.players.len.int32]:
      check not world.performShortcut(player, [worker], BuildFarmShortcut)
    check not world.performShortcut(LightPlayer, [], BuildFarmShortcut)
    world.units[0].state = UnitInMine
    check not world.performShortcut(LightPlayer, [worker], BuildFarmShortcut)
    world.units[0].state = UnitDying
    check not world.performShortcut(LightPlayer, [worker], BuildFarmShortcut)
    world.units[0].state = UnitIdle
    world.units[0].hp = 0
    check not world.performShortcut(LightPlayer, [worker], BuildFarmShortcut)
    world.units[0].hp = 40
    world.players[LightPlayer].gold = 0
    check not world.performShortcut(LightPlayer, [worker], BuildFarmShortcut)
    check pendingBuild == -1

  test "train queues through controls and revalidates affordability at flush":
    var hall = NoEntity
    for building in world.buildings:
      if building.owner == LightPlayer and building.kind == TownHallBuilding:
        hall = building.id
    require hall != NoEntity
    let index = world.buildingIndex(hall)
    let before = world.players[LightPlayer].gold
    check world.performShortcut(LightPlayer, [hall], TrainPeonShortcut)
    check world.buildings[index].queueLength == 0
    check world.players[LightPlayer].gold == before
    game.flushPlayerCommands()
    check world.buildings[index].queueLength == 1
    check world.players[LightPlayer].gold == before - unitOf(LightPlayer, PeonUnit).gold
    check not world.performShortcut(DarkPlayer, [hall], TrainPeonShortcut)
    check not world.performShortcut(LightPlayer, [hall], TrainSoldierShortcut)
    check world.performShortcut(LightPlayer, [hall], TrainPeonShortcut)
    world.players[LightPlayer].gold = 0
    game.flushPlayerCommands()
    check world.buildings[index].queueLength == 1
    check not world.performShortcut(LightPlayer, [hall], TrainPeonShortcut)
