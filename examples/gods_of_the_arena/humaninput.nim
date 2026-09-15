## Frame input that can be exercised without opening a renderer.
import windy, content, maps, sim, controls, keybinds

type
  HumanKeys* = object
    pressed*, held*: set[Button]
    focused*: bool
  PlayerAim* = object
    x*, y*, pickedId*: int32
    onMap*: bool
  HumanInputState* = object
    steeringX, steeringY: int32
    steeringTick: int32
    stopOnResume: bool

proc stopSteering*(state: var HumanInputState, heroId: int32) =
  if state.steeringX != 0 or state.steeringY != 0:
    queueStop(heroId)
  state = HumanInputState()

proc activateFromInput*(world: World, heroId: int32, slot: int,
    aim: PlayerAim, inspectedId: int32, fromHud = false): bool =
  let hero = world.heroById(heroId)
  if hero.id == 0: return false
  let mode = if fromHud and castMode == QuickCast: NormalCast else: castMode
  let picked = if mode == AssistedCast: inspectedId else: aim.pickedId
  let x = if aim.onMap: aim.x else: mapCoordinate(hero.position.x)
  let y = if aim.onMap: aim.y else: mapCoordinate(hero.position.z)
  if not aim.onMap and mode == QuickCast and
    heroAbility(hero.class, HeroAbilitySlot(slot)).abilitySpec.casting != SelfCast:
      notifyPlayer("Point at the battlefield to cast", true)
      return false
  activatePlayerAbility(world, heroId, slot.int32, picked, x, y, mode,
    useCombatTarget = mode != QuickCast)

proc handlePlayerKeys*(state: var HumanInputState, keys: HumanKeys,
    world: World, heroId, inspectedId: int32, aim: PlayerAim,
    acceptsCommands: bool) =
  ## Presses are edge-triggered: holding a spell never queues a future cast.
  if not acceptsCommands or not keys.focused:
    state.stopOnResume = state.stopOnResume or state.steeringX != 0 or state.steeringY != 0
    if state.stopOnResume and acceptsCommands:
      state.stopSteering(heroId)
    return
  if state.stopOnResume: state.stopSteering(heroId)
  let hero = world.heroById(heroId)
  if hero.id == 0: return
  for slot in 0 .. 3:
    if (abilityKey(slot) in keys.pressed):
      discard activateFromInput(world, heroId, slot, aim, inspectedId)
  if hudAbilityRequest >= 0:
    let slot = hudAbilityRequest
    hudAbilityRequest = -1
    discard activateFromInput(world, heroId, int(slot), aim, inspectedId, true)
  if (playKey(AttackMove) in keys.pressed):
    cancelPlayerAim()
    attackMoveArmed = true
    notifyPlayer("Attack-move: left-click a destination; Esc cancels")
  if (playKey(Stop) in keys.pressed): queueStop(heroId)
  if (KeyF in keys.pressed): queueUseItem(heroId, 0)
  if (KeyG in keys.pressed): queueUseItem(heroId, 1)
  if controlPreset != WasdControls:
    state.stopSteering(heroId)
    return
  let dx = int32((KeyD in keys.held)) - int32((KeyA in keys.held))
  let dy = int32((KeyS in keys.held)) - int32((KeyW in keys.held))
  if dx == 0 and dy == 0:
    state.stopSteering(heroId)
  elif dx != state.steeringX or dy != state.steeringY or
      world.tick - state.steeringTick >= 2:
    state.steeringX = dx
    state.steeringY = dy
    state.steeringTick = world.tick
    queueWalkTo(heroId, clamp(mapCoordinate(hero.position.x) + dx * 4, 0'i32, int32(mapTiles() - 1)),
      clamp(mapCoordinate(hero.position.z) + dy * 4, 0'i32, int32(mapTiles() - 1)))

proc handlePlayerKeys*(state: var HumanInputState, window: Window,
    world: World, heroId, inspectedId: int32, aim: PlayerAim,
    acceptsCommands: bool) =
  let keys = HumanKeys(focused: window.focused,
    pressed: pressedPlayButtons, held: heldPlayButtons)
  state.handlePlayerKeys(keys, world, heroId, inspectedId, aim, acceptsCommands)
