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
## The observation is 4392 int32 values. obs[0 ..< 4356] is a 33 x 33 grid
## of the tiles within the 16-tile vision radius in four channels, stored
## at channel * 1089 + row * 33 + column, mirrored for team 1: walkable
## tile, occupant code, occupant health tenths, and object count. The 36
## self scalars from obs[4356] are listed in `observe`. The action heads
## have sizes `ActionSizes`: move dy, move dx, target filter, one cast flag
## per ability slot, item to buy, inventory slot to use, and buyback.

import
  fixxy,
  polyworld/[bodies, metrics, pathing],
  content, maps, replays, sim, terrains

const
  GridReach = 16'i32
    ## Tiles from the hero to the grid edge, the largest vision radius.
  GridSide = int(2 * GridReach + 1)
  GridCells = GridSide * GridSide
  ScalarStart = 4 * GridCells
  ScalarCount = 36
  ObservationSize* = ScalarStart + ScalarCount
  ActionSizes* = [7'i32, 7, 3, 2, 2, 2, 2, 23, 7, 2]
  ActionCount* = ActionSizes.len
  MoveTiles = 3'i32
    ## Tiles per step of the move heads.
  TargetReach = 65'i32
    ## One more than the squared 8-tile target radius.
  CodeRanks = [0'i32, 3, 3, 1, 1, 1, 2, 2, 4, 4]
    ## Occupant priority by code: god, hero, structure, then creep.

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
    priorityId*, priorityX*, priorityY*, priorityDistance*: int32
    bestId*, bestX*, bestY*, bestDistance*: int32
    casted*: bool

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

proc readObject(
  harness: var Harness,
  turn: Turn,
  value: WorldObject,
  observer: Team,
  observation: var array[ObservationSize, int32]
) =
  ## Adds one visible object to the grid and to both target candidates.
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
  if dx >= -GridReach and dx <= GridReach and
    dy >= -GridReach and dy <= GridReach:
      let cell = int(dy + GridReach) * GridSide + int(dx + GridReach)
      var code =
        if kind == 1: 9'i32
        elif kind == 2: 2'i32
        elif kind == 3: 4'i32
        elif kind == 6: 5'i32
        else: 7'i32
      if team == turn.data.team:
        code = code - 1
      if CodeRanks[code] > CodeRanks[observation[GridCells + cell]]:
        observation[GridCells + cell] = code
        var health = 0'i32
        if value.maxHp > 0:
          health = hp * 10 div value.maxHp
        if health > 10:
          health = 10
        observation[2 * GridCells + cell] = health
      if observation[3 * GridCells + cell] < 9:
        observation[3 * GridCells + cell] =
          observation[3 * GridCells + cell] + 1
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
  ## Writes the grid and the 36 self scalars into `observation`.
  let
    data = turn.data
    hero = turn.hero
    side = harness.side
  for cell in 0 ..< ScalarStart:
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
  var observer = hero.team
  let objects = turn.world.worldObjectCount(data.id)
  for index in 0 ..< objects:
    let value = turn.world.scriptObject(data.id, index, observer)
    harness.readObject(turn, value[], observer, observation)
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
  for i, value in scalars:
    observation[ScalarStart + i] = value

proc shop(turn: Turn, actions: array[ActionCount, int32]) =
  ## Uses the chosen inventory slot, then buys the chosen affordable item.
  let hero = turn.hero
  if actions[8] > 0:
    let itemSlot = actions[8] - 1
    if hero.inventory[itemSlot] != NoItem and
      hero.itemCooldown(int(itemSlot), turn.world.tick) == 0:
        discard turn.useItem(itemSlot)
  if actions[7] > 0:
    if turn.world.phase != Drafting and hero.canShop:
      if turn.data.gold >= ItemSpecs[Item(actions[7])].cost:
        discard turn.buyItem(actions[7])

proc castSpells(
  harness: var Harness,
  turn: Turn,
  actions: array[ActionCount, int32]
) =
  ## Casts the first flagged slot that is ready and has a legal target.
  let
    data = turn.data
    hero = turn.hero
  harness.casted = false
  for spellSlot in 0'i32 .. 3'i32:
    if actions[3 + spellSlot] == 1:
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

proc move(
  harness: var Harness,
  turn: Turn,
  actions: array[ActionCount, int32]
) =
  ## Walks a move cells away, or else attacks the chosen target.
  let
    data = turn.data
    moveY = actions[0] - 3
    moveX = actions[1] - 3
  if moveX == 0 and moveY == 0:
    if harness.bestId != 0:
      if data.target != harness.bestId:
        discard turn.attackTarget(harness.bestId)
    return
  if data.rootTicks > 0:
    return
  let
    goalX = data.x + harness.side * moveX * MoveTiles
    goalY = data.y + harness.side * moveY * MoveTiles
  # The same fallbacks as hero.bas travel(): the goal, then 3 tiles off it.
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
      if turn.walkTo(tryX, tryY):
        return

proc initialize(harness: var Harness, turn: Turn) =
  ## Sets per-class cast reach in whole tiles.
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
  if data.hp <= 0:
    if actions[9] == 1:
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
  turn.shop(actions)
  harness.bestId = 0
  if actions[2] == 1:
    harness.bestId = harness.enemyId
    harness.bestX = harness.enemyX
    harness.bestY = harness.enemyY
    harness.bestDistance = harness.enemyDistance
  elif actions[2] == 2:
    harness.bestId = harness.priorityId
    harness.bestX = harness.priorityX
    harness.bestY = harness.priorityY
    harness.bestDistance = harness.priorityDistance
  harness.castSpells(turn, actions)
  if not harness.casted:
    harness.move(turn, actions)
