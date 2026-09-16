## Gods of the Arena simulation: objects, vision, combat, and the tick.
##
## Planar unit motion uses Q16.16 tile-space bodies. Height, combat ranges,
## and replay integers stay on `WorldPoint`. This module must not import
## anything that returns a float. Graphics may sample `surfaceHeight` and
## must not write simulation state.
##
## BASIC decisions arrive through `onHeroTurn`. This module owns the
## VM type on `Game` but never runs a program.

import
  polyworld/[basic, bodies, fixed, hashes, metrics, noises, pathing, profiles, rngs,
    tapes, visions],
  content, events,
  maps,
  replays

export events

## Deterministic animation slots shared by every backend.

const
  runClip* = 0
  idleClip* = 1
  deathClip* = 2
  victoryClip* = 3
  attackClips* = [4, 5]
  heroRunClip* = 0
  heroIdleClip* = 1
  heroDeathClip* = 2
  heroAttackClips* = [3, 4]

var
  lanePathPoints*: array[3, seq[PathPoint]]
  lanePathTiles: array[3, seq[PathTile]]
  laneWorldLayers: array[3, seq[int32]]
  visionBlockers {.threadvar.}: seq[int16]
  visionSources {.threadvar.}: seq[VisionSource]
  visionSkipNow {.threadvar.}: seq[int32]
  heroPathPoints {.threadvar.}: seq[PathPoint]
  heroPathTiles {.threadvar.}: seq[PathTile]
  gotaWalkLayer {.threadvar.}: int
  gotaWalkDestLayer {.threadvar.}: int
  gotaWalkOrigin {.threadvar.}: FixedVec2

## Simulation

type
  Team* = enum RedTeam, BlueTeam
  FootmanState* = enum Marching, Fighting, Dying
  TowerTier* = enum OuterTower, InnerTower, GateTower
  BuildingKind* = enum TowerBuilding, BarracksBuilding
  WorldPoint* = object
    x*, y*, z*: int32
  Heading* = object
    x*, z*: int32
  HeroVm* = ref object
    output*: PrintProc
    runtime*: Runtime
    limits*: Limits
    ready*: bool
    failed*: bool
    lastError*: string
    decisions*: int
    lastWork*, lastInstructions*: int64

  Footman* = object
    id*: int32
    team*: Team
    lane*: int
    position*: WorldPoint
    facing*: Heading
    velocity*: Heading
    body*: Body
    hp*: int32
    state*: FootmanState
    waypointIndex*: int
    movePath*: seq[PathTile]
    movePathIndex*: int
    moveGoal*: WorldPoint
    moveRevision*: int32
    nextPathTick*: int32
    stuckTicks*: int32
    targetId*: int32
    targetHeroId*: int32
    targetBuildingId*: int32
    attackingFort*: bool
    swingClip*: int
    swingTicks*: int32
    damageLanded*: bool
    animClip*: int
    animTicks*: int32
    deathTicks*: int32
    surfaceHint*: int32
    navLayer*: int32

  Hero* = ref object
    id*: int32
    team*: Team
    slot*: int
    lane*: int
    class*: HeroClass
    position*: WorldPoint
    spawnPosition*: WorldPoint
    facing*: Heading
    velocity*: Heading
    body*: Body
    hp*: int32
    maxHp*: int32
    mana*: int32
    maxMana*: int32
    level*: int
    xp*: int
    totalXp*: int
    gold*: int
    state*: FootmanState
    waypointIndex*: int
    targetFootmanId*: int32
    targetHeroId*: int32
    targetBuildingId*: int32
    attackingFort*: bool
    swingClip*: int
    swingTicks*: int32
    damageLanded*: bool
    attacksLanded*: int32
    animClip*: int
    animTicks*: int32
    deathTicks*: int32
    surfaceHint*: int32
    navLayer*: int32
    attackObjectId*: int32
    attackMoving*: bool
    movePath*: seq[WorldPoint]
    movePathLayers*: seq[int32]
    movePathIndex*: int
    moveTileX*: int
    moveTileY*: int
    hasMoveTarget*: bool
    moveRevision*: int32
    stuckTicks*: int32
    inventory*: array[InventorySlots, Item]
    itemCounts*: array[InventorySlots, int32]
    cooldowns*: array[HeroAbilitySlot, int32]
    charges*: array[HeroAbilitySlot, int32]
    recharges*: array[HeroAbilitySlot, int32]
    spellsReady*: bool
    manualSpells*: bool
    lastActionError*: ActionError

  Fort* = object
    id*: int32
    team*: Team
    center*: WorldPoint
    hp*: int32

  Building* = object
    kind*: BuildingKind
    guardsGod*: bool
    spawn*: WorldPoint
    footprint*: seq[PathTile]
    occupied*: bool
    knownAlive*: array[Team, bool]
    id*: int32
    team*: Team
    lane*: int
    tier*: TowerTier
    position*: WorldPoint
    facing*: Heading
    hp*: int32
    maxHp*: int32
    targetId*: int32
    attackTicks*: int32

  WorldObject* = object
    id*: int32
    kind*: int32
    class*: int32
    team*: Team
    position*: WorldPoint
    hp*: int32
    maxHp*: int32
    alive*: bool
    level*, mana*: int32
    inventory*: array[InventorySlots, Item]
    itemCounts*: array[InventorySlots, int32]
    facing*, velocity*: Heading
    targetId*: int32

  NavTile* = object
    layer*: int
    x*: int
    z*: int

  SpellCast* = object
    ability*: Ability
    heroId*: int32
    targetId*: int32
    origin*: WorldPoint
    position*: WorldPoint
    direction*: Heading
    started*: int32
    impact*: int32
    ends*: int32
    resolved*: bool

  World* = ref object
    when defined(replayEvents):
      events*: seq[GameEvent]
      eventTick: int32
    heroSpawns*: array[2, WorldPoint]
    casts*: seq[SpellCast]
    stats*: CombatStats
    ## One match. A ref so `a = b` aliases and a second world is `clone()`.
    footmen*: seq[Footman]
    heroes*: seq[Hero]
    forts*: array[2, Fort]
    buildings*: seq[Building]
    occupancy*: seq[seq[int16]]
    navigationRevision*: int32
    spawnIntervalTicks*: int32
    spawnTimerTicks*: int32
    gameOver*: bool
    winner*: Team
    rng*: Rng
    nextFootmanId*: int32
    tick*: int32
    heroTurnTicks*: int32
    heroTurnStart*: int
    teamHeroKills*: array[2, int]
    teamHeroDeaths*: array[2, int]
    teamVisible*: array[2, seq[uint8]]
    teamExplored*: array[2, seq[uint8]]
    visionCache: array[2, VisionCache]
    visionSkipKeys: seq[int32]
    scriptObjects: seq[WorldObject]
    scriptObjectCount: int
    scriptObjectsHeroId: int32
    scriptObjectsTick: int32
  Game* = ref object
    ## One match session. World is the hashable sim; everything else is
    ## tape, map, and agents.
    world*: World
    metrics*: MatchMetrics
    history*: MetricHistory
    map*: MapData
    recorder*: ReplayRecorder
    replayData*: ReplayData
    replayPlayer*: ReplayPlayer
    hashCheck*: ReplayHashCheck
    historyPlayback*: bool
    replayMode*: bool
    recordingError*: string
    heroVms*: seq[HeroVm]

var navigationWorld {.threadvar.}: World

const
  WorldScale* = 60_000'i32
  FirstTowerId = 10'i32
  FirstBarracksId = 40'i32
  WaypointRadius* = 6 * WorldScale
  WaypointSpacing = 10 * WorldScale
  PathPointRadius = WorldScale div 3
  ChasePathTicks = 6'i32
  FailedPathTicks = TickRate
  TowerHitPoints*: array[TowerTier, int32] = [950'i32, 1_300, 1_950]
  TowerDamages*: array[TowerTier, int32] = [18'i32, 24, 30]
  TowerAttackRanges*: array[TowerTier, int32] = [
    300_000'i32,
    330_000,
    360_000
  ]
  TowerAttackTicks* = TickRate
  TowerSiegeRange* = 105_000'i32

proc config*(game: Game): GotaConfig =
  ## Reads the match configuration owned by the live or loaded replay.
  if game.recorder != nil:
    game.recorder.data.config
  else:
    game.replayData.config

proc worldPoint(point: PathPoint): WorldPoint =
  ## Converts one exact 1/32-tile path point into integer world units.
  const PathUnit = WorldScale div PathUnitsPerTile
  WorldPoint(
    x: point.x * PathUnit,
    y: point.y * PathUnit,
    z: point.z * PathUnit
  )

proc heading*(x, z: int32): Heading =
  ## Creates an integer heading from a non-normalized planar direction.
  Heading(x: x, z: z)

proc `-`(first, second: WorldPoint): WorldPoint =
  ## Subtracts two authoritative world positions.
  WorldPoint(
    x: first.x - second.x,
    y: first.y - second.y,
    z: first.z - second.z
  )

proc `+`(first, second: WorldPoint): WorldPoint =
  ## Adds two authoritative world offsets.
  WorldPoint(
    x: first.x + second.x,
    y: first.y + second.y,
    z: first.z + second.z
  )

proc distanceSquared(first, second: WorldPoint): int64 =
  ## Returns squared planar distance without floating-point arithmetic.
  let
    x = int64(first.x) - int64(second.x)
    z = int64(first.z) - int64(second.z)
  x * x + z * z

proc within*(first, second: WorldPoint, distance: int32): bool =
  ## Tests a planar range using squared authoritative integer units.
  distanceSquared(first, second) <= int64(distance) * int64(distance)

proc scaledPlanar(direction: WorldPoint, distance: int32): WorldPoint =
  ## Scales an integer direction to an exact signed planar distance.
  let length = integerSqrt(
    int64(direction.x) * int64(direction.x) +
    int64(direction.z) * int64(direction.z)
  )
  if length == 0:
    return
  WorldPoint(
    x: int32(roundDivision(int64(direction.x) * distance, length)),
    z: int32(roundDivision(int64(direction.z) * distance, length))
  )

proc floorWorldTile(value: int32): int =
  ## Floors a signed fixed-point coordinate to its whole world tile.
  if value >= 0:
    int(value div WorldScale)
  else:
    -int(((-int64(value)) + int64(WorldScale) - 1) div
      int64(WorldScale))

proc fixedSurfaceHeight(position: WorldPoint): int32
proc fixedSurfaceHeightNear(
    position: WorldPoint,
    referenceY: int32
): int32

proc initTowers(world: World, map: MapData) =
  ## Creates towers at the courts selected by this map's layout.
  for lane in 0 .. 2:
    for team in Team:
      for tier in TowerTier:
        let
          hitPoints = TowerHitPoints[tier]
          site = map.layout.towers[lane][team.ord][tier.ord]
          facing = heading(
            site.facing.x - site.position.x,
            site.facing.z - site.position.z
          )
        var position = worldPoint(site.position)
        position.y = fixedSurfaceHeight(position)
        world.buildings.add Building(
          id: FirstTowerId + world.buildings.len.int32,
          team: team,
          lane: lane,
          tier: tier,
          position: position,
          facing: facing,
          hp: hitPoints,
          maxHp: hitPoints
        )

const
  FootmanHp* = 60'i32
  FootmanDamage* = 12'i32
  FootmanMovePerTick* = 5_500'i32
  FootmanBodyRadius = 0.22'fx
  HeroBodyRadius = 0.28'fx
  BodyTurnRate = 0.35'fx
  FootmanSightRadius* = 5 * WorldScale
  FootmanTowerSightRadius = 7 * WorldScale
  FootmanMeleeRange* = 54_000'i32
  FortRange = 255_000'i32
  FortSightRadius = 14'i32
  HeroMeleeIdleRange* = 150_000'i32
    ## Standing melee heroes auto-attack enemies this close.
  HeroMeleeAttackMoveRange* = 480_000'i32
    ## Attack-move melee chase radius, much larger than idle aggro.
  HeroLanes = [0, 0, 1, 2, 2]
  HeroRespawnTicks = 8 * TickRate
  HeroMaxLevel* = 20
  FootmanXpReward = 25
  FootmanGoldReward = 15
  HeroXpReward = 150
  HeroGoldReward = 100
  TowerXpReward = 100
  TowerGoldReward = 75
  DecisionTicks = 1'i32
    ## Ticks between hero VM decisions. One decision per simulation tick.
  FortObjectKind = 1'i32
  HeroObjectKind = 2'i32
  FootmanObjectKind = 3'i32
  TowerObjectKind = 4'i32
  BarracksObjectKind = 5'i32
  RedFortId = 1'i32
  BlueFortId = 2'i32
  FirstHeroId* = 100'i32
  FirstFootmanId = 1000'i32
  UnitCap = 120 * CreepsPerBarracks
  CorpseLingerTicks = 60'i32
  FootmanDeathTicks = 24'i32
  HeroDeathTicks = 24'i32
  FortHp* = 400'i32

proc startingForts(map: MapData): array[2, Fort] =
  ## Places both gods at the selected layout's fort centers.
  for team in Team:
    result[team.ord] = Fort(
      id: (if team == RedTeam: RedFortId else: BlueFortId),
      team: team,
      hp: FortHp,
      center: worldPoint(map.layout.forts[team.ord])
    )

proc cloneHeroes(heroes: seq[Hero]): seq[Hero] =
  ## Copies each hero so two worlds never share a path seq.
  result.setLen(heroes.len)
  for i, hero in heroes:
    result[i] = Hero()
    result[i][] = hero[]

proc clone*(w: World): World =
  ## Deep copy. Heroes are refs and must be cloned one by one.
  result = World()
  result[] = w[]
  result.stats = w.stats.clone()
  result.heroes = cloneHeroes(w.heroes)
  when defined(replayEvents):
    result.events = @[]

proc restore*(w: World, snapshot: World) =
  ## Overwrites in place, keeping the caller's ref identity.
  w[] = snapshot[]
  w.stats = snapshot.stats.clone()
  w.heroes = cloneHeroes(snapshot.heroes)
  when defined(replayEvents):
    w.events = @[]
    w.eventTick = w.tick
  navigationWorld = w

proc buildSightTerrain(): tuple[
    terrainHeights,
    blockerHeights: seq[int16]
] =
  ## Builds one integer occlusion grid from terrain and forest tiles.
  let cellCount = mapTiles() * mapTiles()
  result.terrainHeights = newSeq[int16](cellCount)
  result.blockerHeights = newSeq[int16](cellCount)
  for value in result.terrainHeights.mitems:
    value = int16.low
  for layer in layers:
    if layer.water:
      continue
    for z in 0 ..< layer.depth:
      for x in 0 ..< layer.width:
        let
          tile = layer.tiles[z * layer.width + x]
          mapX = layer.originX + x - mapOrigin()
          mapZ = layer.originZ + z - mapOrigin()
        if not tile.exists or mapX < 0 or mapX >= mapTiles() or
            mapZ < 0 or mapZ >= mapTiles():
          continue
        let
          index = mapZ * mapTiles() + mapX
          mean = int16(
            (int32(tile.tops[0]) + int32(tile.tops[1]) +
              int32(tile.tops[2]) + int32(tile.tops[3])) div 4
          )
        result.terrainHeights[index] = max(
          result.terrainHeights[index],
          mean
        )
  let ground = layers[GroundLayer]
  for z in 0 ..< ground.depth:
    for x in 0 ..< ground.width:
      let index = z * ground.width + x
      if ground.tiles[index].kind == TreeTile or
        ground.tiles[index].kind == ArenaRockKind:
          result.blockerHeights[
            z * ground.width + x
          ] = 24
  for value in result.terrainHeights.mitems:
    if value == int16.low:
      value = 0

var sightTerrain: tuple[terrainHeights, blockerHeights: seq[int16]]

proc sightTile(position: WorldPoint): tuple[x, z: int32] =
  ## Converts one integer world position to the shared visibility grid.
  result.x = int32(floorWorldTile(position.x) + mapTiles() div 2)
  result.z = int32(floorWorldTile(position.z) + mapTiles() div 2)

proc addVisionBlocker(position: WorldPoint, height: int16) =
  ## Raises one tile's occluder height for this tick's vision pass.
  let tile = sightTile(position)
  if tile.x >= 0 and tile.x < mapTiles() and
      tile.z >= 0 and tile.z < mapTiles():
    let index = tile.z * mapTiles() + tile.x
    visionBlockers[index] = max(visionBlockers[index], height)

proc fillVisionKeys(world: World, dest: var seq[int32]) =
  ## Records living observers and the towers or forts that occlude them.
  dest.setLen(0)
  dest.add int32(world.heroes.len)
  for i in 0 ..< world.heroes.len:
    let
      hero = world.heroes[i]
      tile = sightTile(hero.position)
    dest.add hero.id
    dest.add int32(hero.team.ord)
    dest.add int32(hero.state != Dying and hero.hp > 0)
    dest.add tile.x
    dest.add tile.z
  dest.add int32(world.footmen.len)
  for footman in world.footmen:
    let tile = sightTile(footman.position)
    dest.add footman.id
    dest.add int32(footman.team.ord)
    dest.add int32(footman.state != Dying and footman.hp > 0)
    dest.add tile.x
    dest.add tile.z
  dest.add int32(world.buildings.len)
  for tower in world.buildings:
    let tile = sightTile(tower.position)
    dest.add tower.id
    dest.add int32(tower.team.ord)
    dest.add int32(tower.hp > 0)
    dest.add tile.x
    dest.add tile.z
  dest.add int32(world.forts.len)
  for fort in world.forts:
    let tile = sightTile(fort.center)
    dest.add fort.id
    dest.add int32(fort.team.ord)
    dest.add int32(fort.hp > 0)
    dest.add tile.x
    dest.add tile.z

proc rebuildVision*(world: World) {.measure.} =
  ## Rebuilds both teams' limited, terrain-occluded visibility maps.
  world.fillVisionKeys(visionSkipNow)
  if sameVisionKeys(visionSkipNow, world.visionSkipKeys):
    return
  visionBlockers.setLen(sightTerrain.blockerHeights.len)
  for i, value in sightTerrain.blockerHeights:
    visionBlockers[i] = value
  for tower in world.buildings:
    if tower.hp > 0:
      addVisionBlocker(tower.position, 28)
  for fort in world.forts:
    if fort.hp > 0:
      addVisionBlocker(fort.center, 32)
  for team in Team:
    visionSources.setLen(0)
    for i in 0 ..< world.heroes.len:
      let hero = world.heroes[i]
      if hero.team == team and hero.state != Dying and hero.hp > 0:
        let tile = sightTile(hero.position)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: 10,
          eyeHeight: 14
        )
    for footman in world.footmen:
      if footman.team == team and footman.state != Dying and footman.hp > 0:
        let tile = sightTile(footman.position)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: FootmanSightRadius div WorldScale,
          eyeHeight: 12
        )
    for tower in world.buildings:
      if tower.team == team and tower.hp > 0:
        let tile = sightTile(tower.position)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: TowerAttackRanges[tower.tier] div WorldScale + 2,
          eyeHeight: 24
        )
    for fort in world.forts:
      if fort.team == team and fort.hp > 0:
        let tile = sightTile(fort.center)
        visionSources.add VisionSource(
          x: tile.x,
          z: tile.z,
          radius: FortSightRadius,
          eyeHeight: 28
        )
    revealVisionCached(
      world.visionCache[team.ord],
      world.teamVisible[team.ord],
      mapTiles().int32,
      mapTiles().int32,
      sightTerrain.terrainHeights,
      visionBlockers,
      visionSources
    )
    for i, value in world.teamVisible[team.ord]:
      if value != 0:
        world.teamExplored[team.ord][i] = 255
  copyVisionKeys(world.visionSkipKeys, visionSkipNow)

proc visible*(world: World, team: Team, position: WorldPoint): bool =
  ## Returns whether a position is currently visible to one team.
  let tile = sightTile(position)
  tile.x >= 0 and tile.x < mapTiles() and
    tile.z >= 0 and tile.z < mapTiles() and
    world.teamVisible[team.ord].len == mapTiles() * mapTiles() and
    world.teamVisible[team.ord][tile.z * mapTiles() + tile.x] != 0

proc enemyFort(team: Team): int =
  ## Returns the opposing fort index for a team.
  if team == RedTeam: 1 else: 0

proc footmanIndex(world: World, id: int32): int =
  ## Returns the footman slot for one id, or -1.
  if id == 0:
    return -1
  for i, footman in world.footmen:
    if footman.id == id:
      return i
  -1

proc heroIndex*(world: World, id: int32): int =
  ## Returns the hero slot for one id, or -1.
  if id == 0:
    return -1
  for i in 0 ..< world.heroes.len:
    if world.heroes[i].id == id:
      return i
  -1

proc buildingIndex*(world: World, id: int32): int =
  ## Returns the tower slot for one id, or -1.
  if id == 0:
    return -1
  for i, tower in world.buildings:
    if tower.id == id:
      return i
  -1

when defined(replayEvents):
  proc eventEntity(world: World, id: int32): EventEntity =
    ## Retains entity identity even after removal from the world.
    result = EventEntity(id: id, team: -1, class: -1, player: -1)
    var position: WorldPoint
    let hero = world.heroIndex(id)
    if hero >= 0:
      let value = world.heroes[hero]
      result.kind = HeroObjectKind
      result.team = value.team.ord.int32
      result.class = value.class.ord.int32
      result.player = hero.int32
      position = value.position
    else:
      let creep = world.footmanIndex(id)
      let building = world.buildingIndex(id)
      if creep >= 0:
        let value = world.footmen[creep]
        result.kind = FootmanObjectKind
        result.team = value.team.ord.int32
        position = value.position
      elif building >= 0:
        let value = world.buildings[building]
        result.kind =
          if value.kind == TowerBuilding: TowerObjectKind
          else: BarracksObjectKind
        result.team = value.team.ord.int32
        position = value.position
      else:
        for value in world.forts:
          if id != 0 and value.id == id:
            result.kind = FortObjectKind
            result.team = value.team.ord.int32
            position = value.center
    result.x = position.x
    result.y = position.y
    result.z = position.z

  proc emit(world: World, event: GameEvent) =
    ## Appends one value record to the current tick's reusable buffer.
    var value = event
    value.tick = world.eventTick
    world.events.add value

  proc deathEvent(world: World, id: int32): int32 =
    ## Finds the lethal event that precedes this tick's kill reward.
    for i in countdown(world.events.high, 0):
      if world.events[i].kind == Death and world.events[i].target.id == id:
        return i.int32
    -1

  proc damageEvent(
      world: World,
      source, target, requested, before, after: int32,
      cause: EventCause,
      detail: int32
  ) =
    ## Records effective damage, the lethal hit, and existing assist credit.
    if requested <= 0 or after == before:
      return
    let
      actor = world.eventEntity(source)
      victim = world.eventEntity(target)
      hit = world.events.len.int32
    world.emit GameEvent(
      kind: Damage, actor: actor, target: victim, cause: cause,
      detail: detail, requested: requested,
      amount: max(before, 0) - max(after, 0),
      before: before, after: after, related: -1
    )
    if before > 0 and after <= 0:
      let death = world.events.len.int32
      world.emit GameEvent(
        kind: Death, actor: actor, target: victim, cause: cause,
        detail: detail, related: hit
      )
      if victim.kind == HeroObjectKind and world.stats != nil:
        let count = world.stats.values.len
        for slot in 0 ..< count:
          let lastHit = world.stats.hits[victim.player.int * count + slot]
          if slot != actor.player and lastHit >= 0 and
            world.tick - lastHit <= TickRate * 10 and
            world.stats.teams[slot] != victim.team:
              world.emit GameEvent(
                kind: Assist, actor: world.eventEntity(world.heroes[slot].id),
                target: victim, cause: KillReward, related: death, amount: 1
              )
      if victim.kind in [TowerObjectKind, BarracksObjectKind]:
        world.emit GameEvent(
          kind: EntityRemoved, actor: actor, target: victim,
          cause: cause, related: death
        )

  proc valueEvent(
      world: World,
      kind: EventKind,
      source, target: int32,
      cause: EventCause,
      detail: int32,
      before, after, requested: int64,
      related = -1'i32
  ) =
    ## Records a resource mutation without formatting or heap payloads.
    if before != after:
      world.emit GameEvent(
        kind: kind, actor: world.eventEntity(source),
        target: world.eventEntity(target), cause: cause, detail: detail,
        before: before, after: after, amount: after - before,
        requested: requested, related: related
      )

  proc lifecycleEvent(
      world: World,
      kind: EventKind,
      source, target: int32,
      cause: EventCause
  ) =
    ## Captures the identity of one initialized, spawned, or removed entity.
    world.emit GameEvent(
      kind: kind, actor: world.eventEntity(source),
      target: world.eventEntity(target), cause: cause, related: -1
    )

proc applyDamage[T: Hero | Footman](
    world: World,
    target: var T,
    amount, source: int32,
    cause = BasicAttack,
    detail = 0'i32
) =
  ## Applies a unit hit and records its actual health change.
  when defined(replayEvents):
    let before = target.hp
  target.hp -= amount
  when defined(replayEvents):
    world.damageEvent(source, target.id, amount, before, target.hp, cause, detail)

proc healHero(
    world: World,
    target: Hero,
    amount, source: int32,
    cause: EventCause,
    detail: int32
) =
  ## Restores health up to the hero's maximum and records the effective heal.
  when defined(replayEvents):
    let before = target.hp
  target.hp = min(target.maxHp, target.hp + amount)
  when defined(replayEvents):
    world.valueEvent(Healing, source, target.id, cause, detail,
      before, target.hp, amount)

proc restoreMana(
    world: World,
    target: Hero,
    amount, source: int32,
    cause: EventCause,
    detail: int32
) =
  ## Restores mana up to the hero's maximum and records the resource change.
  when defined(replayEvents):
    let before = target.mana
  target.mana = min(target.maxMana, target.mana + amount)
  when defined(replayEvents):
    world.valueEvent(ManaChanged, source, target.id, cause, detail,
      before, target.mana, amount)

proc finishAction(
    world: World,
    heroId: int32,
    action: uint8,
    slot, first, second: int32,
    error: ActionError
): bool =
  ## Updates only the submitting hero's diagnostic and records failed commands.
  let index = world.heroIndex(heroId)
  if index >= 0:
    world.heroes[index].lastActionError = error
  when defined(replayEvents):
    if error != NoActionError:
      world.emit GameEvent(
        kind: ActionRejected, actor: world.eventEntity(heroId),
        target: world.eventEntity(0), cause: Command, related: -1,
        action: action, slot: slot, first: first, second: second, error: error
      )
  error == NoActionError

proc buildingById*(world: World, id: int32): Building =
  ## Reads one tower by its script-visible object ID.
  let index = buildingIndex(world, id)
  if index >= 0:
    result = world.buildings[index]

proc laneCleared(world: World, team: Team): bool =
  ## Returns whether attackers have destroyed every tower in any one lane.
  for lane in 0 .. 2:
    var standing = false
    for tower in world.buildings:
      if tower.kind == TowerBuilding and not tower.guardsGod and
          tower.team == team and tower.lane == lane and tower.hp > 0:
        standing = true
        break
    if not standing:
      return true
  false

proc buildingExposed*(world: World, tower: Building): bool =
  ## Exposes lane structures in order and god guards after any lane falls.
  if tower.id == 0 or tower.hp <= 0:
    return false
  if tower.guardsGod:
    return world.laneCleared(tower.team)
  for other in world.buildings:
    if other.kind == TowerBuilding and not other.guardsGod and
        other.team == tower.team and
        other.lane == tower.lane and other.hp > 0 and
        (tower.kind == BarracksBuilding or other.tier.ord < tower.tier.ord):
      return false
  true

proc nextEnemyBuilding(
    world: World, team: Team, lane: int, position: WorldPoint
): Building =
  ## Finds lane towers, then barracks, then the nearest exposed god guard.
  let enemy = if team == RedTeam: BlueTeam else: RedTeam
  for tier in TowerTier:
    for tower in world.buildings:
      if tower.kind == TowerBuilding and not tower.guardsGod and
          tower.team == enemy and
          tower.lane == lane and tower.tier == tier and tower.hp > 0:
        return tower

  var nearest = int64.high
  for building in world.buildings:
    if building.kind == BarracksBuilding and building.team == enemy and
        building.lane == lane and building.hp > 0:
      let distance = distanceSquared(position, building.position)
      if distance < nearest:
        nearest = distance
        result = building
  if result.id != 0:
    return
  for building in world.buildings:
    if building.guardsGod and building.team == enemy and
        world.buildingExposed(building):
      let distance = distanceSquared(position, building.position)
      if distance < nearest:
        nearest = distance
        result = building

proc fortExposed*(world: World, team: Team): bool =
  ## Keeps a god invulnerable until both of its own guard towers are dead.
  for tower in world.buildings:
    if tower.guardsGod and tower.team == team and tower.hp > 0:
      return false
  true

proc damageFort(
    world: World, index: int, damage, source: int32,
    cause = BasicAttack, detail = 0'i32
) =
  ## Applies damage only after the god's two guards have been destroyed.
  if damage > 0 and world.fortExposed(world.forts[index].team):
    when defined(replayEvents):
      let before = world.forts[index].hp
    world.forts[index].hp = max(0'i32, world.forts[index].hp - damage)
    when defined(replayEvents):
      world.damageEvent(source, world.forts[index].id, damage,
        before, world.forts[index].hp, cause, detail)

proc xpForNextLevel*(level: int): int =
  ## Returns the XP needed to advance from the given hero level.
  100 + (level - 1) * 75

proc recordHeroKill(world: World, team: Team, victimTeam: Team) =
  ## Records one hero kill and the opposing hero's death.
  inc world.teamHeroKills[team.ord]
  inc world.teamHeroDeaths[victimTeam.ord]

proc heroItemBonus(hero: Hero): tuple[
    maxHp, maxMana, damage, movePerTick: int32
] =
  ## Sums passive bonuses from every item the hero is holding.
  for slot in 0 ..< InventorySlots:
    if hero.inventory[slot] == NoItem:
      continue
    let spec = hero.inventory[slot].itemSpec
    result.maxHp += spec.maxHp
    result.maxMana += spec.maxMana
    result.damage += spec.damage
    result.movePerTick += spec.movePerTick

proc refreshHeroStats*(
    hero: Hero,
    world: World = nil,
    cause = Initialization,
    detail = 0'i32
) =
  ## Rebuilds maximums and records live level or equipment adjustments.
  when defined(replayEvents):
    let
      beforeHp = hero.hp
      beforeMana = hero.mana
  let
    previousMaxHp = hero.maxHp
    previousMaxMana = hero.maxMana
    bonus = hero.heroItemBonus()
  hero.maxHp = heroMaxHp(hero.class, hero.level) + bonus.maxHp
  hero.maxMana = heroMaxMana(hero.class, hero.level) + bonus.maxMana
  hero.hp += hero.maxHp - previousMaxHp
  hero.mana += hero.maxMana - previousMaxMana
  if hero.hp > hero.maxHp:
    hero.hp = hero.maxHp
  if hero.mana > hero.maxMana:
    hero.mana = hero.maxMana
  when defined(replayEvents):
    if world != nil:
      world.valueEvent(ManaChanged, hero.id, hero.id, cause, detail,
        beforeMana, hero.mana, 0)
      world.valueEvent(HealthAdjusted, hero.id, hero.id, cause, detail,
        beforeHp, hero.hp, 0)

proc heroAttackDamage*(hero: Hero): int32 =
  ## Returns basic-attack damage including held equipment.
  heroDamage(hero.class, hero.level) + hero.heroItemBonus().damage

proc heroAttackTicks*(world: World, hero: Hero): int32 =
  ## Returns the hero class's current basic-attack cadence.
  heroAttackTicks(hero.class)

proc heroAttackCooldown*(world: World, hero: Hero): int32 =
  ## Returns ticks until the next basic hit, assuming uninterrupted range.
  if hero.hp <= 0 or hero.state == Dying:
    return 0
  let
    duration = world.heroAttackTicks(hero)
    windup = duration * 45 div 100
  if hero.swingTicks < 0:
    return windup
  if not hero.damageLanded:
    return max(0, windup - hero.swingTicks)
  max(0, duration - hero.swingTicks) + windup

proc heroMoveSpeed*(hero: Hero): int32 =
  ## Returns movement distance including held equipment.
  heroMovePerTick(hero.class, hero.level) +
    hero.heroItemBonus().movePerTick

proc gainRewards(world: World, hero: Hero, xp, gold: int, victim: int32) =
  ## Grants the existing kill rewards and links them to their lethal event.
  when defined(replayEvents):
    let related = world.deathEvent(victim)
    world.valueEvent(XpGained, victim, hero.id, KillReward, 0,
      hero.totalXp, hero.totalXp + xp, xp, related)
    world.valueEvent(GoldGained, victim, hero.id, KillReward, 0,
      hero.gold, hero.gold + gold, gold, related)
  hero.xp += xp
  hero.totalXp += xp
  hero.gold += gold
  while hero.level < HeroMaxLevel and
      hero.xp >= xpForNextLevel(hero.level):
    hero.xp -= xpForNextLevel(hero.level)
    when defined(replayEvents):
      let beforeLevel = hero.level
    inc hero.level
    when defined(replayEvents):
      world.valueEvent(LevelChanged, hero.id, hero.id, LevelUp, 0,
        beforeLevel, hero.level, 1)
    hero.refreshHeroStats(world, LevelUp)

proc layerFixedHeight(
    layerIndex: int,
    position: WorldPoint,
    height: var int32
): bool =
  ## Samples one packed tile surface using only fixed-point arithmetic.
  let
    layer = layers[layerIndex]
    worldTileX = floorWorldTile(position.x) + GridTiles div 2
    worldTileZ = floorWorldTile(position.z) + GridTiles div 2
    tileX = worldTileX - layer.originX
    tileZ = worldTileZ - layer.originZ
  if tileX < 0 or tileX >= layer.width or
      tileZ < 0 or tileZ >= layer.depth:
    return false
  let tile = layer.tiles[tileZ * layer.width + tileX]
  if not tile.exists:
    return false
  let
    floorX = int64(floorWorldTile(position.x)) * int64(WorldScale)
    floorZ = int64(floorWorldTile(position.z)) * int64(WorldScale)
    offsetX = int64(position.x) - floorX
    offsetZ = int64(position.z) - floorZ
    inverseX = int64(WorldScale) - offsetX
    inverseZ = int64(WorldScale) - offsetZ
    north = int64(tile.tops[0]) * inverseX +
      int64(tile.tops[1]) * offsetX
    south = int64(tile.tops[2]) * inverseX +
      int64(tile.tops[3]) * offsetX
    numerator = north * inverseZ + south * offsetZ
    denominator = int64(WorldScale) * 8
  height = int32(roundDivision(numerator, denominator))
  true

proc fixedSurfaceHeight(position: WorldPoint): int32 =
  ## Returns the highest packed solid surface at an integer world position.
  var found = false
  for layerIndex, layer in layers:
    if layer.water:
      continue
    var height: int32
    if layerFixedHeight(layerIndex, position, height) and
        (not found or height > result):
      result = height
      found = true

proc fixedSurfaceHeightNear(
    position: WorldPoint,
    referenceY: int32
): int32 =
  ## Returns the packed solid surface nearest an integer reference height.
  var
    found = false
    bestDistance = int64.high
  for layerIndex, layer in layers:
    if layer.water:
      continue
    var height: int32
    if layerFixedHeight(layerIndex, position, height):
      let distance = abs(int64(height) - int64(referenceY))
      if not found or distance < bestDistance or
          (distance == bestDistance and height > result):
        result = height
        bestDistance = distance
        found = true

proc canStand(x, z: int32): bool =
  ## Keeps units out of forests, blocked fort tiles, and the map rim.
  const Margin = 18_000'i32
  let halfGridUnits = mapTiles().int32 div 2 * WorldScale
  if x < -halfGridUnits + Margin or x > halfGridUnits - Margin or
      z < -halfGridUnits + Margin or z > halfGridUnits - Margin:
    return false
  let
    tileX = floorWorldTile(x) + GridTiles div 2 -
      layers[GroundLayer].originX
    tileZ = floorWorldTile(z) + GridTiles div 2 -
      layers[GroundLayer].originZ
  isWalkable(GroundLayer, tileX, tileZ)

proc navTileAt(position: WorldPoint, value: var NavTile): bool

proc walkWorldCell(pos: FixedVec2): tuple[x, z: int] =
  ## Converts a tile-space body into a world tile index.
  (
    int(floorWorldTile(tilesToWorld(pos.x, WorldScale))) + GridTiles div 2,
    int(floorWorldTile(tilesToWorld(pos.y, WorldScale))) + GridTiles div 2
  )

proc inWalkMargin(pos: FixedVec2): bool =
  ## Keeps units off the map rim.
  const Margin = 18_000'i32
  let halfGridUnits = mapTiles().int32 div 2 * WorldScale
  let
    x = tilesToWorld(pos.x, WorldScale)
    z = tilesToWorld(pos.y, WorldScale)
  x >= -halfGridUnits + Margin and x <= halfGridUnits - Margin and
    z >= -halfGridUnits + Margin and z <= halfGridUnits - Margin

proc navigationOpen*(layer, x, z: int): bool

proc navigationLineClear(
    a, b: WorldPoint, firstLayer, lastLayer: int32
): bool =
  ## Checks exact positions against the same tile edges and building occupancy.
  const Origin = int64(GridTiles div 2) * WorldScale
  let
    first = layers[firstLayer]
    last = layers[lastLayer]
  lineClear(
    PathTile(
      layer: firstLayer,
      x: int32(floorWorldTile(a.x) + GridTiles div 2 - first.originX),
      z: int32(floorWorldTile(a.z) + GridTiles div 2 - first.originZ)
    ),
    PathTile(
      layer: lastLayer,
      x: int32(floorWorldTile(b.x) + GridTiles div 2 - last.originX),
      z: int32(floorWorldTile(b.z) + GridTiles div 2 - last.originZ)
    ),
    (int64(a.x) + Origin, int64(a.z) + Origin),
    (int64(b.x) + Origin, int64(b.z) + Origin),
    WorldScale,
    navigationOpen
  )

proc tilesWalkable(pos: FixedVec2): bool =
  ## Applies the same tile rule to walking, sliding, and unit separation.
  if not inWalkMargin(pos):
    return false
  let
    (x, z) = walkWorldCell(pos)
    destLayer = worldPreferLayer(gotaWalkLayer, gotaWalkDestLayer, x, z)
  navigationLineClear(
    WorldPoint(x: tilesToWorld(gotaWalkOrigin.x, WorldScale),
      z: tilesToWorld(gotaWalkOrigin.y, WorldScale)),
    WorldPoint(x: tilesToWorld(pos.x, WorldScale),
      z: tilesToWorld(pos.y, WorldScale)),
    gotaWalkLayer.int32,
    destLayer.int32
  )

proc bindNavLayer(position: WorldPoint): int32 =
  ## Picks the packed layer under a spawn or teleport.
  var tile: NavTile
  if navTileAt(position, tile):
    int32(tile.layer)
  else:
    int32(GroundLayer)

proc navigationOpen*(layer, x, z: int): bool =
  ## Combines static terrain with the active world's living buildings.
  if not isWalkable(layer, x, z):
    return false
  navigationWorld == nil or navigationWorld.occupancy.len == 0 or
    navigationWorld.occupancy[layer][z * layers[layer].width + x] == 0

proc buildingFootprint(building: Building): seq[PathTile] =
  ## Rasterizes shared, fixed-point foundation sizes onto the occupied layer.
  const TowerRadii = [63_000'i32, 75_000'i32, 99_000'i32]
  let
    layer = int(bindNavLayer(building.position))
    floor = layers[layer]
    forward = scaledPlanar(WorldPoint(
      x: building.facing.x, z: building.facing.z), WorldScale)
    halfX = 39_000'i64
    halfZ = 50_400'i64
    halfTile = int64(WorldScale div 2)
  for z in floorWorldTile(building.position.z) - 3 ..
      floorWorldTile(building.position.z) + 3:
    for x in floorWorldTile(building.position.x) - 3 ..
        floorWorldTile(building.position.x) + 3:
      let
        localX = x + GridTiles div 2 - floor.originX
        localZ = z + GridTiles div 2 - floor.originZ
      if localX < 0 or localZ < 0 or localX >= floor.width or localZ >= floor.depth:
        continue
      let
        dx = int64(x) * WorldScale + halfTile - building.position.x
        dz = int64(z) * WorldScale + halfTile - building.position.z
      var touches: bool
      if building.kind == TowerBuilding:
        let radius = int64(TowerRadii[building.tier.ord])
        touches = dx * dx + dz * dz <= radius * radius
      else:
        let
          fx = int64(forward.x)
          fz = int64(forward.z)
          projectedTile = halfTile * (abs(fx) + abs(fz))
        touches =
          abs(dx) * WorldScale < halfX * abs(fz) + halfZ * abs(fx) +
            halfTile * WorldScale and
          abs(dz) * WorldScale < halfX * abs(fx) + halfZ * abs(fz) +
            halfTile * WorldScale and
          abs(dx * fz - dz * fx) < halfX * WorldScale + projectedTile and
          abs(dx * fx + dz * fz) < halfZ * WorldScale + projectedTile
      if touches:
        result.add PathTile(layer: layer.int32, x: localX.int32, z: localZ.int32)

proc syncBuildings*(world: World) =
  ## Releases destroyed footprints and invalidates paths and stale targets.
  navigationWorld = world
  for building in world.buildings.mitems:
    let alive = building.hp > 0
    if alive == building.occupied:
      continue
    for tile in building.footprint:
      world.occupancy[tile.layer][int(tile.z) * layers[tile.layer].width +
        int(tile.x)] += (if alive: 1'i16 else: -1'i16)
    building.occupied = alive
    inc world.navigationRevision
    if not alive:
      building.targetId = 0
      for hero in world.heroes:
        if hero.attackObjectId == building.id:
          hero.attackObjectId = 0
          hero.hasMoveTarget = false
          hero.movePath.setLen(0)
        if hero.targetBuildingId == building.id:
          hero.targetBuildingId = 0
      for footman in world.footmen.mitems:
        if footman.targetBuildingId == building.id:
          footman.targetBuildingId = 0

proc initOccupancy(world: World) =
  ## Initializes independent occupancy and known building state for one match.
  navigationWorld = nil
  world.occupancy.setLen(layers.len)
  for i, layer in layers:
    world.occupancy[i] = newSeq[int16](layer.width * layer.depth)
  for building in world.buildings.mitems:
    building.footprint = buildingFootprint(building)
    building.knownAlive = [true, true]
  world.syncBuildings()

proc updateKnownBuildings(world: World) =
  ## Remembers enemy destruction only when the team's vision confirms it.
  for building in world.buildings.mitems:
    for team in Team:
      if building.team == team or world.visible(team, building.position):
        building.knownAlive[team] = building.hp > 0

proc knownWalkable*(world: World, team: Team, layer, x, z: int): bool =
  ## Reports static terrain and remembered occupancy without fog information leaks.
  if not isWalkable(layer, x, z):
    return false
  for building in world.buildings:
    if not building.knownAlive[team]:
      continue
    for tile in building.footprint:
      if tile.layer == layer and tile.x == x and tile.z == z:
        return false
  true

proc buildingAim*(building: Building, fromPoint: WorldPoint): WorldPoint =
  ## Finds the nearest point on occupied tiles for siege range and approach.
  result = building.position
  var best = int64.high
  for tile in building.footprint:
    let
      center = worldPoint(pathPoint(int(tile.layer), int(tile.x), int(tile.z)))
      point = WorldPoint(
        x: clamp(fromPoint.x, center.x - WorldScale div 2,
          center.x + WorldScale div 2),
        y: center.y,
        z: clamp(fromPoint.z, center.z - WorldScale div 2,
          center.z + WorldScale div 2))
      distance = distanceSquared(fromPoint, point)
    if distance < best:
      best = distance
      result = point

proc damageBuilding(
    world: World, index: int, damage, source: int32,
    cause = BasicAttack, detail = 0'i32
) =
  ## Applies building damage and releases occupied tiles on the killing hit.
  when defined(replayEvents):
    let before = world.buildings[index].hp
  world.buildings[index].hp -= damage
  when defined(replayEvents):
    world.damageEvent(source, world.buildings[index].id, damage,
      before, world.buildings[index].hp, cause, detail)
  if world.buildings[index].hp <= 0:
    world.syncBuildings()

proc settleOnLayer(position: var WorldPoint, layer: int32) =
  ## Writes this layer's packed height onto a world point.
  var height: int32
  if layerFixedHeight(int(layer), position, height):
    position.y = height

proc finishMove(navLayer: var int32, pos: FixedVec2) =
  ## Keeps the unit on its layer until the current cell leaves it.
  let (x, z) = walkWorldCell(pos)
  navLayer = int32(worldPreferLayer(
    int(navLayer), gotaWalkDestLayer, x, z
  ))

proc toPlanar(point: WorldPoint): FixedVec2 =
  ## Reads the xz plane of a world point in tile-space.
  fixedVec2(
    worldToTiles(point.x, WorldScale),
    worldToTiles(point.z, WorldScale)
  )

proc bindBody(position: WorldPoint, facing: Heading, radius: Fixed): Body =
  ## Builds a body from an integer spawn pose.
  result.pos = toPlanar(position)
  result.radius = radius
  if facing.x != 0 or facing.z != 0:
    result.facing = angle(fixedVec2(
      worldToTiles(facing.x, WorldScale),
      worldToTiles(facing.z, WorldScale)
    ))

proc applyBody(position: var WorldPoint, facing: var Heading, body: Body) =
  ## Writes the body plane back onto the integer pose used by combat.
  position.x = tilesToWorld(body.pos.x, WorldScale)
  position.z = tilesToWorld(body.pos.y, WorldScale)
  let dir = direction(body.facing)
  facing = heading(
    tilesToWorld(dir.x, WorldScale),
    tilesToWorld(dir.y, WorldScale)
  )

proc applyBody(footman: var Footman) =
  ## Syncs one footman's integer pose from its body.
  applyBody(footman.position, footman.facing, footman.body)

proc applyBody(hero: Hero) =
  ## Syncs one hero's integer pose from its body.
  applyBody(hero.position, hero.facing, hero.body)

proc place*(footman: var Footman, at: WorldPoint) =
  ## Teleports a footman and keeps its body on the same plane.
  footman.position = at
  footman.velocity = Heading()
  footman.body.pos = toPlanar(at)
  footman.navLayer = bindNavLayer(at)

proc place*(hero: Hero, at: WorldPoint) =
  ## Teleports a hero and keeps its body on the same plane.
  hero.position = at
  hero.velocity = Heading()
  hero.body.pos = toPlanar(at)
  hero.navLayer = bindNavLayer(at)

proc snapFacing(body: var Body, facing: var Heading, offset: WorldPoint) =
  ## Turns toward a world-space offset the short way.
  if offset.x == 0 and offset.z == 0:
    return
  turnToward(
    body.facing,
    angle(toPlanar(offset)),
    FixedPi
  )
  let dir = direction(body.facing)
  facing = heading(
    tilesToWorld(dir.x, WorldScale),
    tilesToWorld(dir.y, WorldScale)
  )

proc tryMove(
    footman: var Footman,
    direction: WorldPoint,
    destLayer = -1'i32
) =
  ## Turns toward the offset, then walks along facing with wall-slide.
  gotaWalkLayer = int(footman.navLayer)
  gotaWalkOrigin = footman.body.pos
  gotaWalkDestLayer =
    if destLayer < 0: gotaWalkLayer else: int(destLayer)
  steer(
    footman.body,
    toPlanar(direction),
    worldToTiles(FootmanMovePerTick, WorldScale),
    BodyTurnRate,
    tilesWalkable
  )
  applyBody(footman)
  finishMove(footman.navLayer, footman.body.pos)
  settleOnLayer(footman.position, footman.navLayer)
  footman.surfaceHint = footman.position.y

proc tryMove(hero: Hero, direction: WorldPoint, destLayer = -1'i32) =
  ## Turns and walks a hero at its level-scaled tile-space speed.
  gotaWalkLayer = int(hero.navLayer)
  gotaWalkOrigin = hero.body.pos
  gotaWalkDestLayer =
    if destLayer < 0: gotaWalkLayer else: int(destLayer)
  steer(
    hero.body,
    toPlanar(direction),
    worldToTiles(hero.heroMoveSpeed, WorldScale),
    BodyTurnRate,
    tilesWalkable
  )
  applyBody(hero)
  finishMove(hero.navLayer, hero.body.pos)
  settleOnLayer(hero.position, hero.navLayer)
  hero.surfaceHint = hero.position.y

var laneWorldPaths: array[3, seq[WorldPoint]]

proc waypointAt(footman: Footman, index: int): WorldPoint =
  ## Reads one lane waypoint in the team's march order.
  if footman.team == RedTeam:
    laneWorldPaths[footman.lane][index]
  else:
    laneWorldPaths[footman.lane][
      laneWorldPaths[footman.lane].len - 1 - index
    ]

proc currentWaypoint(footman: Footman): WorldPoint =
  ## Red walks the lane forward, blue walks it backward.
  footman.waypointAt(footman.waypointIndex)

proc currentWaypointLayer(footman: Footman): int32 =
  ## Layer of the waypoint this footman is walking toward.
  let route = laneWorldLayers[footman.lane]
  if route.len == 0:
    return footman.navLayer
  let index =
    if footman.team == RedTeam:
      footman.waypointIndex
    else:
      route.len - 1 - footman.waypointIndex
  if index < 0 or index >= route.len:
    footman.navLayer
  else:
    route[index]

proc advanceWaypoints*(footman: var Footman) =
  ## Clears reached lane goals even while pursuing an enemy.
  let route = laneWorldPaths[footman.lane]
  while footman.waypointIndex < route.len and
      within(footman.position, footman.currentWaypoint, WaypointRadius):
    inc footman.waypointIndex

proc creepWaypoints*(footman: Footman): seq[WorldPoint] =
  ## Returns the lane goals in this creep's marching order for the viewer.
  for i in 0 ..< laneWorldPaths[footman.lane].len:
    result.add footman.waypointAt(i)

proc liveHeroSetup(total: int): seq[ReplayHero] =
  ## Assigns the ten live bot slots evenly across both teams.
  let redCount = (total + 1) div 2
  for i in 0 ..< total:
    let
      team =
        if i < redCount: RedTeam
        else: BlueTeam
      slot =
        if team == RedTeam: i
        else: i - redCount
      lane = HeroLanes[slot mod HeroLanes.len]
    result.add ReplayHero(
      id: FirstHeroId + int32(i),
      team: uint8(team.ord),
      slot: uint8(slot),
      lane: uint8(lane),
      class: uint8(heroClassForTeam(team.ord, slot).ord)
    )

proc spawnHeroes(world: World, setup: openArray[ReplayHero]) =
  ## Creates the persistent heroes described by a live or replay setup.
  const SlotOffsets = [
    -48_000'i32,
    48_000'i32,
    0'i32,
    -48_000'i32,
    48_000'i32
  ]
  for heroSetup in setup:
    let
      team = Team(heroSetup.team)
      slot = int(heroSetup.slot)
      lane = int(heroSetup.lane)
      class = HeroClass(heroSetup.class)
      path = lanePathPoints[lane]
      start = world.heroSpawns[team.ord]
      inner =
        if team == RedTeam:
          worldPoint(path[min(3, path.len - 1)])
        else:
          worldPoint(path[max(path.len - 4, 0)])
      direction = inner - start
      side = WorldPoint(x: -direction.z, z: direction.x)
      group = slot div HeroLanes.len
    var fixedPosition = start +
      scaledPlanar(side, SlotOffsets[slot mod SlotOffsets.len]) +
      scaledPlanar(direction, int32(group * 75_000))
    if not canStand(fixedPosition.x, fixedPosition.z):
      fixedPosition = start
    fixedPosition.y = fixedSurfaceHeight(fixedPosition)
    let
      maxHp = heroMaxHp(class, 1)
      maxMana = heroMaxMana(class, 1)
    world.heroes.add Hero(
      id: heroSetup.id,
      team: team,
      slot: slot,
      lane: lane,
      class: class,
      position: fixedPosition,
      spawnPosition: fixedPosition,
      facing: heading(direction.x, direction.z),
      body: bindBody(
        fixedPosition,
        heading(direction.x, direction.z),
        HeroBodyRadius
      ),
      hp: maxHp,
      maxHp: maxHp,
      mana: maxMana,
      maxMana: maxMana,
      level: 1,
      gold: 150,
      state: Marching,
      swingTicks: -1,
      animClip: heroRunClip,
      surfaceHint: fixedPosition.y,
      navLayer: bindNavLayer(fixedPosition)
    )

proc seededHeroTurnStart(world: World): int =
  ## Chooses the first VM from the order stream.
  int(world.rng.below(int32(world.heroes.len)))

proc currentSetup*(game: Game, maximumTicks: uint32): Setup =
  ## Captures the deterministic arena setup without any bot implementation.
  result = Setup(
    mapSeed: game.map.seed,
    mapHash: game.map.hash,
    tickRate: uint16(TickRate),
    gridTiles: uint16(game.map.resolution),
    spawnIntervalTicks: uint32(game.world.spawnIntervalTicks),
    maximumTicks: maximumTicks
  )
  for hero in game.world.heroes:
    result.heroes.add ReplayHero(
      id: hero.id,
      team: uint8(hero.team.ord),
      slot: uint8(hero.slot),
      lane: uint8(hero.lane),
      class: uint8(hero.class.ord)
    )

proc validateReplayWorld(game: Game) =
  ## Confirms that the replay setup matches this game simulation build.
  let
    actual = game.replayData.header.setup
    expected = currentSetup(game, actual.maximumTicks)
  if actual != expected:
    raise newException(
      ReplayError,
      "the replay setup does not match this Gods of the Arena build"
    )

proc nearestNavTile(
    mapX, mapY: int, referenceY: int32, value: var NavTile,
    excluded: seq[PathTile] = @[]
): bool

proc spawnWave(world: World) {.measure.} =
  ## Spawns three aligned creeps per surviving barracks on separate open tiles.
  var count = 0
  for building in world.buildings:
    if building.kind == BarracksBuilding and building.hp > 0:
      count += CreepsPerBarracks
  if world.footmen.len + count > UnitCap:
    return
  var occupied: seq[PathTile]
  for footman in world.footmen:
    if footman.hp <= 0:
      continue
    var tile: NavTile
    if navTileAt(footman.position, tile):
      occupied.add PathTile(
        layer: tile.layer.int32, x: tile.x.int32, z: tile.z.int32)
  for building in world.buildings:
    if building.kind != BarracksBuilding or building.hp <= 0:
      continue
    for unit in 0 ..< CreepsPerBarracks:
      let start = building.spawn + scaledPlanar(
        WorldPoint(x: building.facing.z, z: -building.facing.x),
        int32(unit - CreepsPerBarracks div 2) * WorldScale
      )
      var tile: NavTile
      if not nearestNavTile(
        floorWorldTile(start.x) + mapTiles() div 2,
        floorWorldTile(start.z) + mapTiles() div 2, start.y, tile, occupied
      ):
        continue
      occupied.add PathTile(
        layer: tile.layer.int32, x: tile.x.int32, z: tile.z.int32)
      let placed = worldPoint(pathPoint(tile.layer, tile.x, tile.z))
      var footman = Footman(
        id: world.nextFootmanId,
        team: building.team, lane: building.lane,
        position: placed,
        body: bindBody(placed, Heading(), FootmanBodyRadius),
        hp: FootmanHp, state: Marching, animClip: runClip,
        animTicks: world.rng.below(TickRate),
        surfaceHint: placed.y, navLayer: tile.layer.int32)
      inc world.nextFootmanId
      footman.advanceWaypoints()
      world.footmen.add footman
      when defined(replayEvents):
        world.lifecycleEvent(EntitySpawned, building.id, footman.id, Wave)

proc mapCoordinate*(value: int32): int32 =
  ## Converts one world coordinate to a clamped script map coordinate.
  int32(clamp(
    floorWorldTile(value) + mapTiles() div 2,
    0,
    mapTiles() - 1
  ))

proc rawWorldObjectCount(world: World): int =
  ## Returns the total number of stable script-addressable objects.
  world.forts.len + world.buildings.len + world.heroes.len + world.footmen.len

proc rawWorldObjectAt(world: World, index: int, value: var WorldObject): bool =
  ## Reads one object from the complete stable world enumeration.
  if index < 0:
    return false
  if index < world.forts.len:
    let fort = world.forts[index]
    value = WorldObject(
      id: fort.id,
      kind: FortObjectKind,
      class: -1,
      team: fort.team,
      position: fort.center,
      hp: fort.hp,
      maxHp: FortHp,
      alive: fort.hp > 0 and fortExposed(world, fort.team)
    )
    return true
  let buildingIndex = index - world.forts.len
  if buildingIndex < world.buildings.len:
    let tower = world.buildings[buildingIndex]
    value = WorldObject(
      id: tower.id,
      kind: (if tower.kind == TowerBuilding: TowerObjectKind
        else: BarracksObjectKind),
      class: -1,
      team: tower.team,
      position: tower.position,
      hp: tower.hp,
      maxHp: tower.maxHp,
      alive: buildingExposed(world, tower),
      facing: tower.facing,
      targetId: (if tower.hp > 0: tower.targetId else: 0)
    )
    return true
  let heroIndex = buildingIndex - world.buildings.len
  if heroIndex < world.heroes.len:
    let hero = world.heroes[heroIndex]
    value = WorldObject(
      id: hero.id,
      kind: HeroObjectKind,
      class: int32(hero.class.ord),
      team: hero.team,
      position: hero.position,
      hp: hero.hp,
      maxHp: hero.maxHp,
      alive: hero.state != Dying and hero.hp > 0,
      level: int32(hero.level),
      mana: hero.mana,
      inventory: hero.inventory,
      itemCounts: hero.itemCounts,
      facing: hero.facing,
      velocity: hero.velocity,
      targetId:
        if hero.hp > 0 and hero.state != Dying: hero.attackObjectId
        else: 0
    )
    return true
  let footmanIndex = heroIndex - world.heroes.len
  if footmanIndex < world.footmen.len:
    let footman = world.footmen[footmanIndex]
    value = WorldObject(
      id: footman.id,
      kind: FootmanObjectKind,
      class: -1,
      team: footman.team,
      position: footman.position,
      hp: footman.hp,
      maxHp: FootmanHp,
      alive: footman.state != Dying and footman.hp > 0,
      facing: footman.facing,
      velocity: footman.velocity,
      targetId:
        if footman.hp <= 0 or footman.state == Dying: 0
        elif footman.targetId != 0: footman.targetId
        elif footman.targetHeroId != 0: footman.targetHeroId
        elif footman.targetBuildingId != 0: footman.targetBuildingId
        elif footman.attackingFort: world.forts[enemyFort(footman.team)].id
        else: 0
    )
    return true
  false

proc objectVisibleTo(world: World, team: Team, value: WorldObject): bool =
  ## Returns whether one object is visible to a querying hero's team.
  value.team == team or visible(world, team, value.position)

proc ensureScriptObjects(world: World, heroId: int32) =
  ## Rebuilds the visible object list once per hero decision tick.
  if world.scriptObjectsHeroId == heroId and
      world.scriptObjectsTick == world.tick:
    return
  world.scriptObjectCount = 0
  let observer = heroIndex(world, heroId)
  if observer >= 0:
    let team = world.heroes[observer].team
    var value: WorldObject
    for i in 0 ..< rawWorldObjectCount(world):
      if not rawWorldObjectAt(world, i, value) or
          not objectVisibleTo(world, team, value) or
          (value.kind in [TowerObjectKind, BarracksObjectKind] and value.hp <= 0):
        continue
      if world.scriptObjectCount == world.scriptObjects.len:
        world.scriptObjects.add value
      else:
        world.scriptObjects[world.scriptObjectCount] = value
      inc world.scriptObjectCount
  world.scriptObjectsHeroId = heroId
  world.scriptObjectsTick = world.tick

proc worldObjectCount*(world: World, heroId: int32): int =
  ## Returns the number of objects visible to one hero script.
  world.ensureScriptObjects(heroId)
  world.scriptObjectCount

proc worldObjectAt*(
    world: World,
    heroId: int32,
    index: int,
    value: var WorldObject
): bool =
  ## Reads one object from a hero's stable visibility-filtered enumeration.
  world.ensureScriptObjects(heroId)
  if index < 0 or index >= world.scriptObjectCount:
    return false
  value = world.scriptObjects[index]
  true

proc worldObjectById(
    world: World,
    heroId,
    id: int32,
    value: var WorldObject
): bool =
  ## Finds one object currently visible to a hero by stable object ID.
  world.ensureScriptObjects(heroId)
  for i in 0 ..< world.scriptObjectCount:
    if world.scriptObjects[i].id == id:
      value = world.scriptObjects[i]
      return true
  false

proc heroById*(world: World, id: int32): Hero =
  ## Reads one hero by its script-visible object ID.
  let index = heroIndex(world, id)
  if index >= 0:
    result = world.heroes[index]
  else:
    result = Hero()

proc footmanById*(world: World, id: int32): Footman =
  ## Reads one footman by its script-visible object ID.
  let index = footmanIndex(world, id)
  if index >= 0:
    result = world.footmen[index]

proc navTileAt(position: WorldPoint, value: var NavTile): bool =
  ## Finds the walkable layer tile closest to a world-space position.
  let
    worldX = floorWorldTile(position.x) + GridTiles div 2
    worldZ = floorWorldTile(position.z) + GridTiles div 2
  var bestHeight = int64.high
  for layerIndex, layer in layers:
    if layer.water:
      continue
    let
      x = worldX - layer.originX
      z = worldZ - layer.originZ
    if not isWalkable(layerIndex, x, z):
      continue
    let height = abs(
      int64(worldPoint(pathPoint(layerIndex, x, z)).y) -
      int64(position.y)
    )
    if not result or height < bestHeight:
      value = NavTile(layer: layerIndex, x: x, z: z)
      bestHeight = height
      result = true

proc nearestNavTile(
    mapX,
    mapY: int,
    referenceY: int32,
    value: var NavTile,
    excluded: seq[PathTile]
): bool =
  ## Finds the closest walkable tile, optionally reserving occupied spawn cells.
  var bestScore = int64.high
  for dz in -8 .. 8:
    for dx in -8 .. 8:
      let
        worldX = mapX + dx
        worldZ = mapY + dz
      if worldX < 0 or worldX >= mapTiles() or
          worldZ < 0 or worldZ >= mapTiles():
        continue
      for layerIndex, layer in layers:
        if layer.water:
          continue
        let
          x = worldX + mapOrigin() - layer.originX
          z = worldZ + mapOrigin() - layer.originZ
        if not navigationOpen(layerIndex, x, z):
          continue
        if PathTile(layer: layerIndex.int32, x: x.int32, z: z.int32) in excluded:
          continue
        let
          centerY = worldPoint(pathPoint(layerIndex, x, z)).y
          planar = int64(dx * dx + dz * dz)
          score = planar * int64(WorldScale) * 100 +
            abs(int64(centerY) - int64(referenceY))
        if score < bestScore:
          value = NavTile(layer: layerIndex, x: x, z: z)
          bestScore = score
          result = true

proc movementPath(tiles: seq[PathTile], start: WorldPoint): seq[PathTile] =
  ## Keeps the farthest clear shortcut from each turn, starting at the unit.
  if tiles.len == 0:
    return
  result.add tiles[0]
  var
    anchor = 0
    position = start
  while anchor < tiles.high:
    var
      last = anchor
      reach = -1
      destination: WorldPoint
    while last < tiles.high and tiles[last + 1].layer == tiles[anchor].layer:
      inc last
    last = max(last, anchor + 1)
    for i in countdown(last, anchor + 1):
      let point = worldPoint(pathPoint(
        int(tiles[i].layer), int(tiles[i].x), int(tiles[i].z)))
      if navigationLineClear(position, point, tiles[anchor].layer, tiles[i].layer):
        reach = i
        destination = point
        break
    if reach < 0:
      return @[]
    result.add tiles[reach]
    position = destination
    anchor = reach

proc followCreepPath(world: World, footman: var Footman, goal: WorldPoint) =
  ## Follows a cached route and throttles changed chase goals and failed searches.
  let
    changed = floorWorldTile(goal.x) != floorWorldTile(footman.moveGoal.x) or
      floorWorldTile(goal.z) != floorWorldTile(footman.moveGoal.z) or
      goal.y != footman.moveGoal.y
    invalid = footman.moveRevision != world.navigationRevision
    finished = footman.movePathIndex >= footman.movePath.len
  if invalid or ((changed or finished) and world.tick >= footman.nextPathTick):
    footman.moveGoal = goal
    footman.moveRevision = world.navigationRevision
    footman.movePathIndex = 0
    footman.movePath.setLen(0)
    footman.nextPathTick = world.tick + FailedPathTicks
    var first, last: NavTile
    if navTileAt(footman.position, first) and nearestNavTile(
      int(mapCoordinate(goal.x)), int(mapCoordinate(goal.z)), goal.y, last
    ):
      let route = findTilePath(PathQuery(
        startLayer: first.layer, startX: first.x, startZ: first.z,
        finishLayer: last.layer, finishX: last.x, finishZ: last.z,
        walkable: navigationOpen)).tiles
      footman.movePath = movementPath(route, footman.position)
      # The first tile is the search origin, not a movement destination.
      if footman.movePath.len > 1:
        footman.movePathIndex = 1
      if footman.movePath.len > 0:
        footman.nextPathTick = world.tick + ChasePathTicks
  while footman.movePathIndex < footman.movePath.len:
    let
      tile = footman.movePath[footman.movePathIndex]
      point = worldPoint(pathPoint(int(tile.layer), int(tile.x), int(tile.z)))
    if not navigationOpen(int(tile.layer), int(tile.x), int(tile.z)):
      footman.moveRevision = -1
      return
    var reached = within(footman.position, point, PathPointRadius)
    if reached and footman.movePathIndex < footman.movePath.high:
      let
        next = footman.movePath[footman.movePathIndex + 1]
        nextPoint = worldPoint(pathPoint(int(next.layer), int(next.x), int(next.z)))
      reached = navigationLineClear(
        footman.position, nextPoint, footman.navLayer, next.layer)
    if reached:
      inc footman.movePathIndex
    else:
      let before = footman.position
      footman.tryMove(point - footman.position, tile.layer)
      if within(before, footman.position, 100):
        inc footman.stuckTicks
        if footman.stuckTicks >= TickRate:
          footman.moveRevision = -1
          footman.stuckTicks = 0
      else:
        footman.stuckTicks = 0
      return

proc setHeroDestination(
    hero: Hero,
    mapX,
    mapY: int,
    referenceY: int32
): bool =
  ## Computes and stores a server-side path for one hero destination.
  let
    targetX = clamp(mapX, 0, mapTiles() - 1)
    targetY = clamp(mapY, 0, mapTiles() - 1)
  if hero.moveRevision == navigationWorld.navigationRevision and
      hero.hasMoveTarget and hero.moveTileX == targetX and
      hero.moveTileY == targetY and hero.movePathIndex < hero.movePath.len:
    return true
  var
    startTile: NavTile
    finishTile: NavTile
  if not navTileAt(hero.position, startTile) or
      not nearestNavTile(targetX, targetY, referenceY, finishTile):
    return false
  discard fillTilePath(PathQuery(
    startLayer: startTile.layer,
    startX: startTile.x,
    startZ: startTile.z,
    finishLayer: finishTile.layer,
    finishX: finishTile.x,
    finishZ: finishTile.z,
    walkable: navigationOpen
  ), heroPathTiles)
  if heroPathTiles.len == 0:
    return false
  let pulled = movementPath(heroPathTiles, hero.position)
  if pulled.len == 0:
    return false
  hero.movePath.setLen(pulled.len)
  hero.movePathLayers.setLen(pulled.len)
  for i, tile in pulled:
    hero.movePath[i] = worldPoint(pathPoint(
      int(tile.layer),
      int(tile.x),
      int(tile.z)
    ))
    hero.movePathLayers[i] = tile.layer
  hero.moveRevision = navigationWorld.navigationRevision
  # Replanning must not send the hero back to its starting tile's center.
  hero.movePathIndex = if pulled.len > 1: 1 else: 0
  hero.moveTileX = targetX
  hero.moveTileY = targetY
  hero.hasMoveTarget = true
  true

proc stopHeroPath(hero: Hero) =
  ## Drops the finished chase so a hero can acquire nearby creeps again.
  hero.hasMoveTarget = false
  hero.movePath.setLen(0)
  hero.movePathLayers.setLen(0)
  hero.movePathIndex = 0

proc followHeroPath(hero: Hero): bool =
  ## Advances a hero along its current server-generated path.
  if hero.hasMoveTarget and hero.moveRevision != navigationWorld.navigationRevision:
    if not hero.setHeroDestination(hero.moveTileX, hero.moveTileY, hero.position.y):
      hero.movePath.setLen(0)
      return false
  while hero.movePathIndex < hero.movePath.len:
    let waypoint = hero.movePath[hero.movePathIndex]
    let offset = WorldPoint(
      x: waypoint.x - hero.position.x,
      z: waypoint.z - hero.position.z
    )
    var reached = within(hero.position, waypoint, PathPointRadius)
    if reached and hero.movePathIndex < hero.movePath.high:
      let
        next = hero.movePathIndex + 1
        layer =
          if next < hero.movePathLayers.len: hero.movePathLayers[next]
          else: hero.navLayer
      reached = navigationLineClear(
        hero.position, hero.movePath[next], hero.navLayer, layer)
    if not reached:
      let destLayer =
        if hero.movePathIndex < hero.movePathLayers.len:
          hero.movePathLayers[hero.movePathIndex]
        else:
          hero.navLayer
      let before = hero.position
      hero.tryMove(offset, destLayer)
      if within(before, hero.position, 100):
        inc hero.stuckTicks
        if hero.stuckTicks >= TickRate:
          hero.moveRevision = -1
          hero.stuckTicks = 0
      else:
        hero.stuckTicks = 0
      return true
    inc hero.movePathIndex
  hero.hasMoveTarget = false
  false

proc applyWalkTo*(world: World, heroId, mapX, mapY: int32): bool =
  ## Applies one hero walk command using server-side pathfinding.
  navigationWorld = world
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionWalkTo,
      0,
      mapX,
      mapY,
      ActionNotAlive
    )
  world.heroes[index].attackObjectId = 0
  world.heroes[index].attackMoving = false
  world.heroes[index].targetFootmanId = 0
  world.heroes[index].targetHeroId = 0
  world.heroes[index].targetBuildingId = 0
  world.heroes[index].attackingFort = false
  let accepted = setHeroDestination(
    world.heroes[index],
    int(mapX),
    int(mapY),
    world.heroes[index].position.y
  )
  world.finishAction(
    heroId,
    ActionWalkTo,
    0,
    mapX,
    mapY,
    if accepted: NoActionError else: ActionNoRoute
  )

proc applyAttackMove*(world: World, heroId, mapX, mapY: int32): bool =
  ## Walks toward a map tile and attacks enemies found along the way.
  navigationWorld = world
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionAttackMove,
      0,
      mapX,
      mapY,
      ActionNotAlive
    )
  world.heroes[index].attackObjectId = 0
  world.heroes[index].attackMoving = true
  world.heroes[index].targetFootmanId = 0
  world.heroes[index].targetHeroId = 0
  world.heroes[index].targetBuildingId = 0
  world.heroes[index].attackingFort = false
  let accepted = setHeroDestination(
    world.heroes[index],
    int(mapX),
    int(mapY),
    world.heroes[index].position.y
  )
  world.finishAction(
    heroId,
    ActionAttackMove,
    0,
    mapX,
    mapY,
    if accepted: NoActionError else: ActionNoRoute
  )

proc isEnemyTarget(world: World, hero: Hero, targetId: int32): bool =
  ## Returns whether `targetId` is a living enemy the hero can chase.
  if targetId == 0:
    return false
  let footman = footmanIndex(world, targetId)
  if footman >= 0:
    let other = world.footmen[footman]
    return other.team != hero.team and
      other.state != Dying and
      other.hp > 0
  let otherHero = heroIndex(world, targetId)
  if otherHero >= 0:
    let other = world.heroes[otherHero]
    return other.team != hero.team and
      other.state != Dying and
      other.hp > 0
  let tower = buildingIndex(world, targetId)
  if tower >= 0:
    let other = world.buildings[tower]
    return other.team != hero.team and other.hp > 0
  for fort in world.forts:
    if fort.id == targetId:
      return fort.team != hero.team and fort.hp > 0
  false

proc applyAttackTarget*(world: World, heroId, targetId: int32): bool =
  ## Applies one hero attack command after validating its target.
  navigationWorld = world
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionAttackTarget,
      0,
      targetId,
      0,
      ActionNotAlive
    )
  if targetId == 0:
    world.heroes[index].attackObjectId = 0
    world.heroes[index].attackMoving = false
    return world.finishAction(
      heroId,
      ActionAttackTarget,
      0,
      targetId,
      0,
      NoActionError
    )
  if not world.isEnemyTarget(world.heroes[index], targetId):
    return world.finishAction(
      heroId,
      ActionAttackTarget,
      0,
      targetId,
      0,
      ActionTargetUnavailable
    )
  world.heroes[index].attackMoving = false
  if world.heroes[index].attackObjectId != targetId:
    world.heroes[index].hasMoveTarget = false
  world.heroes[index].attackObjectId = targetId
  world.finishAction(heroId, ActionAttackTarget, 0, targetId, 0, NoActionError)

proc purchaseError(world: World, heroId, itemId: int32): ActionError =
  ## Returns the first failing purchase check without allocating a string.
  let index = heroIndex(world, heroId)
  if index < 0 or world.heroes[index].state == Dying:
    return ActionNotAlive
  if world.heroes[index].hp <= 0:
    return ActionNotAlive
  let item = itemFromId(itemId)
  if item == NoItem:
    return ActionUnknownItem
  let spec = item.itemSpec
  if world.heroes[index].gold < spec.cost:
    return ActionInsufficientGold
  var empty = false
  for slot in 0 ..< InventorySlots:
    if world.heroes[index].inventory[slot] == NoItem:
      empty = true
    elif world.heroes[index].inventory[slot] == item:
      if spec.kind == Equipment:
        return ActionAlreadyEquipped
      if world.heroes[index].itemCounts[slot] >= MaxItemStack:
        return ActionStackFull
      return NoActionError
  if not empty:
    return ActionInventoryFull
  NoActionError

proc purchaseReason*(world: World, heroId, itemId: int32): string =
  ## Formats the same purchase validator for the shop UI.
  world.purchaseError(heroId, itemId).actionErrorMessage()

proc applyBuyItem*(world: World, heroId, itemId: int32): bool =
  ## Spends gold to put one validated shop item into a hero inventory.
  let error = world.purchaseError(heroId, itemId)
  if error != NoActionError:
    return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0, error)
  let
    hero = world.heroes[world.heroIndex(heroId)]
    item = itemFromId(itemId)
    spec = item.itemSpec
  var
    stackSlot = -1
    emptySlot = -1
  for slot in 0 ..< InventorySlots:
    if hero.inventory[slot] == item:
      stackSlot = slot
    elif hero.inventory[slot] == NoItem and emptySlot < 0:
      emptySlot = slot
  if spec.kind == Consumable and stackSlot >= 0:
    if hero.itemCounts[stackSlot] >= MaxItemStack:
      return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0,
        ActionStackFull)
  elif spec.kind == Equipment and stackSlot >= 0:
    return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0,
      ActionAlreadyEquipped)
  elif emptySlot < 0:
    return world.finishAction(heroId, ActionBuyItem, 0, itemId, 0,
      ActionInventoryFull)
  let slot = if stackSlot >= 0: stackSlot else: emptySlot
  when defined(replayEvents):
    let beforeCount = hero.itemCounts[slot]
  hero.inventory[slot] = item
  if stackSlot >= 0:
    inc hero.itemCounts[slot]
  else:
    hero.itemCounts[slot] = 1
  when defined(replayEvents):
    world.valueEvent(ItemPurchased, heroId, heroId, EquipmentChange, itemId,
      beforeCount, hero.itemCounts[slot], 1)
    let beforeGold = hero.gold
  hero.gold -= spec.cost
  when defined(replayEvents):
    world.valueEvent(GoldSpent, heroId, heroId, EquipmentChange, itemId,
      beforeGold, hero.gold, -spec.cost)
  hero.refreshHeroStats(world, EquipmentChange, itemId)
  world.finishAction(heroId, ActionBuyItem, 0, itemId, 0, NoActionError)

proc footmanAttackTicks(clip: int): int32 =
  ## Returns the deterministic footman attack duration in ticks.
  discard clip
  32

proc startSwing(world: World, footman: var Footman) =
  ## Begins a randomly selected melee animation and damage cycle.
  footman.swingClip = attackClips[world.rng.below(2)]
  footman.swingTicks = 0
  footman.damageLanded = false

proc startSwing(world: World, hero: Hero) =
  ## Begins a randomly selected hero melee animation and damage cycle.
  hero.swingClip = heroAttackClips[world.rng.below(2)]
  hero.swingTicks = 0
  hero.damageLanded = false

proc updateTower*(world: World, tower: var Building) =
  ## Acquires one nearby enemy and applies a deterministic periodic attack.
  if tower.kind == BarracksBuilding or tower.hp <= 0:
    tower.targetId = 0
    tower.attackTicks = 0
    return
  let attackRange = TowerAttackRanges[tower.tier]
  var
    targetFootman = footmanIndex(world, tower.targetId)
    targetHero = heroIndex(world, tower.targetId)
  if targetFootman >= 0:
    let footman = world.footmen[targetFootman]
    if footman.team == tower.team or
        footman.state == Dying or footman.hp <= 0 or
        not within(tower.position, footman.position, attackRange) or
        not visible(world, tower.team, footman.position):
      targetFootman = -1
  if targetHero >= 0:
    let hero = world.heroes[targetHero]
    if hero.team == tower.team or hero.state == Dying or
        hero.hp <= 0 or
        not within(tower.position, hero.position, attackRange) or
        not visible(world, tower.team, hero.position):
      targetHero = -1
  if targetFootman < 0 and targetHero < 0:
    var
      bestSquared = int64(attackRange) * attackRange
      bestId = int32.high
    for i, footman in world.footmen:
      if footman.team == tower.team or footman.state == Dying or
          footman.hp <= 0 or
          not visible(world, tower.team, footman.position):
        continue
      let distance = distanceSquared(tower.position, footman.position)
      if distance < bestSquared or
          (distance == bestSquared and footman.id < bestId):
        bestSquared = distance
        bestId = footman.id
        targetFootman = i
    if targetFootman < 0:
      bestSquared = int64(attackRange) * attackRange
      bestId = int32.high
      for i in 0 ..< world.heroes.len:
        let hero = world.heroes[i]
        if hero.team == tower.team or hero.state == Dying or hero.hp <= 0:
          continue
        if not visible(world, tower.team, hero.position):
          continue
        let distance = distanceSquared(tower.position, hero.position)
        if distance < bestSquared or
            (distance == bestSquared and hero.id < bestId):
          bestSquared = distance
          bestId = hero.id
          targetHero = i
  let targetId =
    if targetFootman >= 0: world.footmen[targetFootman].id
    elif targetHero >= 0: world.heroes[targetHero].id
    else: 0'i32
  if tower.targetId != targetId:
    tower.targetId = targetId
    tower.attackTicks = 0
  if targetId == 0:
    return
  inc tower.attackTicks
  if tower.attackTicks < TowerAttackTicks:
    return
  tower.attackTicks -= TowerAttackTicks
  let damage = TowerDamages[tower.tier]
  if targetFootman >= 0:
    world.applyDamage(world.footmen[targetFootman],
      damage, tower.id, BasicAttack, 0)
  else:
    let wasAlive = world.heroes[targetHero].hp > 0
    world.applyDamage(world.heroes[targetHero],
      damage, tower.id, BasicAttack, 0)
    if wasAlive and world.heroes[targetHero].hp <= 0:
      recordHeroKill(world, tower.team, world.heroes[targetHero].team)
      world.stats.hitHero(-1, targetHero, world.tick, TickRate, true)

proc updateFootman(world: World, footman: var Footman) =
  ## Advances one footman's movement, target selection, combat, and animation.
  footman.velocity = Heading()
  if footman.state == Dying:
    inc footman.deathTicks
    footman.animClip = deathClip
    footman.animTicks = min(footman.deathTicks, FootmanDeathTicks)
    return

  if footman.hp <= 0:
    footman.state = Dying
    footman.deathTicks = 0
    return

  footman.advanceWaypoints()
  let start = footman.position
  defer:
    footman.velocity = heading(
      footman.position.x - start.x,
      footman.position.z - start.z
    )

  # Acquire: keep a live target while it stays in extended range, otherwise
  # take the nearest visible enemy; with none, batter the fort when close.
  var
    targetFootman = footmanIndex(world, footman.targetId)
    targetHero = heroIndex(world, footman.targetHeroId)
    targetBuilding = buildingIndex(world, footman.targetBuildingId)
  if targetFootman >= 0:
    let other = world.footmen[targetFootman]
    if other.state == Dying or other.hp <= 0 or
        not visible(world, footman.team, other.position) or
        not within(
          footman.position,
          other.position,
          FootmanSightRadius * 8 div 5
        ):
      targetFootman = -1
  if targetHero >= 0:
    let hero = world.heroes[targetHero]
    if hero.state == Dying or hero.hp <= 0 or
        not visible(world, footman.team, hero.position) or
        not within(
          footman.position,
          hero.position,
          FootmanSightRadius * 8 div 5
        ):
      targetHero = -1
  if targetBuilding >= 0:
    let tower = world.buildings[targetBuilding]
    if not buildingExposed(world, tower) or
        not visible(world, footman.team, tower.position) or
        not within(
          footman.position,
          tower.position,
          FootmanTowerSightRadius * 8 div 5
        ):
      targetBuilding = -1
  if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
    var bestSquared = int64(FootmanSightRadius) * FootmanSightRadius
    for i, other in world.footmen:
      if other.team == footman.team or other.state == Dying or other.hp <= 0:
        continue
      if not visible(world, footman.team, other.position):
        continue
      let distance = distanceSquared(footman.position, other.position)
      if distance < bestSquared:
        bestSquared = distance
        targetFootman = i
    for i in 0 ..< world.heroes.len:
      let hero = world.heroes[i]
      if hero.team == footman.team or hero.state == Dying or hero.hp <= 0:
        continue
      if not visible(world, footman.team, hero.position):
        continue
      let distance = distanceSquared(footman.position, hero.position)
      if distance < bestSquared:
        bestSquared = distance
        targetFootman = -1
        targetHero = i
  if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
    let tower = nextEnemyBuilding(world, footman.team, footman.lane, footman.position)
    if tower.id != 0 and within(
        footman.position,
        tower.position,
        FootmanTowerSightRadius
    ) and visible(world, footman.team, tower.position):
      targetBuilding = buildingIndex(world, tower.id)
  footman.targetId =
    if targetFootman >= 0: world.footmen[targetFootman].id else: 0
  footman.targetHeroId =
    if targetHero >= 0: world.heroes[targetHero].id else: 0
  footman.targetBuildingId =
    if targetBuilding >= 0: world.buildings[targetBuilding].id else: 0
  let fortIndex = enemyFort(footman.team)
  footman.attackingFort = targetFootman < 0 and targetHero < 0 and
    targetBuilding < 0 and
    fortExposed(world, world.forts[fortIndex].team) and
    visible(world, footman.team, world.forts[fortIndex].center) and
    within(footman.position, world.forts[fortIndex].center, FortRange)

  if targetFootman >= 0 or targetHero >= 0 or
      targetBuilding >= 0 or footman.attackingFort:
    footman.state = Fighting
    let targetPosition =
      if targetFootman >= 0: world.footmen[targetFootman].position
      elif targetHero >= 0: world.heroes[targetHero].position
      elif targetBuilding >= 0:
        buildingAim(world.buildings[targetBuilding], footman.position)
      else: world.forts[fortIndex].center
    footman.surfaceHint = targetPosition.y
    let
      offset = targetPosition - footman.position
      # Fort walls sit well inside FortRange: close enough already counts
      # as being at arm's length of the enemy god's walls.
      inRange =
        if targetFootman >= 0 or targetHero >= 0:
          within(footman.position, targetPosition, FootmanMeleeRange)
        elif targetBuilding >= 0:
          within(footman.position, targetPosition, TowerSiegeRange)
        else: true
    if not inRange:
      footman.swingTicks = -1
      footman.animClip = runClip
      inc footman.animTicks
      world.followCreepPath(footman, targetPosition)
    else:
      snapFacing(footman.body, footman.facing, offset)
      if footman.swingTicks < 0:
        startSwing(world, footman)
      let duration = footmanAttackTicks(footman.swingClip)
      inc footman.swingTicks
      if not footman.damageLanded and
          footman.swingTicks >= duration * 45 div 100:
        footman.damageLanded = true
        if targetFootman >= 0:
          world.applyDamage(world.footmen[targetFootman],
            FootmanDamage, footman.id, BasicAttack, 0)
        elif targetHero >= 0:
          let wasAlive = world.heroes[targetHero].hp > 0
          world.applyDamage(world.heroes[targetHero],
            FootmanDamage, footman.id, BasicAttack, 0)
          if wasAlive and world.heroes[targetHero].hp <= 0:
            recordHeroKill(world, footman.team, world.heroes[targetHero].team)
            world.stats.hitHero(-1, targetHero, world.tick, TickRate, true)
        elif targetBuilding >= 0:
          world.damageBuilding(targetBuilding, FootmanDamage, footman.id)
        else:
          world.damageFort(fortIndex, FootmanDamage, footman.id)
      if footman.swingTicks >= duration:
        startSwing(world, footman)
      footman.animClip = footman.swingClip
      footman.animTicks = max(footman.swingTicks, 0)
    return

  footman.state = Marching
  footman.swingTicks = -1
  footman.animClip = runClip
  inc footman.animTicks
  var goal = world.forts[enemyFort(footman.team)].center
  if footman.waypointIndex < laneWorldPaths[footman.lane].len:
    goal = footman.currentWaypoint
  else:
    let objective = world.nextEnemyBuilding(
      footman.team, footman.lane, footman.position
    )
    if objective.id != 0:
      goal = buildingAim(objective, footman.position)
  world.followCreepPath(footman, goal)

proc respawn(world: World, hero: Hero) =
  ## Restores a fallen hero and records the new life's resource adjustments.
  when defined(replayEvents):
    let
      beforeHp = hero.hp
      beforeMana = hero.mana
  hero.place(hero.spawnPosition)
  hero.applyBody()
  hero.hp = hero.maxHp
  hero.mana = hero.maxMana
  hero.state = Marching
  hero.waypointIndex = 0
  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetBuildingId = 0
  hero.attackingFort = false
  hero.attackObjectId = 0
  hero.attackMoving = false
  hero.hasMoveTarget = false
  hero.movePath.setLen(0)
  hero.movePathIndex = 0
  hero.swingTicks = -1
  hero.animClip = heroRunClip
  hero.animTicks = 0
  hero.deathTicks = 0
  hero.surfaceHint = hero.spawnPosition.y
  hero.navLayer = bindNavLayer(hero.spawnPosition)
  for slot in HeroAbilitySlot:
    hero.cooldowns[slot] = 0
  hero.spellsReady = false
  when defined(replayEvents):
    world.valueEvent(ManaChanged, hero.id, hero.id, Respawn, 0,
      beforeMana, hero.mana, 0)
    world.valueEvent(HealthAdjusted, hero.id, hero.id, Respawn, 0,
      beforeHp, hero.hp, 0)
    world.lifecycleEvent(EntityRespawned, 0, hero.id, Respawn)

proc initHeroCharges(hero: Hero) =
  ## Starts a new life with every ability fully charged.
  for slot in HeroAbilitySlot:
    hero.charges[slot] = heroAbility(hero.class, slot).abilitySpec.charges
    hero.recharges[slot] = 0
  hero.spellsReady = true

proc tickHeroCooldowns(world: World, hero: Hero) =
  ## Advances spell cooldowns and restores spent charges one at a time.
  if not hero.spellsReady:
    hero.initHeroCharges()
  for slot in HeroAbilitySlot:
    if hero.cooldowns[slot] > 0:
      dec hero.cooldowns[slot]
    if hero.recharges[slot] > 0:
      dec hero.recharges[slot]
      if hero.recharges[slot] == 0:
        let spec = heroAbility(hero.class, slot).abilitySpec
        hero.charges[slot] = min(hero.charges[slot] + 1, spec.charges)
        if hero.charges[slot] < spec.charges:
          hero.recharges[slot] = spec.rechargeTicks

proc regenHeroMana(world: World, hero: Hero, tick: int32) =
  ## Restores a small amount of mana on a stable cadence.
  if tick mod 6 == 0 and hero.mana < hero.maxMana:
    world.restoreMana(hero, 1, hero.id, Regeneration, 0)

proc applyHeroHit(
    world: World,
    hero: Hero,
    damage: int32,
    targetFootman, targetHero, targetBuilding, fortIndex: int,
    cause = BasicAttack, detail = 0'i32
) =
  ## Applies one hero hit to the current combat target.
  if damage <= 0:
    return
  if targetFootman >= 0:
    let wasAlive = world.footmen[targetFootman].hp > 0
    world.applyDamage(world.footmen[targetFootman],
      damage, hero.id, cause, detail)
    if wasAlive and world.footmen[targetFootman].hp <= 0:
      world.gainRewards(hero, FootmanXpReward, FootmanGoldReward,
        world.footmen[targetFootman].id)
      world.stats.add(heroIndex(world, hero.id), GoldMetric, FootmanGoldReward)
  elif targetHero >= 0:
    let wasAlive = world.heroes[targetHero].hp > 0
    world.applyDamage(world.heroes[targetHero],
      damage, hero.id, cause, detail)
    if wasAlive:
      world.stats.hitHero(
        heroIndex(world, hero.id), targetHero, world.tick, TickRate,
        world.heroes[targetHero].hp <= 0
      )
    if wasAlive and world.heroes[targetHero].hp <= 0:
      world.gainRewards(hero, HeroXpReward, HeroGoldReward,
        world.heroes[targetHero].id)
      world.stats.add(heroIndex(world, hero.id), GoldMetric, HeroGoldReward)
      recordHeroKill(world, hero.team, world.heroes[targetHero].team)
  elif targetBuilding >= 0:
    let wasStanding = world.buildings[targetBuilding].hp > 0
    world.damageBuilding(targetBuilding, damage, hero.id, cause, detail)
    if wasStanding and world.buildings[targetBuilding].hp <= 0:
      world.gainRewards(hero, TowerXpReward, TowerGoldReward,
        world.buildings[targetBuilding].id)
      world.stats.add(heroIndex(world, hero.id), GoldMetric, TowerGoldReward)
  elif fortIndex >= 0:
    world.damageFort(fortIndex, damage, hero.id, cause, detail)

proc consumeItem(world: World, hero: Hero, slot: int) =
  ## Removes one charge and records consumption before an empty stack is lost.
  when defined(replayEvents):
    let
      item = hero.inventory[slot]
      before = hero.itemCounts[slot]
  dec hero.itemCounts[slot]
  if hero.itemCounts[slot] <= 0:
    hero.inventory[slot] = NoItem
    hero.itemCounts[slot] = 0
  when defined(replayEvents):
    world.valueEvent(ItemConsumed, hero.id, hero.id, ItemEffect,
      item.ord.int32, before, hero.itemCounts[slot], -1)

proc canHitTarget(
    world: World,
    hero: Hero,
    targetFootman, targetHero, targetBuilding, fortIndex: int,
    range: int32
): bool =
  ## Requires a living, visible, exposed enemy within the strike's range.
  var position: WorldPoint
  if targetFootman >= 0:
    let target = world.footmen[targetFootman]
    if target.team == hero.team or target.hp <= 0 or target.state == Dying:
      return false
    position = target.position
  elif targetHero >= 0:
    let target = world.heroes[targetHero]
    if target.team == hero.team or target.hp <= 0 or target.state == Dying:
      return false
    position = target.position
  elif targetBuilding >= 0:
    let target = world.buildings[targetBuilding]
    if target.team == hero.team or not world.buildingExposed(target):
      return false
    position = target.position
  elif fortIndex >= 0:
    let target = world.forts[fortIndex]
    if target.team == hero.team or target.hp <= 0 or
      not world.fortExposed(target.team):
        return false
    position = target.center
  else:
    return false
  let aim =
    if targetBuilding >= 0: buildingAim(world.buildings[targetBuilding], hero.position)
    else: position
  within(hero.position, aim, range) and world.visible(hero.team, position)

proc applyUseItem*(world: World, heroId, slotId: int32): bool =
  ## Spends one consumable for a heal, mana restore, or poison strike.
  let
    index = heroIndex(world, heroId)
    slot = int(slotId)
  if index < 0 or world.heroes[index].state == Dying:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionNotAlive
    )
  if world.heroes[index].hp <= 0:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionNotAlive
    )
  if slot < 0 or slot >= InventorySlots:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionInvalidSlot
    )
  let item = world.heroes[index].inventory[slot]
  if item == NoItem:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionEmptySlot
    )
  let spec = item.itemSpec
  if spec.kind != Consumable:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionNotConsumable
    )
  if spec.heal > 0:
    if world.heroes[index].hp >= world.heroes[index].maxHp:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionFullHealth
      )
    world.healHero(world.heroes[index], spec.heal, heroId,
      ItemEffect, item.ord.int32)
  elif spec.restore > 0:
    if world.heroes[index].mana >= world.heroes[index].maxMana:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionFullMana
      )
    world.restoreMana(world.heroes[index], spec.restore, heroId,
      ItemEffect, item.ord.int32)
  elif spec.strike > 0:
    let targetId = world.heroes[index].attackObjectId
    if targetId == 0:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionTargetUnavailable
      )
    var
      targetFootman = footmanIndex(world, targetId)
      targetHero = heroIndex(world, targetId)
      targetBuilding = buildingIndex(world, targetId)
      fortIndex = -1
    if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
      for i, fort in world.forts:
        if fort.id == targetId:
          fortIndex = i
          break
    if targetFootman < 0 and targetHero < 0 and
        targetBuilding < 0 and fortIndex < 0:
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionTargetUnavailable
      )
    if not world.canHitTarget(
      world.heroes[index],
      targetFootman,
      targetHero,
      targetBuilding,
      fortIndex,
      heroAttackRange(world.heroes[index].class)
    ):
      return world.finishAction(
        heroId,
        ActionUseItem,
        slotId,
        slotId,
        0,
        ActionTargetUnavailable
      )
    applyHeroHit(
      world,
      world.heroes[index],
      spec.strike,
      targetFootman,
      targetHero,
      targetBuilding,
      fortIndex,
      ItemEffect,
      item.ord.int32
    )
  else:
    return world.finishAction(
      heroId,
      ActionUseItem,
      slotId,
      slotId,
      0,
      ActionNotConsumable
    )
  world.consumeItem(world.heroes[index], slot)
  world.finishAction(heroId, ActionUseItem, slotId, slotId, 0, NoActionError)

proc spellTarget*(world: World, id: int32, value: var WorldObject): bool =
  ## Resolves an existing object without depending on the script query cache.
  let hero = heroIndex(world, id)
  if hero >= 0:
    let target = world.heroes[hero]
    value = WorldObject(id: id, team: target.team, position: target.position,
      hp: target.hp, alive: target.hp > 0 and target.state != Dying)
    return true
  let footman = footmanIndex(world, id)
  if footman >= 0:
    let target = world.footmen[footman]
    value = WorldObject(id: id, team: target.team, position: target.position,
      hp: target.hp, alive: target.hp > 0 and target.state != Dying)
    return true
  let tower = buildingIndex(world, id)
  if tower >= 0:
    let target = world.buildings[tower]
    value = WorldObject(id: id, team: target.team, position: target.position,
      hp: target.hp, alive: world.buildingExposed(target))
    return true
  for fort in world.forts:
    if fort.id == id:
      value = WorldObject(id: id, team: fort.team, position: fort.center,
        hp: fort.hp, alive: fort.hp > 0 and world.fortExposed(fort.team))
      return true
  false

proc hitSpellTarget(world: World, spell: SpellCast, id: int32) =
  ## Applies one effect, checking living targets and structure protection again.
  let
    caster = heroIndex(world, spell.heroId)
    spec = spell.ability.abilitySpec
  var target: WorldObject
  if caster < 0 or not world.spellTarget(id, target) or not target.alive:
    return
  let hero = world.heroes[caster]
  if spec.kind == Strike:
    if target.team == hero.team:
      return
    var fortIndex = -1
    for i, fort in world.forts:
      if fort.id == id:
        fortIndex = i
    world.applyHeroHit(
      hero, spec.damage, world.footmanIndex(id), world.heroIndex(id),
      world.buildingIndex(id), fortIndex, AbilityEffect, spell.ability.ord.int32
    )
  elif target.team == hero.team:
    let index = world.heroIndex(id)
    if index >= 0:
      let ally = world.heroes[index]
      world.healHero(ally, spec.heal, hero.id, AbilityEffect,
        spell.ability.ord.int32)
      world.restoreMana(ally, spec.restore, hero.id, AbilityEffect,
        spell.ability.ord.int32)

proc spellContains*(spell: SpellCast, area: FxArea, point: WorldPoint): bool =
  ## Transforms a target into the spell's fixed local frame before hit testing.
  let
    offset = point - spell.position
    x = int32((int64(offset.x) * spell.direction.z -
      int64(offset.z) * spell.direction.x) div WorldScale)
    z = int32((int64(offset.x) * spell.direction.x +
      int64(offset.z) * spell.direction.z) div WorldScale)
  area.contains(x, z, offset.y)

proc resolveSpell(world: World, spell: var SpellCast) =
  ## Resolves one area or single-target impact exactly once.
  spell.resolved = true
  let spec = spell.ability.abilitySpec
  if spec.casting == SelfCast:
    world.hitSpellTarget(spell, spell.heroId)
    return
  if spec.casting != AreaCast and spell.targetId != 0:
    world.hitSpellTarget(spell, spell.targetId)
    return
  var
    footprint = spec.area
    frame = spell
    nearest = int64.high
    nearestId = 0'i32
  if spec.casting != AreaCast:
    footprint = FxArea(
      shape: CapsuleFootprint, width: 30_000, height: 120_000,
      length: max(30_000'i32, int32(integerSqrt(
        distanceSquared(spell.origin, spell.position))))
    )
    frame.position = spell.origin
  template affect(id: int32, position: WorldPoint) =
    if frame.spellContains(footprint, position):
      if spec.casting == AreaCast:
        world.hitSpellTarget(spell, id)
      else:
        var target: WorldObject
        let caster = world.heroIndex(spell.heroId)
        if caster >= 0 and world.spellTarget(id, target) and target.alive and
          target.team != world.heroes[caster].team:
            let distance = distanceSquared(spell.origin, position)
            if distance < nearest:
              nearest = distance
              nearestId = id
  for hero in world.heroes:
    affect(hero.id, hero.position)
  if spec.kind == Strike:
    for footman in world.footmen:
      affect(footman.id, footman.position)
    for tower in world.buildings:
      affect(tower.id, tower.position)
    for fort in world.forts:
      affect(fort.id, fort.center)
  if nearestId != 0:
    world.hitSpellTarget(spell, nearestId)

proc advanceGroundShot(world: World, spell: var SpellCast) =
  ## Sweeps one tick of projectile travel and stops at the first enemy.
  let
    spec = spell.ability.abilitySpec
    start = spell.started + spec.castTicks
    duration = max(1'i32, spell.impact - start)
    elapsed = clamp(world.tick - start, 0'i32, duration)
    previous = max(0'i32, elapsed - 1)
    caster = world.heroIndex(spell.heroId)
    origin = spell.origin
    destination = spell.position
  if elapsed == 0 or caster < 0:
    return
  proc travel(ticks: int32): WorldPoint =
    ## Interpolates one authoritative projectile position with integers.
    result.x = origin.x + int32(
      int64(destination.x - origin.x) * ticks div duration
    )
    result.y = origin.y + int32(
      int64(destination.y - origin.y) * ticks div duration
    )
    result.z = origin.z + int32(
      int64(destination.z - origin.z) * ticks div duration
    )
  let
    first = travel(previous)
    last = travel(elapsed)
    distance = int32(integerSqrt(distanceSquared(first, last)))
    radius = 15_000'i32
    footprint = FxArea(
      shape: CapsuleFootprint,
      width: radius * 2,
      length: distance + radius * 2,
      height: 120_000
    )
  var
    frame = spell
    nearest = int64.high
    nearestId = 0'i32
  frame.position = first - scaledPlanar(
    WorldPoint(x: spell.direction.x, z: spell.direction.z), radius
  )
  template consider(id: int32, position: WorldPoint) =
    if frame.spellContains(footprint, position):
      var target: WorldObject
      if world.spellTarget(id, target) and target.alive and
        target.team != world.heroes[caster].team:
          let distance = distanceSquared(first, position)
          if distance < nearest:
            nearest = distance
            nearestId = id
  for hero in world.heroes:
    consider(hero.id, hero.position)
  for footman in world.footmen:
    consider(footman.id, footman.position)
  for tower in world.buildings:
    consider(tower.id, tower.position)
  for fort in world.forts:
    consider(fort.id, fort.center)
  if nearestId != 0:
    world.hitSpellTarget(spell, nearestId)
    spell.resolved = true
    spell.position = last
    spell.impact = world.tick
    spell.ends = world.tick + 12
  elif world.tick >= spell.impact:
    spell.resolved = true

proc advanceSpells(world: World) =
  ## Resolves due effects and bounds the retained impact presentation state.
  var write = 0
  for read in 0 ..< world.casts.len:
    var spell = world.casts[read]
    if not spell.resolved:
      if spell.ability.abilitySpec.casting == ProjectileCast and
        spell.targetId == 0:
          world.advanceGroundShot(spell)
      elif world.tick >= spell.impact:
        world.resolveSpell(spell)
    if world.tick < spell.ends:
      world.casts[write] = spell
      inc write
  world.casts.setLen(write)

proc castAbility(
    world: World,
    hero: Hero,
    slot: HeroAbilitySlot,
    targetId: int32,
    aim: WorldPoint
): ActionError =
  ## Releases an object or ground spell after atomically checking its costs.
  if hero.hp <= 0 or hero.state == Dying:
    return ActionNotAlive
  if world.casts.len >= 512:
    return ActionSpellLimit
  if not hero.spellsReady:
    hero.initHeroCharges()
  let
    ability = heroAbility(hero.class, slot)
    spec = ability.abilitySpec
  if hero.cooldowns[slot] > 0:
    return ActionCooldown
  if hero.charges[slot] <= 0:
    return ActionNoCharges
  if hero.mana < spec.manaCost:
    return ActionInsufficientMana
  var
    point = aim
    selected = targetId
  if spec.casting == SelfCast:
    point = hero.position
    selected = hero.id
    if spec.kind == Heal and hero.hp >= hero.maxHp:
      return ActionFullHealth
    if spec.kind == Restore and hero.mana >= hero.maxMana:
      return ActionFullMana
  else:
    if selected != 0:
      var target: WorldObject
      if not world.spellTarget(selected, target) or not target.alive or
        not world.visible(hero.team, target.position):
          return ActionTargetUnavailable
      if (spec.kind == Strike and target.team == hero.team) or
        (spec.kind != Strike and target.team != hero.team):
          return ActionTargetUnavailable
      point = target.position
      if not within(hero.position, point, spec.range):
        return ActionOutOfRange
    elif not within(hero.position, point, spec.range):
      point = hero.position + scaledPlanar(point - hero.position, spec.range)
      point.y = fixedSurfaceHeightNear(point, aim.y)
    if not world.visible(hero.team, point):
      return ActionTargetUnavailable
  var direction = scaledPlanar(point - hero.position, WorldScale)
  if direction.x == 0 and direction.z == 0:
    direction = scaledPlanar(
      WorldPoint(x: hero.facing.x, z: hero.facing.z), WorldScale
    )
  if direction.x == 0 and direction.z == 0:
    direction.z = WorldScale
  var spell = SpellCast(
    ability: ability, heroId: hero.id, targetId: selected,
    origin: hero.position, position: point,
    direction: heading(direction.x, direction.z),
    started: world.tick, impact: world.tick + spec.castTicks
  )
  if spec.casting == AreaCast:
    spell.targetId = 0
    if spec.fromCaster:
      spell.position = hero.position
    elif selected != 0 and spec.area.innerRadius > 0:
      spell.position = point - scaledPlanar(
        direction, (spec.area.innerRadius + spec.area.radius) div 2
      )
  if spec.casting == ProjectileCast:
    spell.impact += max(1'i32, int32((integerSqrt(
      distanceSquared(spell.origin, point)) + spec.projectileSpeed - 1) div
      max(spec.projectileSpeed, 1)))
  spell.ends = spell.impact + 12
  when defined(replayEvents):
    world.emit GameEvent(
      kind: SpellReleased, actor: world.eventEntity(hero.id),
      target: world.eventEntity(selected), cause: AbilityEffect,
      detail: ability.ord.int32, slot: slot.ord.int32, related: -1
    )
    let beforeMana = hero.mana
  hero.mana -= spec.manaCost
  when defined(replayEvents):
    world.valueEvent(ManaChanged, hero.id, hero.id, AbilityEffect,
      ability.ord.int32, beforeMana, hero.mana, -spec.manaCost)
  dec hero.charges[slot]
  hero.cooldowns[slot] = spec.cooldownTicks
  if hero.recharges[slot] == 0:
    hero.recharges[slot] = spec.rechargeTicks
  hero.facing = spell.direction
  if spell.impact <= world.tick:
    world.resolveSpell(spell)
  world.casts.add spell
  NoActionError

proc applyCastTarget*(world: World, heroId, slotId, targetId: int32): bool =
  ## Records the first failure of an explicit object-targeted spell.
  let index = world.heroIndex(heroId)
  if index < 0:
    return world.finishAction(
      heroId,
      ActionCastTarget,
      slotId,
      targetId,
      0,
      ActionNotAlive
    )
  if slotId < 0 or slotId > HeroAbilitySlot.high.ord:
    return world.finishAction(
      heroId,
      ActionCastTarget,
      slotId,
      targetId,
      0,
      ActionInvalidSlot
    )
  let hero = world.heroes[index]
  world.finishAction(
    heroId,
    ActionCastTarget,
    slotId,
    targetId,
    0,
    world.castAbility(hero, HeroAbilitySlot(slotId), targetId, hero.position)
  )

proc applyCastPoint*(
    world: World,
    heroId, slotId, mapX, mapY: int32
): bool =
  ## Records explicit ground casts while preserving the raw input arguments.
  let index = world.heroIndex(heroId)
  if index < 0:
    return world.finishAction(
      heroId,
      ActionCastPoint,
      slotId,
      mapX,
      mapY,
      ActionNotAlive
    )
  if slotId < 0 or slotId > HeroAbilitySlot.high.ord:
    return world.finishAction(
      heroId,
      ActionCastPoint,
      slotId,
      mapX,
      mapY,
      ActionInvalidSlot
    )
  if mapX < 0 or mapX >= mapTiles() or mapY < 0 or mapY >= mapTiles():
    return world.finishAction(
      heroId,
      ActionCastPoint,
      slotId,
      mapX,
      mapY,
      ActionInvalidPoint
    )
  let hero = world.heroes[index]
  var point = WorldPoint(
    x: (mapX - mapTiles().int32 div 2) * WorldScale + WorldScale div 2,
    z: (mapY - mapTiles().int32 div 2) * WorldScale + WorldScale div 2
  )
  point.y = fixedSurfaceHeightNear(point, hero.position.y)
  world.finishAction(
    heroId,
    ActionCastPoint,
    slotId,
    mapX,
    mapY,
    world.castAbility(hero, HeroAbilitySlot(slotId), 0, point)
  )

proc applyReplayAction(world: World, action: ReplayAction): bool {.discardable.} =
  ## Applies one recorded bot command without requiring its private VM.
  case action.kind
  of ActionWalkTo:
    applyWalkTo(world, action.heroId, action.first, action.second)
  of ActionAttackMove:
    applyAttackMove(
      world, action.heroId, action.first, action.second
    )
  of ActionAttackTarget:
    applyAttackTarget(world, action.heroId, action.first)
  of ActionBuyItem:
    applyBuyItem(world, action.heroId, action.first)
  of ActionUseItem:
    applyUseItem(world, action.heroId, action.first)
  of ActionCastTarget:
    applyCastTarget(world, action.heroId,
      action.slot, action.first)
  of ActionCastPoint:
    applyCastPoint(world, action.heroId,
      action.slot, action.first, action.second)
  of ActionManualSpells:
    let index = world.heroIndex(action.heroId)
    if index >= 0:
      world.heroes[index].manualSpells = action.first != 0
    false
  else:
    raise newException(ReplayError, "replay action kind is invalid")

proc tryCastAbility(
    world: World,
    hero: Hero,
    slot: HeroAbilitySlot,
    targetFootman, targetHero, targetBuilding, fortIndex: int
): bool =
  ## Attempts an automatic cast using the current spell rules.
  let spec = heroAbility(hero.class, slot).abilitySpec
  var targetId = 0'i32
  if spec.kind != Strike:
    if spec.casting == SelfCast:
      return world.castAbility(
        hero, slot, hero.id, hero.position
      ) == NoActionError
    for ally in world.heroes:
      if ally.team == hero.team and ally.hp > 0 and ally.hp < ally.maxHp and
        ally.state != Dying and
        within(hero.position, ally.position, spec.range):
          if world.castAbility(
            hero, slot, ally.id, ally.position
          ) == NoActionError:
            return true
    return false
  if targetFootman >= 0:
    targetId = world.footmen[targetFootman].id
  elif targetHero >= 0:
    targetId = world.heroes[targetHero].id
  elif targetBuilding >= 0:
    targetId = world.buildings[targetBuilding].id
  elif fortIndex >= 0:
    targetId = world.forts[fortIndex].id
  if targetId == 0:
    return false
  world.castAbility(hero, slot, targetId, hero.position) == NoActionError

proc tryCombatAbilities(
    world: World,
    hero: Hero,
    targetFootman, targetHero, targetBuilding, fortIndex: int
) =
  ## Fires the passive, then the strongest ready strike or support ability.
  if hero.manualSpells:
    return
  discard tryCastAbility(
    world,
    hero,
    PassiveAbility,
    targetFootman,
    targetHero,
    targetBuilding,
    fortIndex
  )
  if tryCastAbility(
      world,
      hero,
      UltimateAbility,
      targetFootman,
      targetHero,
      targetBuilding,
      fortIndex
    ):
    return
  if tryCastAbility(
      world,
      hero,
      SecondaryAbility,
      targetFootman,
      targetHero,
      targetBuilding,
      fortIndex
    ):
    return
  discard tryCastAbility(
    world,
    hero,
    PrimaryAbility,
    targetFootman,
    targetHero,
    targetBuilding,
    fortIndex
  )

proc nearestEnemy(
    world: World, hero: Hero, radius: int32, creepsOnly = false
): int32 =
  ## Returns the closest visible enemy, optionally restricting it to creeps.
  var bestSquared = int64(radius) * int64(radius)
  for footman in world.footmen:
    if footman.team == hero.team or
        footman.state == Dying or
        footman.hp <= 0 or
        not visible(world, hero.team, footman.position):
      continue
    let squared = distanceSquared(hero.position, footman.position)
    if squared <= bestSquared:
      bestSquared = squared
      result = footman.id
  if creepsOnly:
    return
  for other in world.heroes:
    if other.id == hero.id or
        other.team == hero.team or
        other.state == Dying or
        other.hp <= 0 or
        not visible(world, hero.team, other.position):
      continue
    let squared = distanceSquared(hero.position, other.position)
    if squared <= bestSquared:
      bestSquared = squared
      result = other.id
  for tower in world.buildings:
    if tower.team == hero.team or
        tower.hp <= 0 or
        not buildingExposed(world, tower) or
        not visible(world, hero.team, tower.position):
      continue
    let squared = distanceSquared(hero.position, tower.position)
    if squared <= bestSquared:
      bestSquared = squared
      result = tower.id
  for fort in world.forts:
    if fort.team == hero.team or
        fort.hp <= 0 or
        not fortExposed(world, fort.team) or
        not visible(world, hero.team, fort.center):
      continue
    let squared = distanceSquared(hero.position, fort.center)
    if squared <= bestSquared:
      bestSquared = squared
      result = fort.id

proc acquireRadius(world: World, hero: Hero): int32 =
  ## Returns the search radius for idle or attack-move acquisition.
  if hero.attackMoving:
    if hero.class.heroSpec.attackStyle == MeleeAttack:
      return HeroMeleeAttackMoveRange
    return heroAttackRange(hero.class)
  if not hero.hasMoveTarget:
    if hero.class.heroAttackCasting == MeleeCast:
      return HeroMeleeIdleRange
    return heroAttackRange(hero.class)
  0

proc updateHero(world: World, hero: Hero) =
  ## Applies scripted navigation, combat, rewards, death, and respawn.
  hero.velocity = Heading()
  if hero.state == Dying:
    inc hero.deathTicks
    hero.animClip = heroDeathClip
    hero.animTicks = min(hero.deathTicks, HeroDeathTicks)
    if hero.deathTicks >= HeroDeathTicks + HeroRespawnTicks:
      world.respawn(hero)
    return

  if hero.hp <= 0:
    hero.state = Dying
    hero.deathTicks = 0
    hero.targetFootmanId = 0
    hero.targetHeroId = 0
    hero.targetBuildingId = 0
    hero.attackingFort = false
    hero.attackObjectId = 0
    hero.attackMoving = false
    hero.hasMoveTarget = false
    return

  let start = hero.position
  defer:
    hero.velocity = heading(
      hero.position.x - start.x,
      hero.position.z - start.z
    )

  hero.targetFootmanId = 0
  hero.targetHeroId = 0
  hero.targetBuildingId = 0
  hero.attackingFort = false
  var
    targetFootman = -1
    targetHero = -1
    targetBuilding = -1
    fortIndex = -1
  if hero.attackObjectId != 0:
    targetFootman = footmanIndex(world, hero.attackObjectId)
    if targetFootman >= 0:
      let footman = world.footmen[targetFootman]
      if footman.team == hero.team or footman.state == Dying or
          footman.hp <= 0 or not visible(world, hero.team, footman.position):
        targetFootman = -1
    if targetFootman < 0:
      targetHero = heroIndex(world, hero.attackObjectId)
      if targetHero >= 0:
        let other = world.heroes[targetHero]
        if other.team == hero.team or other.state == Dying or
            other.hp <= 0 or not visible(world, hero.team, other.position):
          targetHero = -1
    if targetFootman < 0 and targetHero < 0:
      targetBuilding = buildingIndex(world, hero.attackObjectId)
      if targetBuilding >= 0:
        let tower = world.buildings[targetBuilding]
        if tower.team == hero.team or not buildingExposed(world, tower) or
            not visible(world, hero.team, tower.position):
          targetBuilding = -1
    if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
      for i, fort in world.forts:
        if fort.id == hero.attackObjectId and fort.team != hero.team and
            fort.hp > 0 and fortExposed(world, fort.team):
          if not visible(world, hero.team, fort.center):
            continue
          fortIndex = i
          hero.attackingFort = true
          break
    if targetFootman < 0 and targetHero < 0 and targetBuilding < 0 and
        not hero.attackingFort:
      hero.attackObjectId = 0
      if not hero.attackMoving:
        hero.stopHeroPath()
  if hero.attackObjectId == 0:
    let radius = world.acquireRadius(hero)
    if radius > 0:
      hero.attackObjectId = world.nearestEnemy(
        hero, radius, creepsOnly = true
      )
      if hero.attackObjectId != 0:
        targetFootman = footmanIndex(world, hero.attackObjectId)
        if targetFootman >= 0:
          let footman = world.footmen[targetFootman]
          if footman.team == hero.team or footman.state == Dying or
              footman.hp <= 0:
            targetFootman = -1
        if targetFootman < 0:
          targetHero = heroIndex(world, hero.attackObjectId)
          if targetHero >= 0:
            let other = world.heroes[targetHero]
            if other.team == hero.team or other.state == Dying or
                other.hp <= 0:
              targetHero = -1
        if targetFootman < 0 and targetHero < 0:
          targetBuilding = buildingIndex(world, hero.attackObjectId)
          if targetBuilding >= 0:
            let tower = world.buildings[targetBuilding]
            if tower.team == hero.team or not buildingExposed(world, tower):
              targetBuilding = -1
        if targetFootman < 0 and targetHero < 0 and targetBuilding < 0:
          for i, fort in world.forts:
            if fort.id == hero.attackObjectId:
              fortIndex = i
              hero.attackingFort = true
              break
  hero.targetFootmanId =
    if targetFootman >= 0: world.footmen[targetFootman].id else: 0
  hero.targetHeroId =
    if targetHero >= 0: world.heroes[targetHero].id else: 0
  hero.targetBuildingId =
    if targetBuilding >= 0: world.buildings[targetBuilding].id else: 0

  world.regenHeroMana(hero, world.tick)
  tryCombatAbilities(
    world,
    hero,
    targetFootman,
    targetHero,
    targetBuilding,
    fortIndex
  )

  if not world.isEnemyTarget(hero, hero.attackObjectId):
    if hero.attackObjectId != 0 and not hero.attackMoving:
      hero.stopHeroPath()
    targetFootman = -1
    targetHero = -1
    targetBuilding = -1
    fortIndex = -1
    hero.attackObjectId = 0
    hero.targetFootmanId = 0
    hero.targetHeroId = 0
    hero.targetBuildingId = 0
    hero.attackingFort = false

  if targetFootman >= 0 or targetHero >= 0 or
      targetBuilding >= 0 or hero.attackingFort:
    hero.state = Fighting
    let targetPosition =
      if targetFootman >= 0: world.footmen[targetFootman].position
      elif targetHero >= 0: world.heroes[targetHero].position
      elif targetBuilding >= 0:
        buildingAim(world.buildings[targetBuilding], hero.position)
      else: world.forts[fortIndex].center
    hero.surfaceHint = targetPosition.y
    let
      offset = targetPosition - hero.position
      inRange =
        if targetFootman >= 0 or targetHero >= 0:
          within(
            hero.position,
            targetPosition,
            heroAttackRange(hero.class)
          )
        elif targetBuilding >= 0:
          within(
            hero.position,
            targetPosition,
            max(heroAttackRange(hero.class), TowerSiegeRange)
          )
        else:
          within(hero.position, targetPosition, FortRange)
    if not inRange:
      hero.swingTicks = -1
      hero.animClip = heroRunClip
      inc hero.animTicks
      let
        targetX = int(mapCoordinate(targetPosition.x))
        targetY = int(mapCoordinate(targetPosition.z))
      if hero.setHeroDestination(
        targetX,
        targetY,
        targetPosition.y
      ):
        discard hero.followHeroPath()
      else:
        hero.stopHeroPath()
    else:
      snapFacing(hero.body, hero.facing, offset)
      if hero.swingTicks < 0:
        startSwing(world, hero)
      let duration = world.heroAttackTicks(hero)
      inc hero.swingTicks
      if not hero.damageLanded and
          hero.swingTicks >= duration * 45 div 100:
        hero.damageLanded = true
        let damage = hero.heroAttackDamage
        if damage > 0:
          inc hero.attacksLanded
        applyHeroHit(
          world,
          hero,
          damage,
          targetFootman,
          targetHero,
          targetBuilding,
          fortIndex
        )
      if hero.swingTicks >= duration:
        startSwing(world, hero)
      hero.animClip = hero.swingClip
      hero.animTicks = max(hero.swingTicks, 0)
    return

  let moving = hero.followHeroPath()
  hero.state = Marching
  hero.swingTicks = -1
  hero.animClip = if moving: heroRunClip else: heroIdleClip
  inc hero.animTicks

proc separateBodies(first, second: var Body, layer: int32) =
  ## Pushes two living units apart while keeping both on this layer.
  if not needsSeparation(first, second):
    return
  gotaWalkLayer = int(layer)
  gotaWalkDestLayer = int(layer)
  gotaWalkOrigin = first.pos
  if not tilesWalkable(second.pos):
    return
  separatePair(first, second, tilesWalkable)

proc addHashy(hash: var uint32, value: WorldPoint) =
  ## Mixes one authoritative integer world position.
  hash.addHashy(value.x)
  hash.addHashy(value.y)
  hash.addHashy(value.z)

proc addHashy(hash: var uint32, value: Heading) =
  ## Mixes one authoritative integer heading.
  hash.addHashy(value.x)
  hash.addHashy(value.z)

proc stateHash*(game: Game): uint64 =
  ## Hashes replay-authoritative state after actions for one tick are applied.
  let world = game.world
  var hash = HashySeed
  hash.addHashy(game.map.hash)
  hash.addHashy(world.tick)
  hash.addHashy(world.spawnTimerTicks)
  hash.addHashy(world.heroTurnTicks)
  hash.addHashy(world.heroTurnStart)
  hash.addHashy(world.rng)
  hash.addHashy(world.nextFootmanId)
  hash.addHashy(world.gameOver)
  hash.addHashy(world.winner.ord)
  for value in world.teamHeroKills:
    hash.addHashy(value)
  for value in world.teamHeroDeaths:
    hash.addHashy(value)
  hash.addHashy(world.forts.len)
  for fort in world.forts:
    hash.addHashy(fort.id)
    hash.addHashy(fort.team.ord)
    hash.addHashy(fort.center)
    hash.addHashy(fort.hp)
  hash.addHashy(world.navigationRevision)
  hash.addHashy(world.buildings.len)
  for tower in world.buildings:
    hash.addHashy(tower.kind.ord)
    hash.addHashy(tower.guardsGod)
    hash.addHashy(tower.knownAlive)
    hash.addHashy(tower.id)
    hash.addHashy(tower.team.ord)
    hash.addHashy(tower.lane)
    hash.addHashy(tower.tier.ord)
    hash.addHashy(tower.position)
    hash.addHashy(tower.facing)
    hash.addHashy(tower.hp)
    hash.addHashy(tower.maxHp)
    hash.addHashy(tower.targetId)
    hash.addHashy(tower.attackTicks)
  hash.addHashy(world.heroes.len)
  for i in 0 ..< world.heroes.len:
    let hero = world.heroes[i]
    hash.addHashy(hero.id)
    hash.addHashy(hero.team.ord)
    hash.addHashy(hero.slot)
    hash.addHashy(hero.lane)
    hash.addHashy(hero.class.ord)
    hash.addHashy(hero.position)
    hash.addHashy(hero.spawnPosition)
    hash.addHashy(hero.facing)
    hash.addHashy(hero.velocity)
    hash.addHashy(hero.body)
    hash.addHashy(hero.hp)
    hash.addHashy(hero.maxHp)
    hash.addHashy(hero.mana)
    hash.addHashy(hero.maxMana)
    hash.addHashy(hero.level)
    hash.addHashy(hero.xp)
    hash.addHashy(hero.totalXp)
    hash.addHashy(hero.gold)
    hash.addHashy(hero.state.ord)
    hash.addHashy(hero.waypointIndex)
    hash.addHashy(hero.targetFootmanId)
    hash.addHashy(hero.targetHeroId)
    hash.addHashy(hero.targetBuildingId)
    hash.addHashy(hero.attackingFort)
    hash.addHashy(hero.swingClip)
    hash.addHashy(hero.swingTicks)
    hash.addHashy(hero.damageLanded)
    hash.addHashy(hero.attacksLanded)
    hash.addHashy(hero.animClip)
    hash.addHashy(hero.animTicks)
    hash.addHashy(hero.deathTicks)
    hash.addHashy(hero.surfaceHint)
    hash.addHashy(hero.navLayer)
    hash.addHashy(hero.attackObjectId)
    hash.addHashy(hero.attackMoving)
    hash.addHashy(hero.movePath.len)
    for waypoint in hero.movePath:
      hash.addHashy(waypoint)
    hash.addHashy(hero.movePathIndex)
    hash.addHashy(hero.moveRevision)
    hash.addHashy(hero.stuckTicks)
    hash.addHashy(hero.moveTileX)
    hash.addHashy(hero.moveTileY)
    hash.addHashy(hero.hasMoveTarget)
    for slot in 0 ..< InventorySlots:
      hash.addHashy(hero.inventory[slot].ord)
      hash.addHashy(hero.itemCounts[slot])
    for slot in HeroAbilitySlot:
      hash.addHashy(hero.cooldowns[slot])
      hash.addHashy(hero.charges[slot])
      hash.addHashy(hero.recharges[slot])
    hash.addHashy(hero.spellsReady)
    hash.addHashy(hero.manualSpells)
    hash.addHashy(hero.lastActionError.ord)
  hash.addHashy(world.footmen.len)
  for footman in world.footmen:
    hash.addHashy(footman.id)
    hash.addHashy(footman.team.ord)
    hash.addHashy(footman.lane)
    hash.addHashy(footman.position)
    hash.addHashy(footman.facing)
    hash.addHashy(footman.velocity)
    hash.addHashy(footman.body)
    hash.addHashy(footman.hp)
    hash.addHashy(footman.state.ord)
    hash.addHashy(footman.waypointIndex)
    hash.addHashy(footman.movePath)
    hash.addHashy(footman.movePathIndex)
    hash.addHashy(footman.moveGoal)
    hash.addHashy(footman.moveRevision)
    hash.addHashy(footman.nextPathTick)
    hash.addHashy(footman.stuckTicks)
    hash.addHashy(footman.targetId)
    hash.addHashy(footman.targetHeroId)
    hash.addHashy(footman.targetBuildingId)
    hash.addHashy(footman.attackingFort)
    hash.addHashy(footman.swingClip)
    hash.addHashy(footman.swingTicks)
    hash.addHashy(footman.damageLanded)
    hash.addHashy(footman.animClip)
    hash.addHashy(footman.animTicks)
    hash.addHashy(footman.deathTicks)
    hash.addHashy(footman.surfaceHint)
    hash.addHashy(footman.navLayer)
  hash.addHashy(world.casts.len)
  for spell in world.casts:
    hash.addHashy(spell.ability.ord)
    hash.addHashy(spell.heroId)
    hash.addHashy(spell.targetId)
    hash.addHashy(spell.origin)
    hash.addHashy(spell.position)
    hash.addHashy(spell.direction)
    hash.addHashy(spell.started)
    hash.addHashy(spell.impact)
    hash.addHashy(spell.ends)
    hash.addHashy(spell.resolved)
  hash.addHashy(world.stats)
  uint64(hash)

proc settleSurface(position: var WorldPoint, surfaceHint: int32) =
  ## Quantizes terrain geometry back into authoritative integer height.
  position.y = fixedSurfaceHeightNear(position, surfaceHint)

proc checkReplayHash(game: Game, hash: uint64) =
  ## Reports each divergent replay tick once while allowing playback to run.
  if not game.historyPlayback or game.world.tick <= 0:
    return
  let hashes =
    if game.recorder != nil: game.recorder.data.hashes
    else: game.replayPlayer.data.hashes
  hashes.checkReplayHash(uint32(game.world.tick), hash, game.hashCheck)

iterator tickWorldSteps*(game: Game): bool {.closure.} =
  ## Suspends at the authoritative hero turn; resuming completes the same tick.
  let world = game.world
  when defined(replayEvents):
    world.events.setLen(0)
    world.eventTick = world.tick + 1
  world.syncBuildings()
  if world.gameOver:
    return
  if game.replayMode and
      world.tick >= game.replayData.hashes.len:
    return

  dec world.spawnTimerTicks
  if world.spawnTimerTicks <= 0:
    world.spawnTimerTicks += world.spawnIntervalTicks
    profileBlock "spawnWave":
      spawnWave(world)

  world.tick = world.tick +% 1
  for hero in world.heroes:
    if hero.hp > 0 and hero.state != Dying:
      world.tickHeroCooldowns(hero)
  profileBlock "vision":
    rebuildVision(world)
    world.updateKnownBuildings()
  if game.historyPlayback:
    if game.recorder != nil:
      game.replayPlayer.data = game.recorder.data
    var action: ReplayAction
    while game.replayPlayer.takeActionAt(uint32(world.tick), action):
      if applyReplayAction(world, action):
        game.metrics.command(heroIndex(world, action.heroId), world.tick)
  dec world.heroTurnTicks
  if world.heroTurnTicks <= 0:
    world.heroTurnTicks += DecisionTicks
    if game.historyPlayback:
      world.heroTurnStart = (world.heroTurnStart + 1) mod world.heroes.len
    else:
      profileBlock "decisions":
        yield true

  profileBlock "footmen":
    for footman in world.footmen.mitems:
      updateFootman(world, footman)
  profileBlock "towers":
    for tower in world.buildings.mitems:
      updateTower(world, tower)
  profileBlock "heroes":
    for hero in world.heroes:
      updateHero(world, hero)

  world.advanceSpells()

  var write = 0
  for read in 0 ..< world.footmen.len:
    if world.footmen[read].state != Dying or
        world.footmen[read].deathTicks < FootmanDeathTicks + CorpseLingerTicks:
      if write != read:
        world.footmen[write] = world.footmen[read]
      inc write
    else:
      when defined(replayEvents):
        world.lifecycleEvent(EntityRemoved, 0, world.footmen[read].id,
          CorpseExpired)
  world.footmen.setLen(write)

  profileBlock "separate":
    for i in 0 ..< world.footmen.len:
      if world.footmen[i].state == Dying:
        continue
      for j in i + 1 ..< world.footmen.len:
        if world.footmen[j].state == Dying:
          continue
        if world.footmen[i].navLayer != world.footmen[j].navLayer:
          continue
        separateBodies(
          world.footmen[i].body,
          world.footmen[j].body,
          world.footmen[i].navLayer
        )

    for i in 0 ..< world.heroes.len:
      if world.heroes[i].state == Dying:
        continue
      for j in i + 1 ..< world.heroes.len:
        if world.heroes[j].state == Dying:
          continue
        if world.heroes[i].navLayer != world.heroes[j].navLayer:
          continue
        separateBodies(
          world.heroes[i].body,
          world.heroes[j].body,
          world.heroes[i].navLayer
        )
      for j in 0 ..< world.footmen.len:
        if world.footmen[j].state == Dying:
          continue
        if world.heroes[i].navLayer != world.footmen[j].navLayer:
          continue
        separateBodies(
          world.heroes[i].body,
          world.footmen[j].body,
          world.heroes[i].navLayer
        )

  profileBlock "applyBody":
    for footman in world.footmen.mitems:
      let before = footman.position
      applyBody(footman)
      if footman.state != Dying:
        footman.velocity.x += footman.position.x - before.x
        footman.velocity.z += footman.position.z - before.z
      settleOnLayer(footman.position, footman.navLayer)
    for hero in world.heroes:
      let before = hero.position
      applyBody(hero)
      if hero.state != Dying:
        hero.velocity.x += hero.position.x - before.x
        hero.velocity.z += hero.position.z - before.z
      settleOnLayer(hero.position, hero.navLayer)

  for fort in world.forts.mitems:
    if fort.hp <= 0:
      world.gameOver = true
      world.winner = if fort.team == RedTeam: BlueTeam else: RedTeam
      for footman in world.footmen.mitems:
        if footman.state == Dying:
          continue
        footman.animClip =
          if footman.team == world.winner: victoryClip else: idleClip
        footman.animTicks = 0
      for hero in world.heroes:
        if hero.state == Dying:
          continue
        hero.animClip =
          if hero.team == world.winner: heroIdleClip else: heroDeathClip
        hero.animTicks = 0

  when defined(replayEvents):
    if world.gameOver:
      world.emit GameEvent(
        kind: MatchEnded, cause: GodDestroyed, amount: world.winner.ord,
        actor: world.eventEntity(0), target: world.eventEntity(0), related: -1
      )
    elif world.tick == game.config.maxTicks:
      world.emit GameEvent(
        kind: MatchEnded, cause: TimeLimit, amount: -1,
        actor: world.eventEntity(0), target: world.eventEntity(0), related: -1
      )

  if game.historyPlayback:
    checkReplayHash(game, stateHash(game))
  elif game.recorder != nil and game.recordingError.len == 0 and
      game.recorder.data.hashes.len < world.tick:
    try:
      game.recorder.recordHash(stateHash(game))
    except ReplayError as error:
      game.recordingError = error.msg

proc tickWorld*(game: Game, onHeroTurn: proc() {.closure.}) {.measure.} =
  for _ in tickWorldSteps(game):
    onHeroTurn()

proc initLanePaths(map: MapData) =
  ## Samples symmetric lane goals without baking live buildings into roads.
  proc gate(lane: int, team: Team): ArenaStop =
    ## Places a lane endpoint between its two barracks at the fort exit.
    var midpoint: WorldPoint
    var count = 0
    for site in map.layout.barracks:
      if site.lane == lane and site.team == team.ord:
        midpoint = midpoint + worldPoint(site.position)
        inc count
    doAssert count == 2
    (
      GroundLayer,
      int(mapCoordinate(midpoint.x div count.int32)),
      int(mapCoordinate(midpoint.z div count.int32))
    )

  proc nearestStop(route: seq[ArenaStop], stop: ArenaStop): int =
    ## Finds the generated road sample nearest a fort exit during map setup.
    var best = int.high
    for i, candidate in route:
      let distance = (candidate.x - stop.x) * (candidate.x - stop.x) +
        (candidate.z - stop.z) * (candidate.z - stop.z)
      if distance < best:
        best = distance
        result = i

  for lane in [0, 1]:
    let
      source = map.layout.lanes[lane]
      first = gate(lane, RedTeam)
      last = gate(lane, BlueTeam)
      firstIndex = source.nearestStop(first)
      lastIndex = source.nearestStop(last)
    doAssert firstIndex < lastIndex
    var route = @[first]
    for i in firstIndex + 1 ..< lastIndex:
      route.add source[i]
    route.add last
    if lane == 1:
      route.setLen(route.len div 2 + route.len mod 2)
    lanePathPoints[lane].setLen(0)
    lanePathTiles[lane].setLen(0)
    if route.len == 0:
      continue
    var distance = 0'i64
    for i, stop in route:
      let point = pathPoint(stop.layer, stop.x, stop.z)
      if i > 0:
        let previous = route[i - 1]
        distance += integerSqrt(distanceSquared(
          worldPoint(point),
          worldPoint(pathPoint(previous.layer, previous.x, previous.z))
        ))
      let crossing = i > 0 and stop.layer != route[i - 1].layer
      var bend = false
      if i > 0 and i < route.high:
        let
          back = route[max(0, i - 5)]
          ahead = route[min(route.high, i + 5)]
          dx = int64(stop.x - back.x)
          dz = int64(stop.z - back.z)
          ex = int64(ahead.x - stop.x)
          ez = int64(ahead.z - stop.z)
        bend = distance >= WaypointSpacing div 2 and
          abs(dx * ez - dz * ex) > abs(dx * ex + dz * ez)
      if i == 0 or i == route.high or crossing or bend or
          distance >= WaypointSpacing:
        lanePathPoints[lane].add point
        lanePathTiles[lane].add PathTile(
          layer: stop.layer.int32, x: stop.x.int32, z: stop.z.int32)
        distance = 0

  proc mirrored(tile: PathTile): PathTile =
    ## Rotates a goal by 180 degrees on the same symmetric arena layer.
    PathTile(layer: tile.layer,
      x: int32(layers[tile.layer].width - 1) - tile.x,
      z: int32(layers[tile.layer].depth - 1) - tile.z)
  lanePathTiles[2].setLen(0)
  for i in countdown(lanePathTiles[0].high, 0):
    lanePathTiles[2].add mirrored(lanePathTiles[0][i])
  let middle = lanePathTiles[1]
  for i in countdown(middle.high, 0):
    let tile = mirrored(middle[i])
    if lanePathTiles[1][^1] != tile:
      lanePathTiles[1].add tile
  for lane in 0 .. 2:
    lanePathPoints[lane].setLen(0)
    for tile in lanePathTiles[lane]:
      lanePathPoints[lane].add pathPoint(int(tile.layer), int(tile.x), int(tile.z))

proc sampleMetrics*(game: Game, force = false) =
  ## Samples deterministic world counters and independent VM telemetry.
  if game.metrics == nil or game.world.stats == nil:
    return
  for slot, values in game.world.stats.values:
    for kind in MetricKind:
      game.metrics.set(slot, kind, values[kind])
    game.metrics.set(slot, LevelMetric, game.world.heroes[slot].level)
  game.history.capture(game.metrics, game.world.tick, force)

proc newGame*(
    map: MapData,
    spawnInterval: int32,
    botCount: int,
    replayMode: bool,
    replayData: ReplayData
): Game =
  ## Builds one match session: world, lane paths, towers, and heroes.
  result = Game(
    world: World(
      forts: startingForts(map),
      nextFootmanId: FirstFootmanId,
      winner: RedTeam,
      scriptObjects: newSeqOfCap[WorldObject](256),
      scriptObjectsTick: -1
    ),
    map: map,
    replayMode: replayMode,
    replayData: replayData
  )
  let world = result.world
  world.spawnIntervalTicks = spawnInterval
  world.rng = initRng(map.seed)
  initTowers(world, map)
  initLanePaths(map)
  for team in Team:
    var point = worldPoint(map.layout.spawns[team.ord])
    point.y = fixedSurfaceHeight(point)
    world.heroSpawns[team.ord] = point
  for i, site in map.layout.barracks:
    var
      position = worldPoint(site.position)
      spawn = worldPoint(site.spawn)
    position.y = fixedSurfaceHeight(position)
    spawn.y = fixedSurfaceHeight(spawn)
    world.buildings.add Building(
      kind: BarracksBuilding,
      id: FirstBarracksId + int32(i),
      team: Team(site.team), lane: site.lane,
      position: position, spawn: spawn,
      facing: heading(site.facing.x - site.position.x,
        site.facing.z - site.position.z),
      hp: TowerHitPoints[OuterTower], maxHp: TowerHitPoints[OuterTower]
    )
  for team in Team:
    for i, site in map.layout.guards[team.ord]:
      var position = worldPoint(site.position)
      position.y = fixedSurfaceHeight(position)
      world.buildings.add Building(
        id: FirstTowerId + 18 + int32(team.ord * 2 + i),
        kind: TowerBuilding,
        guardsGod: true,
        team: team,
        lane: -1,
        tier: GateTower,
        position: position,
        facing: heading(
          site.facing.x - site.position.x,
          site.facing.z - site.position.z
        ),
        hp: TowerHitPoints[GateTower],
        maxHp: TowerHitPoints[GateTower]
      )
  world.initOccupancy()
  sightTerrain = buildSightTerrain()
  let visionCells = mapTiles() * mapTiles()
  for team in Team:
    world.teamVisible[team.ord] = newSeq[uint8](visionCells)
    world.teamExplored[team.ord] = newSeq[uint8](visionCells)
  for lane in 0 .. 2:
    laneWorldPaths[lane].setLen(0)
    laneWorldLayers[lane].setLen(0)
    for tile in lanePathTiles[lane]:
      laneWorldPaths[lane].add worldPoint(pathPoint(
        int(tile.layer),
        int(tile.x),
        int(tile.z)
      ))
      laneWorldLayers[lane].add tile.layer
  for fort in world.forts.mitems:
    fort.center.y = fixedSurfaceHeight(fort.center)
  let heroSetup =
    if replayMode:
      replayData.header.setup.heroes
    else:
      liveHeroSetup(botCount)
  spawnHeroes(world, heroSetup)
  for hero in world.heroes:
    hero.initHeroCharges()
  world.stats = newCombatStats(world.heroes.len)
  result.metrics = newMetrics(world.heroes.len, TickRate)
  for slot, hero in world.heroes:
    world.stats.teams[slot] = hero.team.ord
  doAssert world.heroes.len == heroSetup.len, "every configured hero must spawn"
  rebuildVision(world)
  world.updateKnownBuildings()
  world.heroTurnStart = seededHeroTurnStart(world)
  if replayMode:
    validateReplayWorld(result)
  result.sampleMetrics(true)
  when defined(replayEvents):
    for fort in world.forts:
      world.lifecycleEvent(EntitySpawned, 0, fort.id, Initialization)
    for building in world.buildings:
      world.lifecycleEvent(EntitySpawned, 0, building.id, Initialization)
    for hero in world.heroes:
      world.lifecycleEvent(EntitySpawned, 0, hero.id, Initialization)

proc scores*(world: World): seq[int] =
  ## Awards every hero on the victorious team one win.
  result.setLen(world.heroes.len)
  if world.gameOver:
    for slot, hero in world.heroes:
      if hero.team == world.winner:
        result[slot] = 1

proc totalXp*(world: World): seq[int] =
  ## Returns lifetime hero XP in platform seat order.
  for hero in world.heroes:
    result.add hero.totalXp
