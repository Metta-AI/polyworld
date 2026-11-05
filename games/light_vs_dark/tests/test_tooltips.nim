import std/[os, strutils, unittest]
import vmath
import polyworld/gameuis
import ../[assets, content, tooltips]

proc row(card: DetailTooltip, label: string): string =
  for entry in card.rows:
    if entry.label == label:
      return entry.value

suite "LvD command tooltip content":
  test "every buildable structure describes authoritative costs and footprint":
    for kind in TownHallBuilding .. BuildableHigh:
      let
        card = buildingDetails(kind, LightPlayer)
        stats = BuildingTable[kind]
      check card.title.len > 0
      check card.description.len > 20
      check card.row("Gold") == $stats.gold
      check card.row("Wood") == $stats.wood
      check card.row("Health") == $stats.hp & " HP"
      check card.row("Build time") == tooltipSeconds(stats.buildTicks)
      check card.row("Footprint") == $stats.footprint.width & " x " &
        $stats.footprint.depth & " tiles"
      check card.row("Sight") == $stats.sightTiles & " tiles"
      check card.requirements.len > 0

  test "production, unlocks, supply and weapons follow content tables":
    for player in [LightPlayer, DarkPlayer]:
      for kind in TownHallBuilding .. BuildableHigh:
        let card = buildingDetails(kind, player)
        let stats = BuildingTable[kind]
        for unit in UnitKind:
          let unitStats = unitOf(player, unit)
          if unitStats.trainedAt == kind:
            check card.production.contains(UnitNames[unit])
          if kind in unitStats.requires:
            check card.unlocks.contains(UnitNames[unit])
        for other in TownHallBuilding .. BuildableHigh:
          if kind in BuildingTable[other].requires:
            check card.unlocks.contains(tooltipBuildingName(other, player))
        if stats.foodProvided > 0:
          check card.row("Food capacity") == "+" & $stats.foodProvided
        if stats.damage > 0:
          check card.row("Damage") == $stats.damage
          check card.row("Attack interval") == tooltipSeconds(stats.cooldownTicks)
          check card.row("Attack range") == $stats.rangeTiles & " tiles"
        else:
          check card.row("Damage") == ""
        if stats.dropOffGold: check card.row("Drop-off").contains("Gold")
        if stats.dropOffWood: check card.row("Drop-off").contains("Wood")
        for required in stats.requires:
          check card.requirements.contains(tooltipBuildingName(required, player))
    check buildingDetails(StablesBuilding, DarkPlayer).title == "Kennels"
    check buildingDetails(ChurchBuilding, DarkPlayer).title == "Temple"
    check buildingDetails(StablesBuilding).production == "None"
    check buildingDetails(ChurchBuilding).description.contains("do not heal")

  test "all units report side-specific combat, training and prerequisites":
    for player in [LightPlayer, DarkPlayer, 7'i32]:
      for kind in UnitKind:
        let stats = unitOf(player, kind)
        let card = unitDetails(kind, player)
        check card.title == UnitNames[kind]
        check card.description.len > 20
        check card.row("Gold") == $stats.gold
        check card.row("Wood") == $stats.wood
        check card.row("Train time") == tooltipSeconds(stats.trainTicks)
        check card.row("Health") == $stats.hp & " HP"
        check card.row("Armor") == $stats.armor
        check card.row("Basic damage") == $stats.basic
        check card.row("Piercing damage") == $stats.piercing
        check card.row("Attack interval") == tooltipSeconds(stats.cooldownTicks)
        check card.row("Attack range") == $stats.rangeTiles & " tiles"
        check card.row("Miss chance") == $stats.missPercent & "%"
        check card.row("Food used") == $stats.food
        check card.row("Sight") == $stats.sightTiles & " tiles"
        check card.row("Move speed").endsWith(" tiles/s")
        check card.production == tooltipBuildingName(stats.trainedAt, player)
        for required in stats.requires:
          check card.requirements.contains(tooltipBuildingName(required, player))
        if stats.splash > 0:
          check card.row("Splash damage") == $stats.splash
    check unitDetails(ClericUnit).description.contains("does not heal")
    check unitDetails(CatapultUnit).description.contains("neighbour")
    check unitDetails(CatapultUnit).description.contains("structures")
    check unitDetails(PeonUnit).row("Gold per trip") == $GoldPerTrip
    check unitDetails(PeonUnit).row("Wood per trip") == $WoodPerTrip

suite "LvD tooltip hover timing":
  test "delay restarts on motion, target change, off-target and clock rollback":
    var state: TooltipHover
    let
      farm = buildingTooltipTarget(FarmBuilding, 0)
      tower = buildingTooltipTarget(TowerBuilding, 0)
      anchor = GameUiPanel(origin: vec2(100), size: vec2(72))
      mouse = vec2(110)
    check not state.updateTooltipHover(farm, anchor, mouse, 10.0)
    check not state.updateTooltipHover(farm, anchor, mouse, 10.49)
    check state.updateTooltipHover(farm, anchor, mouse, 10.5)
    check not state.updateTooltipHover(farm, anchor, mouse + vec2(1, 0), 10.6)
    check state.updateTooltipHover(farm, anchor, mouse + vec2(1, 0), 11.1)
    check not state.updateTooltipHover(tower, anchor, mouse + vec2(1, 0), 11.2)
    check state.updateTooltipHover(tower, anchor, mouse + vec2(1, 0), 11.7)
    check not state.updateTooltipHover(NoTooltipTarget, anchor, mouse, 11.8)
    check not state.updateTooltipHover(tower, anchor, mouse, 11.9)
    check not state.updateTooltipHover(tower, anchor, mouse, 2.0)
    check state.updateTooltipHover(tower, anchor, mouse, 2.5)
    check not state.updateTooltipHover(tower, anchor, vec2(0), 3.0)
    check not state.updateTooltipHover(tower, anchor, mouse, 3.1)
    check not state.updateTooltipHover(buildingTooltipTarget(TowerBuilding, 1), anchor, mouse, 4.0)
    check not state.updateTooltipHover(unitTooltipTarget(PeonUnit, 1), anchor, mouse, 4.1)
    let shifted = GameUiPanel(origin: vec2(99), size: vec2(72))
    check not state.updateTooltipHover(unitTooltipTarget(PeonUnit, 1), shifted, mouse, 5.0)
    check state.updateTooltipHover(unitTooltipTarget(PeonUnit, 1), shifted, mouse, 5.5)
    # HUD frames are skipped while the Esc menu is visible.
    check not state.updateTooltipHover(unitTooltipTarget(PeonUnit, 1), shifted, mouse, 8.0)
    check state.updateTooltipHover(unitTooltipTarget(PeonUnit, 1), shifted, mouse, 8.5)

suite "LvD tooltip viewport placement":
  test "cards fit scaled viewports and prefer above bottom-right slots":
    for viewport in [vec2(1920, 1080), vec2(960, 540), vec2(480, 270), vec2(240, 135)]:
      let anchor = GameUiPanel(origin: viewport - vec2(82), size: vec2(72))
      for height in [350'f32, 550'f32, 720'f32]:
        let placement = placeTooltip(anchor, viewport, vec2(420, height))
        check placement.panel.inside(viewport)
        check placement.scale > 0
        check placement.scale <= 1
        check placement.panel.size == vec2(420, height) * placement.scale
        if height + 100 < viewport.y:
          check placement.panel.origin.y + placement.panel.size.y < anchor.origin.y
    let empty = placeTooltip(GameUiPanel(), vec2(0), vec2(420, 500))
    check empty.scale == 0

  test "word wrapping preserves all words and bounds each line":
    proc measure(text: string): float32 = text.len.float32 * 8
    let original = "Town Hall, Barracks, Lumber Mill and Blacksmith"
    let lines = wrapTooltipText(original, 112, measure)
    check lines.join(" ") == original
    for line in lines:
      check measure(line) <= 112

suite "LvD tooltip HUD integration":
  test "build and unit slots feed a single frame-ending tooltip call":
    let source = readFile(currentSourcePath().parentDir / "../ui.nim")
    check source.contains("buildingTooltipTarget(kind, player)")
    check source.contains("unitTooltipTarget(kind, player)")
    check source.contains("hoveredTarget = NoTooltipTarget")
    check source.count("sk.drawCommandTooltip(") == 1
    check source.contains("if playbackControlsVisible():")

when defined(tooltipRenderTest):
  import pixie, silky
  import polyworld/viewers
  import ../symbols

  suite "LvD tooltip rendering":
    test "real themed draw is delayed and its vertices fit at every HUD scale":
      let window = newWindow("Tooltip regression", ivec2(960, 540), visible = false)
      window.makeContextCurrent()
      loadExtensions()
      let builder = newHudAtlas(2048)
      builder.addDefaultFonts()
      let badges = loadUnitSymbols()
      check builder.addImage(unitSymbolKey(PeonUnit), badges[PeonUnit])
      let sk = newSilky(window, builder.atlasImage, builder.atlas)
      sk.applyThemePatches()
      for scale in [0.5'f32, 1'f32, 2'f32]:
        sk.uiScale = scale
        sk.beginUi(window, window.size)
        let viewport = window.size.vec2 / scale
        let anchor = GameUiPanel(origin: viewport - vec2(82), size: vec2(72))
        sk.mousePos = anchor.origin + vec2(10)
        var state: TooltipHover
        let target = unitTooltipTarget(PeonUnit, DarkPlayer)
        check not sk.drawCommandTooltip(state, target, anchor, viewport, 10.0,
          unitSymbolKey(PeonUnit))
        check sk.drawer.layers[PopupsLayer].len == 0
        check sk.drawCommandTooltip(state, target, anchor, viewport, 10.5,
          unitSymbolKey(PeonUnit))
        check sk.drawer.layers[PopupsLayer].len > 0
        for vertex in sk.drawer.layers[PopupsLayer]:
          check vertex.pos.x >= 0
          check vertex.pos.y >= 0
          check vertex.pos.x <= viewport.x
          check vertex.pos.y <= viewport.y
        check sk.uiScale == scale
        check sk.currentDrawLayer == NormalLayer
        sk.endUi()
      window.close()
