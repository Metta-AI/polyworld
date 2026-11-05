## Call to Adventure simulation.
##
## Planar motion uses Q16.16 tile-space bodies. Home tiles, claims, and
## replay integers stay derived from `cell(body.pos)`. This module must not
## import anything that returns a float. Graphics may sample `surfaceHeight`
## and must not write simulation state.
##
## BASIC decisions arrive through `onHeroDecision`. This module owns the
## VM type on `Game` but never runs a program.

import
  bassy, fixxy,
  polyworld/[bodies, hashes, metrics, pathing, profiles, rngs, tapes,
    visions, mailboxes],
  content,
  maps,
  replays

type
  HeroVm* = ref object
    output*: PrintProc
    prepareDecision*: proc(tick: int32) {.closure.}
    pollRequests*: proc(): bool {.closure.}
    ## One compiled BASIC program for a party slot. Not simulation state.
    runtime*: Runtime
    ready*: bool
    failed*: bool
    lastError*: string
    decisions*: int
    lastWork*, lastInstructions*: int64
  Game* = ref object
    ## One expedition session. World is the hashable sim; everything else
    ## is tape, map, and agents.
    world*: World
    metrics*: MatchMetrics
    history*: MetricHistory
    dungeon*: Dungeon
    log*: seq[string]
    recorder*: ReplayRecorder
    replayData*: ReplayData
    replayPlayer*: ReplayPlayer
    hashCheck*: ReplayHashCheck
    historyPlayback*: bool
    replayMode*: bool
    heroVms*: array[PartySize, HeroVm]
    inboxes*: array[PartySize, Mailbox]

const
  AggroTiles* = 9'i32
  HeroAggroTiles* = 11'i32
  MonstersPerLevel* = [0, 8, 8, 9, 9, 10]
  PackMin = 2'i32
  PackMax = 4'i32
    ## Monsters spawn in packs of this many, standing together in one room.
  SwarmMin = 3'i32
  SwarmMax = 5'i32
    ## Swarmlings each pack brings on top of its members.
  SwarmHoldTiles = 2'i32
    ## How close a swarmling with no free side of a hero to run for waits.
  PackSpreadTiles = 2'i32
    ## How far a pack member stands from the spot the pack gathers on.
  RespawnIntervalTicks* = 720'i32
    ## A fresh pack every 30 seconds while the party returns.
  KiteTiles = 3'i32
    ## A caster backs off from front-line heroes closer than this.
  LineHalfWidth = 0.7'fx
    ## How close to a line a body's middle must be to be caught: the strip
    ## the line draws, plus the body's own radius.
  SlipTiles = 5'i32
    ## A cloaked hero backs off from monsters closer than this.
  SlipSteps = 7'i32
    ## How far round itself a cloaked hero looks for somewhere safer.
  CloakTicks = 72'i16
    ## Three seconds of Shadow Cloak, enough to get clear and turn round.
  CrowdTiles* = 2'i32
    ## How near its target other foes must stand for a kiting hero to see a
    ## crowd it will not walk in among; see `ClassCrowdLimit`.
  ChaseTiles = 4'i32
    ## How near foes that can still come at a kiting hero must be before it
    ## counts them as on its heels: near enough to reach it during a swing.
  KiteReach = 5'i32
    ## How far a kiting hero wants to be from every foe.
  KiteSteps = 2'i32
    ## How far round itself a kiting hero looks for somewhere better. Any
    ## farther and the way there can run past the foes it is getting away
    ## from.
  HemmedFoes = 3'i32
    ## How many foes at its elbow leave a kiting hero no way out, so that it
    ## stands and fights rather than push against a wall of bodies.
  KiteSettle = 3'i32
    ## How much better somewhere new must be before a kiting hero gives up
    ## the spot it is already making for, so it does not turn back and
    ## forth between two.
  RepositionTicks* = 12'i32
    ## The slack a hero getting clear before its Sun Orb leaves itself, so
    ## the orb still comes down while the vines hold.
  PackTiles = 2'i32
    ## How far from its target a foe still counts as one of its pack.
  BurnVinesHeld = 3'i32
    ## How many foes a hero's vines must hold before it throws its Sun Orb
    ## into them as soon as it is clear, rather than wait for more.
  LootPickupRange* = 1'i32
  MaxMonsters* = 180
  ArenaLightRadius = 14'i32
    ## Lights the whole arena room, walls included, from anywhere inside it,
    ## for heroes and monsters alike.
  ArenaRanks = 4'i32
    ## Monsters per arena column, every other row and clear of both walls.
  ArenaMonsterLimit* = 24
    ## Six arena columns, leaving a gap before the heroes' column.
  ActorBodyRadius = 0.33'fx
  BodyTurnRate = 0.35'fx
  PathArrive = 0.35'fx

var
  sightTerrain: array[LevelCount, seq[int16]]
  sightBlockers: array[LevelCount, seq[int16]]
  visionBlockers: array[LevelCount, seq[int16]]
  visionSkipWorld: pointer
  visionSkipKeys: seq[int32]
  visionSkipNow: seq[int32]
  pathWorld: World
  pathSlot: int32
  pathGoalTile: TileRef
  pathTiles: seq[PathTile]
  pathThroughMonsters: bool
  ctaWalkLayer: int
  ctaWalkDestLayer: int

proc config*(game: Game): GameConfig =
  ## Reads the match configuration owned by the live or loaded replay.
  if game.recorder != nil:
    game.recorder.data.config
  else:
    game.replayData.config

proc lightRadius*(world: World, slot: int32): int32
proc bindActorBody(actor: Actor)
proc applyActorBody(world: World, slot: int32)

## Construction

proc newWorld*(setup: Setup): World =
  ## Creates the tick-zero world. Pure: no file access, no assets, no command
  ## line. Reads the generated terrain through `maps` but never mutates it.
  result = World()
  result.stats = newCombatStats(PartySize)
  result.setup = setup
  result.outcome = RunningOutcome
  result.phase = DescendingPhase
  result.nextActorId = 1
  result.nextItemId = 1
  result.rng = initRng(setup.seed)
  result.claims = newSeq[uint16](WorldTiles)
  result.explored = newSeq[uint8](WorldTiles div 8)
  for slot in 0 ..< PartySize:
    result.visible[slot] = newSeq[uint8](WorldTiles div 8)
  result.turnStart = result.rng.below(PartySize)

proc cloneActors(actors: seq[Actor]): seq[Actor] =
  ## Copies each actor so two worlds never share a path seq.
  result.setLen(actors.len)
  for i, actor in actors:
    result[i] = Actor()
    if not actor.isNil:
      result[i][] = actor[]

proc clone*(world: World): World =
  ## Deep copy. Actors are refs and must be cloned one by one.
  result = World()
  result[] = world[]
  result.stats = world.stats.clone()
  result.actors = cloneActors(world.actors)

proc restore*(world: World, snapshot: World) =
  ## Overwrites in place, keeping the caller's ref identity.
  world[] = snapshot[]
  world.stats = snapshot.stats.clone()
  world.actors = cloneActors(snapshot.actors)

## Bit maps

proc testBit(bits: seq[uint8], index: int32): bool {.inline.} =
  (bits[index shr 3] and (1'u8 shl (index and 7))) != 0

proc setBit(bits: var seq[uint8], index: int32) {.inline.} =
  bits[index shr 3] = bits[index shr 3] or (1'u8 shl (index and 7))

proc clearBits*(bits: var seq[uint8]) {.inline.} =
  for index in 0 ..< bits.len:
    bits[index] = 0

proc explored*(world: World, tile: TileRef): bool =
  ## Party-shared memory: true once any hero has seen this tile.
  world.explored.testBit(tile.tileIndex)

proc markExplored*(world: World, tile: TileRef) =
  world.explored.setBit(tile.tileIndex)

proc visible*(world: World, slot: int32, tile: TileRef): bool =
  ## Private sight: what this one hero can see right now.
  world.visible[slot].testBit(tile.tileIndex)

proc markVisible*(world: World, slot: int32, tile: TileRef) =
  world.visible[slot].setBit(tile.tileIndex)

proc tileKnown*(world: World, slot: int32, tile: TileRef): int32 =
  ## 0 unexplored, 1 remembered by the party, 2 visible to this hero. The
  ## asymmetry is deliberate: the party remembers together but each hero only
  ## sees for itself, which is what makes scouting worth scripting.
  if world.visible(slot, tile):
    2
  elif world.explored(tile):
    1
  else:
    0

proc prepareSightTerrain() =
  ## Builds derived integer terrain and structure occlusion grids by level.
  for level in 0 ..< LevelCount:
    if sightTerrain[level].len == TilesPerLevel:
      continue
    sightTerrain[level] = newSeq[int16](TilesPerLevel)
    sightBlockers[level] = newSeq[int16](TilesPerLevel)
    let layer = layers[level]
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let
          index = z * GridTiles + x
          tile = layer.tiles[index]
          tops = tile.tops
        sightTerrain[level][index] = int16(
          (int32(tops[0]) + int32(tops[1]) +
            int32(tops[2]) + int32(tops[3])) div 4
        )
        if tile.kind == TreeTile:
          sightBlockers[level][index] = 24

proc fillVisionKeys(world: World, dest: var seq[int32]) =
  ## Records hero homes, life, torch range, and door state.
  dest.setLen(0)
  dest.add int32(world.actors.len)
  for slot in 0 ..< min(PartySize, world.actors.len):
    let hero = world.actors[slot]
    dest.add hero.id
    dest.add int32(hero.alive)
    dest.add int32(hero.home.level)
    dest.add int32(hero.home.x)
    dest.add int32(hero.home.z)
    dest.add world.lightRadius(int32(slot))
  dest.add int32(world.doors.len)
  for door in world.doors:
    dest.add door.id
    dest.add int32(door.tile.level)
    dest.add int32(door.tile.x)
    dest.add int32(door.tile.z)
    dest.add int32(door.open)

proc fillDynamicSightBlockers(world: World, level: int) =
  ## Fills reused occluders when a level has a closed door.
  visionBlockers[level].setLen(0)
  for door in world.doors:
    if not door.open and int(door.tile.level) == level:
      if visionBlockers[level].len == 0:
        visionBlockers[level].setLen(TilesPerLevel)
        for i, value in sightBlockers[level]:
          visionBlockers[level][i] = value
      visionBlockers[level][
        int32(door.tile.z) * GridTiles + int32(door.tile.x)
      ] = 28

proc rebuildVision*(world: World) {.measure.} =
  ## Rebuilds each hero's range- and occluder-limited private sight.
  world.fillVisionKeys(visionSkipNow)
  if visionSkipWorld == cast[pointer](world) and
      sameVisionKeys(visionSkipNow, visionSkipKeys):
    return
  prepareSightTerrain()
  for level in 0 ..< LevelCount:
    world.fillDynamicSightBlockers(level)
  initVisionKernel()
  for slot in 0 ..< PartySize:
    world.visible[slot].clearBits()
    if slot >= world.actors.len:
      continue
    let hero = world.actors[slot]
    if not hero.alive:
      continue
    let
      level = int(hero.home.level)
      radius = world.lightRadius(int32(slot))
      sourceX = int32(hero.home.x)
      sourceZ = int32(hero.home.z)
      sourceY = int64(sightTerrain[level][sourceZ * GridTiles + sourceX]) + 14
      useDynamic = visionBlockers[level].len > 0
    for offset in visionCircleTiles(radius):
      let
        x = sourceX + int32(offset.dx)
        z = sourceZ + int32(offset.dz)
      if x < 0 or x >= GridTiles or z < 0 or z >= GridTiles:
        continue
      let seen =
        if useDynamic:
          offsetVisible(
            GridTiles,
            sightTerrain[level],
            visionBlockers[level],
            sourceX,
            sourceZ,
            sourceY,
            offset
          )
        else:
          offsetVisible(
            GridTiles,
            sightTerrain[level],
            sightBlockers[level],
            sourceX,
            sourceZ,
            sourceY,
            offset
          )
      if seen:
        let tile = TileRef(
          level: int8(level),
          x: uint8(x),
          z: uint8(z)
        )
        world.markVisible(int32(slot), tile)
        world.markExplored(tile)
  copyVisionKeys(visionSkipKeys, visionSkipNow)
  visionSkipWorld = cast[pointer](world)

proc monsterSight(world: World, monster: Actor): int32 =
  ## How far a monster sees: its species' sight, or the whole lit arena room.
  if world.isArena: ArenaLightRadius else: SpeciesSight[monster.species]

proc actorCanSee*(world: World, slot, targetSlot: int32): bool =
  ## Returns whether one hero or monster has unobstructed sight of another.
  if slot < 0 or targetSlot < 0 or
      slot >= world.actors.len or targetSlot >= world.actors.len:
    return false
  let
    observer = world.actors[slot]
    target = world.actors[targetSlot]
  if not observer.alive or not target.alive or
      observer.home.level != target.home.level:
    return false
  if observer.kind == HeroActor:
    return world.visible(slot, target.home)
  prepareSightTerrain()
  let level = int(observer.home.level)
  world.fillDynamicSightBlockers(level)
  if visionBlockers[level].len > 0:
    lineVisible(
      GridTiles,
      GridTiles,
      sightTerrain[level],
      visionBlockers[level],
      int32(observer.home.x),
      int32(observer.home.z),
      int32(target.home.x),
      int32(target.home.z),
      world.monsterSight(observer),
      12
    )
  else:
    lineVisible(
      GridTiles,
      GridTiles,
      sightTerrain[level],
      sightBlockers[level],
      int32(observer.home.x),
      int32(observer.home.z),
      int32(target.home.x),
      int32(target.home.z),
      world.monsterSight(observer),
      12
    )

## Claims

proc claimant*(world: World, tile: TileRef): int32 =
  ## Slot holding this tile, or -1 when free.
  int32(world.claims[tile.tileIndex]) - 1

proc claimed*(world: World, tile: TileRef): bool =
  world.claims[tile.tileIndex] != 0

proc claim*(world: World, tile: TileRef, slot: int32) =
  world.claims[tile.tileIndex] = uint16(slot + 1)

proc release*(world: World, tile: TileRef) =
  world.claims[tile.tileIndex] = 0

proc rebuildClaims*(world: World) =
  ## Claims are a pure function of actor home tiles.
  for index in 0 ..< world.claims.len:
    world.claims[index] = 0
  for slot, actor in world.actors:
    if actor.id == 0:
      continue
    world.claim(actor.home, int32(slot))

## Actors

proc addActor*(world: World, actor: Actor): int32 =
  ## Places an actor in the lowest free slot and claims its tile. Returns the
  ## slot, or -1 when the tile is already taken.
  if world.claimed(actor.home):
    return -1
  var placed = actor
  placed.id = world.nextActorId
  inc world.nextActorId
  placed.next = placed.home
  result = -1
  for slot in PartySize ..< world.actors.len:
    if world.actors[slot].id == 0:
      world.actors[slot] = placed
      result = int32(slot)
      break
  if result < 0:
    world.actors.add placed
    result = int32(world.actors.len - 1)
  world.claim(placed.home, result)
  world.actors[result].bindActorBody()

proc removeActor*(world: World, slot: int32) =
  ## Frees an actor's slot and both of its tile claims.
  if world.actors[slot].id == 0:
    return
  world.release(world.actors[slot].home)
  if world.actors[slot].moving:
    world.release(world.actors[slot].next)
  world.actors[slot] = Actor()

proc actorSlot*(world: World, id: int32): int32 =
  ## Slot for an actor id, or -1. Ids are small and actors few, so a scan
  ## beats carrying a derived index that a checkpoint would have to hash.
  if id == 0:
    return -1
  for slot, actor in world.actors:
    if actor.id == id:
      return int32(slot)
  -1

proc itemIndex*(world: World, id: int32): int32 =
  if id == 0:
    return -1
  for index, item in world.items:
    if item.id == id:
      return int32(index)
  -1

proc deleteItem(world: World, index: int32) =
  ## Removes one floor or carried item by seq index.
  if index < 0 or index >= world.items.len:
    return
  world.items.del(int(index))

proc freeInventorySlot(actor: Actor): int32 =
  ## First empty item slot, or -1 when both are full.
  for index in 0 ..< InventorySlots:
    if actor.inventory[index] == 0:
      return int32(index)
  -1

proc refreshSpeed(actor: Actor) =
  ## Applies encumbrance, a short winged-boot haste and any slow.
  var scale = EncumbranceScale[actor.encumbrance(actor.carryCapacity)]
  if actor.hasteTicks > 0:
    scale = scale * 13 div 10
  if actor.slowTicks > 0:
    scale = scale * SlowPercent div 100
  if actor.entangledTicks > 0:
    scale = scale * int32(VineRootTicks - actor.entangledTicks) div
      int32(VineRootTicks)
  actor.speed = max(actor.baseSpeed * scale div 100, 1)

proc spawnLoot(
    game: Game,
    kind: LootKind,
    tile: TileRef,
    value = 0'i32
): int32 =
  ## Places one pile or usable item on a tile and returns its id.
  result = game.world.nextItemId
  game.world.items.add Item(
    id: result,
    kind: kind,
    tile: tile,
    value:
      if value > 0: value
      else: LootValues[kind],
    weight: LootWeights[kind]
  )
  inc game.world.nextItemId

proc doorIndex*(world: World, id: int32): int32 =
  if id == 0:
    return -1
  for index, door in world.doors:
    if door.id == id:
      return int32(index)
  -1

## Party helpers

proc heroSlot*(world: World, id: int32): int32 =
  ## Like `actorSlot`, but restricted to the four party members.
  for slot in 0 ..< PartySize:
    if world.actors[slot].id == id:
      return int32(slot)
  -1

proc partyAlive*(world: World): int32 =
  for slot in 0 ..< PartySize:
    if world.actors[slot].alive:
      inc result

proc lightRadius*(world: World, slot: int32): int32 =
  ## How far this hero's torch reaches, before line of sight is applied.
  let actor = world.actors[slot]
  if actor.kind != HeroActor:
    return 0
  if world.isArena:
    return ArenaLightRadius
  ClassLightRadius[actor.heroClass]

## Chat

proc say*(world: World, speaker, phrase, value: int32) =
  ## Appends to the chat ring. Simulation state, so it is hashed and replayed.
  world.chat[world.chatHead] = ChatLine(
    speaker: speaker,
    phrase: phrase,
    value: value,
    tick: world.tick
  )
  world.chatHead = (world.chatHead + 1) mod ChatLines

## Geometry

proc tileDistance*(a, b: TileRef): int32 =
  ## Chebyshev distance in tiles, or -1 when the tiles are on different
  ## levels. Integer throughout: nothing in the simulation takes a root.
  if a.level != b.level:
    return -1
  max(abs(int32(a.x) - int32(b.x)), abs(int32(a.z) - int32(b.z)))

proc neighbor*(tile: TileRef, facing: Facing): TileRef =
  ## The adjacent tile within the same level, ignoring layer links. Callers
  ## that need a cross-level step use `edgeLink` instead.
  result = tile
  case facing
  of East: result.x = uint8(int32(tile.x) + 1)
  of South: result.z = uint8(int32(tile.z) + 1)
  of West: result.x = uint8(int32(tile.x) - 1)
  of North: result.z = uint8(int32(tile.z) - 1)

proc walkable*(tile: TileRef): bool =
  ## Terrain-only test; occupancy is a separate question.
  isWalkable(int(tile.level), int(tile.x), int(tile.z))

proc planarCenter(tile: TileRef): FixedVec2 =
  ## Returns the tile-space centre of one dungeon cell.
  fixedVec2(
    fixed(int32(tile.x)) + 0.5'fx,
    fixed(int32(tile.z)) + 0.5'fx
  )

proc lineTile*(origin, aim: TileRef, step: int32): (bool, TileRef) =
  ## The tile `step` tiles along the straight line from `origin` through
  ## `aim`, and whether it is on the map. Counted along the longer axis, so
  ## the line is one tile thin and passes through `aim` itself.
  let
    dx = int32(aim.x) - int32(origin.x)
    dz = int32(aim.z) - int32(origin.z)
    span = max(max(abs(dx), abs(dz)), 1)
  proc along(delta: int32): int32 =
    let rounded = (2 * abs(delta) * step + span) div (2 * span)
    if delta < 0: -rounded else: rounded
  let
    x = int32(origin.x) + along(dx)
    z = int32(origin.z) + along(dz)
  if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
    return (false, origin)
  (true, TileRef(level: origin.level, x: uint8(x), z: uint8(z)))

proc lineReach*(world: World, origin, aim: TileRef, length: int32): int32 =
  ## How many tiles a line travels before a wall or a shut door stops it.
  for step in 1'i32 .. length:
    let (onMap, tile) = lineTile(origin, aim, step)
    if not onMap or not tile.walkable:
      return step - 1
    for door in world.doors:
      if not door.open and door.tile == tile:
        return step - 1
  length

proc lineEnd*(world: World, spec: AbilitySpec, origin, aim: TileRef): TileRef =
  ## The last tile a line ability reaches.
  lineTile(origin, aim, world.lineReach(
    origin, aim, int32(spec.radiusTiles)))[1]

proc onLine(
    world: World,
    spec: AbilitySpec,
    origin, aim: TileRef,
    pos: FixedVec2
): bool =
  ## Whether a body stands in a line, judged by the body and not its tile,
  ## which can be a whole tile off the line as a walker crosses into it.
  let
    start = planarCenter(origin)
    run = planarCenter(world.lineEnd(spec, origin, aim)) - start
    span = length(run)
    offset = pos - start
  if span == 0.0'fx:
    return length(offset) <= LineHalfWidth
  let along = dot(offset, run)
  abs(cross(offset, run)) <= LineHalfWidth * span and
    along >= -(LineHalfWidth * span) and
    along <= (span + LineHalfWidth) * span

proc inCone(spec: AbilitySpec, origin, aim: TileRef, pos: FixedVec2): bool =
  ## Whether a body stands in a cone: within its radius and a half of the
  ## caster and at most an eighth of a turn off the way it is aimed, judged
  ## by the body so that it matches the slice of floor spectators see.
  let
    start = planarCenter(origin)
    run = planarCenter(aim) - start
    offset = pos - start
  length(offset) <= fixed(int32(spec.radiusTiles)) + 0.5'fx and
    abs(cross(offset, run)) <= dot(offset, run)

proc inArea*(
    world: World,
    spec: AbilitySpec,
    origin, aim: TileRef,
    victim: Actor
): bool =
  ## Whether an area cast from `origin` at `aim` catches an actor. A disc
  ## takes in every tile whose middle lies within its radius and a half.
  if aim.level != victim.home.level:
    return false
  let radius = int32(spec.radiusTiles)
  case spec.shape
  of SquareArea:
    tileDistance(aim, victim.home) <= radius
  of RoundArea:
    let
      dx = int32(aim.x) - int32(victim.home.x)
      dz = int32(aim.z) - int32(victim.home.z)
    4 * (dx * dx + dz * dz) <= (2 * radius + 1) * (2 * radius + 1)
  of LineArea:
    world.onLine(spec, origin, aim, victim.body.pos)
  of ConeArea:
    spec.inCone(origin, aim, victim.body.pos)

proc angleFromFacing(facing: Facing): Fixed =
  ## Maps a cardinal facing onto body radians (east is zero).
  case facing
  of East: FixedZero
  of South: FixedHalfPi
  of West: FixedPi
  of North: -FixedHalfPi

proc facingFromAngle(angle: Fixed): Facing =
  ## Snaps a body heading to the nearest cardinal.
  let dir = direction(wrapAngle(angle))
  if abs(dir.x) >= abs(dir.y):
    if dir.x >= FixedZero: East else: West
  else:
    if dir.y >= FixedZero: South else: North

proc bindActorBody(actor: Actor) =
  ## Stands a body on the actor's home tile.
  actor.body.pos = planarCenter(actor.home)
  actor.body.radius = ActorBodyRadius
  actor.body.facing = angleFromFacing(actor.facing)

proc applyActorBody(world: World, slot: int32) =
  ## Writes the body plane back onto home, facing, and the current waypoint.
  let
    actor = world.actors[slot]
    (x, z) = cell(actor.body.pos)
  actor.home.x = uint8(clamp(x, 0'i32, int32(GridTiles - 1)))
  actor.home.z = uint8(clamp(z, 0'i32, int32(GridTiles - 1)))
  actor.home.level = int8(preferLayer(
    int(actor.home.level),
    ctaWalkDestLayer,
    int(actor.home.x),
    int(actor.home.z)
  ))
  actor.facing = facingFromAngle(actor.body.facing)
  if actor.moving:
    actor.next = actor.path[actor.pathIndex].tile
  else:
    actor.next = actor.home

proc ctaTilesWalkable(pos: FixedVec2): bool {.nimcall.} =
  ## Current floor, plus the next waypoint's floor while crossing a ramp.
  let (x, z) = cell(pos)
  layersOpen(ctaWalkLayer, ctaWalkDestLayer, int(x), int(z))

proc moveSpeed(actor: Actor): Fixed =
  ## Tiles walked in one tick from the actor's phase speed.
  fixed(max(actor.speed, 1)) / fixed(PhaseUnits)

proc smoothPathLayers(tiles: seq[PathTile]): seq[PathTile] =
  ## String-pulls each same-layer run so a ramp stays an explicit waypoint.
  if tiles.len == 0:
    return
  var start = 0
  for i in 1 .. tiles.len:
    if i < tiles.len and tiles[i].layer == tiles[start].layer:
      continue
    let pulled = smoothPathTiles(tiles[start ..< i])
    if result.len > 0 and pulled.len > 0 and result[^1] == pulled[0]:
      for j in 1 ..< pulled.len:
        result.add pulled[j]
    else:
      result.add pulled
    start = i

proc stepTarget*(tile: TileRef, facing: Facing): (bool, TileRef) =
  ## Resolves one step through the engine's cross-layer edge links, which is
  ## what lets a hero walk up a ramp onto the next level with no special case.
  let link = edgeLink(int(tile.level), int(tile.x), int(tile.z), facing.ord)
  if not link.open:
    return (false, tile)
  (true, TileRef(level: int8(link.layer), x: uint8(link.x), z: uint8(link.z)))

proc stepCost*(fromTile, toTile: TileRef): int32 =
  ## What one step costs in phase units. Climbing is dearer than walking and
  ## descending is slightly cheaper, priced straight off the packed corner
  ## heights so a ramp slows the party down without any floating point.
  let
    fromTop = tileTop(int(fromTile.level), int(fromTile.x), int(fromTile.z))
    toTop = tileTop(int(toTile.level), int(toTile.x), int(toTile.z))
    rise = toTop - fromTop
  result =
    if rise > 0: PhaseUnits + rise * ClimbCostPerStep
    else: PhaseUnits + rise * DescendCostPerStep
  result = clamp(result, MinimumStepUnits, MaximumStepUnits)

proc startStep*(world: World, slot: int32, facing: Facing): bool =
  ## Begins one step. Returns false when the way is blocked, which is normal:
  ## the caller waits or re-paths rather than treating it as an error.
  if world.actors[slot].moving:
    return false
  let
    home = world.actors[slot].home
    (open, target) = home.stepTarget(facing)
  if not open:
    return false
  if world.claimed(target):
    return false
  world.claim(target, slot)
  world.actors[slot].next = target
  world.actors[slot].facing = facing
  world.actors[slot].stepUnits = stepCost(home, target)
  true

proc advanceStep*(world: World, slot: int32) =
  ## Moves one tick along the current step, releasing the tile behind once the
  ## actor has fully arrived. The leftover phase carries into the next step so
  ## speed stays exactly linear rather than drifting a little each tile.
  if not world.actors[slot].moving:
    world.actors[slot].phase = 0
    return
  world.actors[slot].phase += max(world.actors[slot].speed, 1)
  if world.actors[slot].phase >= world.actors[slot].stepUnits:
    world.release(world.actors[slot].home)
    world.actors[slot].phase -= world.actors[slot].stepUnits
    world.actors[slot].home = world.actors[slot].next
    if world.actors[slot].phase >= world.actors[slot].stepUnits:
      world.actors[slot].phase = 0

proc facingToward*(fromTile, toTile: TileRef): Facing =
  ## Which way to face to reach an adjacent tile.
  if toTile.x > fromTile.x: East
  elif toTile.x < fromTile.x: West
  elif toTile.z > fromTile.z: South
  else: North

proc faceActor(world: World, slot, targetSlot: int32) =
  ## Turns a standing body to face another, so a shot from range leaves
  ## toward its target rather than wherever the shooter last walked.
  let offset =
    world.actors[targetSlot].body.pos - world.actors[slot].body.pos
  if offset != FixedVec2Zero:
    world.actors[slot].body.facing = angle(offset)
  world.actors[slot].facing = facingFromAngle(world.actors[slot].body.facing)

proc faceTile(world: World, slot: int32, tile: TileRef) =
  ## Turns a standing body toward the middle of a tile.
  let offset = planarCenter(tile) - world.actors[slot].body.pos
  if offset != FixedVec2Zero:
    world.actors[slot].body.facing = angle(offset)
  world.actors[slot].facing = facingFromAngle(world.actors[slot].body.facing)

proc clearPath*(world: World, slot: int32) =
  world.actors[slot].path.setLen(0)
  world.actors[slot].pathIndex = 0
  world.actors[slot].stuckTicks = 0

proc ctaPathWalkable(layer, x, z: int): bool {.nimcall.} =
  ## Terrain plus occupancy, except the searcher and the destination.
  let tile = TileRef(
    level: int8(layer),
    x: uint8(x),
    z: uint8(z)
  )
  if not tile.walkable:
    return false
  if tile == pathGoalTile:
    return true
  let holder = pathWorld.claimant(tile)
  holder < 0 or holder == pathSlot or
    (pathThroughMonsters and pathWorld.actors[holder].kind == MonsterActor)

proc tileRef(tile: PathTile): TileRef =
  TileRef(level: int8(tile.layer), x: uint8(tile.x), z: uint8(tile.z))

proc setPath*(world: World, slot: int32, goal: TileRef,
    offset = FixedVec2Zero, recenter = false): bool =
  ## Asks the engine for a route around other occupants and stores it as
  ## tiles to walk. The path crosses layers wherever a ramp does.
  ##
  ## A fresh route first steps to the middle of the tile the actor stands
  ## on. A walker that re-plans the same route, or one still short of an
  ## unreachable goal that it asks for again every decision, carries on from
  ## where it is instead: walking back each time pins it inside its tile.
  ## `recenter` keeps the first step anyway, for a body wedged off-center.
  let actor = world.actors[slot]
  let
    walking = not recenter and actor.moving
    previousEnd = if walking: actor.path[^1].tile else: actor.home
  if actor.home == goal:
    world.clearPath(slot)
    if offset != FixedVec2Zero:
      actor.path.add PathStep(tile: goal, offset: offset)
    return true
  pathWorld = world
  pathSlot = slot
  pathGoalTile = goal
  let query = PathQuery(
    startLayer: int(actor.home.level),
    startX: int(actor.home.x),
    startZ: int(actor.home.z),
    finishLayer: int(goal.level),
    finishX: int(goal.x),
    finishZ: int(goal.z),
    walkable: ctaPathWalkable,
    partial: true
  )
  discard fillTilePath(query, pathTiles)
  if actor.kind == HeroActor and pathTiles.len > 0 and
      pathTiles[^1].tileRef != goal:
    # A pack standing in a corridor walls it off, and the nearest tile short
    # of it can be on another floor entirely. Walk up and fight through.
    pathThroughMonsters = true
    discard fillTilePath(query, pathTiles)
    pathThroughMonsters = false
  if pathTiles.len < 2:
    world.clearPath(slot)
    return false
  let pulled = smoothPathLayers(pathTiles)
  if pulled.len == 0:
    world.clearPath(slot)
    return false
  let
    finish = pulled[^1].tileRef
    first =
      if walking and pulled.len > 1 and pulled[0].tileRef == actor.home and
          (finish == previousEnd or finish != goal):
        1
      else:
        0
    steps = min(pulled.len - first, MaximumPathTiles)
  actor.path.setLen(steps)
  var previous = actor.home
  for i in 0 ..< steps:
    let tile = pulled[first + i].tileRef
    actor.path[i] = PathStep(
      tile: tile,
      direction: facingToward(previous, tile)
    )
    previous = tile
  if actor.path[^1].tile == goal:
    actor.path[^1].offset = offset
  actor.pathIndex = 0
  actor.stuckTicks = 0
  true

proc pathGoal*(world: World, slot: int32): TileRef =
  let actor = world.actors[slot]
  if actor.path.len == 0:
    return actor.home
  actor.path[^1].tile

proc headingFor*(world: World, slot: int32, tile: TileRef): bool =
  ## True while the actor still walks a route that ends on this tile.
  let actor = world.actors[slot]
  actor.moving and actor.path[^1].tile == tile

proc routeTiles*(world: World, slot: int32, goal: TileRef): int32 =
  ## Tiles a hero walks to reach a goal, through monsters if it must, with a
  ## grid's width added when even that route stops short.
  let actor = world.actors[slot]
  pathWorld = world
  pathSlot = slot
  pathGoalTile = goal
  pathThroughMonsters = true
  discard fillTilePath(PathQuery(
    startLayer: int(actor.home.level),
    startX: int(actor.home.x),
    startZ: int(actor.home.z),
    finishLayer: int(goal.level),
    finishX: int(goal.x),
    finishZ: int(goal.z),
    walkable: ctaPathWalkable,
    partial: true
  ), pathTiles)
  pathThroughMonsters = false
  if pathTiles.len == 0:
    return int32(GridTiles * 4)
  result = int32(pathTiles.len)
  if pathTiles[^1].tileRef != goal:
    result += int32(GridTiles)

proc crowdedOut(world: World, slot: int32): bool =
  ## True while an actor still heads for the middle of its own tile and
  ## another body already stands nearer it. Bodies are too wide for three
  ## to share one center, so all but the nearest walk on from where they are.
  let actor = world.actors[slot]
  if actor.pathIndex != 0 or actor.path.len < 2:
    return false
  let step = actor.path[0]
  if step.offset != FixedVec2Zero or step.tile != actor.home:
    return false
  let
    center = planarCenter(step.tile)
    distance = length(center - actor.body.pos)
  for other in 0 ..< world.actors.len:
    if other == slot:
      continue
    let mate = world.actors[other]
    if not mate.alive or mate.home.level != actor.home.level:
      continue
    if length(center - mate.body.pos) < distance:
      return true

proc followPath*(world: World, slot: int32): bool =
  ## Steers toward the next pulled waypoint. Returns false once finished.
  if world.actors[slot].pathIndex >= int32(world.actors[slot].path.len):
    world.clearPath(slot)
    ctaWalkDestLayer = int(world.actors[slot].home.level)
    world.applyActorBody(slot)
    return false
  let
    step = world.actors[slot].path[world.actors[slot].pathIndex]
    waypoint = step.tile
    dest = planarCenter(waypoint) + step.offset
    radius =
      if step.offset != FixedVec2Zero:
        fixed(1, 1000)
      else:
        PathArrive
  if length(dest - world.actors[slot].body.pos) <= radius or
      world.crowdedOut(slot):
    world.actors[slot].home = waypoint
    inc world.actors[slot].pathIndex
    world.actors[slot].stuckTicks = 0
    return world.followPath(slot)
  let before = world.actors[slot].body.pos
  ctaWalkLayer = int(world.actors[slot].home.level)
  ctaWalkDestLayer = int(waypoint.level)
  steer(
    world.actors[slot].body,
    dest - world.actors[slot].body.pos,
    world.actors[slot].moveSpeed,
    BodyTurnRate,
    ctaTilesWalkable
  )
  world.applyActorBody(slot)
  # A hair's slide along a wall corner is no progress either: two bodies
  # side by side can creep that way forever without ever standing still.
  if length(world.actors[slot].body.pos - before) * 4 <
      world.actors[slot].moveSpeed:
    inc world.actors[slot].stuckTicks
    if world.actors[slot].stuckTicks >= SidestepAfterStuckTicks:
      world.clearPath(slot)
      return false
    if world.actors[slot].stuckTicks mod RepathAfterStuckTicks == 0:
      let
        goal = world.pathGoal(slot)
        offset = world.actors[slot].path[^1].offset
        stuck = world.actors[slot].stuckTicks
      if not world.setPath(slot, goal, offset, recenter = true):
        world.clearPath(slot)
        return false
      world.actors[slot].stuckTicks = stuck
  else:
    world.actors[slot].stuckTicks = 0
  true

proc advancePath*(world: World, slot: int32): bool =
  ## Advances one path tick along the current pulled route.
  world.followPath(slot)

proc stepToward*(world: World, slot: int32, goal: TileRef,
    offset = FixedVec2Zero): bool =
  ## Sets or updates a walk path. Movement happens in `advancePath`.
  if world.actors[slot].path.len == 0 or
      world.actors[slot].pathIndex >= int32(world.actors[slot].path.len) or
      world.pathGoal(slot) != goal or
      world.actors[slot].path[^1].offset != offset:
    if not world.setPath(slot, goal, offset):
      return false
  true

proc wantedTile*(world: World, slot: int32): (bool, TileRef) =
  ## The tile this actor is trying to step into right now, if any.
  let actor = world.actors[slot]
  if actor.moving or actor.busy or not actor.alive:
    return (false, TileRef())
  if actor.pathIndex >= int32(actor.path.len):
    return (false, TileRef())
  actor.home.stepTarget(actor.path[actor.pathIndex].direction)

proc resolveAllySwaps*(world: World) =
  ## Lets two party members walk through each other when each wants the tile
  ## the other is standing on.
  ##
  ## Exclusive occupancy means a head-on pair deadlocks permanently: neither
  ## can move, so neither ever frees the tile the other is waiting for, and
  ## re-pathing returns the same blocked first step forever. A four-hero party
  ## in a corridor hits this constantly. Pairs are resolved in ascending slot
  ## order so the outcome does not depend on iteration accidents, and longer
  ## jams unwind over successive ticks as each pair in the chain swaps.
  for first in 0'i32 ..< PartySize:
    let (firstWants, firstTarget) = world.wantedTile(first)
    if not firstWants:
      continue
    for second in first + 1 ..< PartySize:
      let (secondWants, secondTarget) = world.wantedTile(second)
      if not secondWants:
        continue
      if not (firstTarget == world.actors[second].home):
        continue
      if not (secondTarget == world.actors[first].home):
        continue
      let
        firstHome = world.actors[first].home
        secondHome = world.actors[second].home
      world.claim(secondHome, first)
      world.claim(firstHome, second)
      world.actors[first].home = secondHome
      world.actors[first].next = secondHome
      world.actors[first].facing = facingToward(firstHome, secondHome)
      world.actors[first].phase = 0
      inc world.actors[first].pathIndex
      world.actors[first].stuckTicks = 0
      world.actors[second].home = firstHome
      world.actors[second].next = firstHome
      world.actors[second].facing = facingToward(secondHome, firstHome)
      world.actors[second].phase = 0
      inc world.actors[second].pathIndex
      world.actors[second].stuckTicks = 0
      break

proc adjacent*(a, b: TileRef): bool =
  ## True when two tiles share an edge on the same level.
  if a.level != b.level:
    return false
  let
    dx = abs(int32(a.x) - int32(b.x))
    dz = abs(int32(a.z) - int32(b.z))
  dx + dz == 1

proc inMelee*(a, b: TileRef): bool =
  ## Melee reaches the eight surrounding tiles, so a hero pinned diagonally
  ## in a doorway can still fight. It also reaches the actor's own tile:
  ## bodies are smaller than a tile, so two of them can share one, and a
  ## pair that could not swing there would stand together forever.
  if a.level != b.level:
    return false
  let
    dx = abs(int32(a.x) - int32(b.x))
    dz = abs(int32(a.z) - int32(b.z))
  dx <= 1 and dz <= 1

proc hashWorld*(world: World): uint64 =
  ## Hashes all authoritative world fields, including statistics.
  var hash = HashySeed
  for name, value in fieldPairs(world[]):
    when name != "stats":
      hash.addHashy(value)
  hash.addHashy(world.stats)
  uint64(hash)

## Spawning

proc levelSpecies*(level: int, rng: var Rng): Species =
  ## Chooses a weighted rank from the floor's color-coded family.
  assert level > SurfaceLevel and level < LevelCount
  let
    roll = rng.below(100)
    rank =
      if roll < 40: RuntRank
      elif roll < 70: RaiderRank
      elif roll < 90: CasterRank
      else: ChampionRank
  familySpecies(FloorFamilies[level], rank)

proc packSpecies(level, size: int32, rng: var Rng): seq[Species] =
  ## Rolls each member's rank on its own, then keeps the pack a fighting
  ## unit: one champion at most, and someone up front for its casters to
  ## stand behind.
  let family = FloorFamilies[level]
  var champion = false
  for _ in 0 ..< size:
    var species = levelSpecies(level, rng)
    if species.monsterRank == ChampionRank:
      if champion:
        species = familySpecies(family, RaiderRank)
      champion = true
    result.add species
  for species in result:
    if species.monsterRank != CasterRank:
      return
  result[0] = familySpecies(family, RuntRank)

proc packSizes(count: int32, rng: var Rng): seq[int32] =
  ## Splits a floor's monsters into packs, folding any leftover too small
  ## to be a pack into the last one so nobody waits alone.
  var left = count
  while left > 0:
    var size = min(rng.between(PackMin, PackMax), left)
    if left - size < PackMin:
      size = left
    result.add size
    left -= size

proc freeTileIn(
    game: Game, level: int, room: Room, rng: var Rng
): (bool, TileRef) =
  ## Finds an unclaimed walkable tile inside a room. Occupancy is exclusive,
  ## so a spawn has to check claims, not just terrain.
  for _ in 0 ..< 40:
    let
      x = rng.between(room.x, room.x + room.width - 1)
      z = rng.between(room.z, room.z + room.depth - 1)
      tile = TileRef(level: int8(level), x: uint8(x), z: uint8(z))
    if isWalkable(level, int(x), int(z)) and not game.world.claimed(tile):
      return (true, tile)
  (false, TileRef())

proc monsterActor(species: Species, tile: TileRef): Actor =
  ## A fresh monster of one species, standing guard on a tile.
  # Deeper monsters are tougher, which is what makes the climb back out worse
  # than the way down. Widen to int32 before multiplying champion health.
  let
    toughness = 100'i32 + int32(tile.level) * 10
    hp = int16(
      min(int32(SpeciesHp[species]) * toughness div 100, 30_000))
  Actor(
    kind: MonsterActor,
    class: uint8(species),
    home: tile,
    next: tile,
    baseSpeed: SpeciesSpeeds[species],
    speed: SpeciesSpeeds[species],
    hp: hp,
    maxHp: hp,
    state: GuardingState
  )

proc spawnPack*(
    game: Game, level: int, room: Room, size: int32, rng: var Rng
): int32 =
  ## Stands a pack and its swarm together around one spot in a room,
  ## close enough that the whole pack wakes and fights as one. Returns how
  ## many it placed. The swarm comes last, so a full dungeon drops it first.
  let (found, center) = game.freeTileIn(level, room, rng)
  if not found:
    return 0
  let
    left = max(room.x, int32(center.x) - PackSpreadTiles)
    top = max(room.z, int32(center.z) - PackSpreadTiles)
    huddle = Room(
      x: left,
      z: top,
      width:
        min(room.x + room.width, int32(center.x) + PackSpreadTiles + 1) - left,
      depth:
        min(room.z + room.depth, int32(center.z) + PackSpreadTiles + 1) - top)
  var members = packSpecies(int32(level), size, rng)
  for _ in 0 ..< rng.between(SwarmMin, SwarmMax):
    members.add familySpecies(FloorFamilies[level], SwarmRank)
  for species in members:
    if game.world.actors.len - PartySize >= MaxMonsters:
      break
    var (placed, tile) = game.freeTileIn(level, huddle, rng)
    if not placed:
      (placed, tile) = game.freeTileIn(level, room, rng)
    if not placed:
      continue
    discard game.world.addActor(monsterActor(species, tile))
    inc result

proc populateDungeon*(game: Game) =
  ## Splits each floor's monsters into packs and gives each pack its own
  ## room, wrapping round only when a floor has more packs than rooms.
  var rng = game.world.rng
  for level in 1 ..< LevelCount:
    let rooms = game.dungeon.rooms[level]
    if rooms.len == 0:
      continue
    var order = newSeq[int32](rooms.len)
    for index in 0 ..< rooms.len:
      order[index] = int32(index)
    for index in countdown(rooms.high, 1):
      swap(order[index], order[rng.below(int32(index + 1))])
    for index, size in packSizes(int32(MonstersPerLevel[level]), rng):
      let room = rooms[order[index mod rooms.len]]
      discard game.spawnPack(level, room, size, rng)
  game.world.rng = rng

proc placeHero(game: Game, slot: int32, tile: TileRef) =
  ## Stands the hero of one party slot, whose class is its slot, on a tile.
  let class = HeroClass(slot)
  game.world.actors[slot] = Actor(
    id: 100 + slot,
    kind: HeroActor,
    class: uint8(class),
    home: tile,
    next: tile,
    baseSpeed: ClassSpeeds[class],
    speed: ClassSpeeds[class],
    hp: ClassHp[class],
    maxHp: ClassHp[class],
    mana: ClassMana[class],
    maxMana: ClassMana[class]
  )
  game.world.claim(tile, slot)
  game.world.actors[slot].bindActorBody()

proc spawnParty*(game: Game) =
  ## Puts the four heroes on and around the entrance tile.
  let entrance = game.dungeon.entrance
  game.world.actors.setLen(PartySize)
  var placed = 0
  for radius in 0'i32 .. 6'i32:
    for dz in -radius .. radius:
      for dx in -radius .. radius:
        if placed >= PartySize:
          continue
        if max(abs(dx), abs(dz)) != radius:
          continue
        let tile = TileRef(
          level: entrance.level,
          x: uint8(int32(entrance.x) + dx),
          z: uint8(int32(entrance.z) + dz))
        if not isWalkable(
            int(tile.level), int(tile.x), int(tile.z)) or
            game.world.claimed(tile):
          continue
        game.placeHero(int32(placed), tile)
        inc placed
  doAssert placed == PartySize, "the entrance has no room for the party"
  game.world.nextActorId = int32(100 + PartySize)

proc sampleMetrics*(game: Game, force = false) =
  ## Samples deterministic world counters and independent VM telemetry.
  if game.metrics == nil or game.world.stats == nil:
    return
  for slot, values in game.world.stats.values:
    for kind in MetricKind:
      game.metrics.set(slot, kind, values[kind])
    let hero = game.world.actors[slot]
    game.metrics.set(slot, GoldMetric,
      if hero.alive: hero.carriedValue else: 0)
    game.metrics.set(slot, BankedMetric, game.world.bankedGold[slot])
  game.history.capture(game.metrics, game.world.tick, force)

proc newSetup(
    seed: int32,
    maximumTicks: int32,
    dungeon: Dungeon,
    mapVersion = 1'u16
): Setup =
  ## Describes one run on a generated map, with the party in slot order.
  result = Setup(
    seed: seed,
    mapVersion: mapVersion,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridTiles),
    levels: uint8(LevelCount),
    decisionTicks: uint16(DecisionTicks),
    hashIntervalTicks: uint16(HashIntervalTicks),
    maximumTicks: uint32(maximumTicks)
  )
  for slot in 0 ..< PartySize:
    result.party[slot] = PartyMember(
      id: int32(100 + slot), class: HeroClass(slot))
  result.mapHash = dungeon.hash

proc newGame*(
    seed: int32,
    maximumTicks = DefaultMaximumTicks
): Game =
  ## Generates a dungeon, verifies it can be completed, and fills it.
  result = Game(metrics: newMetrics(PartySize, TickRate))
  result.dungeon = generateMap(seed)
  result.dungeon.verifyDungeon()
  doAssert result.dungeon.descentPath(),
    "generated a dungeon the party cannot finish"
  result.world = newWorld(newSetup(seed, maximumTicks, result.dungeon))
  result.spawnParty()
  result.populateDungeon()
  result.world.rebuildVision()

  result.sampleMetrics(true)

proc newArenaGame*(
    seed: int32,
    maximumTicks: int32,
    heroes: openArray[HeroClass],
    monsters: openArray[Species]
): Game =
  ## Builds the debug arena fight: the heroes in a column near the east wall
  ## and up to ArenaMonsterLimit monsters in staggered columns from the west
  ## wall. Each hero
  ## keeps its own party slot and bot; the slots of absent classes stay
  ## empty.
  result = Game(metrics: newMetrics(PartySize, TickRate))
  result.dungeon = generateArena(seed)
  result.world = newWorld(
    newSetup(seed, maximumTicks, result.dungeon, ArenaMapVersion))
  result.world.actors.setLen(PartySize)
  for slot in 0 ..< PartySize:
    result.world.actors[slot] = Actor()
  let room = result.dungeon.rooms[ArenaLevel][0]
  var spot = result.dungeon.entrance
  for index, class in heroes:
    spot.z = uint8(int(result.dungeon.entrance.z) - heroes.len + 1 + 2 * index)
    result.placeHero(int32(class.ord), spot)
  result.world.nextActorId = int32(100 + PartySize)
  doAssert monsters.len <= ArenaMonsterLimit
  for index, species in monsters:
    let column = int32(index) div ArenaRanks
    spot.x = uint8(room.x + 1 + column)
    spot.z = uint8(
      room.z + 1 + 2 * (int32(index) mod ArenaRanks) + column mod 2)
    discard result.world.addActor(monsterActor(species, spot))
  result.world.rebuildVision()

  result.sampleMetrics(true)

## Queries

proc monstersOn*(game: Game, level: int): int32 =
  for actor in game.world.actors:
    if actor.kind == MonsterActor and actor.alive and
        int(actor.home.level) == level:
      inc result

proc partyLevel*(game: Game): int32 =
  ## The level most of the living party is standing on, which is what
  ## "the party has cleared this floor" means.
  var counts: array[LevelCount, int32]
  for slot in 0 ..< PartySize:
    if game.world.actors[slot].alive:
      inc counts[int(game.world.actors[slot].home.level)]
  var best = 0'i32
  for level in 0 ..< LevelCount:
    if counts[level] > counts[best]:
      best = int32(level)
  best

proc viewLevel*(
    game: Game,
    selected: array[PartySize, bool]
): int32 =
  ## The uppermost floor a selected living hero stands on. The cutaway
  ## draws that floor and everything under it, so a hero who has started
  ## the climb is not hidden by party members still below.
  result = int32(LevelCount)
  for slot in 0 ..< min(PartySize, game.world.actors.len):
    if not selected[slot]:
      continue
    let actor = game.world.actors[slot]
    if actor.alive and int32(actor.home.level) < result:
      result = int32(actor.home.level)
  if result < int32(LevelCount):
    return
  for slot in 0 ..< min(PartySize, game.world.actors.len):
    let actor = game.world.actors[slot]
    if actor.alive and int32(actor.home.level) < result:
      result = int32(actor.home.level)
  if result >= int32(LevelCount):
    result = 0

proc nearestEnemy*(game: Game, slot: int32, reach: int32): int32 =
  ## Nearest living opponent on the same level within reach, or -1.
  result = -1
  let
    actor = game.world.actors[slot]
    wantMonster = actor.kind == HeroActor
  var bestDistance = reach + 1
  for other in 0 ..< game.world.actors.len:
    let target = game.world.actors[other]
    if not target.alive or target.cloaked:
      continue
    if (target.kind == MonsterActor) != wantMonster:
      continue
    if not game.world.actorCanSee(slot, int32(other)):
      continue
    let distance = tileDistance(actor.home, target.home)
    if distance < 0 or distance > reach:
      continue
    if distance < bestDistance:
      bestDistance = distance
      result = int32(other)

proc partyAnchor*(game: Game): int32 =
  ## The living hero the rest of the party orients on: the fighter while he
  ## stands, otherwise whoever is left, lowest slot first so the choice never
  ## depends on iteration order.
  for slot in 0 ..< PartySize:
    if game.world.actors[slot].alive:
      return int32(slot)
  -1

proc nearestMonsterHome*(game: Game, slot: int32): TileRef =
  ## Closest living monster on this hero's floor, even through fog of war.
  ## A hero already walking to one turns to another only when it is nearer
  ## by route as well: the way to a monster can first lead away from it and
  ## toward another, and straight distance alone would turn the hero around
  ## at every step between the two.
  let actor = game.world.actors[slot]
  result = actor.home
  var
    bestDistance = int32(GridTiles * 2)
    headed = actor.home
    walkingToOne = false
  for other in 0 ..< game.world.actors.len:
    let target = game.world.actors[other]
    if not target.alive or target.kind != MonsterActor:
      continue
    if target.home.level != actor.home.level:
      continue
    if game.world.headingFor(slot, target.home):
      headed = target.home
      walkingToOne = true
    let distance = tileDistance(actor.home, target.home)
    if distance >= 0 and distance < bestDistance:
      bestDistance = distance
      result = target.home
  if walkingToOne and result != headed and
      game.world.routeTiles(slot, headed) <=
        game.world.routeTiles(slot, result):
    result = headed

proc nearestLoot*(game: Game, slot: int32): int32 =
  ## Index of the closest unclaimed treasure on this hero's level, or -1.
  ## Treasure the hero is already walking to still counts out of sight: a
  ## corner can hide it from the next tile on the way, and dropping it there
  ## sends the hero back to where it shows again, forever.
  result = -1
  let actor = game.world.actors[slot]
  var bestDistance = 30'i32
  for index, item in game.world.items:
    if item.carrier != 0:
      continue
    if item.tile.level != actor.home.level:
      continue
    if not game.world.visible(slot, item.tile) and
        not game.world.headingFor(slot, item.tile):
      continue
    if item.kind.lootUsesSlot and actor.freeInventorySlot() < 0:
      continue
    let distance = tileDistance(actor.home, item.tile)
    if distance >= 0 and distance < bestDistance:
      bestDistance = distance
      result = int32(index)

## Combat

proc pathAhead(world: World, slot: int32, ticks: int32): FixedVec2 =
  ## Where an actor's body will be `ticks` from now if it keeps walking its
  ## path at its present speed, or where it stands if it is not walking.
  let actor = world.actors[slot]
  result = actor.body.pos
  if not actor.moving or actor.busy or actor.staggered or actor.rooted:
    return
  var
    left = actor.moveSpeed * ticks
    index = actor.pathIndex
  while index < int32(actor.path.len) and left > 0.0'fx:
    let
      step = actor.path[index]
      dest = planarCenter(step.tile) + step.offset
      span = length(dest - result)
    if span > left:
      return result + (dest - result) * (left / span)
    result = dest
    left -= span
    inc index

proc packAim(game: Game, slot, targetSlot: int32, ticks: int32): TileRef =
  ## The tile in the middle of the target's pack, every foe the caster can
  ## see within `PackTiles` of the target, as it will stand `ticks` from
  ## now. The target's own tile when that one is not floor.
  let
    actor = game.world.actors[slot]
    target = game.world.actors[targetSlot]
  var
    sum = fixedVec2()
    count = 0'i32
  for other in 0 ..< game.world.actors.len:
    let foe = game.world.actors[other]
    if not foe.alive or foe.kind == actor.kind or
        foe.home.level != target.home.level or
        tileDistance(foe.home, target.home) > PackTiles or
        not game.world.actorCanSee(slot, int32(other)):
      continue
    sum += game.world.pathAhead(int32(other), ticks)
    inc count
  if count == 0:
    return target.home
  let (x, z) = cell(sum / count)
  if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
    return target.home
  result = TileRef(level: target.home.level, x: uint8(x), z: uint8(z))
  if not result.walkable:
    result = target.home

proc aimAt(game: Game, slot, targetSlot: int32): TileRef =
  ## Where an ability winding up at a target is aimed this tick: the
  ## target's tile, or for one that leads a pack, the middle of its pack
  ## as it will stand once the effect has landed and taken hold.
  let
    actor = game.world.actors[slot]
    spec = Abilities[actor.action]
  if not spec.leadsPack:
    return game.world.actors[targetSlot].home
  game.packAim(slot, targetSlot,
    int32(spec.impactTicks - actor.actionTicks + VineLeadTicks))

proc beginAbility(game: Game, slot: int32, ability: Ability, target: int32) =
  ## Starts an ability's wind-up and pins its aim to where the target
  ## stands now, which is where an area ability will land.
  if game.world.actors[slot].busy:
    return
  if game.world.actors[slot].cooldowns[int(ability)] > 0:
    return
  game.world.actors[slot].action = ability
  game.world.actors[slot].actionTicks = 0
  game.world.actors[slot].target = target
  game.world.actors[slot].aim = game.world.actors[slot].home
  let targetSlot = game.world.actorSlot(target)
  if targetSlot >= 0 and targetSlot != slot:
    game.world.actors[slot].aim = game.aimAt(slot, targetSlot)

proc pickUp(game: Game, slot, itemIndex: int32) =
  ## Takes an item off the floor on the spot, so from this tick on no one
  ## else can reach for it: treasure goes into the hero's purse and off the
  ## map, gear into the bag. Picking then cools down, so a hero takes one
  ## item at a time.
  let
    actor = game.world.actors[slot]
    item = game.world.items[itemIndex]
  if actor.cooldowns[int(ChainAxe)] > 0 or item.carrier != 0:
    return
  if not item.kind.lootUsesSlot:
    actor.carriedValue += item.value
    game.world.deleteItem(itemIndex)
  else:
    let bag = actor.freeInventorySlot()
    if bag < 0:
      return
    actor.carriedValue += item.value
    game.world.items[itemIndex].value = 0
    game.world.items[itemIndex].carrier = actor.id
    actor.inventory[bag] = item.id
    actor.carriedWeight += item.weight
    actor.refreshSpeed()
  inc game.world.collected
  actor.cooldowns[int(ChainAxe)] = Abilities[ChainAxe].cooldownTicks

proc chooseAttack(game: Game, slot, targetSlot: int32): Ability =
  ## Picks a hero's attack on a target: the best ready one that already
  ## reaches it, otherwise the longest-reaching one the hero can pay for,
  ## which it then closes to, or waits on while it cools down.
  let
    actor = game.world.actors[slot]
    distance = tileDistance(actor.home, game.world.actors[targetSlot].home)
    attacks = ClassAttacks[actor.heroClass]
  result = attacks[^1]
  for ability in attacks:
    let spec = Abilities[ability]
    if actor.mana < spec.manaCost:
      continue
    if actor.cooldowns[int(ability)] == 0 and
        distance <= int32(spec.rangeTiles):
      return ability
    if spec.rangeTiles > Abilities[result].rangeTiles:
      result = ability

proc attackWith(game: Game, slot, targetSlot: int32, ability: Ability): bool =
  ## Closes to the attack's range, holds there while it cools down, and
  ## starts it, paying its mana, once it is ready. Returns false only when
  ## the hero has no way to step closer.
  let
    actor = game.world.actors[slot]
    target = game.world.actors[targetSlot]
    spec = Abilities[ability]
  if tileDistance(actor.home, target.home) > int32(spec.rangeTiles):
    return game.world.stepToward(slot, target.home)
  game.world.clearPath(slot)
  game.world.faceActor(slot, targetSlot)
  if actor.cooldowns[int(ability)] == 0:
    game.world.actors[slot].mana -= spec.manaCost
    game.beginAbility(slot, ability, target.id)
  true

proc readySkill(game: Game, slot, targetSlot: int32): Ability =
  ## The first of the hero's skills that is ready and reaches a target the
  ## hero can see, or `NoAbility`.
  let actor = game.world.actors[slot]
  if not game.world.actorCanSee(slot, targetSlot):
    return NoAbility
  let distance =
    tileDistance(actor.home, game.world.actors[targetSlot].home)
  for ability in ClassSkills[actor.heroClass]:
    let spec = Abilities[ability]
    if actor.cooldowns[int(ability)] == 0 and
        actor.mana >= spec.manaCost and
        distance <= int32(spec.rangeTiles):
      return ability
  NoAbility

proc backAway(
    game: Game,
    slot: int32,
    threats: seq[TileRef],
    reach, steps: int32
): bool

proc slipAway(game: Game, slot: int32): bool =
  ## Walks a cloaked hero clear of the monsters closer than SlipTiles.
  ## Returns false when none are, or no tile round it is safer.
  let actor = game.world.actors[slot]
  var threats: seq[TileRef]
  for other in PartySize ..< game.world.actors.len:
    let
      monster = game.world.actors[other]
      distance = tileDistance(actor.home, monster.home)
    if monster.alive and distance >= 0 and distance < SlipTiles:
      threats.add monster.home
  threats.len > 0 and game.backAway(slot, threats, SlipTiles, SlipSteps)

proc crowdAt(game: Game, slot: int32, tile: TileRef): int32 =
  ## How many foes a hero can see stand within `CrowdTiles` of a tile.
  for other in PartySize ..< game.world.actors.len:
    let
      foe = game.world.actors[other]
      distance = tileDistance(tile, foe.home)
    if foe.alive and distance >= 0 and distance <= CrowdTiles and
        game.world.actorCanSee(slot, int32(other)):
      inc result

proc onHeels(game: Game, slot: int32): int32 =
  ## How many foes a hero can see that can come at it: free ones within
  ## `ChaseTiles`, and rooted ones only at its elbow.
  let actor = game.world.actors[slot]
  for other in PartySize ..< game.world.actors.len:
    let
      foe = game.world.actors[other]
      distance = tileDistance(actor.home, foe.home)
      reach = if foe.rooted: 1'i32 else: ChaseTiles
    if foe.alive and distance >= 0 and distance <= reach and
        game.world.actorCanSee(slot, int32(other)):
      inc result

proc roominess(tile: TileRef): int32 =
  ## How many of the eight tiles round a tile are floor: three in a corner,
  ## five against a wall, eight out in the open.
  for dz in -1'i32 .. 1:
    for dx in -1'i32 .. 1:
      let
        x = int32(tile.x) + dx
        z = int32(tile.z) + dz
      if (dx != 0 or dz != 0) and x >= 0 and z >= 0 and x < GridTiles and
          z < GridTiles and
          TileRef(level: tile.level, x: uint8(x), z: uint8(z)).walkable:
        inc result

proc kite(game: Game, slot: int32, anchor: TileRef, leash: int32): bool =
  ## Walks a kiting hero to the tile within `KiteSteps` that leaves it
  ## safest: farthest from the nearest foe first, then from the rest of
  ## them, each counted up to `KiteReach`, or for a rooted foe that cannot
  ## follow, only until it is out of arm's reach. Open floor round a tile
  ## counts too, so it never runs itself into a corner. It stays within
  ## `leash` of `anchor` unless `leash` is negative. Returns false when no
  ## foe is near, when nowhere there is better, or when `HemmedFoes` stand
  ## at its elbow: backing into a wall of bodies would only stop it
  ## swinging.
  let actor = game.world.actors[slot]
  var
    threats: seq[TileRef]
    held: seq[bool]
  for other in PartySize ..< game.world.actors.len:
    let
      foe = game.world.actors[other]
      distance = tileDistance(actor.home, foe.home)
    if foe.alive and distance >= 0 and distance < KiteReach + KiteSteps:
      threats.add foe.home
      held.add foe.rooted
  if threats.len == 0:
    return false
  proc room(tile: TileRef, index: int): int32 =
    ## How safe a tile is from one foe, up to `KiteReach`.
    let distance = tileDistance(tile, threats[index])
    if held[index] and distance >= 2: KiteReach
    else: min(distance, KiteReach)
  proc nearest(tile: TileRef): int32 =
    result = KiteReach
    for index in 0 ..< threats.len:
      result = min(result, room(tile, index))
  proc score(tile: TileRef): int32 =
    result = 4 * nearest(tile) + 2 * roominess(tile)
    for index in 0 ..< threats.len:
      result += room(tile, index)
  var elbow = 0'i32
  for threat in threats:
    if tileDistance(actor.home, threat) <= 1:
      inc elbow
  if elbow >= HemmedFoes:
    return false
  proc usable(tile: TileRef): bool =
    tile.walkable and tile.level == actor.home.level and
      (not game.world.claimed(tile) or
        game.world.claimant(tile) == slot) and
      game.world.visible(slot, tile) and
      (leash < 0 or tileDistance(tile, anchor) <= leash)
  var
    best = actor.home
    bestScore = score(actor.home)
    bestStep = 0'i32
  for dz in -KiteSteps .. KiteSteps:
    for dx in -KiteSteps .. KiteSteps:
      let
        x = int32(actor.home.x) + dx
        z = int32(actor.home.z) + dz
      if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
        continue
      let tile = TileRef(level: actor.home.level, x: uint8(x), z: uint8(z))
      if tile == actor.home or not usable(tile):
        continue
      let
        tileScore = score(tile)
        step = max(abs(dx), abs(dz))
      if tileScore > bestScore or
          (tileScore == bestScore and best != actor.home and
            step < bestStep):
        best = tile
        bestScore = tileScore
        bestStep = step
  if best == actor.home:
    return false
  # Already making for somewhere nearly as good, it keeps going there.
  let goal = game.world.pathGoal(slot)
  if actor.moving and goal != actor.home and usable(goal) and
      tileDistance(goal, actor.home) <= KiteSteps + 1 and
      score(goal) + KiteSettle >= bestScore:
    return true
  game.world.stepToward(slot, best)

proc vinesToBurn(game: Game, slot: int32, held: var int32): int32 =
  ## The patch of a hero's own vines its Sun Orb is saved for, and in
  ## `held` how many foes it holds: the one holding the most, within the
  ## orb's reach and still holding when it comes down. -1 when the orb is
  ## not ready or the hero has no vines holding anything.
  let
    actor = game.world.actors[slot]
    spec = Abilities[SunOrb]
  result = -1
  held = 0
  if SunOrb notin ClassSkills[actor.heroClass] or
      actor.cooldowns[int(SunOrb)] > 0 or actor.mana < spec.manaCost:
    return
  for index, patch in game.world.vines:
    let distance = tileDistance(actor.home, patch.center)
    if patch.side != actor.kind or distance < 0 or
        distance > int32(spec.rangeTiles) or
        not patch.holding(game.world.tick + int32(spec.impactTicks)) or
        not game.world.visible(slot, patch.center):
      continue
    var inside = 0'i32
    for victim in game.world.actors:
      if victim.alive and victim.kind != patch.side and
          game.world.inArea(Abilities[Entangle], patch.center, patch.center,
            victim):
        inc inside
    if inside > held:
      held = inside
      result = int32(index)

proc fight(game: Game, slot, targetSlot: int32): bool =
  ## A hero's next move against a target. With its own vines holding foes
  ## and its Sun Orb ready, it saves the orb for them: it gets clear of
  ## whatever is on its heels, staying in the orb's reach of the vines, and
  ## throws it into them once clear with a crowd held, or before they let
  ## go. Otherwise: a skill the moment one is ready; under a cloak, getting
  ## clear; for a hero that kites, keeping away from what is on its heels
  ## and out of a crowd; and otherwise its plain attack.
  let orb = Abilities[SunOrb]
  var held = 0'i32
  let vines = game.vinesToBurn(slot, held)
  if vines >= 0:
    let
      middle = game.world.vines[vines].center
      lastChance = not game.world.vines[vines].holding(
        game.world.tick + int32(orb.impactTicks) + RepositionTicks)
      chased = game.onHeels(slot) > 0
    if not lastChance and (chased or held < BurnVinesHeld) and
        game.kite(slot, middle, int32(orb.rangeTiles)):
      return true
    if lastChance or held >= BurnVinesHeld:
      # The orb lands in the middle of the vines, whatever the hero is
      # after, so the fire runs through everything they hold.
      game.world.clearPath(slot)
      game.world.faceTile(slot, middle)
      game.world.actors[slot].mana -= orb.manaCost
      game.beginAbility(slot, SunOrb, game.world.actors[slot].id)
      game.world.actors[slot].aim = middle
      return true
  var ability = game.readySkill(slot, targetSlot)
  if ability == SunOrb and vines >= 0:
    ability = NoAbility
  if ability != NoAbility:
    let
      actor = game.world.actors[slot]
      spec = Abilities[ability]
    game.world.clearPath(slot)
    game.world.faceActor(slot, targetSlot)
    game.world.actors[slot].mana -= spec.manaCost
    game.beginAbility(slot, ability,
      if (spec.damage > 0 or spec.radiusTiles > 0) and not spec.onSelf:
        game.world.actors[targetSlot].id
      else:
        actor.id)
    return true
  if game.world.actors[slot].cloaked and game.slipAway(slot):
    return true
  let
    actor = game.world.actors[slot]
    limit = ClassCrowdLimit[actor.heroClass]
    attack = game.chooseAttack(slot, targetSlot)
  if limit > 0:
    # With too many on its heels it gets clear while it has room to, and
    # it never walks in among a crowd to swing at one of them: it holds,
    # and lets them come or waits on its skills.
    if game.onHeels(slot) >= limit and game.kite(slot, actor.home, -1):
      return true
    if tileDistance(actor.home, game.world.actors[targetSlot].home) >
        int32(Abilities[attack].rangeTiles) and
        game.crowdAt(slot, game.world.actors[targetSlot].home) >= limit:
      game.world.clearPath(slot)
      game.world.faceActor(slot, targetSlot)
      return true
  game.attackWith(slot, targetSlot, attack)

proc extraLootKind(level: int, species: Species, rng: var Rng): LootKind =
  ## Picks one extra drop. Deeper floors and champions roll richer treasure.
  if rng.chance(45):
    if level >= 5 or
      (species.monsterRank == ChampionRank and rng.chance(35)):
        return Crown
    if level >= 4 or species.monsterRank == ChampionRank:
      if rng.chance(55):
        return Idol
      return Chalice
    if level >= 3:
      if rng.chance(50):
        return Chalice
      return Gemstone
    if level >= 2 and rng.chance(35):
      return Chalice
    return Gemstone
  UsableLoot[rng.below(int32(UsableLoot.len))]

proc dropLoot(game: Game, slot: int32) =
  ## A dead monster always leaves gold, and often a second floor drop. The
  ## swarm carries nothing, so the party does not stop to sweep up after it.
  if game.world.actors[slot].species.monsterRank == SwarmRank:
    return
  var rng = game.world.rng
  let
    actor = game.world.actors[slot]
    level = int(actor.home.level)
    gold = LootValues[GoldPile] + int32(level) * 8
  discard game.spawnLoot(GoldPile, actor.home, gold)
  var itemChance = 22 + level * 8
  if actor.species.monsterRank == ChampionRank:
    itemChance += 25
  if rng.chance(int32(min(itemChance, 75))):
    discard game.spawnLoot(
      extraLootKind(level, actor.species, rng),
      actor.home
    )
  game.world.rng = rng

proc killActor(game: Game, slot: int32) =
  let actor = game.world.actors[slot]
  if actor.kind == MonsterActor:
    game.dropLoot(slot)
    inc game.world.killed
    game.world.removeActor(slot)
  else:
    # A fallen hero drops gold and gear so the rest of the party can
    # still take it. Their tile frees up; the body is not simulated.
    if actor.carriedValue > 0:
      discard game.spawnLoot(GoldPile, actor.home, actor.carriedValue)
    for index in 0 ..< InventorySlots:
      let itemId = actor.inventory[index]
      if itemId == 0:
        continue
      let itemIndex = game.world.itemIndex(itemId)
      if itemIndex >= 0:
        game.world.items[itemIndex].carrier = 0
        game.world.items[itemIndex].tile = actor.home
    game.log.add "a hero has fallen on level " & $int(actor.home.level)
    game.world.removeActor(slot)

proc strike(game: Game, slot, targetSlot: int32, ability: Ability)
proc burnVines(game: Game, slot: int32)

proc guard(actor: Actor, ticks, percent: int16) =
  ## Lets only `percent` of every blow through for a while.
  actor.guardTicks = ticks
  actor.guardPercent = percent

proc applyAbility(game: Game, slot: int32) =
  ## Lands an ability's effect on its last release tick, never on an
  ## animation frame: the client warps its clip to match, not the other way
  ## round.
  let
    actor = game.world.actors[slot]
    ability = actor.action
    spec = Abilities[ability]
  if ability == HealingPotion:
    game.world.stats.add(int(slot), HealingMetric,
      min(80, int(actor.maxHp - actor.hp)))
    game.world.actors[slot].hp = min(
      actor.hp + 80,
      actor.maxHp
    )
    return
  if ability == ManaCrystal:
    game.world.actors[slot].mana = min(
      actor.mana + 50,
      actor.maxMana
    )
    return
  if ability == BattleHorn:
    for other in 0 ..< PartySize:
      if game.world.actors[other].alive and
          game.world.actors[other].home.level == actor.home.level:
        game.world.actors[other].guard(48, GuardPercent)
    return
  if ability == WingedBoot:
    game.world.actors[slot].hasteTicks = 72
    game.world.actors[slot].refreshSpeed()
    return
  if ability == ShadowCloak:
    game.world.actors[slot].cloakTicks = CloakTicks
    return
  if ability in {LionGuard, InfernoAegis, IceWall, ThornRing}:
    game.world.actors[slot].guard(64, GuardPercent)
    return
  if ability == Heat:
    game.world.actors[slot].heatTicks = HeatTicks
    return
  if ability == Taunt:
    game.world.actors[slot].guard(TauntTicks, TauntGuardPercent)
  if ability == NatureTalisman:
    game.world.stats.add(int(slot), HealingMetric,
      min(40, int(actor.maxHp - actor.hp)))
    game.world.actors[slot].hp = min(actor.hp + 40, actor.maxHp)
    game.world.actors[slot].mana = min(actor.mana + 30, actor.maxMana)
    return
  if ability == Entangle:
    game.world.vines.add VinePatch(side: actor.kind, center: actor.aim,
      sprouted: game.world.tick)
    return

  if spec.radiusTiles > 0:
    # An area lands where the target stood as the wind-up began, on every
    # foe still inside it, so stepping out of the marked ring dodges it.
    for other in 0 ..< game.world.actors.len:
      let victim = game.world.actors[other]
      if not victim.alive or victim.kind == actor.kind:
        continue
      if not game.world.inArea(spec, actor.home, actor.aim, victim):
        continue
      if ability == Taunt:
        victim.tauntTicks = TauntTicks
        victim.tauntedBy = actor.id
      else:
        game.strike(slot, int32(other), ability)
    if ability == SunOrb:
      game.burnVines(slot)
    return

  let targetSlot = game.world.actorSlot(actor.target)
  if targetSlot < 0 or not game.world.actors[targetSlot].alive:
    return
  # A blow already on its way at someone who has since cloaked goes wide.
  if game.world.actors[targetSlot].cloaked and
      game.world.actors[targetSlot].kind != actor.kind:
    return
  if not game.world.actorCanSee(slot, targetSlot):
    return
  if tileDistance(actor.home, game.world.actors[targetSlot].home) >
      int32(spec.rangeTiles):
    return
  game.strike(slot, targetSlot, ability)

proc strike(game: Game, slot, targetSlot: int32, ability: Ability) =
  ## Rolls one ability's damage or healing onto one actor.
  let
    actor = game.world.actors[slot]
    spec = Abilities[ability]
  var rng = game.world.rng
  var damage = int32(spec.damage) + rng.below(int32(spec.spread) + 1)
  if actor.kind == MonsterActor:
    damage = damage * SpeciesDamage[actor.species] div 100
  elif damage > 0:
    damage = damage * ClassDamage[actor.heroClass] div 100
  if game.world.actors[targetSlot].guardTicks > 0:
    damage = damage * game.world.actors[targetSlot].guardPercent div 100
  game.world.rng = rng

  if damage < 0:
    if actor.kind == HeroActor and
      game.world.actors[targetSlot].kind == HeroActor:
        game.world.stats.add(int(slot), HealingMetric,
          min(-damage, int32(game.world.actors[targetSlot].maxHp -
            game.world.actors[targetSlot].hp)))
    # Healing is negative damage, so one path covers both and the cleric
    # needs no special case beyond choosing an ally to aim at.
    game.world.actors[targetSlot].hp = min(
      game.world.actors[targetSlot].hp + int16(-damage),
      game.world.actors[targetSlot].maxHp)
    return

  if actor.kind == HeroActor and
    game.world.actors[targetSlot].kind == MonsterActor:
      game.world.stats.add(int(slot), DamageMetric,
        min(max(damage, 1), int32(game.world.actors[targetSlot].hp)))
      if max(damage, 1) >= game.world.actors[targetSlot].hp:
        game.world.stats.add(int(slot), KillsMetric)
  game.world.actors[targetSlot].hp -= int16(max(damage, 1))
  game.world.actors[targetSlot].sinceHitTicks = 0
  game.world.actors[targetSlot].staggerTicks = max(
    game.world.actors[targetSlot].staggerTicks, spec.staggerTicks)
  if spec.slowTicks > 0:
    game.world.actors[targetSlot].slowTicks = max(
      game.world.actors[targetSlot].slowTicks, spec.slowTicks)
    game.world.actors[targetSlot].refreshSpeed()
  if game.world.actors[targetSlot].hp <= 0:
    game.killActor(targetSlot)

proc radiateHeat(game: Game, slot: int32) =
  ## Burns every foe round a hero under Heat, one small hit each period.
  ## The aura goes where the hero goes.
  let actor = game.world.actors[slot]
  if actor.heatTicks == 0 or actor.heatTicks mod HeatPeriodTicks != 0:
    return
  for other in 0 ..< game.world.actors.len:
    let victim = game.world.actors[other]
    if not victim.alive or victim.kind == actor.kind:
      continue
    if game.world.inArea(Abilities[Heat], actor.home, actor.home, victim):
      game.strike(slot, int32(other), Heat)

proc inVines*(world: World, patch: VinePatch, victim: Actor): bool =
  ## Whether an actor stands in a patch of vines, judged by its tile the
  ## way Entangle's own disc is.
  world.inArea(Abilities[Entangle], patch.center, patch.center, victim)

proc orbLandsIn*(patch: VinePatch, aim: TileRef): bool =
  ## The landing point must be inside the patch, on the same floor.
  ## Merely touching its edge with the orb's area does not ignite it.
  if aim.level != patch.center.level:
    return false
  let
    dx = int32(aim.x) - int32(patch.center.x)
    dz = int32(aim.z) - int32(patch.center.z)
    diameter = 2 * int32(Abilities[Entangle].radiusTiles) + 1
  4 * (dx * dx + dz * dz) <= diameter * diameter

proc burnVines(game: Game, slot: int32) =
  ## Sets alight every live patch a Sun Orb lands inside. The
  ## fire runs through the whole patch and lets go of whatever it held,
  ## and every foe standing in it takes the orb's blow a second time.
  let actor = game.world.actors[slot]
  for index in 0 ..< game.world.vines.len:
    let patch = game.world.vines[index]
    if not patch.holding(game.world.tick) or
        not patch.orbLandsIn(actor.aim):
      continue
    game.world.vines[index].burned = game.world.tick
    game.world.vines[index].burnedFrom = actor.aim
    for other in 0 ..< game.world.actors.len:
      let victim = game.world.actors[other]
      if victim.alive and victim.kind != patch.side and
          game.world.inVines(patch, victim):
        game.strike(slot, int32(other), SunOrb)

proc tendVines(game: Game) =
  ## Clears away vines that have withered or burned, then tightens the
  ## rest round whoever stands in them: every tick inside slows a body
  ## further until, `VineRootTicks` in, it is rooted. Stepping out, or the
  ## vines letting go, frees it at once.
  let tick = game.world.tick
  var kept = 0
  for index in 0 ..< game.world.vines.len:
    if not game.world.vines[index].gone(tick):
      game.world.vines[kept] = game.world.vines[index]
      inc kept
  game.world.vines.setLen(kept)
  for slot in 0 ..< game.world.actors.len:
    let actor = game.world.actors[slot]
    if not actor.alive:
      continue
    var held = false
    for patch in game.world.vines:
      if patch.holding(tick) and actor.kind != patch.side and
          game.world.inVines(patch, actor):
        held = true
        break
    let before = actor.entangledTicks
    actor.entangledTicks =
      if held: min(before + 1, VineRootTicks)
      else: 0
    if actor.entangledTicks != before:
      actor.refreshSpeed()

proc trackTarget(game: Game, slot: int32) =
  ## Keeps a winding-up actor turned to what it is about to hit: the spot
  ## an area lands on, or the actor a single blow or spell is aimed at.
  let actor = game.world.actors[slot]
  if actor.target == actor.id:
    return
  let
    spec = Abilities[actor.action]
    targetSlot = game.world.actorSlot(actor.target)
    found = targetSlot >= 0 and game.world.actors[targetSlot].alive and
      game.world.actors[targetSlot].home.level == actor.home.level
  if spec.tracksTarget and found:
    game.world.actors[slot].aim = game.aimAt(slot, targetSlot)
  if spec.radiusTiles > 0:
    if game.world.actors[slot].aim != actor.home:
      game.world.faceTile(slot, game.world.actors[slot].aim)
    return
  if found:
    game.world.faceActor(slot, targetSlot)

proc advanceAction(game: Game, slot: int32) =
  ## Steps an ability through anticipation, release and recovery. The
  ## effect lands on the last release tick and only then; until recovery
  ## ends the actor stays committed, neither deciding nor moving.
  if game.world.actors[slot].action == NoAbility:
    return
  let spec = Abilities[game.world.actors[slot].action]
  inc game.world.actors[slot].actionTicks
  let ticks = game.world.actors[slot].actionTicks
  if ticks <= spec.anticipationTicks:
    game.trackTarget(slot)
  if ticks == spec.impactTicks:
    game.applyAbility(slot)
  if ticks >= spec.totalTicks:
    game.world.actors[slot].cooldowns[int(game.world.actors[slot].action)] =
      spec.cooldownTicks
    game.world.actors[slot].action = NoAbility
    game.world.actors[slot].actionTicks = 0


## Hero behaviour

proc rampTileFor(game: Game, level: int, descending: bool): TileRef =
  ## Where to walk to leave this level. Deliberately a landing on the *far*
  ## side of the ramp: aiming at the near landing parks the party on the top
  ## step forever, because arriving there satisfies the goal without ever
  ## crossing. Pathing spans layers by itself, so the far landing is enough.
  for ramp in game.dungeon.ramps:
    if descending and int(ramp.upper) == level:
      return TileRef(
        level: int8(ramp.lower),
        x: uint8(ramp.bottomX),
        z: uint8(ramp.bottomZ))
    if not descending and int(ramp.lower) == level:
      return TileRef(
        level: int8(ramp.upper), x: uint8(ramp.topX), z: uint8(ramp.topZ))
  TileRef(level: int8(level), x: 0, z: 0)

proc decideHero(game: Game, slot: int32) =
  ## One hero's whole mind, in priority order. This is the proc the scripting
  ## VM will eventually replace; nothing below it knows the difference.
  let actor = game.world.actors[slot]
  if actor.busy:
    return
  let level = int(actor.home.level)

  # The cleric patches the party up before doing anything else. Without this
  # the run is pure attrition and the party dies on the second floor with no
  # way to recover between fights.
  if actor.heroClass == ClericClass and
      actor.cooldowns[int(Bloom)] == 0 and
      actor.mana >= Abilities[Bloom].manaCost:
    var
      worst = -1'i32
      worstFraction = 70'i32
    for other in 0 ..< PartySize:
      let mate = game.world.actors[other]
      if not mate.alive or mate.home.level != actor.home.level:
        continue
      if tileDistance(actor.home, mate.home) >
          int32(Abilities[Bloom].rangeTiles):
        continue
      let fraction = int32(mate.hp) * 100 div int32(mate.maxHp)
      if fraction < worstFraction:
        worstFraction = fraction
        worst = int32(other)
    if worst >= 0:
      game.world.actors[slot].mana -= Abilities[Bloom].manaCost
      game.beginAbility(slot, Bloom, game.world.actors[worst].id)
      return

  # Fight whatever is in reach, and if the floor still holds monsters that
  # are further off, go and find them. Without the second half the party
  # arrives at the stairs, sees nothing within aggro range, and stands there
  # forever while the level it is supposed to clear waits across the map.
  #
  # Distant targets are chosen relative to the party's anchor rather than to
  # each hero, so the four of them converge on the same monster instead of
  # fanning out across the floor and being killed one at a time.
  var enemy = game.nearestEnemy(slot, HeroAggroTiles)
  if enemy < 0 and game.world.phase == DescendingPhase:
    let anchor = game.partyAnchor()
    enemy =
      if anchor >= 0: game.nearestEnemy(anchor, int32(GridTiles * 2))
      else: game.nearestEnemy(slot, int32(GridTiles * 2))
  # On the way out the party fights only what stands in its way. Hunting
  # across the floor while the dungeon refills behind them is how a run turns
  # into a treadmill they can never step off.
  if enemy >= 0:
    discard game.fight(slot, enemy)
    return

  # Nothing hostile nearby: pick up anything lying around, one item at a
  # time, waiting where it stands while picking cools down.
  let lootIndex = game.nearestLoot(slot)
  if lootIndex >= 0:
    let item = game.world.items[lootIndex]
    if tileDistance(actor.home, item.tile) <= LootPickupRange:
      game.world.clearPath(slot)
      game.pickUp(slot, lootIndex)
    else:
      discard game.world.stepToward(slot, item.tile)
    return

  # Floor is clear: take the stairs.
  if game.world.phase == DescendingPhase:
    if level >= LevelCount - 1:
      return
    if game.monstersOn(level) == 0:
      discard game.world.stepToward(
        slot, game.rampTileFor(level, true))
  else:
    if level <= 0:
      # Out, but not done: walk clear of the stairhead and wait at the
      # entrance. A hero who simply stops on arrival stands on the one tile
      # the rest of the party has to come up through, and strands them.
      if not (actor.home == game.dungeon.entrance):
        discard game.world.stepToward(slot, game.dungeon.entrance)
      return
    discard game.world.stepToward(slot, game.rampTileFor(level, false))

proc objectiveTile*(game: Game, slot: int32): TileRef =
  ## Returns the strategic destination for one idle hero.
  let
    actor = game.world.actors[slot]
    level = int(actor.home.level)
  if game.world.phase == DescendingPhase:
    if game.monstersOn(level) > 0:
      return game.nearestMonsterHome(slot)
    if level >= LevelCount - 1:
      return game.dungeon.vault
    game.rampTileFor(level, true)
  elif level <= 0:
    game.dungeon.entrance
  else:
    game.rampTileFor(level, false)

proc applyHeroAction*(
    game: Game,
    slot: int32,
    action: ReplayAction
): bool =
  ## Applies one high-level hero command through native pathfinding and combat.
  if slot < 0 or slot >= game.world.actors.len:
    return false
  let actor = game.world.actors[slot]
  if not actor.alive or actor.kind != HeroActor or actor.busy or
      actor.id != action.heroId:
    return false
  defer:
    if result:
      game.metrics.command(int(slot), game.world.tick)
  case action.kind
  of ActionWalkTo:
    if not action.offset.validTileOffset:
      return false
    if action.first < 0 or action.first >= LevelCount or
        action.second < 0 or action.second >= GridTiles or
        action.third < 0 or action.third >= GridTiles:
      return false
    let tile = TileRef(
      level: int8(action.first),
      x: uint8(action.second),
      z: uint8(action.third)
    )
    if not tile.walkable:
      return false
    game.world.stepToward(slot, tile, action.offset)
  of ActionAttackTarget:
    let targetSlot = game.world.actorSlot(action.first)
    if targetSlot < 0:
      return false
    let target = game.world.actors[targetSlot]
    if not target.alive or target.kind != MonsterActor or
        target.home.level != actor.home.level:
      return false
    if not game.world.actorCanSee(slot, targetSlot):
      return false
    game.fight(slot, targetSlot)
  of ActionPickupTarget:
    let itemIndex = game.world.itemIndex(action.first)
    if itemIndex < 0 or game.world.items[itemIndex].carrier != 0:
      return false
    let item = game.world.items[itemIndex]
    if item.tile.level != actor.home.level:
      return false
    if not game.world.visible(slot, item.tile) and
        not game.world.headingFor(slot, item.tile):
      return false
    if item.kind.lootUsesSlot:
      if actor.freeInventorySlot() < 0:
        return false
    if tileDistance(actor.home, item.tile) > LootPickupRange:
      return game.world.stepToward(slot, item.tile)
    # In reach, the hero takes it now or holds there while picking cools down.
    game.world.clearPath(slot)
    game.pickUp(slot, itemIndex)
    true
  of ActionUseItem:
    if action.first < 0 or action.first >= InventorySlots:
      return false
    let itemId = actor.inventory[action.first]
    let itemIndex = game.world.itemIndex(itemId)
    if itemIndex < 0:
      return false
    let
      kind = game.world.items[itemIndex].kind
      ability = LootAbilities[kind]
    if ability == NoAbility or actor.cooldowns[int(ability)] != 0:
      return false
    if kind == ManaPotionLoot and actor.maxMana <= 0:
      return false
    let spec = Abilities[ability]
    var targetId = actor.id
    if spec.damage > 0:
      let prey = game.nearestEnemy(
        slot,
        max(int32(spec.rangeTiles), HeroAggroTiles)
      )
      if prey < 0:
        return false
      if not game.world.actorCanSee(slot, prey) or
          tileDistance(
            actor.home,
            game.world.actors[prey].home
          ) > int32(spec.rangeTiles):
        return game.world.stepToward(slot, game.world.actors[prey].home)
      targetId = game.world.actors[prey].id
    game.beginAbility(slot, ability, targetId)
    if LootConsumable[kind]:
      game.world.actors[slot].carriedWeight -=
        game.world.items[itemIndex].weight
      game.world.actors[slot].inventory[action.first] = 0
      game.world.deleteItem(itemIndex)
      game.world.actors[slot].refreshSpeed()
    true
  of ActionDropItem:
    if action.first < 0 or action.first >= InventorySlots:
      return false
    let itemId = actor.inventory[action.first]
    let itemIndex = game.world.itemIndex(itemId)
    if itemIndex < 0:
      return false
    game.world.items[itemIndex].carrier = 0
    game.world.items[itemIndex].tile = actor.home
    game.world.actors[slot].carriedWeight -=
      game.world.items[itemIndex].weight
    game.world.actors[slot].inventory[action.first] = 0
    game.world.actors[slot].refreshSpeed()
    true
  of ActionHealTarget:
    if actor.heroClass != ClericClass or
        actor.cooldowns[int(Bloom)] != 0 or
        actor.mana < Abilities[Bloom].manaCost:
      return false
    let targetSlot = game.world.actorSlot(action.first)
    if targetSlot < 0 or targetSlot >= PartySize:
      return false
    let target = game.world.actors[targetSlot]
    if not target.alive or target.home.level != actor.home.level or
        target.hp >= target.maxHp or
        tileDistance(actor.home, target.home) >
          int32(Abilities[Bloom].rangeTiles):
      return false
    game.world.actors[slot].mana -= Abilities[Bloom].manaCost
    game.beginAbility(slot, Bloom, target.id)
    true
  else:
    false


## Monster behaviour

template frontLine(hero: Actor): bool =
  ## True for a hero whose best attack is a melee swing.
  Abilities[ClassAttacks[hero.heroClass][0]].rangeTiles <= 1

proc kiteAway(game: Game, slot: int32): bool =
  ## Walks a caster out of reach of the front-line heroes it can see closer
  ## than KiteTiles. Of the free tiles two steps round it, it takes the one
  ## that leaves the nearest of them farthest away, capped at KiteTiles, so
  ## it backs off only as far as it must. Returns false when no tile there
  ## is safer than where it stands.
  let actor = game.world.actors[slot]
  var threats: seq[TileRef]
  for hero in 0'i32 ..< PartySize:
    let other = game.world.actors[hero]
    if not other.alive or not other.frontLine:
      continue
    let distance = tileDistance(actor.home, other.home)
    if distance >= 0 and distance < KiteTiles and
        game.world.actorCanSee(slot, hero):
      threats.add other.home
  threats.len > 0 and game.backAway(slot, threats, KiteTiles, 2)

proc backAway(
    game: Game,
    slot: int32,
    threats: seq[TileRef],
    reach, steps: int32
): bool =
  ## Walks an actor to the free tile within `steps` of it that leaves the
  ## nearest threat farthest away, capped at `reach`, so it backs off only as
  ## far as it must. A hero only makes for tiles it can see, which keeps it
  ## out of the next room. Returns false when no tile there is safer.
  let actor = game.world.actors[slot]
  proc safety(tile: TileRef): int32 =
    result = reach
    for threat in threats:
      result = min(result, tileDistance(tile, threat))
  var
    best = actor.home
    bestSafety = safety(actor.home)
    bestStep = 0'i32
  for dz in -steps .. steps:
    for dx in -steps .. steps:
      let
        x = int32(actor.home.x) + dx
        z = int32(actor.home.z) + dz
      if x < 0 or z < 0 or x >= GridTiles or z >= GridTiles:
        continue
      let tile = TileRef(level: actor.home.level, x: uint8(x), z: uint8(z))
      if not tile.walkable or game.world.claimed(tile):
        continue
      if actor.kind == HeroActor and not game.world.visible(slot, tile):
        continue
      let
        tileSafety = safety(tile)
        step = max(abs(dx), abs(dz))
      if tileSafety > bestSafety or
          (tileSafety == bestSafety and best != actor.home and
            step < bestStep):
        best = tile
        bestSafety = tileSafety
        bestStep = step
  if best == actor.home:
    return false
  game.world.stepToward(slot, best)

proc decideCaster(game: Game, slot, prey: int32) =
  ## Casters fight from range. A ready bolt goes at the nearest hero in
  ## reach; while it recharges, the caster backs away from front-line
  ## heroes, holds where it stands if its target is still in reach, and
  ## otherwise closes only until it is.
  let
    actor = game.world.actors[slot]
    target = game.world.actors[prey]
    reach = int32(Abilities[HexBolt].rangeTiles)
    inReach = tileDistance(actor.home, target.home) <= reach
  if inReach and actor.cooldowns[int(HexBolt)] == 0:
    actor.state = FightingState
    game.world.clearPath(slot)
    game.world.faceActor(slot, prey)
    game.beginAbility(slot, HexBolt, target.id)
  elif game.kiteAway(slot):
    actor.state = KitingState
  elif inReach:
    actor.state = FightingState
    game.world.clearPath(slot)
    game.world.faceActor(slot, prey)
  else:
    actor.state = ChasingState
    discard game.world.stepToward(slot, target.home)

proc swarmSpot(game: Game, slot, prey: int32): (bool, TileRef) =
  ## The free tile beside a hero for a swarmling to run for: the one it
  ## already runs for while that stays open, otherwise the one nearest it.
  ## Each takes its own side, so a swarm closes on its prey from all round
  ## instead of queueing behind the first one in.
  let
    actor = game.world.actors[slot]
    center = game.world.actors[prey].home
  if actor.moving:
    let goal = game.world.pathGoal(slot)
    if tileDistance(goal, center) == 1 and
        game.world.claimant(goal) in [-1'i32, slot]:
      return (true, goal)
  var bestDistance = high(int32)
  for dz in -1'i32 .. 1:
    for dx in -1'i32 .. 1:
      let
        x = int32(center.x) + dx
        z = int32(center.z) + dz
      if (dx == 0 and dz == 0) or x < 0 or z < 0 or
          x >= GridTiles or z >= GridTiles:
        continue
      let tile = TileRef(level: center.level, x: uint8(x), z: uint8(z))
      if not tile.walkable or game.world.claimant(tile) notin [-1'i32, slot]:
        continue
      let
        ax = x - int32(actor.home.x)
        az = z - int32(actor.home.z)
        distance = ax * ax + az * az
      if distance < bestDistance:
        bestDistance = distance
        result = (true, tile)

proc swarmToward(game: Game, slot, prey: int32): bool =
  ## Runs a swarmling for a free side of its prey, or of any other hero it
  ## sees once every side of its prey is taken, and returns false once it
  ## should swing instead. Any tile beside a hero is in reach, so one on its
  ## way round would otherwise stop to swing from a tile another swarmling
  ## holds; it swings only from its own, or when no side is left to take.
  ## With none free it waits a couple of tiles off rather than shoving into
  ## the crowd, where it would only wall off the doorway the party fights in.
  let
    actor = game.world.actors[slot]
    reached = inMelee(actor.home, game.world.actors[prey].home)
  if reached and game.world.claimant(actor.home) == slot:
    return false
  var (found, spot) = game.swarmSpot(slot, prey)
  if not found and not reached:
    let sight = game.world.monsterSight(actor)
    for hero in 0'i32 ..< PartySize:
      let distance = tileDistance(actor.home, game.world.actors[hero].home)
      if hero == prey or not game.world.actors[hero].alive or
          distance < 0 or distance > sight or
          not game.world.actorCanSee(slot, hero):
        continue
      (found, spot) = game.swarmSpot(slot, hero)
      if found:
        break
  if found:
    discard game.world.stepToward(slot, spot)
  elif reached:
    return false
  elif tileDistance(actor.home, game.world.actors[prey].home) >
      SwarmHoldTiles:
    discard game.world.stepToward(slot, game.world.actors[prey].home)
  else:
    game.world.clearPath(slot)
  true

proc tauntedPrey(game: Game, slot: int32): int32 =
  ## The hero a taunted monster has to go for, or -1 once the taunt runs
  ## out or that hero is gone.
  let actor = game.world.actors[slot]
  if actor.tauntTicks == 0:
    return -1
  result = game.world.actorSlot(actor.tauntedBy)
  if result >= 0 and (not game.world.actors[result].alive or
      game.world.actors[result].home.level != actor.home.level):
    result = -1

proc decideMonster(game: Game, slot: int32) =
  let actor = game.world.actors[slot]
  if actor.busy:
    return
  let sight = game.world.monsterSight(actor)
  var prey = game.tauntedPrey(slot)
  if prey < 0:
    prey = game.nearestEnemy(slot, sight)
  if prey < 0:
    actor.state = GuardingState
    game.world.clearPath(slot)
    return
  if actor.species.monsterRank == CasterRank:
    game.decideCaster(slot, prey)
    return
  if actor.species.monsterRank == SwarmRank and game.swarmToward(slot, prey):
    actor.state = ChasingState
    return
  let target = game.world.actors[prey]
  if inMelee(actor.home, target.home):
    actor.state = FightingState
    game.world.clearPath(slot)
    actor.facing = facingToward(actor.home, target.home)
    game.beginAbility(
      slot, RankAttacks[actor.species.monsterRank], target.id)
  else:
    actor.state = ChasingState
    discard game.world.stepToward(slot, target.home)


## The tick

proc settleArena(game: Game) =
  ## Ends an arena fight a moment after one side falls, so the last blow
  ## stays on screen before the match stops or loops back.
  if game.world.arenaDecided == 0:
    if game.world.partyAlive() > 0 and game.monstersOn(ArenaLevel) > 0:
      return
    game.world.arenaDecided = game.world.tick
    game.log.add(
      if game.world.partyAlive() > 0: "the heroes win the fight"
      else: "the heroes lose the fight")
  if game.world.tick - game.world.arenaDecided >= ArenaAftermathTicks:
    game.world.phase =
      if game.world.partyAlive() > 0: EscapedPhase else: WipedPhase

proc tickWorld*(
    game: Game,
    onHeroDecision: proc(game: Game, slot: int32) {.closure.}
) {.measure.} =
  ## One authoritative simulation step.
  if game.world.phase in {EscapedPhase, WipedPhase}:
    return
  inc game.world.tick
  profileBlock "vision":
    game.world.rebuildVision()

  # Decisions run every tick, in a rotating order so no slot is permanently
  # first.
  let thinking = game.world.tick mod DecisionTicks == 0
  if thinking:
    profileBlock "decisions":
      for offset in 0 ..< game.world.actors.len:
        let slot = int32(
          (int(game.world.turnStart) + offset) mod game.world.actors.len)
        if not game.world.actors[slot].alive:
          continue
        if game.world.actors[slot].kind == HeroActor:
          onHeroDecision(game, slot)
        else:
          game.decideMonster(slot)
    game.world.turnStart =
      (game.world.turnStart + 1) mod int32(max(game.world.actors.len, 1))

  profileBlock "actions":
    for slot in 0 ..< game.world.actors.len:
      if not game.world.actors[slot].alive:
        continue
      game.advanceAction(int32(slot))
      game.radiateHeat(int32(slot))
    game.tendVines()

  profileBlock "movement":
    for slot in 0 ..< game.world.actors.len:
      if game.world.actors[slot].id == 0:
        continue
      if game.world.actors[slot].alive and
          not game.world.actors[slot].busy and
          not game.world.actors[slot].staggered and
          not game.world.actors[slot].rooted:
        discard game.world.advancePath(int32(slot))
    for i in 0 ..< game.world.actors.len:
      if not game.world.actors[i].alive:
        continue
      for j in i + 1 ..< game.world.actors.len:
        if not game.world.actors[j].alive:
          continue
        if game.world.actors[i].home.level != game.world.actors[j].home.level:
          continue
        ctaWalkLayer = int(game.world.actors[i].home.level)
        ctaWalkDestLayer = ctaWalkLayer
        # A hero standing still or swinging holds its ground; whoever walks
        # into it takes the whole push and slides around it.
        separatePair(
          game.world.actors[i].body,
          game.world.actors[j].body,
          ctaTilesWalkable,
          game.world.actors[i].planted,
          game.world.actors[j].planted
        )
    for slot in 0 ..< game.world.actors.len:
      if game.world.actors[slot].alive:
        ctaWalkDestLayer = int(game.world.actors[slot].home.level)
        game.world.applyActorBody(int32(slot))
    game.world.rebuildClaims()
  for slot in 0 ..< game.world.actors.len:
    if game.world.actors[slot].id == 0:
      continue
    for ability in 0 ..< AbilityCount:
      if game.world.actors[slot].cooldowns[ability] > 0:
        dec game.world.actors[slot].cooldowns[ability]
    if game.world.actors[slot].sinceHitTicks < 30_000:
      inc game.world.actors[slot].sinceHitTicks
    if game.world.actors[slot].hasteTicks > 0:
      dec game.world.actors[slot].hasteTicks
      if game.world.actors[slot].hasteTicks == 0:
        game.world.actors[slot].refreshSpeed()
    if game.world.actors[slot].guardTicks > 0:
      dec game.world.actors[slot].guardTicks
    if game.world.actors[slot].staggerTicks > 0:
      dec game.world.actors[slot].staggerTicks
    if game.world.actors[slot].cloakTicks > 0:
      dec game.world.actors[slot].cloakTicks
    if game.world.actors[slot].slowTicks > 0:
      dec game.world.actors[slot].slowTicks
      if game.world.actors[slot].slowTicks == 0:
        game.world.actors[slot].refreshSpeed()
    if game.world.actors[slot].heatTicks > 0:
      dec game.world.actors[slot].heatTicks
    if game.world.actors[slot].tauntTicks > 0:
      dec game.world.actors[slot].tauntTicks
    # Wounds close slowly once a fight is over, and mana comes back with
    # them, so the party can afford the walk back up.
    if game.world.actors[slot].kind == HeroActor and
        game.world.actors[slot].alive and
        game.world.actors[slot].sinceHitTicks >= RegenerationIdleTicks and
        game.world.tick mod RegenerationPeriodTicks == 0:
      let actor = game.world.actors[slot]
      actor.hp = min(
        actor.hp +
          int16(max(
            int32(actor.maxHp) * RegenerationPercent div 100,
            1
          )),
        actor.maxHp)
      actor.mana = min(
        actor.mana +
          int16(max(int32(actor.maxMana) * RegenerationPercent div 100, 1)),
        actor.maxMana)

  # Carried treasure travels with its bearer, so the renderer and the score
  # both read the same position.
  for index in 0 ..< game.world.items.len:
    let carrier = game.world.items[index].carrier
    if carrier == 0:
      continue
    let slot = game.world.actorSlot(carrier)
    if slot >= 0:
      game.world.items[index].tile = game.world.actors[slot].home

  let level = game.partyLevel()
  if level > game.world.deepest:
    game.world.deepest = level
    game.log.add "the party reaches " & Themes[level].name

  # Turn around at the bottom.
  if game.world.phase == DescendingPhase and int(level) >= LevelCount - 1 and
      game.monstersOn(LevelCount - 1) == 0:
    game.world.phase = ReturningPhase
    game.log.add "the vault is cleared; the party turns back"

  # While the party climbs out, the dungeon fills in behind them.
  if game.world.phase == ReturningPhase:
    inc game.world.respawnTicks
    if game.world.respawnTicks >= RespawnIntervalTicks:
      game.world.respawnTicks = 0
      # Reinforcements appear on the floors *above* the party, so the way out
      # is contested. Two things this must not do: spawn onto the party's own
      # floor, which piles monsters onto them where they stand, and keep
      # spawning once they are nearly out, which traps the last hero on the
      # first floor forever with the exit in sight.
      if level > 1:
        var rng = game.world.rng
        let
          target = rng.between(1, level - 1)
          rooms = game.dungeon.rooms[target]
        if rooms.len > 0:
          let
            room = rooms[rng.below(int32(rooms.len))]
            size = rng.between(PackMin, PackMax)
          if game.spawnPack(int(target), room, size, rng) > 0:
            game.log.add "a pack stirs on " & Themes[target].name &
              " behind the party"
        game.world.rng = rng

  # Endings.
  if game.world.isArena:
    game.settleArena()
  elif game.world.partyAlive() == 0:
    game.world.phase = WipedPhase
    game.log.add "the party is lost"
  elif game.world.phase == ReturningPhase:
    # Each hero banks what they personally hauled out, the moment they reach
    # the surface. Ending the run on the first one home would strand whatever
    # the stragglers are still carrying.
    var
      living = 0
      surfaced = 0
    for slot in 0 ..< PartySize:
      if not game.world.actors[slot].alive:
        continue
      inc living
      if int(game.world.actors[slot].home.level) != 0:
        continue
      inc surfaced
      game.world.returned[slot] = true
      if game.world.actors[slot].carriedValue > 0:
        game.world.banked += game.world.actors[slot].carriedValue
        game.world.bankedGold[slot] += game.world.actors[slot].carriedValue
        game.log.add HeroClass(game.world.actors[slot].class).`$` &
          " banks " & $game.world.actors[slot].carriedValue & " gold"
        game.world.actors[slot].carriedValue = 0
    if living > 0 and surfaced == living:
      game.world.phase = EscapedPhase
      game.log.add "the party escapes with " & $game.world.banked & " gold"

proc partyGold*(game: Game): int32 =
  ## Sum of gold still carried by living heroes. Each hero has a private purse.
  for slot in 0 ..< PartySize:
    if game.world.actors[slot].alive:
      result += game.world.actors[slot].carriedValue

proc stateHash*(game: Game): uint64 =
  ## The replay digest. `World` has nothing to skip.
  hashWorld(game.world)

proc scores*(world: World): seq[int] =
  ## Awards shared wins to surviving returners with the most banked gold.
  result.setLen(PartySize)
  var highest = -1'i32
  for slot in 0 ..< PartySize:
    if world.actors[slot].alive and world.returned[slot]:
      highest = max(highest, world.bankedGold[slot])
  if highest < 0:
    return
  for slot in 0 ..< PartySize:
    if world.actors[slot].alive and world.returned[slot] and
      world.bankedGold[slot] == highest:
        result[slot] = 1
