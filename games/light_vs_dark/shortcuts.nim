## Game-specific two-stroke shortcuts, independent of window/rendering code.
import std/[json, strutils]
import content, controls, sim

type
  ShortcutAction* = enum
    BuildTownHallShortcut, BuildFarmShortcut, BuildBarracksShortcut,
    BuildLumberMillShortcut, BuildTowerShortcut, BuildStablesShortcut,
    BuildChurchShortcut, BuildBlacksmithShortcut,
    TrainPeonShortcut, TrainSoldierShortcut, TrainArcherShortcut,
    TrainMageShortcut, TrainKnightShortcut, TrainCatapultShortcut,
    TrainClericShortcut, TrainSummonShortcut
  ShortcutBindings* = array[ShortcutAction, string]
  ShortcutState* = object
    prefix: char
    started: float64
    held: set[char]
    consumedKeys: set[char]
  ShortcutMatch* = object
    consumed*: bool
    action*: int

const DefaultShortcuts*: ShortcutBindings = [
  "BH", "BF", "BB", "BL", "BT", "BS", "BC", "BK",
  "TP", "TS", "TA", "TM", "TK", "TC", "TH", "TE"
]

const ShortcutTimeout* = 1.25

const ShortcutLabels*: array[ShortcutAction, string] = [
  "Build Town Hall", "Build Farm", "Build Barracks", "Build Lumber Mill",
  "Build Tower", "Build Stables", "Build Church", "Build Blacksmith",
  "Train Peon", "Train Swordsman", "Train Archer", "Train Mage",
  "Train Knight", "Train Catapult", "Train Cleric", "Train Elemental"
]

proc shortcutLabel*(action: ShortcutAction): string = ShortcutLabels[action]

proc normalizeSequence(text: string): string =
  for key in text:
    if key notin Whitespace:
      result.add key.toUpperAscii
  if result.len != 2 or result[0] notin {'A'..'Z', '0'..'9'} or
      result[1] notin {'A'..'Z', '0'..'9'}:
    raise newException(ValueError, "Use exactly two letters or digits, e.g. B B.")

proc setShortcut*(bindings: var ShortcutBindings, action: ShortcutAction,
    text: string): string =
  ## Returns a visible error and leaves all bindings unchanged on conflict.
  var sequence: string
  try: sequence = normalizeSequence(text)
  except ValueError: return getCurrentExceptionMsg()
  for other in ShortcutAction:
    if other != action and bindings[other] == sequence:
      return "Already assigned to " & shortcutLabel(other) & "."
  bindings[action] = sequence

proc resetShortcuts*(bindings: var ShortcutBindings) = bindings = DefaultShortcuts

proc encodeShortcuts*(bindings: ShortcutBindings): string =
  var root = newJObject()
  root["version"] = %1
  var rows = newJObject()
  for action in ShortcutAction:
    rows[$action] = %bindings[action]
  root["bindings"] = rows
  $root

proc decodeShortcuts*(bytes: string): ShortcutBindings =
  result = DefaultShortcuts
  if bytes.len == 0: return
  try:
    let root = parseJson(bytes)
    if root.kind != JObject or root["version"].getInt != 1 or
        root["bindings"].kind != JObject:
      raise newException(ValueError, "Unsupported shortcut settings format.")
    # Read the full map before validation so valid swaps can round-trip.
    for action in ShortcutAction:
      if root["bindings"].hasKey($action):
        result[action] = normalizeSequence(root["bindings"][$action].getStr)
    for action in ShortcutAction:
      for other in ShortcutAction:
        if action != other and result[action] == result[other]:
          raise newException(ValueError, "Duplicate shortcut: " & result[action])
  except CatchableError:
    raise newException(ValueError, "Cannot read shortcuts: " & getCurrentExceptionMsg())


proc performShortcut*(world: World, player: int32,
    selected: openArray[int32], action: ShortcutAction): bool =
  ## Never mutate simulation state: placement is armed, training is queued.
  ## Validators run again on the normal local/replay/network command path.
  if world == nil or player < 0 or player >= world.players.len: return false
  if action <= BuildBlacksmithShortcut:
    let kind = BuildingKind(action.ord)
    if not world.canBuild(player, kind): return false
    for id in selected:
      let index = world.unitIndex(id)
      if index < 0: continue
      let unit = world.units[index]
      if unit.owner == player and unit.kind == PeonUnit and unit.hp > 0 and
          unit.state notin {UnitDying, UnitInMine}:
        pendingBuild = kind.ord.int32
        attackMoveArmed = false
        return true
  else:
    let kind = UnitKind(action.ord - TrainPeonShortcut.ord)
    for id in selected:
      let index = world.buildingIndex(id)
      if index < 0: continue
      if world.buildings[index].owner == player and
          world.buildings[index].hp > 0 and world.canTrain(id, kind):
        queueTrain(player, id, kind.ord.int32)
        return true

proc cancelShortcut*(state: var ShortcutState) =
  state.prefix = '\0'

proc resetShortcut*(state: var ShortcutState) =
  state = ShortcutState()

proc releaseShortcut*(state: var ShortcutState, key: char) =
  state.held.excl key.toUpperAscii
  state.consumedKeys.excl key.toUpperAscii

proc pressShortcut*(state: var ShortcutState, bindings: ShortcutBindings,
    key: char, now: float64, gameplay = true, modified = false): ShortcutMatch =
  result.action = -1
  let key = key.toUpperAscii
  if not gameplay or modified:
    state.cancelShortcut()
    state.held.incl key
    return
  if now - state.started > ShortcutTimeout or now < state.started:
    state.cancelShortcut()
  if key in state.held:
    result.consumed = key in state.consumedKeys
    return
  state.held.incl key
  if state.prefix != '\0':
    let sequence = $state.prefix & $key
    state.prefix = '\0'
    result.consumed = true
    state.consumedKeys.incl key
    for action in ShortcutAction:
      if bindings[action] == sequence:
        result.action = action.ord
        return
  else:
    for sequence in bindings:
      if sequence.len == 2 and sequence[0] == key:
        state.prefix = key
        state.started = now
        result.consumed = true
        state.consumedKeys.incl key
        return
