## Human hero commands for Gods of the Arena.
##
## Graphics queues intents. The decide tick applies them through the same
## `apply*` procs the BASIC bots use.

import
  std/times,
  polyworld/metrics,
  content, maps, sim, replays

type
  CastMode* = enum
    QuickCast, NormalCast, AssistedCast

  PlayerCommandKind = enum
    CommandStop
    CommandWalk
    CommandAttack
    CommandAttackMove
    CommandBuy
    CommandUse
    CommandCastTarget
    CommandCastPoint

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
  shopOpen* = false
  castMode* = QuickCast
  feedbackText*: string
  feedbackError*: bool
  feedbackTime*: float64

proc notifyPlayer*(text: string, error = false) =
  feedbackText = text
  feedbackError = error
  feedbackTime = epochTime()

proc cancelPlayerAim*() =
  armedAbility = -1

proc resetPlayerCommands*() =
  pending.setLen(0)
  cancelPlayerAim()

proc queueStop*(heroId: int32) =
  ## Cancels the hero's current path and attack.
  pending.add PlayerCommand(kind: CommandStop, heroId: heroId)

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

proc queueCastTarget*(heroId, slot, targetId: int32) =
  ## Queues one ability on the object under the player's pointer.
  pending.add PlayerCommand(
    kind: CommandCastTarget, heroId: heroId, slot: slot, first: targetId
  )

proc queueCastPoint*(heroId, slot, mapX, mapY: int32) =
  ## Queues an ability toward the ground even when no object is selected.
  pending.add PlayerCommand(
    kind: CommandCastPoint, heroId: heroId, slot: slot,
    first: mapX, second: mapY
  )

proc castTargetAt*(world: World, hero: Hero, slot: HeroAbilitySlot,
    picked: int32): int32 =
  let spec = heroAbility(hero.class, slot).abilitySpec
  if spec.casting == SelfCast: return hero.id
  var target: WorldObject
  if picked != 0 and world.spellTarget(picked, target) and
    target.alive and world.visible(hero.team, target.position) and
    ((spec.kind == Strike and target.team != hero.team) or
      (spec.kind != Strike and target.team == hero.team)):
        result = picked

proc confirmPlayerAbility*(world: World, heroId, slotId, picked,
    aimX, aimY: int32): bool =
  if slotId notin 0'i32 .. HeroAbilitySlot.high.ord.int32: return false
  let hero = world.heroById(heroId)
  if hero.id == 0: return false
  let slot = HeroAbilitySlot(slotId)
  let target = world.castTargetAt(hero, slot, picked)
  if aimX < 0 or aimY < 0 or aimX >= mapTiles().int32 or
      aimY >= mapTiles().int32:
    notifyPlayer("Point at the battlefield to cast", true)
    return false
  let checked = world.previewSpell(hero, slot, target, hero.spellAimPoint(aimX, aimY))
  if checked.reason.len > 0:
    notifyPlayer(checked.reason, true)
    return false
  if target != 0: queueCastTarget(heroId, slotId, target)
  else: queueCastPoint(heroId, slotId, aimX, aimY)
  cancelPlayerAim()
  true

proc activatePlayerAbility*(world: World, heroId, slotId, selectedId,
    aimX, aimY: int32, mode = QuickCast, useCombatTarget = true): bool =
  ## Keys, HUD, and spell tests share this. Default targeting matches the
  ## previous selected/attack-object fallback; QuickCast can ignore it.
  if slotId notin 0'i32 .. HeroAbilitySlot.high.ord.int32: return false
  let hero = world.heroById(heroId)
  if hero.id == 0: return false
  let slot = HeroAbilitySlot(slotId)
  let reason = world.abilityReadyReason(hero, slot)
  if reason.len > 0:
    notifyPlayer(reason, true)
    return false
  cancelPlayerAim()
  let spec = heroAbility(hero.class, slot).abilitySpec
  if spec.casting == SelfCast:
    return confirmPlayerAbility(world, heroId, slotId, heroId,
      mapCoordinate(hero.position.x), mapCoordinate(hero.position.z))
  if mode == NormalCast:
    armedAbility = slotId
    notifyPlayer(spec.name & ": left-click to cast; right-click or Esc cancels")
    return false
  var chosen = 0'i32
  var chosenX, chosenY: int32
  for id in [selectedId, (if useCombatTarget: hero.attackObjectId else: 0'i32)]:
    let picked = world.castTargetAt(hero, slot, id)
    if picked == 0: continue
    var target: WorldObject
    if world.spellTarget(picked, target):
      chosen = picked
      chosenX = mapCoordinate(target.position.x)
      chosenY = mapCoordinate(target.position.z)
      break
  if chosen != 0:
    var target: WorldObject
    discard world.spellTarget(chosen, target)
    if spec.casting == MeleeCast and
        not within(hero.position, target.position, spec.range):
      queueCastPoint(heroId, slotId, chosenX, chosenY)
      return true
    queueCastTarget(heroId, slotId, chosen)
    return true
  if spec.casting == MeleeCast:
    queueCastPoint(heroId, slotId, aimX, aimY)
    return true
  if mode == QuickCast and not useCombatTarget:
    return confirmPlayerAbility(world, heroId, slotId, 0, aimX, aimY)
  armedAbility = slotId
  notifyPlayer(spec.name & ": choose a target with left-click")
  false

proc recordCommand(game: Game, command: PlayerCommand) =
  ## Writes one human command attempt onto the live tape.
  if game.recorder == nil:
    return
  let tick = uint32(game.world.tick)
  case command.kind
  of CommandStop:
    game.recorder.record ReplayAction(
      tick: tick, heroId: command.heroId, kind: ActionStop
    )
  of CommandWalk:
    game.recorder.recordWalkTo(
      tick, command.heroId, command.first, command.second
    )
  of CommandAttack:
    game.recorder.recordAttackTarget(tick, command.heroId, command.first)
  of CommandAttackMove:
    game.recorder.recordAttackMove(
      tick, command.heroId, command.first, command.second
    )
  of CommandBuy:
    game.recorder.recordBuyItem(tick, command.heroId, command.first)
  of CommandUse:
    game.recorder.recordUseItem(tick, command.heroId, command.first)

  of CommandCastTarget, CommandCastPoint:
    game.recorder.recordCast(
      tick, command.heroId, command.slot, command.first, command.second,
      command.kind == CommandCastPoint
    )

proc applyCommand(game: Game, command: PlayerCommand): bool =
  ## Applies one queued command through the bot validators.
  case command.kind
  of CommandStop:
    applyStop(game.world, command.heroId)
  of CommandWalk:
    applyWalkTo(
      game.world, command.heroId, command.first, command.second
    )
  of CommandAttack:
    applyAttackTarget(game.world, command.heroId, command.first)
  of CommandAttackMove:
    applyAttackMove(
      game.world, command.heroId, command.first, command.second
    )
  of CommandBuy:
    applyBuyItem(game.world, command.heroId, command.first)
  of CommandUse:
    applyUseItem(game.world, command.heroId, command.first)

  of CommandCastTarget:
    applyCastTarget(game.world, command.heroId, command.slot, command.first)
  of CommandCastPoint:
    applyCastPoint(
      game.world, command.heroId, command.slot, command.first, command.second
    )

proc commandReason(world: World, command: PlayerCommand): string =
  let hero = world.heroById(command.heroId)
  if hero.id == 0: return "Hero unavailable"
  if hero.hp <= 0 or hero.state == Dying:
    return "Respawning in " & hero.respawnTicks.secondsLabel
  case command.kind
  of CommandCastTarget, CommandCastPoint:
    let aim = if command.kind == CommandCastPoint:
      hero.spellAimPoint(command.first, command.second) else: hero.position
    result = world.previewSpell(hero, HeroAbilitySlot(command.slot),
      if command.kind == CommandCastTarget: command.first else: 0'i32, aim).reason
  of CommandBuy: result = world.purchaseReason(command.heroId, command.first)
  of CommandUse:
    if command.first notin 0'i32 .. InventorySlots.int32 - 1:
      return "Invalid item slot"
    let item = hero.inventory[command.first]
    if item == NoItem: return "That item slot is empty"
    let spec = item.itemSpec
    if spec.kind == Equipment: return "Equipment is already active"
    if spec.heal > 0 and hero.hp >= hero.maxHp: return "Health is full"
    if spec.restore > 0 and hero.mana >= hero.maxMana: return "Mana is full"
    if spec.strike > 0: return "Attack an enemy in range to use poison"
  of CommandAttack: result = "Target unavailable or protected"
  of CommandWalk, CommandAttackMove: result = "Cannot reach that ground"
  of CommandStop: result = "Cannot stop right now"
  if result.len == 0: result = "Command unavailable"

proc flushPlayerCommands*(game: Game) =
  ## Drains the human queue on a decision tick.
  if pending.len == 0:
    return
  let commands = pending
  pending.setLen(0)
  for command in commands:
    game.recordCommand(command)
    let accepted = game.applyCommand(command)
    if command.kind == CommandBuy:
      purchaseReceipt = PurchaseReceipt(
        serial: purchaseReceipt.serial + 1,
        heroId: command.heroId, itemId: command.first, accepted: accepted
      )
    if not accepted:
      notifyPlayer(game.world.commandReason(command), true)
    if accepted:
      if command.kind in {CommandCastTarget, CommandCastPoint}:
        let hero = game.world.heroById(command.heroId)
        notifyPlayer(
          heroAbility(hero.class, HeroAbilitySlot(command.slot)).abilitySpec.name &
            " cast"
        )
      game.metrics.command(
        heroIndex(game.world, command.heroId), game.world.tick
      )
