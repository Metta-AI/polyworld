## Content-backed command cards. All geometry is in Silky layout space.
## Does not depend on the live match, HUD, graphics, or simulation state.

import std/strutils
import vmath, pixie, silky
import polyworld/[gameuis, chrome]
import content, assets

const TooltipDelay* = 0.5

type
  TooltipTargetKind* = enum
    NoCommandTooltip, BuildingCommandTooltip, UnitCommandTooltip, ResearchCommandTooltip
  TooltipTarget* = object
    kind*: TooltipTargetKind
    building*: BuildingKind
    unit*: UnitKind
    research*: ResearchKind
    producer*: int32
    player*: int32
  DetailTooltip* = object
    title*, subtitle*, description*, requirements*, production*, unlocks*: string
    rows*: seq[tuple[label, value: string]]
  TooltipHover* = object
    target*: TooltipTarget
    anchor: GameUiPanel
    panel*: GameUiPanel
    card: DetailTooltip
    icon: string
    tint: ColorRGBX
    started, lastTime: float64
    active, warm: bool
    visible*: bool

const NoTooltipTarget* = TooltipTarget(kind: NoCommandTooltip)

proc buildingTooltipTarget*(kind: BuildingKind, player = LightPlayer): TooltipTarget =
  TooltipTarget(kind: BuildingCommandTooltip, building: kind, player: player)

proc unitTooltipTarget*(kind: UnitKind, player = LightPlayer): TooltipTarget =
  TooltipTarget(kind: UnitCommandTooltip, unit: kind, player: player)

proc updateTooltipHover*(state: var TooltipHover, target: TooltipTarget,
    anchor: GameUiPanel, mouse: Vec2, now: float64): bool =
  ## Call once EVERY frame, including no-target frames. Use monotonic seconds.
  ## One HUD-wide warm state; cold dwell belongs to a stable target, not a pixel.
  if target.kind == NoCommandTooltip or not anchor.contains(mouse):
    state = default(TooltipHover)
    return false
  if not state.active or now < state.lastTime:
    state = TooltipHover(target: target, anchor: anchor,
      started: now, lastTime: now, active: true)
    return false
  if not state.warm and (state.target != target or state.anchor != anchor):
    state.started = now
  state.target = target
  state.anchor = anchor
  state.lastTime = now
  state.warm = state.warm or now - state.started >= TooltipDelay
  state.warm


proc clearTooltip*(state: var TooltipHover) =
  state = default(TooltipHover)

proc tooltipContains*(state: TooltipHover, mouse: Vec2): bool =
  state.visible and state.panel.contains(mouse)

proc number(value: float): string =
  result = formatFloat(value, ffDecimal, 2)
  while result.endsWith("0"):
    result.setLen(result.len - 1)
  if result.endsWith("."):
    result.setLen(result.len - 1)

proc tooltipSeconds*(ticks: int32): string =
  ## Readable real seconds, not accelerated world-clock time.
  number(ticks.float / TickRate.float) & "s"

proc tooltipBuildingName*(kind: BuildingKind, player: int32): string =
  case kind
  of TownHallBuilding: "Town Hall"
  of FarmBuilding: "Farm"
  of BarracksBuilding: "Barracks"
  of LumberMillBuilding: "Lumber Mill"
  of TowerBuilding: "Tower"
  of StablesBuilding:
    if player mod FactionCount == DarkPlayer: "Kennels" else: "Stables"
  of ChurchBuilding:
    if player mod FactionCount == DarkPlayer: "Temple" else: "Church"
  of BlacksmithBuilding: "Blacksmith"
  of GoldMineBuilding: "Gold Mine"

proc requirementsText(kinds: set[BuildingKind], player: int32): string =
  var names: seq[string]
  for kind in kinds:
    names.add tooltipBuildingName(kind, player)
  if names.len == 0: "None"
  else: "Completed " & names.join(", ")

proc buildingDetails*(kind: BuildingKind, player = LightPlayer): DetailTooltip =
  let stats = BuildingTable[kind]
  result.title = tooltipBuildingName(kind, player)
  result.subtitle = if kind <= BuildableHigh: "Building" else: "Neutral resource"
  result.description =
    case kind
    of TownHallBuilding:
      "An economic base for workers and resource deliveries. Build near resources to shorten hauling routes."
    of FarmBuilding:
      "Adds food capacity so you can field more units. Food is supply capacity, not a harvested resource."
    of BarracksBuilding:
      "Your army's training site. Additional technology buildings unlock more unit types here."
    of LumberMillBuilding:
      "A wood drop-off point. Place near forests to shorten hauling routes; also unlocks military technology."
    of TowerBuilding:
      "A defensive weapon and training site. Protect approaches to your base and resource lines."
    of StablesBuilding:
      "Unlocks armored troops at the Barracks together with a Blacksmith. This building does not train units itself."
    of ChurchBuilding:
      "A training site for Clerics. Clerics currently fight with piercing attacks; they do not heal allies."
    of BlacksmithBuilding:
      "Unlocks advanced Barracks troops together with their other required buildings. Select it and open Upgrades to research Tempered Edges or Runed Plating."
    of GoldMineBuilding:
      "A neutral source of gold for Peons. Workers must carry mined gold to a completed drop-off building."
  result.rows = @[
    ("Gold", $stats.gold),
    ("Wood", $stats.wood),
    ("Build time", tooltipSeconds(stats.buildTicks)),
    ("Health", $stats.hp & " HP"),
    ("Footprint", $stats.footprint.width & " x " & $stats.footprint.depth & " tiles"),
    ("Sight", $stats.sightTiles & " tiles")
  ]
  result.requirements = requirementsText(stats.requires, player)
  if stats.foodProvided > 0:
    result.rows.add ("Food capacity", "+" & $stats.foodProvided)
  var dropOff: seq[string]
  if stats.dropOffGold: dropOff.add "Gold"
  if stats.dropOffWood: dropOff.add "Wood"
  if dropOff.len > 0:
    result.rows.add ("Drop-off", dropOff.join(" + "))
  if stats.damage > 0:
    result.rows.add ("Damage", $stats.damage)
    result.rows.add ("Attack interval", tooltipSeconds(stats.cooldownTicks))
    result.rows.add ("Attack range", $stats.rangeTiles & " tiles")
  var trains, unlocks: seq[string]
  for unit in UnitKind:
    let unitStats = unitOf(player, unit)
    if unitStats.trainedAt == kind:
      trains.add UnitNames[unit]
    if kind in unitStats.requires:
      unlocks.add UnitNames[unit]
  for other in TownHallBuilding .. BuildableHigh:
    if kind in BuildingTable[other].requires:
      unlocks.add tooltipBuildingName(other, player)
  for research in ResearchKind:
    if researchBuilding(research) == kind:
      unlocks.add researchName(research)
  result.production = if trains.len > 0: trains.join(", ") else: "None"
  result.unlocks = if unlocks.len > 0: unlocks.join(", ") else: "None"

proc unitDetails*(kind: UnitKind, player = LightPlayer): DetailTooltip =
  ## Unit stats use the same player/faction lookup as training and combat.
  let stats = unitOf(player, kind)
  result.title = UnitNames[kind]
  result.subtitle = if player mod FactionCount == DarkPlayer: "Dark unit" else: "Light unit"
  result.description =
    case kind
    of PeonUnit:
      "A worker for mining gold, chopping wood and constructing buildings. Deliver resources to completed drop-off sites."
    of SoldierUnit:
      "A frontline melee fighter. Basic damage is reduced by enemy armor; piercing damage ignores armor."
    of ArcherUnit:
      "A ranged fighter whose piercing attacks ignore armor. Keep behind tougher troops."
    of MageUnit:
      "A fragile fighter with piercing attacks. Protect it with frontline units; its attack reach depends on your side."
    of KnightUnit:
      "An armored frontline fighter. Basic damage is reduced by enemy armor; piercing damage ignores armor."
    of CatapultUnit:
      "A slow siege fighter with long-range piercing attacks. Splash hits hostile units and structures neighbouring the impact tile."
    of ClericUnit:
      "A fragile piercing-damage fighter. Despite its name, this unit currently does not heal allies."
    of SummonUnit:
      "A powerful trained combat unit. Light and Dark versions have different health, damage types and attack reach."
  result.rows = @[
    ("Gold", $stats.gold), ("Wood", $stats.wood),
    ("Train time", tooltipSeconds(stats.trainTicks)),
    ("Health", $stats.hp & " HP"), ("Armor", $stats.armor),
    ("Food used", $stats.food), ("Basic damage", $stats.basic),
    ("Piercing damage", $stats.piercing),
    ("Attack interval", tooltipSeconds(stats.cooldownTicks)),
    ("Attack range", $stats.rangeTiles & " tiles"),
    ("Miss chance", $stats.missPercent & "%"),
    ("Sight", $stats.sightTiles & " tiles"),
    ("Move speed", number(TickRate.float / stats.stepTicks.float) & " tiles/s")
  ]
  if stats.splash > 0: result.rows.add ("Splash damage", $stats.splash)
  if kind == PeonUnit:
    result.rows.add ("Gold per trip", $GoldPerTrip)
    result.rows.add ("Wood per trip", $WoodPerTrip)
  result.production = tooltipBuildingName(stats.trainedAt, player)
  result.requirements = requirementsText(stats.requires, player)


type TooltipPlacement* = object
  panel*: GameUiPanel
  scale*: float32

proc placeTooltip*(anchor: GameUiPanel, viewport, naturalSize: Vec2): TooltipPlacement =
  ## Layout-space inputs: do NOT multiply by uiScale or use framebuffer pixels.
  ## Uniformly fit unusually small viewports rather than truncating card text.
  let available = max(viewport - vec2(16), vec2(0))
  if min(available.x, available.y) <= 0 or min(naturalSize.x, naturalSize.y) <= 0:
    return
  result.scale = min(1'f32, min(available.x / naturalSize.x, available.y / naturalSize.y))
  result.panel.size = naturalSize * result.scale
  let size = result.panel.size
  var at = vec2(anchor.origin.x + anchor.size.x / 2 - size.x / 2,
    anchor.origin.y - size.y - 10)
  if at.y < 8:
    # If the top is crowded, try beside the command panel before overlapping it.
    if anchor.origin.x - size.x - 10 >= 8:
      at = vec2(anchor.origin.x - size.x - 10, anchor.origin.y)
    elif anchor.origin.y + anchor.size.y + size.y + 10 <= viewport.y - 8:
      at.y = anchor.origin.y + anchor.size.y + 10
  result.panel.origin = vec2(
    clamp(at.x, 8'f32, max(8'f32, viewport.x - size.x - 8)),
    clamp(at.y, 8'f32, max(8'f32, viewport.y - size.y - 8)))

proc wrapTooltipText*(text: string, width: float32,
    measure: proc(text: string): float32 {.closure.}): seq[string] =
  ## Wrap complete words using the actual atlas font's measured advances.
  var line: string
  for word in strutils.splitWhitespace(text):
    let candidate = if line.len > 0: line & " " & word else: word
    if line.len > 0 and measure(candidate) > width:
      result.add line
      line = word
    else:
      line = candidate
  if line.len > 0: result.add line

proc drawCommandTooltip*(sk: Silky, state: var TooltipHover,
    target: TooltipTarget, anchor: GameUiPanel, viewport: Vec2,
    now: float64, icon = "", tint = rgbx(255, 255, 255, 255),
    details = DetailTooltip()): bool =
  ## Call once after the HUD, even when target == NoTooltipTarget (empty tab,
  ## off-slot, covered by a menu). `now` is wall/monotonic seconds, NOT match
  ## ticks. `anchor`, `viewport` and sk.mousePos are all layout-space values.
  ## `icon` is the same atlas key used for the hovered slot; tint is its team
  ## color without the unavailable-action dimming. Returns whether drawn.
  # Test the PREVIOUS final fitted panel before clearing anything or adopting
  # a covered anchor. Retain content, icon, tint AND anchor while over the card.
  let retain = state.tooltipContains(sk.mousePos) and
    now >= state.lastTime
  if retain:
    state.lastTime = now
  else:
    state.visible = false
    state.panel = GameUiPanel()
    if not state.updateTooltipHover(target, anchor, sk.mousePos, now):
      return false
    state.card =
      if details.title.len > 0: details
      elif target.kind == BuildingCommandTooltip: buildingDetails(target.building, target.player)
      else: unitDetails(target.unit, target.player)
    state.icon = icon
    state.tint = tint
  let
    card = state.card
    target = state.target
    anchor = state.anchor
    icon = state.icon
    tint = state.tint
  const
    Width = 420'f32
    TextWidth = Width - 32
    Gold = rgbx(247, 221, 143, 255)
    White = rgbx(236, 238, 244, 255)
    Muted = rgbx(166, 174, 190, 255)
  let
    lineHeight = max(16'f32, sk.getTextSize("Small", "Ag").y)
    rowHeight = lineHeight * 2 + 6
    rowCount = (card.rows.len + 1) div 2
    statsHeight = rowCount.float32 * rowHeight
  proc measure(text: string): float32 = sk.getTextSize("Small", text).x
  var sections: seq[tuple[text: string, gold: bool]]
  for line in wrapTooltipText(card.description, TextWidth, measure):
    sections.add (line, false)
  sections.add ("", false)
  for line in wrapTooltipText("Requires: " & card.requirements, TextWidth, measure):
    sections.add (line, true)
  let productionLabel = if target.kind == BuildingCommandTooltip: "Trains: "
    elif target.kind == ResearchCommandTooltip: "Research at: " else: "Trained at: "
  for line in wrapTooltipText(productionLabel & card.production, TextWidth, measure):
    sections.add (line, true)
  if card.unlocks.len > 0 and card.unlocks != "None":
    for line in wrapTooltipText("Unlocks: " & card.unlocks &
        " (other requirements may apply)", TextWidth, measure):
      sections.add (line, true)
  let
    naturalSize = vec2(Width, 112 + statsHeight + 18 + sections.len.float32 * lineHeight + 16)
    placement = placeTooltip(anchor, viewport, naturalSize)
  if placement.scale <= 0:
    state.clearTooltip()
    return false
  state.panel = placement.panel
  state.visible = true
  # Draw in unscaled card coordinates then transform just its vertex span.
  # uiScale remains untouched; Silky applies HUD scaling once at endUi.
  sk.pushLayer(PopupsLayer)
  sk.pushRawClipRect(rect(vec2(0), naturalSize))
  let mark = sk.vertexMark()
  sk.draw9Patch("tooltip.9patch", sk.theme.tooltipPatch, vec2(0), naturalSize)
  let body = vec2(16)
  if icon.len > 0:
    sk.drawWellImage(GameUiPanel(origin: body, size: vec2(64)), icon,
      tint, iconSize = 64)
  discard sk.drawText("Bold", card.title, body + vec2(78, 2), White,
    maxWidth = TextWidth - 78, maxHeight = 48, wordWrap = true)
  sk.drawLabel(card.subtitle, body + vec2(78, 50), vec2(TextWidth - 78, 22), Gold, "Small")
  for i, row in card.rows:
    let at = body + vec2((i mod 2).float32 * (TextWidth / 2),
      96 + (i div 2).float32 * rowHeight)
    sk.drawLabel(row.label, at, vec2(TextWidth / 2 - 8, lineHeight), Muted, "Small")
    sk.drawLabel(row.value, at + vec2(0, lineHeight),
      vec2(TextWidth / 2 - 8, lineHeight), White, "Small")
  let sectionTop = body + vec2(0, 96 + statsHeight + 8)
  sk.drawRect(sectionTop, vec2(TextWidth, 1), rgbx(96, 90, 68, 255))
  for i, line in sections:
    sk.drawLabel(line.text, sectionTop + vec2(0, 10 + i.float32 * lineHeight),
      vec2(TextWidth, lineHeight), if line.gold: Gold else: White, "Small")
  for i in mark ..< sk.drawer.layers[PopupsLayer].len:
    template vertex: untyped = sk.drawer.layers[PopupsLayer][i]
    vertex.pos = placement.panel.origin + vertex.pos * placement.scale
    vertex.clipPos = placement.panel.origin + vertex.clipPos * placement.scale
    vertex.clipSize *= placement.scale
  sk.popClipRect()
  sk.popLayer()
  true
