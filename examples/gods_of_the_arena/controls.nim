## Human hero commands for Gods of the Arena.
##
## Graphics queues intents. The decide tick applies them through the same
## `apply*` procs the BASIC bots use.

import
  content, sim, replays

type
  PlayerCommandKind = enum
    CommandDraft
    CommandWalk
    CommandAttack
    CommandAttackMove
    CommandBuy
    CommandUse
    CommandUseAt
    CommandCastTarget
    CommandCastPoint
    CommandLevelAbility
    CommandBuyback

  PlayerCommand = object
    kind: PlayerCommandKind
    heroId: int32
    first: int32
    second: int32
    slot: int32

type PurchaseReceipt* = object
  serial*: int
  heroId*, itemId*: int32
  accepted*: bool

var
  pending: seq[PlayerCommand]
  purchaseReceipt*: PurchaseReceipt
  armedAbility* = -1'i32
  armedItem* = -1'i32
  shopOpen* = false

proc queueDraft*(heroId, classId: int32) =
  ## Queues a hero choice for validation on the next draft decision.
  pending.add PlayerCommand(
    kind: CommandDraft, heroId: heroId, first: classId
  )

proc queueWalkTo*(heroId, mapX, mapY: int32) =
  ## Queues one walk command for the human hero.
  pending.add PlayerCommand(
    kind: CommandWalk,
    heroId: heroId,
    first: mapX,
    second: mapY
  )

proc queueAttackMove*(heroId, mapX, mapY: int32) =
  ## Queues one attack-move command for the human hero.
  pending.add PlayerCommand(
    kind: CommandAttackMove,
    heroId: heroId,
    first: mapX,
    second: mapY
  )

proc queueAttackTarget*(heroId, targetId: int32) =
  ## Queues one attack command for the human hero.
  pending.add PlayerCommand(
    kind: CommandAttack,
    heroId: heroId,
    first: targetId
  )

proc queueBuyItem*(heroId, itemId: int32) =
  ## Queues one shop purchase for the human hero.
  pending.add PlayerCommand(
    kind: CommandBuy,
    heroId: heroId,
    first: itemId
  )

proc queueUseItem*(heroId, slot: int32) =
  ## Queues one inventory use for the human hero.
  pending.add PlayerCommand(
    kind: CommandUse,
    heroId: heroId,
    first: slot
  )

proc queueBuyback*(heroId: int32) =
  ## Queues one buyback through the shared simulation validator.
  pending.add PlayerCommand(kind: CommandBuyback, heroId: heroId)

proc queueCastTarget*(heroId, slot, targetId: int32) =
  ## Queues one ability on the object under the player's pointer.
  pending.add PlayerCommand(
    kind: CommandCastTarget, heroId: heroId, slot: slot, first: targetId
  )

proc queueUseItemAt*(heroId, slot, mapX, mapY: int32) =
  ## Queues a scroll channel toward the clicked map position.
  pending.add PlayerCommand(
    kind: CommandUseAt, heroId: heroId, slot: slot,
    first: mapX, second: mapY
  )

proc activatePlayerItem*(world: World, heroId, slot: int32) =
  ## Arms portal aiming or immediately uses an ordinary consumable.
  let hero = world.heroById(heroId)
  if hero.id == 0 or slot < 0 or slot >= InventorySlots:
    return
  armedAbility = -1
  armedItem = -1
  if hero.inventory[slot] == PortalScroll:
    armedItem = slot
  else:
    queueUseItem(heroId, slot)

proc queueCastPoint*(heroId, slot, mapX, mapY: int32) =
  ## Queues an ability toward the ground even when no object is selected.
  pending.add PlayerCommand(
    kind: CommandCastPoint, heroId: heroId, slot: slot,
    first: mapX, second: mapY
  )

proc queueLevelAbility*(heroId, slot: int32) =
  ## Queues a player-selected unlock or upgrade for the next decision tick.
  pending.add PlayerCommand(
    kind: CommandLevelAbility, heroId: heroId, slot: slot
  )

proc activatePlayerAbility*(
    world: World,
    heroId, slotId, selectedId, aimX, aimY: int32
): bool =
  ## Casts immediate actions or the current target, otherwise arms map aiming.
  let hero = world.heroById(heroId)
  if hero.id == 0 or hero.hp <= 0 or hero.state == Dying or
    slotId < 0 or slotId > HeroAbilitySlot.high.ord:
      return false
  let spec = heroAbility(hero.class, HeroAbilitySlot(slotId)).abilitySpec
  armedAbility = -1
  armedItem = -1
  if hero.abilityLevels[HeroAbilitySlot(slotId)] == 0:
    queueCastTarget(heroId, slotId, heroId)
    return true
  if spec.casting == SelfCast:
    queueCastTarget(heroId, slotId, heroId)
    return true
  var
    mapX = aimX
    mapY = aimY
  for id in [selectedId, hero.attackObjectId]:
    if id == 0 or id == heroId:
      continue
    var target: WorldObject
    if not world.spellTarget(id, target) or not target.alive or
      not world.visible(hero.team, target.position):
        continue
    if not spec.canTarget(target.faction == hero.team.ord.int32):
      continue
    if spec.casting == MeleeCast and
      not within(hero.position, target.position, spec.range):
        mapX = mapCoordinate(target.position.x)
        mapY = mapCoordinate(target.position.z)
        break
    queueCastTarget(heroId, slotId, id)
    return true
  if spec.casting == MeleeCast:
    queueCastPoint(heroId, slotId, mapX, mapY)
    return true
  armedAbility = slotId

proc action(command: PlayerCommand, tick: int32): ReplayAction =
  ## Converts a human intent to the same payload used by bot commands.
  const Kinds: array[PlayerCommandKind, uint8] = [
    ActionDraft, ActionWalkTo, ActionAttackTarget, ActionAttackMove,
    ActionBuyItem, ActionUseItem, ActionUseItemAt, ActionCastTarget,
    ActionCastPoint, ActionLevelAbility, ActionBuyback
  ]
  ReplayAction(
    tick: uint32(tick), heroId: command.heroId, kind: Kinds[command.kind],
    first: command.first, second: command.second, slot: command.slot
  )

proc clearPlayerCommands*() =
  ## Releases input from the previous match before creating another one.
  pending.setLen(0)
  armedAbility = -1
  armedItem = -1
  shopOpen = false
  purchaseReceipt = PurchaseReceipt()

proc flushPlayerCommands*(game: Game) =
  ## Drains the human queue on a decision tick.
  if pending.len == 0:
    return
  let commands = pending
  pending.setLen(0)
  for command in commands:
    let accepted = game.submitAction(command.action(game.world.tick))
    if command.kind == CommandBuy and not game.networked:
      purchaseReceipt = PurchaseReceipt(
        serial: purchaseReceipt.serial + 1,
        heroId: command.heroId, itemId: command.first, accepted: accepted
      )
