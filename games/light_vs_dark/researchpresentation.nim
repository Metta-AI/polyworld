## Research command presentation only. Values come from authoritative helpers;
## this module neither changes a world nor submits commands.
import std/strutils
import chroma, pixie, silky, vmath, fixxy
import polyworld/[chrome, gameuis]
import content, sim, tooltips

const ResearchIconKeys*: array[ResearchKind, string] = [
  "keenflight_arrows", "tempered_edges", "runed_plating", "windrunner_training"]
const TemporaryResearchIcons*: array[ResearchKind, string] = [
  "bow", "attack", "armor", "speed_1x"]

type ResearchCard* = object
  name*, icon*, reason*: string
  level*: int32
  maxLevel*: int32 = 3
  gold*, wood*, ticks*, ticksRemaining*: int32
  active*, queued*, allowed*: bool

proc researchTitle*(card: ResearchCard): string =
  let target = min(card.level + 1, card.maxLevel)
  let numeral = case target
    of 1: "I"
    of 2: "II"
    of 3: "III"
    else: $target
  card.name & " " & numeral

proc researchEnabled*(card: ResearchCard): bool =
  card.allowed and card.level < card.maxLevel and not card.active and not card.queued

proc researchStatus*(card: ResearchCard): string =
  if card.level >= card.maxLevel: "MAX LEVEL"
  elif card.queued: "QUEUED"
  elif card.active: "RESEARCHING"
  elif card.reason.len > 0: card.reason
  else: "RESEARCH"

proc researchProgress*(card: ResearchCard): float32 =
  if card.active and card.ticks > 0:
    clamp(1'f32 - card.ticksRemaining.float32 / card.ticks.float32, 0'f32, 1'f32)
  else: 0'f32

proc seconds(ticks, tickRate: int32): string =
  var text = formatFloat(max(0, ticks).float / max(1, tickRate).float, ffDecimal, 1)
  if text.endsWith(".0"): text.setLen(text.len - 2)
  text & "s"

proc researchCost*(card: ResearchCard, tickRate: int32): string =
  $card.gold & "g  " & $card.wood & "w  " & seconds(card.ticks, tickRate)

proc researchTiming*(card: ResearchCard, tickRate: int32): string =
  if card.active: seconds(card.ticksRemaining, tickRate) & " left"
  elif card.level >= card.maxLevel: "Complete"
  else: seconds(card.ticks, tickRate)

proc researchKinds*(w: World, player, buildingId: int32): seq[ResearchKind] =
  ## Never silently redirect research to another producer.
  let index = w.buildingIndex(buildingId)
  if index < 0: return
  let building = w.buildings[index]
  if building.owner != player or building.hp <= 0: return
  for kind in ResearchKind:
    if researchBuilding(kind) == building.kind: result.add kind

proc researchCard*(w: World, player, buildingId: int32,
    kind: ResearchKind): ResearchCard =
  result.name = researchName(kind)
  result.icon = ResearchIconKeys[kind]
  result.level = w.researchLevel(player, kind)
  result.maxLevel = MaxResearchLevel
  let cost = researchStats(kind, min(MaxResearchLevel, result.level + 1))
  result.gold = cost.gold
  result.wood = cost.wood
  result.ticks = cost.ticks
  result.allowed = w.canResearch(player, buildingId, kind)
  let index = w.buildingIndex(buildingId)
  if index < 0 or w.buildings[index].owner != player:
    result.reason = "Select your " & tooltipBuildingName(researchBuilding(kind), player)
    return
  let building = w.buildings[index]
  if building.state != BuildingComplete:
    result.reason = "Finish construction"
  elif building.researchTicks > 0 and building.researchKind == kind:
    result.active = true
    result.ticks = building.researchTotal
    result.ticksRemaining = building.researchTicks
  elif w.researchInProgress(player, kind):
    result.reason = "Researching elsewhere"
  elif building.researchTicks > 0 or building.queueLength > 0:
    result.reason = "Building busy"
  elif not w.techMet(player, BuildingTable[building.kind].requires):
    result.reason = "Missing prerequisites"
  elif not result.allowed and result.level < MaxResearchLevel:
    result.reason = "Need resources"

proc researchDetails*(kind: ResearchKind, player: int32, card: ResearchCard,
    temporaryIcon: bool): DetailTooltip =
  result.title = card.researchTitle
  result.subtitle = if temporaryIcon: "Passive research - Temporary icon" else: "Passive research"
  result.description = case kind
    of KeenflightArrows:
      "Archers gain +2 piercing damage per tier (+6 at III). No other unit types are affected."
    of TemperedEdges:
      "Soldier, Knight, Cleric and Mage gain +2 basic damage per tier (+6 at III). Peon, Archer, Catapult and Elemental are excluded."
    of RunedPlating:
      "All mobile units gain +2 armor per tier (+6 at III), including workers, casters, siege and elementals; never buildings."
    of WindrunnerTraining:
      "Knights gain +10% of base movement speed per tier: 110%, 120%, 130%. Additive, not compounded; no other unit types are affected."
  result.description.add " Applies to existing and newly trained units of your side, in both factions. Cancel or destruction loses the investment without a refund."
  result.rows = @[("Completed tier", $card.level & "/" & $card.maxLevel),
    ("Status", card.researchStatus), ("Gold", $card.gold), ("Wood", $card.wood),
    ("Research time", seconds(card.ticks, TickRate)),
    ("Remaining", card.researchTiming(TickRate))]
  var needs = "Completed owned " & tooltipBuildingName(researchBuilding(kind), player)
  for required in BuildingTable[researchBuilding(kind)].requires:
    needs.add ", " & tooltipBuildingName(required, player)
  if card.level > 0 and card.level < MaxResearchLevel:
    needs.add "; preceding tier " & $card.level
  result.requirements = needs & "; idle building and sufficient gold/wood. One active research per building; same upgrade cannot run twice for a player. No campaign gates."
  result.production = tooltipBuildingName(researchBuilding(kind), player)

proc selectedResearchStats*(w: World, player: int32,
    kind: UnitKind): array[4, string] =
  let stats = w.unitStats(player, kind)
  let speed = w.unitMoveSpeed(player, kind).int64.float64 /
    FixedOne.int64.float64 * TickRate.float64
  ["Basic: " & $stats.basic, "Piercing: " & $stats.piercing,
    "Armor: " & $stats.armor, "Speed: " & formatFloat(speed, ffDecimal, 2) & " tiles/s"]

proc researchPanels*(panel: GameUiPanel): array[3, GameUiPanel] =
  let width = max(0'f32, (panel.size.x - 12) / 3)
  for i in 0 ..< result.len:
    result[i] = GameUiPanel(origin: panel.origin + vec2(i.float32 * (width + 6), 0),
      size: vec2(width, panel.size.y))

proc drawResearchCard*(sk: Silky, panel: GameUiPanel, card: ResearchCard,
    tickRate: int32) =
  ## Small framed technology cards evoke classic RTS menus without copying art.
  ## Icon names are supplied by the game-owned research catalog.
  let ready = card.researchEnabled
  let edge = if ready: rgbx(231, 199, 118, 255) else: rgbx(71, 76, 85, 255)
  let text = rgbx(232, 232, 224, 255)
  let gold = rgbx(243, 215, 143, 255)
  sk.drawRect(panel.origin, panel.size, edge)
  sk.drawRect(panel.origin + vec2(1), panel.size - vec2(2), rgbx(28, 30, 35, 255))
  let iconAt = panel.origin + vec2((panel.size.x - 48) / 2, 5)
  sk.drawSprite(card.icon, iconAt, vec2(48),
    if ready: rgbx(250, 236, 204, 255) else: rgbx(132, 135, 139, 255))
  # Use two centered lines rather than ellipsizing the upgrade's identity.
  let textAt = panel.origin + vec2(4, 54)
  discard sk.drawText("Small", card.researchTitle, textAt, text,
    maxWidth = panel.size.x - 8, maxHeight = 38, wordWrap = true,
    hAlign = CenterAlign)
  sk.drawLabel("Level " & $card.level & "/" & $card.maxLevel,
    panel.origin + vec2(4, 92), vec2(panel.size.x - 8, 18), gold, "Small", CenterAlign)
  let cost = if card.level >= card.maxLevel: "Complete"
    else: $card.gold & "g / " & $card.wood & "w"
  sk.drawLabel(cost, panel.origin + vec2(4, 111), vec2(panel.size.x - 8, 17), text, "Small", CenterAlign)
  sk.drawLabel(card.researchTiming(tickRate), panel.origin + vec2(4, 128),
    vec2(panel.size.x - 8, 17), text, "Small", CenterAlign)
  let statusAt = panel.origin + vec2(3, panel.size.y - 16)
  # Preserve the complete reason in the tooltip; the slot itself is compact.
  sk.drawLabel(sk.fittedLabel(card.researchStatus, panel.size.x - 6, "Small"),
    statusAt, vec2(panel.size.x - 6, 15), gold, "Small", CenterAlign)
  if card.active:
    sk.drawRect(panel.origin + vec2(2, panel.size.y - 4),
      vec2(panel.size.x - 4, 3), rgbx(42, 44, 49, 255))
    sk.drawRect(panel.origin + vec2(2, panel.size.y - 4),
      vec2((panel.size.x - 4) * card.researchProgress, 3), gold)
