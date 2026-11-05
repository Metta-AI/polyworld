## Exercise the same HUD layout and hit testing used by battlefield input.
import std/unittest
import vmath, windy
import polyworld/[gameuis, player, rooms, roomclients]
import ../[game, sim, ui, layouts, multiplayer]

suite "LvD gameplay transport":
  test "a local human has no transport or blocked bottom battlefield strip":
    let window = newWindow("LvD transport regression", ivec2(1600, 1000),
      visible = false)
    defer: window.close()
    run = Game()
    options.playerSlot = 1
    defer:
      run = nil
      options.playerSlot = 0
    let layout = currentLayout(window)
    check not playbackControlsVisible()
    check layout.transportHeight == 0
    check layout.gameAreaSize == layout.size
    check not mouseOverUi(window, vec2(layout.size.x / 2, layout.size.y - 1))
    let bottom = layout.panel(GameUiRegion.BottomLeft, PanelSelection)
    check bottom.origin.y + bottom.size.y == layout.size.y - layout.margin
    check mouseOverUi(window, bottom.origin + bottom.size / 2)

  test "a network bot owner is a controller, not a spectator":
    let window = newWindow("LvD network transport regression", ivec2(1600, 1000),
      visible = false)
    defer: window.close()
    run = Game(networked: true)
    options.playerSlot = 0
    hudNetwork = NetworkMatch(client: RoomClient(participant: 7,
      snapshot: RoomMessage(seats: @[
        Seat(owner: 7, name: "Basic bot"), Seat(owner: 9, name: "Human")
      ])))
    defer:
      run = nil
      hudNetwork = nil
    let layout = currentLayout(window)
    check not playbackControlsVisible()
    check layout.transportHeight == 0
    check not mouseOverUi(window, vec2(layout.size.x / 2, layout.size.y - 1))

  test "replays and unowned watches retain transport, including layout input":
    let window = newWindow("LvD viewer transport regression", ivec2(1600, 1000),
      visible = false)
    defer: window.close()
    run = Game()
    defer:
      run = nil
      hudNetwork = nil
      options.playerSlot = 0
    for replay in [false, true]:
      run.replayMode = replay
      options.playerSlot = if replay: 2 else: 0
      check playbackControlsVisible()
      let layout = currentLayout(window)
      check layout.transportHeight == TransportHeight
      check layout.gameAreaSize.y == layout.size.y - TransportHeight
      check mouseOverUi(window, vec2(layout.size.x / 2, layout.size.y - 1))
      let bottom = layout.panel(GameUiRegion.BottomLeft, PanelSelection)
      check bottom.origin.y + bottom.size.y ==
        layout.size.y - TransportHeight - layout.margin
    run.replayMode = false
    options.playerSlot = 0
    hudNetwork = NetworkMatch(client: RoomClient(participant: 8,
      snapshot: RoomMessage(seats: @[Seat(owner: 7, name: "Basic bot")])))
    check playbackControlsVisible()
    check currentLayout(window).transportHeight == TransportHeight

  test "ownership policy ignores seat type, history, and match completion":
    let seats = [Seat(owner: 7, name: "Basic bot"), Seat(owner: 9, name: "Human"),
      Seat(owner: 0)]
    check not showPlaybackControls(false, 1)
    check not showPlaybackControls(false, 0, 7, seats)
    check not showPlaybackControls(false, 0, 9, seats)
    check showPlaybackControls(false, 0, 8, seats)
    check showPlaybackControls(false, 0, 0, seats)
    check showPlaybackControls(true, 1, 7, seats)
    run = Game(historyPlayback: true, world: World(over: true))
    options.playerSlot = 1
    defer:
      run = nil
      options.playerSlot = 0
    check not playbackControlsVisible()
