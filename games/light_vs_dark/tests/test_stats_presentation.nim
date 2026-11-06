## Game-independent renderer seam: LvD opts in; other games retain defaults.
import std/unittest
import vmath, chroma
import polyworld/[stats, gameuis, metrics]

suite "LvD statistics presentation contract":
  test "winner headline is reserved inside the same scaled card":
    when declared(StatsOptions):
      let options = StatsOptions(headline: "Commander wins", individualPlayers: true)
      for size in [vec2(640,480), vec2(1000,700), vec2(1920,1080)]:
        for count in [2, 4, 16]:
          var table = StatsTable(kind: RtsStats)
          for i in 0 ..< count: table.rows.add StatsRow(slot: i, team: i)
          for transport in [0.0'f32, 56.0'f32]:
            for scale in [0.4'f32, 0.75'f32, 1.25'f32]:
              let viewport = statsViewport(initGameUiLayout(size / scale, transport), scale)
              let slots = statsLayout(viewport, table, options)
              check slots.headline.origin.y >= slots.panel.origin.y
              check slots.headline.origin.x >= slots.panel.origin.x
              check slots.headline.origin.x + slots.headline.size.x <= slots.panel.origin.x + slots.panel.size.x
              check slots.headline.origin.y + slots.headline.size.y <= slots.header.origin.y
              check slots.body.origin.y >= slots.header.origin.y + slots.header.size.y
              check slots.panel.inside(viewport.gameAreaSize)
              check slots.body.size.y > 0
    else:
      check false # Renderer cannot yet reserve an in-panel headline.

  test "explicit scores rank descending with stable slot ties, never winner first":
    var table = StatsTable(kind: RtsStats, complete: true, winner: 0)
    for slot in [3, 1, 0, 2]:
      var row = StatsRow(slot: slot, team: slot, name: "Player " & $slot,
        portraitTint: rgbx(uint8(40 + slot * 40), 20, 30, 255),
        selected: slot == 1)
      row.metrics.values[GoldMetric] = int64(1000 - slot * 100)
      row.metrics.values[KillsMetric] = slot
      table.rows.add row
    when compiles(StatsOptions(scores: @[10'i64, 900, 500, 900])):
      let options = StatsOptions(scores: @[10'i64, 900, 500, 900], individualPlayers: true)
      for complete in [false, true]:
        table.complete = complete
        var state: StatsState
        let ranked = state.displayedTable(table, options = options)
        check ranked.rows[0].slot == 1
        check ranked.rows[1].slot == 3
        check ranked.rows[2].slot == 2
        check ranked.rows[3].slot == 0
        check ranked.winner == 0
        for row in ranked.rows:
          check row.name == "Player " & $row.slot
          check row.team == row.slot
          check row.metrics.values[KillsMetric] == row.slot
          check row.portraitTint.r == uint8(40 + row.slot * 40)
          check row.selected == (row.slot == 1)
        check table.rows[0].slot == 3
    else:
      check false # Default gold ranking cannot express the actual score.
