## Current-rank descriptions and themed hover cards for the GotA HUD.

import
  std/strutils,
  pixie, silky, vmath,
  polyworld/[chrome, gameuis],
  content, sim

const
  TooltipDelay = 0.5
  TooltipGold = rgbx(247, 221, 143, 255)
  TooltipWhite = rgbx(236, 238, 244, 255)
  TooltipMuted = rgbx(166, 174, 190, 255)

type
  DetailTooltip* = object
    title*, icon*, subtitle*, description*: string
    rows*: seq[tuple[label, value: string]]

var
  cachedAbility = -1
  cachedRank = -1'i32
  cachedItem = NoItem
  cachedCard: DetailTooltip

proc number(value: float): string =
  ## Formats small measurements without unnecessary trailing zeroes.
  result = formatFloat(value, ffDecimal, 2)
  while result.endsWith("0"):
    result.setLen(result.len - 1)
  if result.endsWith("."):
    result.setLen(result.len - 1)

proc seconds(ticks: int32): string =
  ## Converts simulation ticks to readable seconds.
  number(ticks.float / TickRate.float) & "s"

proc tiles(distance: int32): string =
  ## Converts fixed world distances to map tiles.
  number(distance.float / WorldScale.float) & " tiles"

proc abilityDetails*(ability: Ability, rank: int32): DetailTooltip =
  ## Describes only the currently learned rank using simulation definitions.
  let spec = ability.abilitySpec(rank)
  result.title = spec.name
  result.icon = ability.abilityIconKey
  result.subtitle =
    if rank == 0: "Not learned"
    else: "Rank " & $rank & " / " & $spec.slot.abilityMaxLevel
  case spec.casting
  of SelfCast:
    result.subtitle.add " / Self cast"
    result.description = "Applies to your hero."
  of MeleeCast:
    result.subtitle.add " / Melee"
    result.description = "Hits the selected enemy in melee range."
  of ProjectileCast:
    result.subtitle.add " / Projectile"
    result.description = "Follows the selected target. A ground shot hits " &
      "the first enemy in its path."
  of AreaCast:
    result.subtitle.add " / Area cast"
    result.description =
      if spec.fromCaster:
        "Starts at your position, facing your aim. Affects targets in the " &
          "area at impact."
      else:
        "Locks onto the aimed map position. Affects targets in the area " &
          "at impact."
  if spec.damage > 0:
    result.rows.add ("Enemy damage", $spec.damage)
  if spec.heal > 0:
    result.rows.add ("Healing", $spec.heal & " HP")
    if spec.casting != SelfCast:
      result.description.add " Heals allied heroes."
  if spec.restore > 0:
    result.rows.add ("Mana restored", $spec.restore)
  if rank == 0:
    result.description.add " Learn this ability before casting it."
    result.rows.add ("First rank unlocks", "Hero level " &
      $spec.slot.abilityRequiredLevel(1))
  var
    cooldown = spec.cooldownTicks
    recharge = spec.rechargeTicks
  when defined(gotaTestRoom):
    cooldown = min(cooldown, TickRate)
    recharge = min(recharge, TickRate)
  result.rows.add ("Mana cost", $spec.manaCost)
  result.rows.add ("Max charges", $spec.charges)
  result.rows.add ("Cast cooldown", seconds(cooldown))
  result.rows.add ("Charge recharge", seconds(recharge))
  result.rows.add ("Impact delay",
    if spec.castTicks == 0: "Instant" else: seconds(spec.castTicks))
  if spec.range > 0:
    result.rows.add ("Cast range", tiles(spec.range))
  if spec.casting == AreaCast:
    case spec.area.shape
    of CircleFootprint:
      result.rows.add ("Circle radius", tiles(spec.area.radius))
    of RingFootprint:
      result.rows.add ("Outer radius", tiles(spec.area.radius))
      result.rows.add ("Inner radius", tiles(spec.area.innerRadius))
    of SectorFootprint:
      result.rows.add ("Cone radius", tiles(spec.area.radius))
      result.rows.add ("Cone angle", $spec.area.angle & " degrees")
    of LineFootprint, CapsuleFootprint, CrossFootprint:
      result.rows.add ("Area width", tiles(spec.area.width))
      result.rows.add ("Area length", tiles(spec.area.length))
  if spec.controlTicks > 0:
    case spec.control
    of StunControl:
      result.rows.add ("Stun", seconds(spec.controlTicks))
      result.description.add " Stuns enemies: no movement or actions."
    of RootControl:
      result.rows.add ("Root", seconds(spec.controlTicks))
      result.description.add " Roots enemies: movement is disabled."
    of SilenceControl:
      result.rows.add ("Silence", seconds(spec.controlTicks))
      result.description.add " Silences enemies: abilities are disabled."
    of NoControl:
      discard
  if spec.casting == ProjectileCast:
    result.description.add " Projectile travel adds to the impact delay."

proc itemDetails*(item: Item): DetailTooltip =
  ## Explains consumable targeting, recovery, and passive equipment bonuses.
  let spec = item.itemSpec
  result.title = spec.name
  result.icon = item.itemIconKey
  result.subtitle = if spec.kind == Consumable: "Consumable" else: "Equipment"
  result.rows.add ("Shop price", $spec.cost & " gold")
  if spec.kind == Equipment:
    result.description = "Bonuses apply while held in your inventory."
  elif item == PortalScroll:
    result.description = "Double-click or double-tap its key to return home. " &
      "Otherwise, teleport near a living allied tower. Distant aims " &
      "land inside its attack radius. You cannot move or attack while " &
      "channeling. Stuns and roots interrupt it."
    result.rows.add ("Channel time", seconds(spec.channelTicks))
    result.rows.add ("Landing radius", "Tower attack range")
  elif spec.strike > 0:
    result.description = "Deals damage to your current attack target within " &
      "basic-attack range. Choose an enemy to attack first."
    result.rows.add ("Damage", $spec.strike)
  else:
    result.description = "Use on yourself or an allied hero. Double-click " &
      "its icon or double-tap its hotkey to use it on yourself."
    result.rows.add ("Target range", $PotionTargetRangeTiles & " tiles")
  if spec.heal > 0:
    result.rows.add ("Health restored", $spec.heal & " HP")
  if spec.restore > 0:
    result.rows.add ("Mana restored", $spec.restore)
  if spec.recoveryTicks > 0:
    result.rows.add ("Recovery duration", seconds(spec.recoveryTicks))
    result.description.add " Recovery stops when the recipient takes damage."
  elif spec.heal > 0 or spec.restore > 0:
    result.rows.add ("Recovery", "Instant")
  if spec.cooldownTicks > 0:
    let cooldown =
      when defined(gotaTestRoom): min(spec.cooldownTicks, TickRate)
      else: spec.cooldownTicks
    result.rows.add ("Cooldown", seconds(cooldown))
    if spec.heal > 0 or spec.restore > 0:
      result.description.add " Shares cooldown with the same recovery type."
  if spec.maxHp > 0:
    result.rows.add ("Max health", "+" & $spec.maxHp & " HP")
  if spec.maxMana > 0:
    result.rows.add ("Max mana", "+" & $spec.maxMana)
  if spec.damage > 0:
    result.rows.add ("Attack damage", "+" & $spec.damage)
  if spec.movePerTick > 0:
    result.rows.add ("Move speed", "+" &
      number(spec.movePerTick.float * TickRate.float / WorldScale.float) &
      " tiles/s")
  if spec.kind == Consumable:
    result.description.add " Consumes one from the stack."

proc drawDetails(sk: Silky, card: DetailTooltip, anchor: GameUiPanel,
    size: Vec2, key: string) =
  ## Draws a large themed card above its icon, clamped inside the viewport.
  if sk.mouseIdleTime < TooltipDelay:
    return
  let
    width = min(380.0'f, size.x - 16)
    rowCount = (card.rows.len + 1) div 2
    rowHeight = min(44.0'f, max(28.0'f,
      (size.y - 276) / max(rowCount, 1).float32))
    height = 252.0'f + rowCount.float32 * rowHeight
    at = vec2(
      clamp(anchor.origin.x + anchor.size.x / 2 - width / 2,
        8.0'f, max(8.0'f, size.x - width - 8)),
      max(8.0'f, anchor.origin.y - height - 10)
    )
    body = at + vec2(16)
    textWidth = width - 32
  sk.pushLayer(PopupsLayer)
  sk.pushClipRect(rect(vec2(0), size))
  sk.draw9Patch("tooltip.9patch", sk.theme.tooltipPatch, at, vec2(width, height))
  let icon = GameUiPanel(origin: body, size: vec2(64))
  sk.drawWellImage(icon, card.icon, iconSize = 64)
  if key.len > 0:
    sk.drawKeyPip(icon, key)
  discard sk.drawText(
    "Bold", card.title, body + vec2(78, 2), TooltipWhite,
    maxWidth = textWidth - 78, maxHeight = 44, wordWrap = true
  )
  sk.drawLabel(card.subtitle, body + vec2(0, 72), vec2(textWidth, 22),
    TooltipGold, "Small")
  let statsTop = body + vec2(0, 104)
  for i, row in card.rows:
    let column = statsTop + vec2(
      (i mod 2).float32 * (textWidth / 2),
      (i div 2).float32 * rowHeight
    )
    sk.drawLabel(row.label, column, vec2(textWidth / 2, 14),
      TooltipMuted, "Small")
    sk.drawLabel(row.value, column + vec2(0, 15),
      vec2(textWidth / 2, rowHeight - 15), TooltipWhite, "Small")
  let description = statsTop + vec2(0, rowCount.float32 * rowHeight + 8)
  sk.drawRect(description, vec2(textWidth, 1), rgbx(96, 90, 68, 255))
  discard sk.drawText(
    "Small", card.description, description + vec2(0, 10), TooltipWhite,
    maxWidth = textWidth, maxHeight = 112, wordWrap = true
  )
  sk.popClipRect()
  sk.popLayer()

proc drawAbilityTooltip*(sk: Silky, ability: Ability, rank: int32,
    anchor: GameUiPanel, size: Vec2, key: string) =
  ## Rebuilds the hovered ability card only when its identity or rank changes.
  if cachedAbility != ability.ord or cachedRank != rank:
    cachedCard = abilityDetails(ability, rank)
    cachedAbility = ability.ord
    cachedRank = rank
    cachedItem = NoItem
  sk.drawDetails(cachedCard, anchor, size, key)

proc drawItemTooltip*(sk: Silky, item: Item, anchor: GameUiPanel,
    size: Vec2, key: string) =
  ## Reuses the hovered item's card until a different item is inspected.
  if cachedItem != item:
    cachedCard = itemDetails(item)
    cachedItem = item
    cachedAbility = -1
  sk.drawDetails(cachedCard, anchor, size, key)
