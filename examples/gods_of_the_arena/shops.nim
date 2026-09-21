## Player shop presentation over the shared simulation purchase rules.

import
  std/strutils,
  pixie, silky, vmath, windy,
  polyworld/[chrome, gameuis, stackpanels],
  content, controls, layouts, sim

const
  Gold = rgbx(247, 215, 135, 255)
  Muted = rgbx(163, 175, 192, 255)
  White = rgbx(241, 244, 250, 255)

var
  waitingItem = NoItem
  receiptSerial = 0
  feedback = "Click an item to buy it."

proc drawItemCount*(sk: Silky, well: GameUiPanel, count: int32) =
  ## Keeps stack counts legible without covering the icon or cooldown.
  let corner = well.origin + vec2(well.size.x - 25, 2)
  sk.drawRect(corner, vec2(23, 20), rgbx(0, 0, 0, 210))
  sk.drawLabel($count, corner, vec2(23, 20), Gold, "Bold", CenterAlign)

proc itemDescription(spec: ItemSpec): string =
  ## Summarizes actual item effects without duplicating balance numbers.
  var lines: seq[string]
  if spec.heal > 0:
    lines.add("Heal " & $spec.heal & " health")
  if spec.restore > 0:
    lines.add("Restore " & $spec.restore & " mana")
  if spec.recoveryTicks > 0:
    lines[0].add(" / " & $(spec.recoveryTicks div TickRate) & "s")
    lines.add("Damage interrupts")
  if spec.cooldownTicks > 0 and spec.channelTicks == 0:
    lines.add($(spec.cooldownTicks div TickRate) & "s cooldown")
  if spec.strike > 0:
    lines.add($spec.strike & " damage to target")
  if spec.channelTicks > 0:
    lines.add("Near allied tower")
    lines.add($(spec.channelTicks div TickRate) & "s channel / " &
      $(spec.cooldownTicks div TickRate) & "s CD")
  if spec.maxHp > 0:
    lines.add("+" & $spec.maxHp & " max health")
  if spec.maxMana > 0:
    lines.add("+" & $spec.maxMana & " max mana")
  if spec.damage > 0:
    lines.add("+" & $spec.damage & " attack damage")
  if spec.movePerTick > 0:
    lines.add("+" & formatFloat(
      spec.movePerTick.float / WorldScale.float * TickRate.float,
      ffDecimal, 2
    ) & " movement / sec")
  lines.join("\n")

proc drawShop*(sk: Silky, window: Window, world: World, hero: Hero,
    size: Vec2, playing: bool) =
  ## Draws the full catalog and acknowledges purchases after their tick.
  if purchaseReceipt.serial != receiptSerial:
    receiptSerial = purchaseReceipt.serial
    if purchaseReceipt.heroId == hero.id and waitingItem != NoItem:
      feedback =
        if purchaseReceipt.accepted:
          "Bought " & waitingItem.itemSpec.name & "."
        else:
          "Purchase failed: " & world.purchaseReason(
            hero.id, waitingItem.ord.int32
          )
      waitingItem = NoItem
  sk.drawRect(vec2(0), size, rgbx(5, 10, 18, 245))
  let layout = shopPanels(size)
  sk.drawPanel(layout.panel)
  var heading = layout.heading.stack(RightToLeft)
  let
    close = heading.takeColumn(140, 28)
    wallet = heading.takeColumn(220, 28)
    title = heading.takeRest()
  sk.drawTab(close, hovered = sk.hovered(close))
  sk.drawLabel("CLOSE  Esc", close.origin, close.size, White, "Bold",
    CenterAlign)
  if window.buttonPressed[MouseLeft] and sk.hovered(close):
    shopOpen = false
  sk.drawSprite("gold", wallet.origin + vec2(0, 16), vec2(32))
  sk.drawLabel($hero.gold & " gold", wallet.origin + vec2(44, 0),
    wallet.size - vec2(44, 0), Gold, "Bold")
  sk.drawSprite("shop", title.origin + vec2(0, 4), vec2(64))
  sk.drawLabel("ITEM SHOP", title.origin + vec2(84, 0),
    vec2(title.size.x - 84, 40), White, "H1")
  sk.drawLabel(
    if hero.canShop: "Consumables stack to 8. Buy inside your own keep."
    else: "Return to your own keep to buy items.",
    title.origin + vec2(84, 44), vec2(title.size.x - 84, 24), Muted)
  for index, item in ShopItems:
    let
      spec = item.itemSpec
      card = layout.cards[index]
      reason = world.purchaseReason(hero.id, item.ord.int32)
      enabled = reason.len == 0 and waitingItem == NoItem
      hovered = sk.hovered(card)
    sk.drawTab(card, hovered = hovered and enabled)
    let
      padding = if layout.compact: 8.0'f else: 12.0'f
      iconSize = if layout.compact: 48.0'f else: 72.0'f
    var rows = card.stack(TopToBottom, vec2(padding))
    let name = rows.takeRow(26, 6)
    sk.drawLabel(spec.name, name.origin, name.size, White, "Bold")
    var body = rows.takeRow(iconSize, 6).stack(LeftToRight)
    let
      icon = body.take(vec2(iconSize), padding)
      description = body.takeRest()
    sk.drawWellImage(
      icon, itemIconKey(item), iconSize = if layout.compact: 32 else: 64
    )
    sk.drawLabel(spec.itemDescription, description.origin, description.size,
      Muted)
    let price = rows.takeRest()
    sk.drawSprite("gold", price.origin + vec2(0, 5), vec2(16))
    sk.drawLabel($spec.cost, price.origin + vec2(24, 0), vec2(60, 28), Gold)
    sk.drawLabel(
      if reason.len > 0: reason
      elif waitingItem != NoItem: "Purchase queued"
      elif spec.kind == Consumable: "BUY  /  Consumable"
      else: "BUY  /  Equipment",
      price.origin + vec2(84, 0), vec2(price.size.x - 84, 28),
      if enabled: Gold else: Muted, "Small"
    )
    if enabled and hovered and window.buttonPressed[MouseLeft]:
      queueBuyItem(hero.id, item.ord.int32)
      waitingItem = item
      receiptSerial = purchaseReceipt.serial
      feedback = "Buying " & spec.name & "..."
  var footer = layout.footer.stack(LeftToRight)
  var inventory = footer.takeColumn(6 * 80, 32).stack(LeftToRight)
  for slot in 0 ..< InventorySlots:
    let
      well = inventory.take(vec2(72), 8)
      item = hero.inventory[slot]
    sk.drawWellImage(well,
      if item == NoItem: "" else: itemIconKey(item), iconSize = 64)
    if item != NoItem and item.itemSpec.kind == Consumable:
      sk.drawItemCount(well, hero.itemCounts[slot])
  let status = footer.takeRest()
  sk.drawLabel(
    if waitingItem != NoItem and not playing:
      "Purchase queued. Press Space to resume and complete it."
    else: feedback,
    status.origin, vec2(status.size.x, 32), Gold, "Bold"
  )
  sk.drawLabel(
    if playing: "Battle continues. Space pauses. B or Esc closes the shop."
    else: "Battle paused. Space resumes. B or Esc closes the shop.",
    status.origin + vec2(0, 40), vec2(status.size.x, 28), Muted
  )
