## Current-frame HUD rectangles, composed from fixed rows and columns.

import
  std/math,
  vmath,
  polyworld/[gameuis, stackpanels],
  content

const
  PanelScore* = vec2(298, 104)
  PanelHeroes* = vec2(1090, 142)
  PanelClock* = vec2(128, 86)
  PanelMinimap* = vec2(256, 256)
  PanelDetails* = vec2(859, 242)
  PanelInventory* = vec2(252, 243)
  HeroCardSize = vec2(100, 126)
  HeroGap = 4.0'f
  HeroTeamWidth = HeroCardSize.x * 5 + HeroGap * 4

type
  ClockPanels* = object
    icon*, caption*, time*: GameUiPanel

  HeroPanels* = object
    portrait*, name*, hp*, mana*: GameUiPanel

  DetailsPanels* = object
    portrait*, name*, class*, stats*: GameUiPanel
    hp*, mana*, xp*: GameUiPanel
    abilities*: array[6, GameUiPanel]

  InventoryPanels* = object
    title*, shop*, contents*, gold*: GameUiPanel
    slots*: array[6, GameUiPanel]

  ShopPanels* = object
    panel*, heading*, catalog*, footer*: GameUiPanel
    cards*: array[Item.high.ord, GameUiPanel]
    compact*: bool

proc scorePanel*(layout: GameUiLayout): GameUiPanel =
  ## Moves the score below the hero roster when they cannot fit side by side.
  let heroes = layout.panel(GameUiRegion.TopCenter, PanelHeroes)
  result = layout.panel(GameUiRegion.TopLeft, PanelScore)
  if result.overlaps(heroes, 48):
    result.origin.y = heroes.origin.y + heroes.size.y + 48

proc clockPanels*(panel: GameUiPanel): ClockPanels =
  ## Stacks the clock's icon and caption above its centered time.
  var rows = panel.stack(TopToBottom, vec2(4, 12))
  var heading = rows.takeRow(20, 7).stack(LeftToRight)
  heading.gap(12)
  result.icon = heading.take(vec2(22, 20), 4)
  result.caption = heading.take(vec2(72, 20))
  result.time = rows.takeRow(40)

proc heroPanels*(panel: GameUiPanel): array[10, HeroPanels] =
  ## Stacks two teams of portraits, player names, and paired meters.
  var teams = panel.stack(LeftToRight, vec2(12, 5))
  for team in 0 ..< 2:
    var cards = teams.takeColumn(HeroTeamWidth, 34).stack(LeftToRight)
    for slot in 0 ..< 5:
      var card = cards.take(HeroCardSize, HeroGap).stack(TopToBottom)
      let i = team * 5 + slot
      card.indent = 14
      result[i].portrait = card.take(vec2(72), 3)
      card.indent = 0
      result[i].name = card.takeRow(18)
      result[i].hp = card.takeRow(16, 1)
      result[i].mana = card.takeRow(16)

proc detailsPanels*(panel: GameUiPanel): DetailsPanels =
  ## Gives the portrait, identity, meters, and ability groups their own stacks.
  var rows = panel.stack(TopToBottom, vec2(32, 20))
  rows.gap(12)
  var columns = rows.takeRest().stack(LeftToRight)
  result.portrait = columns.take(vec2(150), 12)
  var identity = columns.takeColumn(96, 10).stack(TopToBottom)
  identity.gap(4)
  result.name = identity.takeRow(28)
  result.class = identity.takeRow(20, 2)
  result.stats = identity.takeRow(54)
  var meters = columns.takeColumn(526).stack(TopToBottom)
  meters.gap(4)
  result.hp = meters.takeRow(28, 10)
  result.mana = meters.takeRow(28, 10)
  result.xp = meters.takeRow(28, 10)
  var groups = meters.takeRow(72).stack(LeftToRight)
  var abilities = groups.takeColumn(72 * 4 + 18 * 3, 22).stack(LeftToRight)
  for i in 0 ..< 4:
    result.abilities[i] = abilities.take(vec2(72), 18)
  var items = groups.takeRest().stack(LeftToRight)
  for i in 4 ..< 6:
    result.abilities[i] = items.take(vec2(72), 18)

proc inventoryPanels*(panel: GameUiPanel): InventoryPanels =
  ## Stacks the clickable title, two inventory rows, and currency footer.
  var rows = panel.stack(TopToBottom, vec2(14, 10))
  var heading = rows.takeRow(28, 12).stack(LeftToRight)
  result.title = heading.takeColumn(112, 4)
  result.shop = heading.takeRest()
  result.contents = rows.takeRow(72 * 2 + 5, 1)
  result.gold = rows.takeRow(31)
  stackGrid(result.contents, vec2(72), 3, vec2(4, 5), result.slots)

proc shopPanels*(size: Vec2): ShopPanels =
  ## Fits the complete item catalog and inventory into the full-screen shop.
  result.compact = size.x < 1920 or size.y < 1080
  let
    margin = if result.compact: 16.0'f else: 24.0'f
    gap = if result.compact: 12.0'f else: 20.0'f
    gridGap = if result.compact: 12.0'f else: 16.0'f
    footerHeight = if result.compact: 112.0'f else: 132.0'f
  result.panel = GameUiPanel(
    origin: vec2(margin),
    size: vec2(floor(size.x), floor(size.y)) - vec2(margin * 2)
  )
  var rows = result.panel.stack(TopToBottom, vec2(margin))
  result.heading = rows.takeRow(72, gap)
  result.catalog = rows.takeRow(rows.remainingSpace.y - footerHeight, gap)
  result.footer = rows.takeRest()
  let
    columns = 6
    rowCount = (result.cards.len + columns - 1) div columns
    cell = vec2(
      floor((result.catalog.size.x - gridGap * (columns - 1).float32) /
        columns.float32),
      floor((result.catalog.size.y - gridGap * (rowCount - 1).float32) /
        rowCount.float32)
    )
  stackGrid(result.catalog, cell, columns, vec2(gridGap), result.cards)
