## Gods of the Arena hero scripting: the BASIC surface one hero has
## on the simulation.

import
  polyworld/[metrics, basic, bodies, cli, controllers, fixed, pathing,
    profiles, tapes],
  content,
  maps,
  observations,
  sim,
  replays,
  terrains

when defined(coworld):
  import polyworld/coworld

type
  HeroDataSlot = enum
    DataSelfId,
    DataSelfTeam,
    DataSelfClass,
    DataSelfX,
    DataSelfY,
    DataSelfHp,
    DataSelfMaxHp,
    DataSelfMana,
    DataSelfMaxMana,
    DataSelfGold,
    DataSelfLevel,
    DataWorldTick,
    DataSelfLayer,
    DataSelfMoveSpeed,
    DataSelfAttackRange,
    DataSelfAttackDamage,
    DataSelfTarget,
    DataSelfAttackCooldown,
    DataSelfAttacksLanded
  ObjectField = enum
    ObjectLevel, ObjectMana, ObjectItemId, ObjectItemCount,
    ObjectFacingX, ObjectFacingY, ObjectTarget, ObjectVelX, ObjectVelY
  SpellField = enum
    SpellAbility, SpellCasterId, SpellX, SpellY, SpellImpactTick

const
  HeroDataNames: array[HeroDataSlot, string] = [
    "selfId",
    "selfTeam",
    "selfClass",
    "selfX",
    "selfY",
    "selfHp",
    "selfMaxHp",
    "selfMana",
    "selfMaxMana",
    "selfGold",
    "selfLevel",
    "worldTick",
    "selfLayer",
    "selfMoveSpeed",
    "selfAttackRange",
    "selfAttackDamage",
    "selfTarget",
    "selfAttackCooldown",
    "selfAttacksLanded"
  ]

var heroDataIds: array[HeroDataSlot, int32]

proc bindHeroData(program: Program) =
  ## Resolves host data slots once so think ticks do not allocate names.
  for slot, name in HeroDataNames:
    heroDataIds[slot] = program.hostDataIndex(name)
    doAssert heroDataIds[slot] >= 0, "missing host data " & name

proc heroVmLimits(): Limits =
  ## Returns independent structural and per-decision limits for a hero VM.
  result = defaultLimits()
  result.maxSourceBytes = 64 * 1024
  result.maxCodeInstructions = 20_000
  result.maxArrays = 32
  result.maxArrayElements = 4096
  result.maxGlobals = 256
  result.maxHostData = 64
  result.maxHostFunctions = 64
  result.maxRoutines = 64
  result.maxParameters = 16
  result.maxRegisters = 256
  result.maxSyntaxDepth = 32
  result.maxCallDepth = 16
  result.maxMemoryBytes = 2 * 1024 * 1024
  result.maxInstructions = 20_000
  result.maxWorkUnits = 50_000
  result.maxPrintBytes = 1024
  result.maxPrintEvents = 128

proc terrainProc(
    game: Game,
    heroId: int32,
    field: TerrainField,
    explicitLayer: bool
): HostProc =
  ## Binds one terrain field to either the hero's layer or an explicit layer.
  result = proc(arguments: openArray[int32]): int32 =
    ## Reads the requested static field without changing the active hero.
    let layer =
      if explicitLayer:
        arguments[2]
      else:
        let index = heroIndex(game.world, heroId)
        if index < 0:
          return 0
        game.world.heroes[index].navLayer
    let value = terrainValue(arguments[0], arguments[1], layer, field)
    if field != TerrainWalkableField or value == 0:
      return value
    let index = heroIndex(game.world, heroId)
    if index < 0:
      return 0
    let floor = layers[int(layer)]
    int32(game.world.knownWalkable(
      game.world.heroes[index].team,
      int(layer),
      int(arguments[0]) + mapOrigin() - floor.originX,
      int(arguments[1]) + mapOrigin() - floor.originZ
    ))

proc objectProc(game: Game, heroId: int32, field: ObjectField): HostProc =
  ## Binds one field to the hero's visibility-filtered object snapshot.
  result = proc(arguments: openArray[int32]): int32 =
    ## Reads a visible object's field without exposing hidden targets.
    let world = game.world
    var value: WorldObject
    if not world.worldObjectAt(heroId, int(arguments[0]), value):
      return 0
    case field
    of ObjectLevel:
      value.level
    of ObjectMana:
      value.mana
    of ObjectItemId, ObjectItemCount:
      let slot = int(arguments[1])
      if slot < 0 or slot >= InventorySlots:
        return 0
      if field == ObjectItemId:
        int32(value.inventory[slot].ord)
      else:
        value.itemCounts[slot]
    of ObjectFacingX, ObjectFacingY:
      let direction = normalize(fixedVec2(
        worldToTiles(value.facing.x, WorldScale),
        worldToTiles(value.facing.z, WorldScale)
      ))
      tilesToWorld(
        if field == ObjectFacingX: direction.x else: direction.y,
        WorldScale
      )
    of ObjectTarget:
      if value.targetId == 0:
        return 0
      var target: WorldObject
      for i in 0 ..< world.worldObjectCount(heroId):
        if world.worldObjectAt(heroId, i, target) and
          target.id == value.targetId:
            return target.id
      0
    of ObjectVelX:
      value.velocity.x
    of ObjectVelY:
      value.velocity.z

proc spellProc(game: Game, heroId: int32, field: SpellField): HostProc =
  ## Binds one field to pending spells visible to the hero's team.
  result = proc(arguments: openArray[int32]): int32 =
    ## Reads an impact warning without revealing a hidden caster.
    let world = game.world
    var value: SpellCast
    if not world.visibleSpellAt(heroId, int(arguments[0]), value):
      return if field == SpellAbility: -1 else: 0
    case field
    of SpellAbility:
      int32(value.ability.ord)
    of SpellCasterId:
      world.visibleSpellCasterId(heroId, value)
    of SpellX:
      mapCoordinate(value.position.x)
    of SpellY:
      mapCoordinate(value.position.z)
    of SpellImpactTick:
      value.impact

proc initHeroHost(game: Game, heroId: int32): Host =
  ## Builds the bounded world-query and action interface for one hero.
  result = initHost()
  for name in HeroDataNames:
    discard result.addData(name)
  discard result.addData("mapWidth", mapTiles().int32)
  discard result.addData("mapHeight", mapTiles().int32)
  discard result.addData("mapLayers", layers.len.int32)
  discard result.addData("worldScale", WorldScale)
  discard result.addData("tickRate", TickRate)
  for kind in TerrainKind:
    discard result.addData($kind, kind.ord.int32)
  for (name, layer) in [
    ("GroundLayer", GroundLayer),
    ("RedFortLayer", RedFortLayer),
    ("BlueFortLayer", BlueFortLayer),
    ("WaterLayer", WaterLayer)
  ]:
    discard result.addData(name, layer.int32)

  let objectCountProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    int32(worldObjectCount(game.world, heroId))
  let objectIdProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(game.world, heroId, int(arguments[0]), value):
      value.id
    else:
      0
  let objectKindProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(game.world, heroId, int(arguments[0]), value):
      value.kind
    else:
      0
  let objectTeamProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(game.world, heroId, int(arguments[0]), value):
      int32(value.team.ord)
    else:
      0
  let objectClassProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(game.world, heroId, int(arguments[0]), value):
      value.class
    else:
      -1
  let objectXProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(game.world, heroId, int(arguments[0]), value):
      mapCoordinate(value.position.x)
    else:
      0
  let objectYProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(game.world, heroId, int(arguments[0]), value):
      mapCoordinate(value.position.z)
    else:
      0
  let objectHpProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    if worldObjectAt(game.world, heroId, int(arguments[0]), value):
      max(value.hp, 0'i32)
    else:
      0
  let objectAliveProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    var value: WorldObject
    int32(
      worldObjectAt(game.world, heroId, int(arguments[0]), value) and
        value.alive
    )
  let walkToProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if game.recorder != nil:
        game.recorder.recordWalkTo(
          uint32(game.world.tick),
          heroId,
          arguments[0],
          arguments[1]
        )
    except ReplayError as error:
      game.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyWalkTo(
      game.world, heroId, arguments[0], arguments[1]
    )
    if accepted:
      game.metrics.command(
        heroIndex(game.world, heroId), game.world.tick
      )
    int32(accepted)
  let attackMoveProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    ## Records and applies the same attack-move order used by human players.
    try:
      if activeGame.recorder != nil:
        activeGame.recorder.record ReplayAction(
          tick: uint32(activeGame.world.tick),
          heroId: heroId,
          kind: ActionAttackMove,
          first: arguments[0],
          second: arguments[1]
        )
    except ReplayError as error:
      activeGame.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = activeGame.world.applyAttackMove(
      heroId, arguments[0], arguments[1]
    )
    if accepted:
      activeGame.metrics.command(
        heroIndex(activeGame.world, heroId), activeGame.world.tick
      )
    int32(accepted)
  let attackTargetProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if game.recorder != nil:
        game.recorder.recordAttackTarget(
          uint32(game.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      game.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyAttackTarget(
      game.world, heroId, arguments[0]
    )
    if accepted:
      game.metrics.command(
        heroIndex(game.world, heroId), game.world.tick
      )
    int32(accepted)
  let itemIdProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    let index = heroIndex(game.world, heroId)
    let slot = int(arguments[0])
    if index < 0 or slot < 0 or slot >= InventorySlots:
      return 0
    int32(game.world.heroes[index].inventory[slot].ord)
  let itemCountProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    let index = heroIndex(game.world, heroId)
    let slot = int(arguments[0])
    if index < 0 or slot < 0 or slot >= InventorySlots:
      return 0
    game.world.heroes[index].itemCounts[slot]
  let buyItemProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if game.recorder != nil:
        game.recorder.recordBuyItem(
          uint32(game.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      game.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyBuyItem(
      game.world, heroId, arguments[0]
    )
    if accepted:
      game.metrics.command(
        heroIndex(game.world, heroId), game.world.tick
      )
    int32(accepted)
  let useItemProc: HostProc = proc(
      arguments: openArray[int32]
  ): int32 =
    try:
      if game.recorder != nil:
        game.recorder.recordUseItem(
          uint32(game.world.tick),
          heroId,
          arguments[0]
        )
    except ReplayError as error:
      game.recordingError = error.msg
      raise newException(
        BasicError,
        "replay recording failed: " & error.msg
      )
    let accepted = applyUseItem(
      game.world, heroId, arguments[0]
    )
    if accepted:
      game.metrics.command(
        heroIndex(game.world, heroId), game.world.tick
      )
    int32(accepted)

  let castTargetProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Records and attempts an explicit object-targeted spell.
    let slot = arguments[0]
    if slot < 0 or slot > HeroAbilitySlot.high.ord:
      return 0
    try:
      game.recorder.recordCast(
        uint32(game.world.tick), heroId, slot, arguments[1], 0, false
      )
    except ReplayError as error:
      game.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = game.world.applyCastTarget(heroId, slot, arguments[1])
    if accepted:
      game.metrics.command(
        heroIndex(game.world, heroId), game.world.tick
      )
    int32(accepted)
  let castPointProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Records and attempts a ground-aimed spell.
    let slot = arguments[0]
    if slot < 0 or slot > HeroAbilitySlot.high.ord:
      return 0
    try:
      game.recorder.recordCast(
        uint32(game.world.tick),
        heroId,
        slot,
        arguments[1],
        arguments[2],
        true
      )
    except ReplayError as error:
      game.recordingError = error.msg
      raise newException(BasicError, "replay recording failed: " & error.msg)
    let accepted = game.world.applyCastPoint(
      heroId, slot, arguments[1], arguments[2]
    )
    if accepted:
      game.metrics.command(
        heroIndex(game.world, heroId), game.world.tick
      )
    int32(accepted)
  let abilityChargesProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads remaining charges for one of this hero's four ability slots.
    let index = heroIndex(game.world, heroId)
    if index < 0 or arguments[0] < 0 or arguments[0] > HeroAbilitySlot.high.ord:
      return 0
    game.world.heroes[index].charges[HeroAbilitySlot(arguments[0])]
  let abilityCooldownProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads the ticks before this slot may cast again.
    let index = heroIndex(game.world, heroId)
    if index < 0 or arguments[0] < 0 or arguments[0] > HeroAbilitySlot.high.ord:
      return 0
    game.world.heroes[index].cooldowns[HeroAbilitySlot(arguments[0])]
  let abilityRechargeProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Reads ticks until this slot restores its next charge.
    let index = heroIndex(game.world, heroId)
    if index < 0 or arguments[0] < 0 or arguments[0] > HeroAbilitySlot.high.ord:
      return 0
    game.world.heroes[index].recharges[HeroAbilitySlot(arguments[0])]
  discard result.addFunction("castTarget", 2, castTargetProc, 80)
  discard result.addFunction("castPoint", 3, castPointProc, 80)
  discard result.addFunction("abilityCharges", 1, abilityChargesProc, 4)
  discard result.addFunction("abilityCooldown", 1, abilityCooldownProc, 4)
  discard result.addFunction("abilityRecharge", 1, abilityRechargeProc, 4)

  for (field, name) in [
    (ObjectLevel, "objectLevel"),
    (ObjectMana, "objectMana"),
    (ObjectItemId, "objectItemId"),
    (ObjectItemCount, "objectItemCount"),
    (ObjectFacingX, "objectFacingX"),
    (ObjectFacingY, "objectFacingY"),
    (ObjectTarget, "objectTarget"),
    (ObjectVelX, "objectVelX"),
    (ObjectVelY, "objectVelY")
  ]:
    let arity =
      if field in {ObjectItemId, ObjectItemCount}: 2 else: 1
    discard result.addFunction(
      name, arity, objectProc(game, heroId, field), 16
    )
  let spellCountProc: HostProc = proc(arguments: openArray[int32]): int32 =
    ## Counts warnings and projectiles visible to this hero's team.
    int32(game.world.visibleSpellCount(heroId))
  discard result.addFunction("spellCount", 0, spellCountProc, 16)
  for (field, name) in [
    (SpellAbility, "spellAbility"),
    (SpellCasterId, "spellCasterId"),
    (SpellX, "spellX"),
    (SpellY, "spellY"),
    (SpellImpactTick, "spellImpactTick")
  ]:
    discard result.addFunction(name, 1, spellProc(game, heroId, field), 16)

  discard result.addFunction("objectCount", 0, objectCountProc, 2)
  discard result.addFunction("objectId", 1, objectIdProc, 4)
  discard result.addFunction("objectKind", 1, objectKindProc, 4)
  discard result.addFunction("objectTeam", 1, objectTeamProc, 4)
  discard result.addFunction("objectClass", 1, objectClassProc, 4)
  discard result.addFunction("objectX", 1, objectXProc, 4)
  discard result.addFunction("objectY", 1, objectYProc, 4)
  discard result.addFunction("objectHp", 1, objectHpProc, 4)
  discard result.addFunction("objectAlive", 1, objectAliveProc, 4)
  discard result.addFunction("walkTo", 2, walkToProc, 800)
  discard result.addFunction("attackMove", 2, attackMoveProc, 800)
  discard result.addFunction("attackTarget", 1, attackTargetProc, 20)
  discard result.addFunction("itemId", 1, itemIdProc, 4)
  discard result.addFunction("itemCount", 1, itemCountProc, 4)
  discard result.addFunction("buyItem", 1, buyItemProc, 20)
  discard result.addFunction("useItem", 1, useItemProc, 20)
  for (field, name) in [
    (TerrainKindField, "terrainKind"),
    (TerrainWalkableField, "terrainWalkable"),
    (TerrainHeightField, "terrainHeight"),
    (TerrainWaterDepthField, "terrainWaterDepth")
  ]:
    discard result.addFunction(
      name, 2, terrainProc(game, heroId, field, false), 32
    )
    discard result.addFunction(
      name & "At",
      3,
      terrainProc(game, heroId, field, true),
      32
    )

proc loadBots*(
    game: Game,
    groups: openArray[BotGroup],
    playerSlot = 0'i32
) =
  ## Loads bot files into every hero slot except the optional human slot.
  let
    limits = heroVmLimits()
    schema = initHeroHost(game, 0)
    kinds = controllerKinds(game.world.heroes.len, playerSlot)
    sources = groups.expandBotSources(kinds)
  game.heroVms.setLen(game.world.heroes.len)
  var bound = false
  for i in 0 ..< game.world.heroes.len:
    if kinds[i] == PlayerController:
      game.world.heroes[i].manualSpells = true
      continue
    let program =
      when defined(coworld):
        compilePlayer(sources[i], schema, limits, int(i))
      else:
        compile(sources[i], schema, limits)
    if not bound:
      bindHeroData(program)
      bound = true
    game.heroVms[i] = HeroVm(
      runtime: initRuntime(
        program,
        initHeroHost(game, game.world.heroes[i].id),
        limits
      ),
      limits: limits,
      ready: true
    )
    when defined(coworld):
      game.heroVms[i].output = playerPrinter(int(i))

proc runHeroScript(game: Game, index: int) =
  ## Runs one bounded persistent BASIC decision for a living hero.
  if index < 0 or index >= game.heroVms.len:
    return
  let
    hero = game.world.heroes[index]
    vm = game.heroVms[index]
  if vm == nil or vm.failed or hero.state == Dying:
    return
  vm.runtime.restart()
  try:
    discard game.world.worldObjectCount(hero.id)
    vm.runtime.setData(heroDataIds[DataSelfId], hero.id)
    vm.runtime.setData(heroDataIds[DataSelfTeam], int32(hero.team.ord))
    vm.runtime.setData(heroDataIds[DataSelfClass], int32(hero.class.ord))
    vm.runtime.setData(
      heroDataIds[DataSelfX],
      mapCoordinate(hero.position.x)
    )
    vm.runtime.setData(
      heroDataIds[DataSelfY],
      mapCoordinate(hero.position.z)
    )
    vm.runtime.setData(heroDataIds[DataSelfHp], max(hero.hp, 0'i32))
    vm.runtime.setData(heroDataIds[DataSelfMaxHp], hero.maxHp)
    vm.runtime.setData(heroDataIds[DataSelfMana], hero.mana)
    vm.runtime.setData(heroDataIds[DataSelfMaxMana], hero.maxMana)
    vm.runtime.setData(heroDataIds[DataSelfGold], int32(hero.gold))
    vm.runtime.setData(heroDataIds[DataSelfLevel], int32(hero.level))
    vm.runtime.setData(heroDataIds[DataWorldTick], game.world.tick)
    vm.runtime.setData(heroDataIds[DataSelfLayer], hero.navLayer)
    vm.runtime.setData(heroDataIds[DataSelfMoveSpeed], hero.heroMoveSpeed())
    vm.runtime.setData(
      heroDataIds[DataSelfAttackRange], hero.class.heroAttackRange()
    )
    vm.runtime.setData(
      heroDataIds[DataSelfAttackDamage], hero.heroAttackDamage()
    )
    vm.runtime.setData(heroDataIds[DataSelfTarget], hero.attackObjectId)
    vm.runtime.setData(
      heroDataIds[DataSelfAttackCooldown],
      game.world.heroAttackCooldown(hero)
    )
    vm.runtime.setData(heroDataIds[DataSelfAttacksLanded], hero.attacksLanded)
    discard vm.runtime.run(vm.output)
    inc vm.decisions
  except BasicError as error:
    vm.failed = true
    vm.lastError = error.msg
    when defined(coworld):
      playerError(index, error.msg)
    else:
      echo "hero ", hero.id, " BASIC error: ", error.msg
  vm.lastWork = vm.runtime.workUsed
  vm.lastInstructions = vm.runtime.instructionsUsed
  game.metrics.decision(
    index, game.world.tick, vm.lastInstructions,
    heroVmLimits().maxInstructions
  )

proc runBotDecisions*(game: Game) {.measure.} =
  ## Runs every VM in seeded cyclic order and advances the first slot.
  for offset in 0 ..< game.world.heroes.len:
    let index = (game.world.heroTurnStart + offset) mod game.world.heroes.len
    runHeroScript(game, index)
  game.world.heroTurnStart =
    (game.world.heroTurnStart + 1) mod game.world.heroes.len
