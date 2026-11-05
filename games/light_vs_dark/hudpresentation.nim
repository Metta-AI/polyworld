## Live selection presentation; never caches cargo or reads player stockpiles.
import content, sim
import chroma, pixie, silky, vmath
import polyworld/[chrome, gameuis]

proc drawBuildPortrait*(sk: Silky, slot: GameUiPanel, key: string, ready: bool) =
  ## Preserve the authored colors when available. Fade the entire unavailable
  ## well, not just the sprite: the dark atlas art otherwise disappears into
  ## equally bright chrome. Silky uses premultiplied GL_ONE blending, so the
  ## neutral veil's RGB must already be premultiplied (not RGB 255 + low alpha).
  sk.drawWellImage(slot, key, iconSize = 64)
  if not ready:
    sk.drawRect(slot.origin, slot.size, rgbx(3, 4, 5, 200))
  let edge = if ready: rgbx(255, 219, 117, 255)
    else: rgbx(54, 60, 70, 255)
  let thickness = if ready: 2'f32 else: 1'f32
  sk.drawRect(slot.origin, vec2(slot.size.x, thickness), edge)
  sk.drawRect(slot.origin, vec2(thickness, slot.size.y), edge)
  sk.drawRect(slot.origin + vec2(0, slot.size.y - thickness),
    vec2(slot.size.x, thickness), edge)
  sk.drawRect(slot.origin + vec2(slot.size.x - thickness, 0),
    vec2(thickness, slot.size.y), edge)

proc drawTrainPortrait*(sk: Silky, slot: GameUiPanel, key: string,
    tint: ColorRGBX, ready: bool, queueCount: int) =
  ## Tint is the runtime player's actual faction color, not its seat ordinal.
  ## Keep symbols pale against a full-strength faction field. Fade unavailable
  ## commands before drawing the badge: existing queued work stays legible.
  sk.drawSlot(slot)
  let inner = slot.inset(2)
  sk.drawRect(inner.origin, inner.size, tint)
  let iconSize = min(64'f32, min(inner.size.x, inner.size.y))
  sk.drawSprite(key, slot.origin + (slot.size - vec2(iconSize)) * 0.5'f32,
    vec2(iconSize), rgbx(255, 255, 255, 255))
  if not ready:
    sk.drawRect(inner.origin, inner.size, rgbx(3, 4, 5, 170))
  if queueCount > 0:
    let badgeSize = vec2(20, 18)
    let origin = slot.origin + slot.size - badgeSize - vec2(2)
    sk.drawRect(origin, badgeSize, rgbx(18, 20, 25, 255))
    sk.drawLabel($queueCount, origin, badgeSize, rgbx(255, 219, 117, 255),
      "Small", CenterAlign)

proc drawTrainCosts*(sk: Silky, slot: GameUiPanel, gold, wood: int32) =
  ## Unit costs occupy the upper two rows, leaving the lower-right count clear.
  ## Caller keeps the original full-slot hover test and tooltip anchor.
  let origin = slot.origin + vec2(4)
  sk.drawRect(origin, vec2(slot.size.x - 8, 40), rgbx(12, 14, 20, 240))
  for i, value in [gold, wood]:
    let row = origin + vec2(2, i.float32 * 19)
    sk.drawSprite(if i == 0: "gold" else: "wood", row + vec2(0, 2),
      vec2(16))
    sk.drawLabel($value, row + vec2(16, 0), vec2(slot.size.x - 28, 19),
      if i == 0: rgbx(232, 196, 86, 255) else: rgbx(196, 168, 120, 255),
      "Small", RightAlign)

proc trainingQueueCount*(world: World, player, producerId: int32,
    kind: UnitKind): int =
  ## Match the train action's primary producer, never aggregate other selections.
  ## Slot zero is the active unit; already spawned units are not in this queue.
  let index = world.buildingIndex(producerId)
  if index < 0: return 0
  let structure = world.buildings[index]
  if structure.owner != player or structure.owner < 0 or
      structure.state != BuildingComplete or structure.hp <= 0 or
      unitOf(player, kind).trainedAt != structure.kind:
    return 0
  for slot in 0 ..< min(structure.queueLength.int, structure.queue.len):
    if structure.queue[slot] == uint8(kind.ord + 1): inc result

proc cargoLabel*(unit: Unit): string =
  ## Only the portrait worker's actual carried resources, including empty.
  if unit == nil or unit.kind != PeonUnit: return ""
  if unit.carryGold > 0:
    result = "GOLD " & $unit.carryGold
  if unit.carryWood > 0:
    if result.len > 0: result.add " / "
    result.add "WOOD " & $unit.carryWood
  if result.len == 0: result = "CARGO: EMPTY"

proc drawWorkerCargo*(sk: Silky, panel: GameUiPanel, worker: Unit) =
  ## This caption explicitly refers to the large portrait, not the group.
  let label = worker.cargoLabel
  if label.len == 0: return
  sk.drawLabel("PORTRAIT WORKER", panel.origin, vec2(panel.size.x, 20),
    rgbx(166, 174, 190, 255), "Small")
  sk.drawLabel(label, panel.origin + vec2(0, 23), vec2(panel.size.x, 26),
    if worker.carryGold > 0: rgbx(255, 220, 105, 255)
    elif worker.carryWood > 0: rgbx(230, 202, 151, 255)
    else: rgbx(185, 193, 204, 255), "Small")
