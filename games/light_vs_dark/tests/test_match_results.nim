## Exercise actual HUD visibility, readable layout, and authoritative telemetry.
import std/[unittest, strutils]
import vmath, windy
import polyworld/[gameuis, metrics, stats, rooms, roomclients]
import ../[game, sim, ui, multiplayer, presets]

suite "LvD finished results":
  test "final statistics automatically own their center without held Tab":
    let window = newWindow("LvD results test", ivec2(1600,1000), visible=false)
    defer: window.close()
    run = Game(world: World(over: true), maximumTicks: 100)
    options.playerSlot = 1
    defer:
      run = nil
      options.playerSlot = 0
    let layout = currentLayout(window)
    check mouseOverUi(window, layout.gameAreaSize / 2)
    check not playbackControlsVisible()

  test "winner headline is inside the card above columns, including scrolling rosters":
    when declared(resultsLayout):
      for size in [vec2(640,480), vec2(1000,700), vec2(1920,1080)]:
        for count in [2, 4, 16]:
          var table = StatsTable(kind: RtsStats)
          for i in 0 ..< count: table.rows.add StatsRow(team: i)
          for transport in [0.0'f32, 56.0'f32]:
            let layout = initGameUiLayout(size, transport)
            let presentation = resultsLayout(layout, table)
            let panel = presentation.panel
            check presentation.headline.origin.y >= panel.origin.y
            check presentation.headline.origin.y + presentation.headline.size.y <=
              panel.origin.y + panel.size.y
            check presentation.headline.origin.x >= panel.origin.x
            check presentation.headline.origin.x + presentation.headline.size.x <=
              panel.origin.x + panel.size.x
            check presentation.headline.inside(layout.gameAreaSize)
            check panel.inside(layout.gameAreaSize)
            check panel.size.y > 120
    else:
      check false # Missing a coordinated headline + table layout.

  test "tick limit and relay interruption show results without inventing a winner":
    run = Game(world: World(tick: 100), maximumTicks: 100)
    defer:
      run = nil
      hudNetwork = nil
    check matchResultsVisible()
    when declared(matchResultHeadline):
      check matchResultHeadline() == "Time limit reached"
      run.world.tick = 30
      hudNetwork = NetworkMatch(client: RoomClient(snapshot: RoomMessage(phase: Desynced)))
      check matchResultsVisible()
      check matchResultHeadline() == "Match interrupted"
      hudNetwork.client.snapshot.phase = rooms.Playing
      check not matchResultsVisible()
      run.world.over = true
      run.world.winner = -1
      check matchResultHeadline() == "Draw"
    else:
      check false # Completion is not always world.over.

  test "real match totals and sampled history back the results":
    var config = defaultConfig()
    config.maxTicks = 120
    initializeLocalMatch(config, ["", ""])
    defer: run = nil
    for i in 0 ..< 120: advanceGame()
    let table = currentStats()
    check table.tick == run.world.tick
    check table.rows.len == run.world.players.len
    check run.history.frames.len > 1
    for row in table.rows:
      check row.metrics.values[GoldMetric] == run.world.players[row.slot].goldGathered
      check row.metrics.values[LossesMetric] == run.world.players[row.slot].unitsLost

  test "Score uses existing world score, retaining departed match identities":
    var config = defaultConfig()
    config.players[0].name = "Departed :)"
    config.players[1].name = "Other commander"
    initializeLocalMatch(config, ["", ""])
    defer:
      run = nil
      hudNetwork = nil
    run.world.players[1].goldGathered = 50000
    run.world.players[1].woodGathered = 90000
    run.world.over = true
    run.world.winner = 0 # Winner is deliberately not the highest scoring row.
    hudNetwork = NetworkMatch(client: RoomClient(snapshot: RoomMessage(phase: rooms.Ended)))
    check matchResultHeadline() == "Departed :) wins"
    when declared(currentStatsOptions):
      let presentation = currentStatsOptions()
      check presentation.scores[0] == run.world.score(0)
      check presentation.scores[1] == run.world.score(1)
      check presentation.scores[1] > presentation.scores[0]
      var state: StatsState
      let table = state.displayedTable(currentStats(), options = presentation)
      check table.rows[0].slot == 1
      check table.rows[1].name == "Departed :)"
      check run.config.players[0].name == "Departed :)"
      check table.winner == 0
    else:
      check false

  test "return controls are absent outside the Esc menu":
    const source = staticRead("../graphics.nim")
    let hud = source.split("if network != nil: transport = beforeHud")[1].split("if matchMenu != HiddenMatchMenu:")[0]
    check not hud.contains("menuButton")
    check not hud.contains("Return to")

  test "lobby return preserves connection and only the owner reopens ended rooms":
    when declared(returnToMatchLobby):
      check returnToMatchLobby(nil)
      let client = RoomClient(participant: 7, connected: true,
        snapshot: RoomMessage(participant: 7, phase: rooms.Ended, room: "room"))
      let network = NetworkMatch(client: client)
      check returnToMatchLobby(network)
      check client.connected
      check client.snapshot.room == "room"
      check client.outgoing.len == 1
      check decode(client.outgoing[0]).kind == ReturnLobby
      client.outgoing.setLen(0)
      client.participant = 8
      check returnToMatchLobby(network)
      check client.outgoing.len == 0
      client.snapshot.phase = rooms.Playing
      check not returnToMatchLobby(network)
      check client.outgoing.len == 0
    else:
      check false
