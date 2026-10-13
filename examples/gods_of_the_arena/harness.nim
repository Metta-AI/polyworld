## Native Gods of the Arena training hero, a 1:1 port of harness.bas.
##
## Training lanes run this instead of one bassy VM per hero. `think` runs
## once per hero per tick, exactly when the VM would run. It reads the same
## host observations, writes the same moba-style observation, applies the
## ten action heads where harness.bas has its `' METTA_DECISION` marker,
## and issues the same commands in the same order. `Harness` holds the
## BASIC globals that matter between and within ticks, named as in BASIC.
## Arithmetic stays in int32 and division truncates toward zero, as in
## bassy with decimals disabled. No value comes near the int32 range, so
## bassy's wrapping never applies. The script calls no random functions.
##
## Tokenized layout (the polyworld-tokens experiment, with the one-key
## actions; harness.bas still has the full layout). The observation is 541
## int32 values instead of a mostly empty grid: obs[0 ..< 81] marks the
## walkable tiles within 4 tiles (9 x 9, mirrored for team 1); obs[81 ..<
## 201] holds 24 tokens of 5 values, one per visible object nearest first
## (occupant code, dx, dy clamped to 16, health tenths, level; zeros when
## fewer are in sight); obs[201 ..< 251] are the 50 self scalars listed in
## `observe`; obs[251 ..< 285] gives each of the 34 structures, own team
## first, its health tenths plus 1 while the team believes it alive; and
## obs[285 ..< 541] is an 8 x 8 minimap, 15 x 15 tiles per cell, of ally
## and enemy heroes and ally and enemy creeps (counts up to 9).
## One action head of 22 keys, pressed once per tick rather than held: 0
## presses nothing and lets the current order run (an idle hero attacks its
## focus target in reach, as moba heroes do), 1 to 8 attack-move 6 tiles in
## one of 8 directions (ignored during a fight), 9 attacks the nearest enemy
## and 10 the nearest enemy hero, structure or god (each also sets the
## focus), 11 to 14 cast Q, W, E or R at the focus target, 15 walks home,
## and 16 to 21 are the menu: shop cursor next and back, buy the item under
## it, inventory cursor next, use the item under it, and buyback.
##
## Standing still with target 0 retreats: the hero walks back to the spot
## it last spawned at, where the spawn room heals it, as base.bas does
## below a quarter of its health.
##
## The target head also picks how the hero moves: 0 walks past enemies
## (to retreat), 1 and 2 attack-move, so the hero fights what it meets the
## way the scripted bots and moba's always-on attacks do. While it fights,
## no new move order interrupts the swing.
##
## After spawn and after every respawn a scripted walk takes the hero to
## its lane (`walkLane`), as Dota bots script their opening, with chance
## `walkPercent` and for `walkReach` percent of the way, so that training
## can wean the policy off it. Until an enemy other than a camp creep is
## within 8 tiles the policy only shops and buys back; the move, target and
## cast heads apply once the walk ends.

import
  std/algorithm,
  fixxy,
  polyworld/[bodies, metrics, pathing],
  content, maps, replays, sim, terrains

const
  GridReach = 4'i32
    ## Tiles from the hero to the edge of the walkable-tile grid.
  GridSide = int(2 * GridReach + 1)
  GridCells = GridSide * GridSide
  TokenCount = 24
    ## Visible objects described one by one, nearest first.
  TokenSize = 5
    ## Values per token: code, dx, dy, health tenths and level.
  TokenReach = 16'i32
    ## Token offsets are clamped to the vision radius.
  TokenStart = GridCells
  ScalarStart = TokenStart + TokenCount * TokenSize
  ScalarCount = 50
  StructureSlots = 34
    ## The map's towers, barracks and gate towers, own team first.
  StructureStart = ScalarStart + ScalarCount
  MiniTiles = 15'i32
    ## Map tiles per minimap cell side.
  MiniSide = 8
    ## Minimap cells per side, covering the 116-tile map.
  MiniCells = MiniSide * MiniSide
  MiniStart = StructureStart + StructureSlots
  ObservationSize* = MiniStart + 4 * MiniCells
  ActionSizes* = [22'i32]
  ActionCount* = ActionSizes.len
  BuildItems = [[8'i32, 1], [1, 2], [21, 2], [22, 2]]
    ## base.bas's shopping list for every hero, as item and count: ranger
    ## boots, health potions, portal scrolls and mana potions.
  RoleBuilds = [
    [[16'i32, 1], [2, 2]],
    [[19'i32, 1], [4, 2]],
    [[20'i32, 1], [3, 2]]
  ]
    ## Then by role: knight armor and vitality elixirs for frontline and
    ## fighters, a rune crossbow and poison potions for carries, an arcane
    ## spellbook and mana elixirs for mages and supports.
  MoveTiles = 6'i32
    ## Tiles per move order.
  MoveSteps = [[0'i32, 0], [0, 1], [1, 1], [1, 0], [1, -1], [0, -1],
    [-1, -1], [-1, 0], [-1, 1]]
    ## The move head's (x, y) directions in the hero's mirrored frame:
    ## stand, then N, NE, E, SE, S, SW, W and NW.
  ShopItemCount = 22'i32
    ## Items the shop cursor cycles through, Item ordinals 1 to 22.
  TargetReach = 65'i32
    ## One more than the squared 8-tile target radius.
  CodeRanks = [0'i32, 3, 3, 1, 1, 1, 2, 2, 4, 4]
    ## Occupant priority by code: god, hero, structure, then creep.
  LaneSlots = [0'i32, 0, 1, 2, 2]
    ## The game's HeroLanes: two heroes top, one mid, two bottom.
  LaneOrderTicks = 24'i32
    ## Ticks between scripted lane walk orders, one per second.
  LaneWalkTicks = 2160'i32
    ## The longest scripted lane walk, 90 seconds.
  LaneArrival = 16'i32
    ## Squared tiles from the lane point that end the walk.

type
  HeroData = object
    ## The host data slots runHeroScript publishes before each VM run.
    id, team, class, x, y: int32
    hp, maxHp, mana, maxMana, gold, level: int32
    tick, target, deaths: int32
    channelTicks, stunTicks, rootTicks, silenceTicks: int32
    drafting: bool
    draftTurnId: int32

  Turn = object
    ## One hero's view while it thinks: the game, its slot, and host data.
    game: Game
    world: World
    hero: Hero
    index: int
    data: HeroData

  Harness* = object
    ## The harness.bas globals, named as in BASIC and exported so tools can
    ## compare them with the VM. A fresh Harness matches a fresh script.
    initialized*: bool
    castRange*: array[5, int32]
    side*: int32
    enemyId*, enemyX*, enemyY*, enemyDistance*: int32
    laneDistance*: int32
      ## Squared distance to the nearest enemy that is not a camp creep.
    priorityId*, priorityX*, priorityY*, priorityDistance*: int32
    bestId*, bestX*, bestY*, bestDistance*: int32
    casted*: bool
    walking*: bool
    laneX*, laneY*, orderTick*, walkUntil*, walkStop*: int32
    homeX*, homeY*: int32
      ## Where the hero last spawned, the goal of a retreat.
    walkPercent*: int32
      ## Chance that a spawned hero walks to its lane; the trainer lowers
      ## it to wean the policy off the walk (harness.bas: 100).
    walkReach*: int32
      ## Percent of the way from spawn to the lane point that the walk
      ## covers; the trainer lowers it to wean gradually (harness.bas: 100).
    build*: bool
      ## Any nonzero buy choice buys the next item of base.bas's shopping
      ## list instead of that item (harness.bas: off).
    retreatPercent*: int32
      ## Below this share of its health the hero walks home and heals to
      ## 90% before the policy moves it again, as base.bas does below a
      ## quarter; 0 is off (harness.bas: 0).
    retreating*: bool
    shopCursor*, inventoryCursor*: int32
    focus*: int32
      ## The attack focus set by keys 9 and 10: 1 the nearest enemy, 2 the
      ## nearest enemy hero, structure or god (0 before the first press).
      ## The menu head's cursors: an item to buy (1 to 22, 0 before the
      ## first move) and an inventory slot (0 to 5).

proc heroData(world: World, hero: Hero): HeroData =
  ## Captures the host data runHeroScript sets before each VM run.
  let tick = world.tick
  HeroData(
    id: hero.id,
    team: int32(hero.team.ord),
    class: world.draftedClass(hero.id),
    x: mapCoordinate(hero.position.x, hero.team),
    y: mapCoordinate(hero.position.z, hero.team),
    hp: max(hero.hp, 0'i32),
    maxHp: hero.maxHp,
    mana: hero.mana,
    maxMana: hero.maxMana,
    gold: int32(hero.gold),
    level: int32(hero.level),
    tick: tick,
    target: hero.attackObjectId,
    deaths: hero.deaths,
    channelTicks: max(0'i32, hero.portalEnds - tick),
    stunTicks: max(0'i32, hero.controls[StunControl].ends - tick),
    rootTicks: max(0'i32, hero.controls[RootControl].ends - tick),
    silenceTicks: max(0'i32, hero.controls[SilenceControl].ends - tick),
    drafting: world.phase == Drafting,
    draftTurnId: world.draftHeroId()
  )

proc classRole(class: int32): int32 =
  ## Mirrors the heroRole host call: a role ordinal, or -1 when invalid.
  if class < 0 or class > HeroClass.high.ord:
    return -1
  int32(HeroClass(class).heroRole.ord)

proc mapSize(): int32 =
  ## Returns mapWidth and mapHeight, which are equal.
  int32(mapTiles())

proc countCommand(turn: Turn, accepted: bool) =
  ## Counts an accepted command in the match metrics like the host calls.
  if accepted:
    turn.game.metrics.command(turn.index, turn.world.tick)

proc draftHero(turn: Turn, class: int32): bool =
  ## Records and applies a draft pick like the draftHero host call.
  turn.game.recorder.record ReplayAction(
    tick: uint32(turn.world.tick),
    heroId: turn.data.id,
    kind: ActionDraft,
    first: class
  )
  result = turn.world.applyDraft(turn.data.id, class)
  turn.countCommand(result)

proc levelAbility(turn: Turn, slot: int32): bool =
  ## Records and spends an ability point like the levelAbility host call.
  turn.game.recorder.recordLevelAbility(
    uint32(turn.world.tick),
    turn.data.id,
    slot
  )
  result = turn.world.applyLevelAbility(turn.data.id, slot)
  turn.countCommand(result)

proc walkTo(turn: Turn, x, y: int32): bool =
  ## Records and applies a walk order like the walkTo host call.
  let (tileX, tileY, offset) = splitTilePoint(fixedVec2(fixed(x), fixed(y)))
  turn.game.recorder.recordWalkTo(
    uint32(turn.world.tick),
    turn.data.id,
    tileX,
    tileY,
    offset
  )
  result = turn.world.applyWalkTo(turn.data.id, tileX, tileY, offset)
  turn.countCommand(result)

proc attackMove(turn: Turn, x, y: int32): bool =
  ## Records and applies an attack-move order like the attackMove host call.
  let (tileX, tileY, offset) = splitTilePoint(fixedVec2(fixed(x), fixed(y)))
  turn.game.recorder.recordAttackMove(
    uint32(turn.world.tick),
    turn.data.id,
    tileX,
    tileY,
    offset
  )
  result = turn.world.applyAttackMove(turn.data.id, tileX, tileY, offset)
  turn.countCommand(result)

proc attackTarget(turn: Turn, target: int32): bool =
  ## Records and applies an attack order like the attackTarget host call.
  turn.game.recorder.recordAttackTarget(
    uint32(turn.world.tick),
    turn.data.id,
    target
  )
  result = turn.world.applyAttackTarget(turn.data.id, target)
  turn.countCommand(result)

proc buyItem(turn: Turn, item: int32): bool =
  ## Records and applies a purchase like the buyItem host call.
  turn.game.recorder.recordBuyItem(uint32(turn.world.tick), turn.data.id, item)
  result = turn.world.applyBuyItem(turn.data.id, item)
  turn.countCommand(result)

proc useItem(turn: Turn, slot: int32): bool =
  ## Records and applies an item use like the useItem host call.
  turn.game.recorder.recordUseItem(uint32(turn.world.tick), turn.data.id, slot)
  result = turn.world.applyUseItem(turn.data.id, slot)
  turn.countCommand(result)

proc buyback(turn: Turn): bool =
  ## Records and attempts a buyback like the buyback host call.
  turn.game.recorder.recordBuyback(uint32(turn.world.tick), turn.data.id)
  result = turn.world.applyBuyback(turn.data.id)
  turn.countCommand(result)

proc castTarget(turn: Turn, slot, target: int32): bool =
  ## Records and applies an object-targeted spell like castTarget.
  turn.game.recorder.recordCast(
    uint32(turn.world.tick),
    turn.data.id,
    slot,
    target,
    0,
    false
  )
  result = turn.world.applyCastTarget(turn.data.id, slot, target)
  turn.countCommand(result)

proc castPoint(turn: Turn, slot, x, y: int32): bool =
  ## Records and applies a ground-aimed spell like castPoint.
  let (tileX, tileY, offset) = splitTilePoint(fixedVec2(fixed(x), fixed(y)))
  turn.game.recorder.recordCast(
    uint32(turn.world.tick),
    turn.data.id,
    slot,
    tileX,
    tileY,
    true,
    offset
  )
  result = turn.world.applyCastPoint(turn.data.id, slot, tileX, tileY, offset)
  turn.countCommand(result)

proc canLevelAbility(turn: Turn, slot: int32): bool =
  ## Mirrors the canLevelAbility host call for a valid slot.
  turn.world.phase != Drafting and
    turn.hero.abilityLevelError(HeroAbilitySlot(slot)) == NoActionError

proc inOwnSpawn(turn: Turn): bool =
  ## Mirrors the inOwnSpawn host call, read live.
  turn.hero.inOwnSpawn

proc terrainWalkable(turn: Turn, x, y: int32): bool =
  ## Mirrors terrainWalkable on the hero's live layer, with known buildings.
  let layer = turn.hero.navLayer
  if terrainValue(x, y, layer, TerrainWalkableField) == 0:
    return false
  let floor = layers[int(layer)]
  turn.world.knownWalkable(
    turn.hero.team,
    int(layer),
    int(x) + mapOrigin() - floor.originX,
    int(y) + mapOrigin() - floor.originZ
  )

proc chooseHero(turn: Turn) =
  ## Drafts the first available class whose role no teammate has picked.
  if turn.data.draftTurnId != turn.data.id:
    return
  let world = turn.world
  var
    bestClass = -1'i32
    bestScore = -10000'i32
  for candidate in 0'i32 .. 9'i32:
    if world.heroAvailable(candidate, turn.data.id):
      let role = classRole(candidate)
      var score = 100'i32
      for player in 0 ..< world.heroes.len:
        if int32(world.heroes[player].team.ord) == turn.data.team:
          let picked = world.draftedClass(world.heroes[player].id)
          if picked >= 0:
            if classRole(picked) == role:
              score = score - 100
      if score > bestScore:
        bestScore = score
        bestClass = candidate
  if bestClass >= 0:
    discard turn.draftHero(bestClass)

proc learnAbilities(turn: Turn) =
  ## Spends points on the ultimate, then primary, secondary, passive.
  for _ in 1 .. 4:
    if turn.hero.abilityPoints() == 0:
      return
    if turn.canLevelAbility(3):
      discard turn.levelAbility(3)
    elif turn.canLevelAbility(1):
      discard turn.levelAbility(1)
    elif turn.canLevelAbility(2):
      discard turn.levelAbility(2)
    elif turn.canLevelAbility(0):
      discard turn.levelAbility(0)
    else:
      return

proc miniCell(side, x, y: int32): int =
  ## The minimap cell of map tile (x, y), mirrored for team 1.
  var
    column = x
    row = y
  if side != 1:
    column = mapSize() - 1 - x
    row = mapSize() - 1 - y
  min(int(row div MiniTiles), MiniSide - 1) * MiniSide +
    min(int(column div MiniTiles), MiniSide - 1)

proc readObject(
  harness: var Harness,
  turn: Turn,
  value: WorldObject,
  observer: Team,
  observation: var array[ObservationSize, int32],
  tokens: var seq[array[TokenSize + 1, int32]],
  structures: var seq[array[2, int32]]
) =
  ## Adds one visible object to the tokens (with its squared distance in
  ## front, for sorting), the minimap or the visible structures, and to
  ## both target candidates.
  let hp = max(value.hp, 0'i32)
  if hp <= 0:
    return
  let
    kind = value.kind
    team = value.faction
    x = mapCoordinate(value.position.x, observer)
    y = mapCoordinate(value.position.z, observer)
    dx = harness.side * (x - turn.data.x)
    dy = harness.side * (y - turn.data.y)
  if kind != 6:
    let
      ally = int(team == turn.data.team)
      cell = miniCell(harness.side, x, y)
    case kind
    of 2, 3:
      let index = MiniStart + (if kind == 2: 1 - ally else: 3 - ally) *
        MiniCells + cell
      if observation[index] < 9:
        observation[index] = observation[index] + 1
    else:
      discard
  var health = 0'i32
  if value.maxHp > 0:
    health = min(hp * 10 div value.maxHp, 10'i32)
  if kind != 1 and kind != 2 and kind != 3 and kind != 6:
    structures.add [value.id, health]
  if value.id != turn.data.id:
    var code =
      if kind == 1: 9'i32
      elif kind == 2: 2'i32
      elif kind == 3: 4'i32
      elif kind == 6: 5'i32
      else: 7'i32
    if team == turn.data.team:
      code = code - 1
    tokens.add [
      dx * dx + dy * dy,
      code,
      clamp(dx, -TokenReach, TokenReach),
      clamp(dy, -TokenReach, TokenReach),
      health,
      value.level
    ]
  if team == turn.data.team:
    return
  if not value.alive:
    return
  let distance = dx * dx + dy * dy
  if distance < harness.enemyDistance:
    harness.enemyDistance = distance
    harness.enemyId = value.id
    harness.enemyX = x
    harness.enemyY = y
  if kind != 6 and distance < harness.laneDistance:
    harness.laneDistance = distance
  if kind != 3 and kind != 6:
    if distance < harness.priorityDistance:
      harness.priorityDistance = distance
      harness.priorityId = value.id
      harness.priorityX = x
      harness.priorityY = y

proc observe(
  harness: var Harness,
  turn: Turn,
  observation: var array[ObservationSize, int32]
) =
  ## Writes the walkable grid, the tokens, the self scalars, the structures
  ## and the minimap into `observation`.
  let
    data = turn.data
    hero = turn.hero
    side = harness.side
  for cell in 0 ..< ObservationSize:
    observation[cell] = 0
  # terrainWalkable per tile: terrain, then the footprints of buildings the
  # team believes alive, marked once here instead of scanned per tile.
  let layer = hero.navLayer
  var blocked: array[GridCells, bool]
  if layer >= 0 and layer < layers.len:
    let
      shiftX = int32(mapOrigin() - layers[int(layer)].originX)
      shiftZ = int32(mapOrigin() - layers[int(layer)].originZ)
    for building in turn.world.buildings:
      if building.knownAlive[hero.team]:
        for tile in building.footprint:
          if tile.layer == layer:
            let
              column = int(side * (tile.x - shiftX - data.x) + GridReach)
              row = int(side * (tile.z - shiftZ - data.y) + GridReach)
            if column >= 0 and column < GridSide and
              row >= 0 and row < GridSide:
                blocked[row * GridSide + column] = true
  for row in 0 ..< GridSide:
    let tileY = data.y + side * (int32(row) - GridReach)
    for column in 0 ..< GridSide:
      let
        tileX = data.x + side * (int32(column) - GridReach)
        cell = row * GridSide + column
      if tileX >= 0 and tileY >= 0 and tileX < mapSize() and
        tileY < mapSize():
          if terrainValue(tileX, tileY, layer, TerrainWalkableField) != 0 and
            not blocked[cell]:
              observation[cell] = 1
  harness.enemyId = 0
  harness.enemyDistance = TargetReach
  harness.priorityId = 0
  harness.priorityDistance = TargetReach
  harness.laneDistance = TargetReach
  var
    observer = hero.team
    tokens: seq[array[TokenSize + 1, int32]]
    structures: seq[array[2, int32]]
  let objects = turn.world.worldObjectCount(data.id)
  for index in 0 ..< objects:
    let value = turn.world.scriptObject(data.id, index, observer)
    harness.readObject(turn, value[], observer, observation, tokens,
      structures)
  # The nearest objects, one token each.
  tokens.sort(proc (a, b: array[TokenSize + 1, int32]): int = cmp(a[0], b[0]))
  for i in 0 ..< min(tokens.len, TokenCount):
    for j in 0 ..< TokenSize:
      observation[TokenStart + i * TokenSize + j] = tokens[i][j + 1]
  # Every structure, own team first: health tenths plus 1 while the team
  # believes it alive (10 plus 1 when out of sight), else 0.
  var structure = 0
  for own in [true, false]:
    for building in turn.world.buildings:
      if (building.team == hero.team) != own or structure >= StructureSlots:
        continue
      if building.knownAlive[hero.team]:
        var health = 10'i32
        for seen in structures:
          if seen[0] == building.id:
            health = seen[1]
        observation[StructureStart + structure] = health + 1
      inc structure
  # Self scalars, from obs[4356].
  var scalars: array[ScalarCount, int32]
  if side == 1:
    scalars[0] = data.x
    scalars[1] = data.y
  else:
    scalars[0] = mapSize() - 1 - data.x
    scalars[1] = mapSize() - 1 - data.y
  scalars[2] = data.level
  if data.maxHp > 0:
    scalars[3] = data.hp * 10 div data.maxHp
  if data.maxMana > 0:
    scalars[4] = data.mana * 10 div data.maxMana
  scalars[5] = min(data.gold div 100, 255'i32)
  for slot in HeroAbilitySlot:
    let base = 6 + slot.ord * 3
    scalars[base] = hero.abilityLevels[slot]
    scalars[base + 1] = hero.charges[slot]
    scalars[base + 2] = hero.cooldowns[slot] div TickRate
  scalars[18] = hero.abilityPoints()
  scalars[19] = data.rootTicks div TickRate
  scalars[20] = data.stunTicks div TickRate
  scalars[21] = data.silenceTicks div TickRate
  scalars[22] = data.team
  if data.class >= 0 and data.class <= 9:
    scalars[23 + data.class] = 1
  scalars[33] = data.deaths
  scalars[34] = int32(turn.inOwnSpawn())
  scalars[35] = data.tick div (TickRate * 60)
  # The menu: the shop cursor's item, its price and whether it is
  # affordable, the inventory cursor's slot, item, count and readiness,
  # then the six inventory items.
  let shopItem = max(harness.shopCursor, 1'i32)
  scalars[36] = shopItem
  scalars[37] = int32(ItemSpecs[Item(shopItem)].cost)
  scalars[38] = int32(data.gold >= ItemSpecs[Item(shopItem)].cost)
  let slot = harness.inventoryCursor
  scalars[39] = slot
  scalars[40] = int32(hero.inventory[slot].ord)
  scalars[41] = hero.itemCounts[slot]
  scalars[42] = int32(hero.inventory[slot] != NoItem and
    hero.itemCooldown(int(slot), turn.world.tick) == 0)
  for i in 0 ..< InventorySlots:
    scalars[43 + i] = int32(hero.inventory[i].ord)
  scalars[49] = max(harness.focus, 1'i32)
  for i, value in scalars:
    observation[ScalarStart + i] = value

proc buildItem(turn: Turn): int32 =
  ## The first item of base.bas's list the hero has fewer of than listed,
  ## can afford and has room for, or 0.
  let
    hero = turn.hero
    role =
      case classRole(turn.data.class)
      of int32(Frontline.ord), int32(Fighter.ord): 0
      of int32(Carry.ord): 1
      else: 2
  var empty = 0
  for slot in 0 ..< InventorySlots:
    if hero.inventory[slot] == NoItem:
      inc empty
  var entries: seq[array[2, int32]]
  for entry in BuildItems:
    entries.add entry
  for entry in RoleBuilds[role]:
    entries.add entry
  for entry in entries:
    let item = entry[0]
    var owned = 0'i32
    for slot in 0 ..< InventorySlots:
      if hero.inventory[slot].ord == item:
        owned += hero.itemCounts[slot]
    if owned >= entry[1] or (owned == 0 and empty == 0):
      continue
    if turn.data.gold >= ItemSpecs[Item(item)].cost:
      return item
  0

proc menu(harness: var Harness, turn: Turn, code: int32) =
  ## Applies a menu key: 1 and 2 move the shop cursor forward and back, 3
  ## buys the item under it, 4 moves the inventory cursor, 5 uses the item
  ## under it (buyback is handled while dead). With `build`, buying takes
  ## the next item of base.bas's list instead of the cursor's.
  let hero = turn.hero
  case code
  of 1:
    harness.shopCursor = max(harness.shopCursor, 1'i32) mod ShopItemCount + 1
  of 2:
    harness.shopCursor =
      (max(harness.shopCursor, 1'i32) + ShopItemCount - 2) mod
        ShopItemCount + 1
  of 3:
    if turn.world.phase != Drafting and hero.canShop:
      let item =
        if harness.build: turn.buildItem()
        else: max(harness.shopCursor, 1'i32)
      if item > 0 and turn.data.gold >= ItemSpecs[Item(item)].cost:
        discard turn.buyItem(item)
  of 4:
    harness.inventoryCursor = (harness.inventoryCursor + 1) mod InventorySlots
  of 5:
    let slot = harness.inventoryCursor
    if hero.inventory[slot] != NoItem and
      hero.itemCooldown(int(slot), turn.world.tick) == 0:
        discard turn.useItem(slot)
  else:
    discard

proc castSpells(harness: var Harness, turn: Turn, chosen: int32) =
  ## Casts slot `chosen` (0 to 3 for Q, W, E, R) when it is ready and has a
  ## legal target.
  let
    data = turn.data
    hero = turn.hero
  harness.casted = false
  for spellSlot in 0'i32 .. 3'i32:
    if chosen == spellSlot:
      let
        slot = HeroAbilitySlot(spellSlot)
        rank = hero.abilityLevels[slot]
      if rank > 0 and hero.charges[slot] > 0:
        let spec = heroAbility(hero.class, slot).abilitySpec(rank)
        if hero.cooldowns[slot] == 0 and data.mana >= spec.manaCost:
          var accepted = false
          if spec.heal > 0 or spec.restore > 0:
            accepted = turn.castTarget(spellSlot, data.id)
          elif spec.damage > 0 and harness.bestId != 0:
            let reach = harness.castRange[spellSlot]
            if harness.bestDistance <= reach * reach:
              if spellSlot >= 2:
                accepted =
                  turn.castPoint(spellSlot, harness.bestX, harness.bestY)
              else:
                accepted = turn.castTarget(spellSlot, harness.bestId)
          if accepted:
            harness.casted = true
            return

proc travel(turn: Turn, goalX, goalY: int32, marching: bool) =
  ## Walks or attack-moves to the goal, or 3 tiles off it when the goal is
  ## not walkable, the same fallbacks as hero.bas travel().
  for attempt in 0 .. 4:
    var
      tryX = goalX
      tryY = goalY
    case attempt
    of 1:
      tryX = goalX + 3
    of 2:
      tryX = goalX - 3
    of 3:
      tryY = goalY + 3
    of 4:
      tryY = goalY - 3
    else:
      discard
    tryX = max(tryX, 1'i32)
    tryY = max(tryY, 1'i32)
    tryX = min(tryX, mapSize() - 2)
    tryY = min(tryY, mapSize() - 2)
    if turn.terrainWalkable(tryX, tryY):
      let accepted =
        if marching:
          turn.attackMove(tryX, tryY)
        else:
          turn.walkTo(tryX, tryY)
      if accepted:
        return

proc press(harness: var Harness, turn: Turn, key: int32) =
  ## Applies a movement or attack key for a hero that can act.
  let data = turn.data
  case key
  of 0:
    # Nothing pressed: an idle hero attacks its focus target in reach.
    if data.target == 0 and not turn.hero.hasMoveTarget and
      harness.bestId != 0:
        discard turn.attackTarget(harness.bestId)
  of 1 .. 8:
    if data.rootTicks == 0 and data.target == 0:
      # Cut 9 moves one tile per key, like moba's one cell per tick.
      let tiles = if turn.world.cut(9): 1'i32 else: MoveTiles
      turn.travel(
        data.x + harness.side * MoveSteps[key][0] * tiles,
        data.y + harness.side * MoveSteps[key][1] * tiles,
        true
      )
  of 9, 10:
    if harness.bestId != 0 and data.target != harness.bestId:
      discard turn.attackTarget(harness.bestId)
  of 15:
    if data.rootTicks == 0:
      turn.travel(harness.homeX, harness.homeY, false)
  else:
    discard

proc walkLane(harness: var Harness, turn: Turn) =
  ## Walks to the lane until an enemy other than a camp creep is within 8
  ## tiles, the walk has covered its reach, or it runs out of time; then the
  ## policy takes over.
  let
    data = turn.data
    dx = data.x - harness.laneX
    dy = data.y - harness.laneY
  if harness.laneDistance < TargetReach or
    dx * dx + dy * dy <= max(LaneArrival, harness.walkStop) or
    data.tick >= harness.walkUntil:
      harness.walking = false
      return
  if data.rootTicks > 0 or data.tick < harness.orderTick:
    return
  harness.orderTick = data.tick + LaneOrderTicks
  turn.travel(harness.laneX, harness.laneY, false)

proc initialize(harness: var Harness, turn: Turn) =
  ## Sets per-class cast reach in whole tiles and starts the lane walk.
  harness.initialized = true
  harness.castRange[0 .. 3] = [0'i32, 1, 2, 2]
  case turn.data.class
  of 1:
    harness.castRange[0 .. 3] = [7'i32, 6, 6, 8]
  of 2:
    harness.castRange[1] = 5
    harness.castRange[2] = 6
    harness.castRange[3] = 7
  of 3:
    harness.castRange[3] = 3
  of 4:
    harness.castRange[3] = 5
  of 6:
    harness.castRange[0 .. 3] = [7'i32, 6, 6, 7]
  of 7:
    harness.castRange[0 .. 3] = [6'i32, 6, 5, 6]
  of 8:
    harness.castRange[1] = 4
    harness.castRange[2] = 4
    harness.castRange[3] = 5
  else:
    discard
  # Lane midpoints, where both teams' creeps meet: two corners and the centre.
  case LaneSlots[(turn.data.id - FirstHeroId) mod 5]
  of 0:
    harness.laneX = mapSize() div 10
    harness.laneY = mapSize() div 10
  of 1:
    harness.laneX = mapSize() div 2
    harness.laneY = mapSize() div 2
  else:
    harness.laneX = mapSize() * 9 div 10
    harness.laneY = mapSize() * 9 div 10
  # A fixed hash of the hero, its deaths and the tick decides the walk.
  let roll = (turn.data.id * 7919 + turn.data.deaths * 104729 +
    turn.data.tick) mod 100
  harness.walking = roll < harness.walkPercent
  # The walk stops (100 - walkReach) percent of the way short of the lane.
  let
    startX = turn.data.x - harness.laneX
    startY = turn.data.y - harness.laneY
    rest = 100 - harness.walkReach
  harness.walkStop = (startX * startX + startY * startY) * rest * rest div 10000
  harness.orderTick = 0
  harness.walkUntil = turn.data.tick + LaneWalkTicks
  harness.homeX = turn.data.x
  harness.homeY = turn.data.y
  harness.retreating = false

proc think*(
  harness: var Harness,
  game: Game,
  index: int,
  actions: array[ActionCount, int32],
  observation: var array[ObservationSize, int32]
) =
  ## Runs harness.bas once for the hero in `index`: writes `observation`
  ## where the BASIC lane calls chooseAction, then applies `actions`.
  let
    world = game.world
    hero = world.heroes[index]
    turn = Turn(
      game: game,
      world: world,
      hero: hero,
      index: index,
      data: heroData(world, hero)
    )
    data = turn.data
  if data.drafting:
    turn.chooseHero()
    return
  harness.side = 1 - data.team * 2
  harness.observe(turn, observation)
  let key = actions[0]
  if key in [16'i32, 17, 19]:
    harness.menu(turn, key - 15)
  if data.hp <= 0:
    if key == 21:
      let price = world.buybackPrice(data.id)
      if price > 0 and data.gold >= price:
        discard turn.buyback()
    harness.initialized = false
    return
  if data.channelTicks > 0 or data.stunTicks > 0:
    return
  if not harness.initialized:
    harness.initialize(turn)
  turn.learnAbilities()
  if key in [18'i32, 20]:
    harness.menu(turn, key - 15)
  if harness.retreatPercent > 0 and data.maxHp > 0:
    if data.hp * 100 < data.maxHp * harness.retreatPercent:
      harness.retreating = true
    if harness.retreating:
      if turn.inOwnSpawn() and data.hp * 10 >= data.maxHp * 9:
        harness.retreating = false
      else:
        if data.rootTicks == 0 and data.tick >= harness.orderTick:
          harness.orderTick = data.tick + LaneOrderTicks
          turn.travel(harness.homeX, harness.homeY, false)
        return
  if harness.walking:
    harness.walkLane(turn)
    if harness.walking:
      return
  if key == 9:
    harness.focus = 1
  elif key == 10:
    harness.focus = 2
  if harness.focus == 2:
    harness.bestId = harness.priorityId
    harness.bestX = harness.priorityX
    harness.bestY = harness.priorityY
    harness.bestDistance = harness.priorityDistance
  else:
    harness.bestId = harness.enemyId
    harness.bestX = harness.enemyX
    harness.bestY = harness.enemyY
    harness.bestDistance = harness.enemyDistance
  harness.casted = false
  if key in 11'i32 .. 14'i32:
    harness.castSpells(turn, key - 11)
  if not harness.casted:
    harness.press(turn, key)
