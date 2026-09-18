import
  std/algorithm,
  chroma, pixie, silky, vmath, windy,
  actioncam, chrome, gameuis, inputs, metrics

when defined(takeScreenshot):
  import std/os

const
  StatsWidth* = 1440.0'f
  StatsRowHeight* = 64.0'f
  StatsHeaderHeight* = 40.0'f
  StatsBandHeight* = 32.0'f
  StatsKillsHeight* = 56.0'f
  StatsPadding* = 16.0'f
  GoldColor = rgbx(235, 196, 95, 255)
  BlueColor = rgbx(76, 154, 239, 255)
  RedColor = rgbx(232, 93, 96, 255)
  PurpleColor = rgbx(192, 124, 234, 255)
  MutedColor = rgbx(151, 159, 176, 255)

type
  StatsKind* = enum
    GotaStats, RtsStats, AdventureStats
  StatsRow* = object
    slot*: int
    name*, subtitle*, portrait*, outcome*: string
    team*: int
    selected*, fallen*: bool
    metrics*: MetricRow
  StatsTable* = object
    kind*: StatsKind
    rows*: seq[StatsRow]
    tick*: int32
    complete*: bool
    winner*: int
    kills*: array[2, int]
  StatsState* = object
    toggled*: bool
    scroll*: float32
    completed: bool
    showingResults*: bool
    automatic*, automaticFinal*: bool
    finalTable: StatsTable
  StatsLayout* = object
    panel*, header*, body*: GameUiPanel
    contentHeight*, maxScroll*: float32
  StatsColumn = object
    label: string
    metric: MetricKind
    width: float32
    spark: bool

var
  sparkSamples: seq[SparkSample]
  sparkScratch: seq[Vec2]

proc visible*(state: StatsState, tabHeld: bool): bool =
  ## Combines held-key visibility with the independent button toggle.
  tabHeld or state.toggled or state.automatic

proc toggle*(state: var StatsState) =
  ## Toggles persistent visibility without modifying held-key visibility.
  state.toggled = not state.toggled
  state.showingResults = false

proc sync*(state: var StatsState, complete: bool) =
  ## Opens results once on completion without changing playback.
  if complete and not state.completed:
    state.toggled = true
    state.showingResults = true
  state.completed = complete

proc syncDirector*(state: var StatsState, cam: ActionCam,
    current: StatsTable, tabHeld: bool) =
  ## Keeps automatic coverage separate from held Tab and manual toggles.
  if current.complete:
    state.finalTable = current
  cam.manualPanel = state.toggled or tabHeld
  state.automatic = cam.enabled and
    (cam.director.overview or cam.director.finalResults)
  state.automaticFinal = cam.enabled and cam.director.finalResults
  state.showingResults = false

proc displayedValue*(row: MetricRow, kind: StatsKind,
    metric: MetricKind): int64 =
  ## Combines Adventure gold for values, charts, scales, and rankings.
  result = row.values[metric]
  if kind == AdventureStats and metric == GoldMetric:
    result += row.values[BankedMetric]

proc sortRows(table: var StatsTable) =
  ## Ranks by gold, preserving Gota factions and breaking ties by seat.
  let kind = table.kind
  table.rows.sort(proc(first, second: StatsRow): int =
    ## Keeps blue before red in Gota, then compares gold and stable seats.
    if kind == GotaStats and first.team != second.team:
      return cmp(second.team, first.team)
    result = cmp(
      second.metrics.displayedValue(kind, GoldMetric),
      first.metrics.displayedValue(kind, GoldMetric)
    )
    if result == 0:
      result = cmp(first.slot, second.slot)
  )

proc displayedTable*(state: var StatsState, current: StatsTable,
    transportInput = false): StatsTable =
  ## Keeps results readable during automatic looping until playback is used.
  if current.complete:
    state.finalTable = current
  if not state.toggled or transportInput:
    state.showingResults = false
  if (state.showingResults or state.automaticFinal) and
      state.finalTable.complete:
    result = state.finalTable
  else:
    result = current
  result.sortRows()

proc tabHeld*(window: Window): bool =
  ## Reads temporary visibility directly from current focused input.
  window.focused and window.buttonDown[KeyTab]

proc columns(kind: StatsKind, compact = false): seq[StatsColumn] =
  ## Selects explicit per-game columns for the shared renderer.
  if compact:
    return @[
      StatsColumn(label: "GOLD", metric: GoldMetric, width: 22),
      StatsColumn(label: "DAMAGE", metric: DamageMetric, width: 22),
      StatsColumn(label: "KILLS", metric: KillsMetric, width: 12)
    ]
  case kind
  of GotaStats:
    result = @[
      StatsColumn(label: "LVL", metric: LevelMetric, width: 5),
      StatsColumn(label: "GOLD EARNED", metric: GoldMetric, width: 20,
        spark: true),
      StatsColumn(label: "KILLS", metric: KillsMetric, width: 17,
        spark: true),
      StatsColumn(label: "DEATHS", metric: LossesMetric, width: 7),
      StatsColumn(label: "ASSISTS", metric: AssistsMetric, width: 8),
      StatsColumn(label: "CPU%", metric: CpuMetric, width: 12),
      StatsColumn(label: "APM", metric: ApmMetric, width: 8)
    ]
  of RtsStats:
    result = @[
      StatsColumn(label: "GOLD GATHERED", metric: GoldMetric, width: 25,
        spark: true),
      StatsColumn(label: "ARMY VALUE", metric: ArmyMetric, width: 22,
        spark: true),
      StatsColumn(label: "KILLS", metric: KillsMetric, width: 7),
      StatsColumn(label: "LOSSES", metric: LossesMetric, width: 7),
      StatsColumn(label: "CPU%", metric: CpuMetric, width: 9),
      StatsColumn(label: "APM", metric: ApmMetric, width: 7)
    ]
  of AdventureStats:
    result = @[
      StatsColumn(label: "GOLD", metric: GoldMetric, width: 23,
        spark: true),
      StatsColumn(label: "DAMAGE", metric: DamageMetric, width: 22,
        spark: true),
      StatsColumn(label: "HEALING", metric: HealingMetric, width: 9),
      StatsColumn(label: "KILLS", metric: KillsMetric, width: 6),
      StatsColumn(label: "CPU%", metric: CpuMetric, width: 10),
      StatsColumn(label: "APM", metric: ApmMetric, width: 8)
    ]

proc statsLayout*(layout: GameUiLayout, table: StatsTable): StatsLayout =
  ## Fits a centered table to its roster above the existing transport.
  var bands = 0
  if table.kind != AdventureStats:
    var previous = -1
    for row in table.rows:
      if row.team != previous:
        inc bands
        previous = row.team
  let
    area = layout.gameAreaSize
    kills = if table.kind == GotaStats: StatsKillsHeight else: 0.0'f
    content = table.rows.len.float32 * StatsRowHeight +
      bands.float32 * StatsBandHeight
    height = min(content + StatsHeaderHeight + kills + StatsPadding * 2,
      max(area.y - layout.margin * 2, 0))
    width = min(StatsWidth, max(area.x - layout.margin * 2, 0))
  result.panel = layout.panel(GameUiRegion.Center, vec2(width, height))
  result.header = GameUiPanel(
    origin: result.panel.origin + vec2(StatsPadding, StatsPadding + kills),
    size: vec2(max(width - StatsPadding * 2, 0), StatsHeaderHeight)
  )
  result.body = GameUiPanel(
    origin: result.header.origin + vec2(0, StatsHeaderHeight),
    size: vec2(result.header.size.x,
      max(height - StatsPadding * 2 - kills - StatsHeaderHeight, 0))
  )
  result.contentHeight = content
  result.maxScroll = max(content - result.body.size.y, 0)

proc statsScale*(hudScale: float32): float32 =
  ## Keeps overview type readable independently of narrow-window HUD chrome.
  max(hudScale, 0.75'f)

proc statsViewport*(layout: GameUiLayout, hudScale: float32): GameUiLayout =
  ## Preserves physical panel placement at the readable statistics scale.
  let ratio = hudScale / statsScale(hudScale)
  initGameUiLayout(layout.size * ratio, layout.transportHeight * ratio,
    layout.margin * ratio)

proc mouseOverStats*(state: StatsState, window: Window,
    layout: GameUiLayout, table: StatsTable, mouse: Vec2): bool =
  ## Blocks underlying input only within the visible statistics window.
  let
    scale = window.size.x.float32 / max(layout.size.x, 1)
    viewport = statsViewport(layout, scale)
  state.visible(window.tabHeld) and
    statsLayout(viewport, table).panel.contains(mouse * scale / statsScale(scale))

proc statsColor(kind: StatsKind, team: int): ColorRGBX =
  ## Selects familiar faction accents for bands and trends.
  case kind
  of GotaStats:
    if team == 1: BlueColor else: RedColor
  of RtsStats:
    if team == 0: BlueColor else: PurpleColor
  of AdventureStats:
    PurpleColor

proc metricText(value: int64, percent = false): string =
  ## Formats integer totals with the existing HUD number helper.
  result.addAmount(int(value))
  if percent:
    result.add '%'

proc drawStats*(sk: Silky, window: Window, layout: GameUiLayout,
    state: var StatsState, current: StatsTable, history: MetricHistory) =
  ## Draws the overlay after the normal world, HUD, and transport pass.
  when defined(takeScreenshot):
    if existsEnv("SHOW_STATS"):
      state.toggled = true
  let table = state.displayedTable(
    current,
    window.buttonPressed[KeySpace] or
      (window.mousePressed(MouseLeft) and
        layout.transportPanel.contains(sk.mousePos))
  )
  if not state.visible(window.tabHeld):
    return
  let
    slots = statsLayout(layout, table)
    specs = columns(table.kind, layout.size.x < 1000)
    innerWidth = slots.header.size.x
  state.scroll = clamp(state.scroll, 0, slots.maxScroll)
  if slots.panel.contains(sk.mousePos):
    state.scroll = clamp(state.scroll - window.scrollDelta.y * 48,
      0, slots.maxScroll)
  sk.drawPanel(slots.panel)
  if table.kind == GotaStats:
    let center = slots.panel.origin + vec2(slots.panel.size.x / 2, 16)
    sk.drawLabel($table.kills[1], center - vec2(132, 0), vec2(88, 48),
      BlueColor, "H1", align = RightAlign)
    sk.drawLabel("KILLS", center - vec2(42, 0), vec2(84, 48),
      align = CenterAlign)
    sk.drawLabel($table.kills[0], center + vec2(44, 0), vec2(88, 48),
      RedColor, "H1")
  var identityWidth = 100.0'f
  for spec in specs:
    identityWidth -= spec.width
  identityWidth *= innerWidth / 100
  sk.drawLabel("PLAYERS", slots.header.origin + vec2(8, 0),
    vec2(identityWidth - 8, StatsHeaderHeight))
  var x = slots.header.origin.x + identityWidth
  for spec in specs:
    let width = spec.width * innerWidth / 100
    sk.drawLabel(spec.label, vec2(x + 6, slots.header.origin.y),
      vec2(width - 12, StatsHeaderHeight), align = CenterAlign)
    x += width
  var maxima: MetricValues
  for row in table.rows:
    for spec in specs:
      maxima[spec.metric] = max(
        maxima[spec.metric],
        row.metrics.displayedValue(table.kind, spec.metric)
      )
  let lastFrame = history.frameIndex(table.tick)
  for i in 0 .. lastFrame:
    for row in history.frames[i].rows:
      for spec in specs:
        maxima[spec.metric] = max(
          maxima[spec.metric],
          row.displayedValue(table.kind, spec.metric)
        )
  sk.pushClipRect(rect(slots.body.origin, slots.body.size))
  var
    y = slots.body.origin.y - state.scroll
    previousTeam = -1
  for row in table.rows:
    let color = statsColor(table.kind, row.team)
    if table.kind != AdventureStats and row.team != previousTeam:
      let name =
        case table.kind
        of GotaStats:
          if row.team == 1: "BLUE TEAM" else: "RED TEAM"
        of RtsStats:
          if row.team == 0: "LIGHT" else: "DARK"
        of AdventureStats: ""
      sk.drawRect(vec2(slots.body.origin.x, y),
        vec2(innerWidth, StatsBandHeight), rgbx(32, 35, 47, 255))
      sk.drawLabel(name, vec2(slots.body.origin.x + 8, y),
        vec2(320, StatsBandHeight), color)
      if table.complete:
        let outcome =
          if table.winner < 0: "DRAW"
          elif table.winner == row.team: "VICTORY"
          else: "DEFEAT"
        sk.drawLabel(outcome, vec2(slots.body.origin.x + innerWidth / 2, y),
          vec2(innerWidth / 2 - 8, StatsBandHeight), color)
      y += StatsBandHeight
      previousTeam = row.team
    let rowPanel = GameUiPanel(origin: vec2(slots.body.origin.x, y),
      size: vec2(innerWidth, StatsRowHeight))
    y += StatsRowHeight
    if rowPanel.origin.y + rowPanel.size.y <= slots.body.origin.y or
      rowPanel.origin.y >= slots.body.origin.y + slots.body.size.y:
        continue
    if row.selected:
      sk.drawRect(rowPanel.origin, rowPanel.size, rgbx(32, 61, 88, 230))
      sk.drawRect(rowPanel.origin, vec2(3, StatsRowHeight), BlueColor)
    sk.drawRect(rowPanel.origin + vec2(0, StatsRowHeight - 1),
      vec2(innerWidth, 1), rgbx(66, 64, 65, 255))
    let
      portrait = GameUiPanel(origin: rowPanel.origin,
        size: vec2(StatsRowHeight))
      tint =
        if row.fallen: rgbx(135, 135, 145, 255)
        else: rgbx(255, 255, 255, 255)
      textX = rowPanel.origin.x + StatsRowHeight + 10
      textWidth = max(identityWidth - StatsRowHeight - 18, 0)
    sk.drawWellImage(portrait, row.portrait, tint, selected = row.selected,
      iconSize = 64)
    sk.drawLabel(sk.fittedLabel(row.name, textWidth),
      vec2(textX, rowPanel.origin.y + 3), vec2(textWidth, 29))
    sk.drawLabel(row.subtitle &
      (if row.selected: "  YOU" else: "") &
      (if row.outcome.len > 0: "  " & row.outcome else: ""),
      vec2(textX, rowPanel.origin.y + 32), vec2(textWidth, 24), MutedColor)
    x = rowPanel.origin.x + identityWidth
    for spec in specs:
      let
        width = spec.width * innerWidth / 100
        cell = GameUiPanel(origin: vec2(x + 8, rowPanel.origin.y + 8),
          size: vec2(width - 16, StatsRowHeight - 16))
        value = row.metrics.displayedValue(table.kind, spec.metric)
      x += width
      if spec.metric == CpuMetric:
        sk.drawLabel(if row.metrics.hasCpu: metricText(value, true) else: "-",
          cell.origin, vec2(cell.size.x, 24), align = CenterAlign)
        if row.metrics.hasCpu:
          let fill =
            if value >= 95: RedColor
            elif value >= 80: GoldColor
            else: BlueColor
          sk.drawBar(cell.origin + vec2(4, 30), vec2(cell.size.x - 8, 12),
            min(value, 100).float32, 100, fill)
      elif spec.spark:
        let
          numberWidth = min(80.0'f, cell.size.x * 0.43'f)
          graph = GameUiPanel(
            origin: cell.origin + vec2(0, 5),
            size: vec2(cell.size.x - numberWidth - 8, cell.size.y - 10)
          )
        sparkSamples.setLen(0)
        for i in 0 .. lastFrame:
          if row.slot < history.frames[i].rows.len:
            sparkSamples.add SparkSample(
              tick: history.frames[i].tick,
              value: history.frames[i].rows[row.slot].displayedValue(
                table.kind,
                spec.metric
              )
            )
        if sparkSamples.len == 0 or sparkSamples[^1].tick < table.tick:
          sparkSamples.add SparkSample(tick: table.tick, value: value)
        sk.drawSparkline(graph, sparkSamples, 0, max(table.tick, 1),
          0, max(maxima[spec.metric], 1),
          if spec.metric == GoldMetric: GoldColor else: color,
          sparkScratch, if spec.metric == KillsMetric: Stepped else: Linear)
        sk.drawLabel(
          metricText(value),
          cell.origin + vec2(graph.size.x + 8, 0),
          vec2(numberWidth, cell.size.y),
          if spec.metric == GoldMetric: GoldColor else: LabelColor
        )
      else:
        let text =
          if spec.metric == ApmMetric and not row.metrics.hasApm: "-"
          else: metricText(value)
        sk.drawLabel(text, cell.origin, cell.size, align = CenterAlign)
  sk.popClipRect()
  if slots.maxScroll > 0:
    let
      height = max(20.0'f, slots.body.size.y * slots.body.size.y /
        slots.contentHeight)
      offset = state.scroll / slots.maxScroll * (slots.body.size.y - height)
    sk.drawRect(slots.body.origin + vec2(innerWidth - 4, offset),
      vec2(3, height), MutedColor)

proc drawStatsOverlay*(sk: Silky, window: Window, layout: GameUiLayout,
    state: var StatsState, current: StatsTable, history: MetricHistory) =
  ## Draws the readable overlay in its own pass after the ordinary HUD.
  when defined(takeScreenshot):
    if existsEnv("SHOW_STATS"):
      state.toggled = true
  if not state.visible(window.tabHeld):
    return
  let
    scale = sk.uiScale
    mouse = sk.mousePos
  sk.uiScale = statsScale(scale)
  sk.beginUi(window, window.size)
  sk.drawStats(window, statsViewport(layout, scale), state, current, history)
  sk.endUi()
  sk.uiScale = scale
  sk.mousePos = mouse
