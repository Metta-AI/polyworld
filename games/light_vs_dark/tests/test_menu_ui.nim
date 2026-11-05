import std/unittest
import ../homes
import ../lobbies
import ../presets

suite "LvD map preview":
  test "preview uses the actual map seed, settings, and player roster":
    var config = defaultConfig(3)
    config.seed = 47
    let preview = previewMap(config)
    check preview.seed == 47
    check preview.hallOrigin.len == 3
    check preview.settings == config.mapSettings
    check preview.hash == generateMap(47, 3, config.mapSettings).hash

suite "LvD roster":
  test "players alternate columns through the final seat":
    for index in 0 ..< 64:
      check rosterColumn(index) == index mod 2
  test "removal moves the human index with the remaining players":
    check humanAfterRemoval(3, 1) == 2
    check humanAfterRemoval(1, 1) == -1
    check humanAfterRemoval(0, 2) == 0
    check humanAfterRemoval(-1, 0) == -1

suite "LvD menu entry":
  test "server overrides do not skip home, room invites do":
    check not opensMultiplayer("")
    check opensMultiplayer("room-code")

when not defined(headless):
  import polyworld/menus

  suite "LvD effective preferences":
    test "configured relay remains a fallback below the query override":
      let stored = Preferences(server: "wss://saved.example/ws")
      let configured = "ws://127.0.0.1:9911/ws"
      check effectivePreferences(stored, "", configured).server == configured
      check effectivePreferences(stored, "wss://query.example/ws", configured).server ==
        "wss://query.example/ws"
      check effectivePreferences(stored, "", Preferences().server) == stored
      check effectivePreferences(stored, "", "") == stored

    test "server query survives settings and local match preference reloads":
      let queryServer = "wss://relay.example/custom/ws?token=a%2Fb&room=ExactCase"
      var stored = Preferences(name: "Before match")
      var effective = effectivePreferences(stored, queryServer, Preferences().server)
      check effective.server == queryServer
      check not opensMultiplayer("")

      # Graphics reads and saves its own preferences while the local match runs.
      # Returning must load those edits, but not its stale/default relay address.
      stored.name = "After match"
      stored.soundMuted = true
      stored.uiScalePercent = 125
      effective = effectivePreferences(stored, queryServer, Preferences().server)
      check effective.server == queryServer
      check effective.name == "After match"
      check effective.soundMuted
      check effective.uiScalePercent == 125
      check stored.server == Preferences().server

      # Saving menu settings and reloading the page must resolve identically.
      stored = effective
      effective = effectivePreferences(stored, queryServer, Preferences().server)
      check effective.server == queryServer
