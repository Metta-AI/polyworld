import
  vmath,
  polyworld/[chrome, gameuis, metrics, player, stats]

echo "Testing gold rankings preserve Gota teams and player identities"
block:
  var
    state: StatsState
    table = StatsTable(kind: GotaStats)
  for slot, amount in [100'i64, 50, 500, 100]:
    var row = StatsRow(slot: slot, team: slot mod 2,
      name: "Player " & $slot)
    row.metrics.values[GoldMetric] = amount
    row.metrics.values[KillsMetric] = slot
    table.rows.add row
  let ranked = state.displayedTable(table)
  doAssert ranked.rows[0].slot == 3
  doAssert ranked.rows[1].slot == 1
  doAssert ranked.rows[2].slot == 2
  doAssert ranked.rows[3].slot == 0
  doAssert ranked.rows[0].name == "Player 3"
  doAssert ranked.rows[0].metrics.values[KillsMetric] == 3
  doAssert table.rows[0].slot == 0

echo "Testing RTS gold rankings ignore faction order and keep ties stable"
block:
  var
    state: StatsState
    table = StatsTable(kind: RtsStats,
      rows: @[StatsRow(slot: 0, team: 0), StatsRow(slot: 1, team: 1)])
  table.rows[0].metrics.values[GoldMetric] = 50
  table.rows[1].metrics.values[GoldMetric] = 100
  let ranked = state.displayedTable(table)
  doAssert ranked.rows[0].slot == 1
  doAssert ranked.rows[1].slot == 0
  table = ranked
  table.rows[1].metrics.values[GoldMetric] = 100
  doAssert state.displayedTable(table).rows[0].slot == 0

echo "Testing Adventure gold totals stay constant when banking loot"
block:
  var
    carried: MetricRow
    banked: MetricRow
  carried.values[GoldMetric] = 150
  carried.values[BankedMetric] = 50
  carried.values[DamageMetric] = 30
  banked = carried
  banked.values[GoldMetric] = 0
  banked.values[BankedMetric] = 200
  for row in [carried, banked]:
    doAssert row.displayedValue(AdventureStats, GoldMetric) == 200
    doAssert row.displayedValue(AdventureStats, DamageMetric) == 30
    doAssert row.displayedValue(GotaStats, GoldMetric) ==
      row.values[GoldMetric]
    doAssert row.displayedValue(RtsStats, GoldMetric) ==
      row.values[GoldMetric]
  doAssert carried.values[GoldMetric] == 150
  doAssert carried.values[BankedMetric] == 50

echo "Testing Adventure ranks total gold in live and results"
block:
  var
    state: StatsState
    table = StatsTable(kind: AdventureStats,
      rows: @[StatsRow(slot: 0), StatsRow(slot: 1), StatsRow(slot: 2)])
  table.rows[0].metrics.values[GoldMetric] = 100
  table.rows[1].metrics.values[GoldMetric] = 50
  table.rows[1].metrics.values[BankedMetric] = 100
  table.rows[2].metrics.values[BankedMetric] = 200
  doAssert state.displayedTable(table).rows[0].slot == 2
  doAssert state.displayedTable(table).rows[1].slot == 1
  table.complete = true
  table.tick = 100
  state.sync(true)
  let final = state.displayedTable(table)
  doAssert final.rows[0].slot == 2
  state.sync(false)
  doAssert state.displayedTable(StatsTable(kind: AdventureStats)) == final

echo "Testing held TAB and the independent stats toggle"
block:
  var state: StatsState
  doAssert not state.visible(false)
  doAssert state.visible(true)
  state.toggle()
  doAssert state.visible(false)
  state.toggle()
  doAssert state.visible(true)
  doAssert not state.visible(false)
  state.sync(true)
  doAssert state.showingResults
  doAssert state.visible(false)
  state.toggle()
  doAssert not state.showingResults
  state.sync(true)
  doAssert not state.visible(false)
  doAssert state.visible(true)

echo "Testing automatic replay loops retain final standings"
block:
  var state: StatsState
  let
    final = StatsTable(kind: RtsStats, tick: 100, complete: true, winner: 1)
    rewound = StatsTable(kind: RtsStats, tick: 0, winner: -1)
  state.sync(true)
  doAssert state.displayedTable(final) == final
  state.sync(false)
  doAssert state.displayedTable(rewound) == final
  doAssert state.displayedTable(rewound, true) == rewound
  state.sync(true)
  discard state.displayedTable(final)
  state.toggle()
  doAssert state.displayedTable(rewound) == rewound

echo "Testing compact rosters and tall table scrolling"
block:
  let layout = initGameUiLayout(vec2(1920, 1080), TransportHeight)
  var table = StatsTable(kind: RtsStats,
    rows: @[StatsRow(team: 0), StatsRow(team: 1)])
  let two = statsLayout(layout, table)
  doAssert two.panel.size.y == 264
  doAssert two.maxScroll == 0
  doAssert two.panel.origin.y + two.panel.size.y <
    layout.transportPanel.origin.y
  table.kind = AdventureStats
  table.rows.setLen(4)
  doAssert statsLayout(layout, table).panel.size.y == 328
  table.kind = GotaStats
  table.rows.setLen(40)
  let many = statsLayout(layout, table)
  doAssert many.maxScroll > 0
  doAssert many.panel.origin.y + many.panel.size.y <= layout.gameAreaSize.y
  let ribbon = layout.transportPanel.transportPanels(true)
  doAssert ribbon.stats.size == vec2(64)
  doAssert ribbon.stats.origin.x + 64 <= ribbon.camera.origin.x
  doAssert ribbon.scrub.size.x > 0

echo "Testing bounded sparklines preserve spikes and flat values"
block:
  let panel = GameUiPanel(origin: vec2(10, 20), size: vec2(20, 40))
  var
    samples: seq[SparkSample]
    points: seq[Vec2]
  sparkPoints(panel, samples, 0, 1000, 0, 100, points)
  doAssert points.len == 0
  samples.add SparkSample(tick: 0, value: 5)
  sparkPoints(panel, samples, 0, 0, 5, 5, points)
  doAssert points == @[vec2(10, 60)]
  for tick in 1 .. 1000:
    samples.add SparkSample(tick: int32(tick),
      value: if tick == 413: 100 else: 0)
  sparkPoints(panel, samples, 0, 1000, 0, 100, points)
  doAssert points.len <= 4 * 21
  var hasPeak = false
  for point in points:
    doAssert point.x >= 10 and point.x <= 30
    doAssert point.y >= 20 and point.y <= 60
    hasPeak = hasPeak or point.y == 20
  doAssert hasPeak
  doAssert points[^1] == vec2(30, 60)
