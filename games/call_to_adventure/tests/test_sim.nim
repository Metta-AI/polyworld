## Call to Adventure simulation: hashing, claims, movement, and restore.

import
  fixxy,
  polyworld/[metrics, pathing, rngs, tapes],
  ../[content, sim, replays]

echo "Testing CTA family progression and monster strength"
block:
  let expected = [
    UndeadFamily, OrcFamily, VampireFamily, VampireFamily, DemonFamily
  ]
  for level in 1 ..< LevelCount:
    var
      first = initRng(2026)
      second = initRng(2026)
      seen: set[MonsterRank]
    for i in 0 ..< 1000:
      let species = levelSpecies(level, first)
      doAssert species == levelSpecies(level, second)
      doAssert species.monsterFamily == expected[level - 1]
      seen.incl species.monsterRank
    doAssert seen == {RuntRank .. ChampionRank}
  const bySize = [SwarmRank, RuntRank, RaiderRank, CasterRank, ChampionRank]
  for family in MonsterFamily:
    for index in 1 ..< bySize.len:
      let
        species = familySpecies(family, bySize[index])
        smaller = familySpecies(family, bySize[index - 1])
      doAssert SpeciesHp[species] > SpeciesHp[smaller]
      doAssert SpeciesDamage[species] > SpeciesDamage[smaller]
      doAssert RankScales[species.monsterRank] >
        RankScales[smaller.monsterRank]
  for species in Species:
    doAssert familySpecies(species.monsterFamily, species.monsterRank) ==
      species
  for family in MonsterFamily:
    let swarm = familySpecies(family, SwarmRank)
    doAssert SpeciesSpeeds[swarm] > ClassSpeeds[RogueClass]

echo "Testing every floor's packs bring their family's swarm"
block:
  let game = newGame(2026)
  var swarms: array[LevelCount, int]
  for slot in PartySize ..< game.world.actors.len:
    let actor = game.world.actors[slot]
    if actor.alive and actor.species.monsterRank == SwarmRank:
      doAssert actor.species.monsterFamily ==
        FloorFamilies[actor.home.level]
      inc swarms[actor.home.level]
  doAssert swarms[SurfaceLevel] == 0
  for level in 1 ..< LevelCount:
    doAssert swarms[level] >= 3, "no swarm on level " & $level
  doAssert game.world.actors.len - PartySize <= MaxMonsters

echo "Testing a swarm spreads round a hero instead of queueing"
block:
  var mites: seq[Species]
  for _ in 0 ..< 6:
    mites.add BoneMiteSpecies
  let
    game = newArenaGame(2026, 2_000, [FighterClass], mites)
    hero = game.world.actors[FighterClass.ord]
  proc standStill(game: Game, slot: int32) =
    discard
  var surrounded = false
  for tick in 0 ..< 240:
    game.tickWorld(standStill)
    var sides: seq[TileRef]
    for slot in PartySize ..< game.world.actors.len:
      let mite = game.world.actors[slot]
      if mite.alive and inMelee(mite.home, hero.home) and
          mite.home notin sides:
        sides.add mite.home
    if sides.len >= 5:
      surrounded = true
      break
  doAssert hero.alive
  doAssert surrounded, "the swarm never closed round the hero"

proc testSetup(): Setup =
  result = Setup(
    seed: 2026,
    mapVersion: 1,
    tickRate: uint16(TickRate),
    gridTiles: uint16(GridTiles),
    levels: uint8(LevelCount),
    decisionTicks: uint16(DecisionTicks),
    hashIntervalTicks: uint16(HashIntervalTicks),
    maximumTicks: uint32(DefaultMaximumTicks),
    mapHash: 0x1234_5678_9ABC_DEF0'u64
  )
  for slot in 0 ..< PartySize:
    result.party[slot] = PartyMember(
      id: int32(100 + slot),
      class: HeroClass(slot)
    )

proc populate(world: World) =
  ## Gives the world enough shape that every hashed field is non-trivial.
  world.actors.setLen(PartySize)
  for slot in 0 ..< PartySize:
    let class = HeroClass(slot)
    world.actors[slot] = Actor(
      id: int32(100 + slot),
      kind: HeroActor,
      class: uint8(class),
      home: TileRef(level: 0, x: uint8(10 + slot), z: 10),
      next: TileRef(level: 0, x: uint8(10 + slot), z: 10),
      baseSpeed: ClassSpeeds[class],
      speed: ClassSpeeds[class],
      hp: ClassHp[class],
      maxHp: ClassHp[class],
      mana: ClassMana[class],
      maxMana: ClassMana[class]
    )
  discard world.addActor(Actor(
    id: 0,
    kind: MonsterActor,
    class: uint8(TuskRaiderSpecies),
    home: TileRef(level: 2, x: 40, z: 40),
    baseSpeed: SpeciesSpeeds[TuskRaiderSpecies],
    speed: SpeciesSpeeds[TuskRaiderSpecies],
    hp: SpeciesHp[TuskRaiderSpecies],
    maxHp: SpeciesHp[TuskRaiderSpecies]
  ))
  world.items.add Item(
    id: 1,
    kind: HealingPotionLoot,
    tile: TileRef(level: 4, x: 60, z: 61),
    value: LootValues[HealingPotionLoot],
    weight: LootWeights[HealingPotionLoot]
  )
  world.doors.add Door(id: 1, tile: TileRef(level: 2, x: 33, z: 44))
  world.markExplored(TileRef(level: 2, x: 33, z: 44))
  world.markVisible(0, TileRef(level: 0, x: 11, z: 10))
  world.say(100, 2, 7)
  world.rebuildClaims()

proc flatTile(): Tile =
  ## Creates one flat tile connected to its east and south neighbors.
  Tile(
    tops: [0'i16, 0, 0, 0],
    flags: TileExists or TileConnectedEast or TileConnectedSouth
  )

proc flatLayer(width: int): QuadLayer =
  ## Creates one row of flat tiles for a straight movement test.
  result = QuadLayer(
    width: width,
    depth: 1,
    tiles: newSeq[Tile](width)
  )
  for tile in result.tiles.mitems:
    tile = flatTile()

proc eastwardPos(actor: Actor): Fixed =
  ## Tile-space x from the centre of the start tile.
  actor.body.pos.x - 0.5'fx

echo "Testing clone is an independent deep copy"
block:
  let world = newWorld(testSetup())
  world.populate()
  let snapshot = world.clone()
  doAssert hashWorld(world) == hashWorld(snapshot)

  world.actors[0].hp = 3
  world.items[0].value = 1
  world.claims[500] = 9
  world.explored[7] = 0xFF
  world.chat[0].value = 99
  doAssert hashWorld(world) != hashWorld(snapshot),
    "mutating the original must not be invisible to the hash"
  doAssert snapshot.actors[0].hp != 3,
    "clone shared its actors seq with the original"
  doAssert snapshot.items[0].value != 1
  doAssert snapshot.claims[500] != 9
  doAssert snapshot.explored[7] != 0xFF
  doAssert snapshot.chat[0].value != 99

echo "Testing restore returns a world to a snapshot exactly"
block:
  let world = newWorld(testSetup())
  world.populate()
  let snapshot = world.clone()
  let before = hashWorld(world)

  for _ in 0 ..< 100:
    discard world.rng.next()
  world.tick = 4137
  world.actors[1].hp = 1
  world.banked = 5000
  world.outcome = WipedOutcome
  doAssert hashWorld(world) != before

  world.restore(snapshot)
  doAssert hashWorld(world) == before, "restore did not reproduce the snapshot"
  doAssert world.tick == 0
  doAssert world.rng.state ==
    snapshot.rng.state

echo "Testing restore keeps the caller's ref identity"
block:
  let world = newWorld(testSetup())
  world.populate()
  let alias = world              # stands in for a captured host closure
  let snapshot = world.clone()
  world.tick = 900
  world.restore(snapshot)
  doAssert alias.tick == 0, "restore rebound the ref instead of assigning"

echo "Testing every scalar field of World reaches the hash"
block:
  # The tripwire. Add a field to World and this fails on the day the field
  # is added rather than during a divergence hunt weeks later.
  let world = newWorld(testSetup())
  world.populate()
  var checked = 0
  for name, value in world[].fieldPairs:
    when value is SomeInteger:
      let base = hashWorld(world)
      let saved = value
      value = value + 1
      doAssert hashWorld(world) != base, "unhashed field: " & name
      value = saved
      doAssert hashWorld(world) == base
      inc checked
    elif value is enum:
      let base = hashWorld(world)
      let saved = value
      value = if saved == low(typeof(value)): succ(saved) else: pred(saved)
      doAssert hashWorld(world) != base, "unhashed field: " & name
      value = saved
      doAssert hashWorld(world) == base
      inc checked
  doAssert checked >= 6, "the tripwire checked suspiciously few fields"

echo "Testing the compound fields of World reach the hash"
block:
  # fieldPairs only reaches top-level scalars, so the seqs, arrays and
  # nested objects are poked by hand. Each of these is a field that a naive
  # hash of packed memory would plausibly miss.
  let world = newWorld(testSetup())
  world.populate()

  template mutates(label: string, body: untyped) =
    let base = hashWorld(world)
    let snapshot = world.clone()
    body
    doAssert hashWorld(world) != base, "unhashed: " & label
    world.restore(snapshot)
    doAssert hashWorld(world) == base

  mutates "actors": world.actors[0].facing = North
  mutates "actor cooldowns": world.actors[0].cooldowns[int(SwordAttack)] = 12
  mutates "actor inventory": world.actors[0].inventory[1] = 77
  mutates "actor haste": world.actors[0].hasteTicks = 12
  mutates "actor entanglement": world.actors[0].entangledTicks = 5
  mutates "vines": world.vines.add VinePatch(center: world.actors[0].home,
    sprouted: 3)
  mutates "actor path":
    world.actors[0].path.add PathStep(
      tile: TileRef(level: 0, x: 12, z: 10), direction: East)
  mutates "actor tombstones": world.actors.add Actor()
  mutates "items": world.items[0].tile.x = 61
  mutates "doors": world.doors[0].open = true
  mutates "claims": world.claims[1234] = 3
  mutates "explored": world.markExplored(TileRef(level: 5, x: 1, z: 1))
  mutates "visible": world.markVisible(3, TileRef(level: 5, x: 1, z: 1))
  mutates "chat": world.chat[2].phrase = 4
  mutates "personal gold": world.bankedGold[1] = 100
  mutates "returned heroes": world.returned[2] = true
  mutates "rng": discard world.rng.next()

echo "Testing tile claims are exclusive"
block:
  let world = newWorld(testSetup())
  world.populate()
  let tile = TileRef(level: 3, x: 20, z: 20)
  doAssert not world.claimed(tile)
  let slot = world.addActor(Actor(
    kind: MonsterActor,
    class: uint8(TuskRaiderSpecies),
    home: tile,
    hp: 10,
    maxHp: 10
  ))
  doAssert slot >= 0
  doAssert world.claimed(tile)
  doAssert world.claimant(tile) == slot

  let rejected = world.addActor(Actor(
    kind: MonsterActor,
    class: uint8(CryptAcolyteSpecies),
    home: tile,
    hp: 10,
    maxHp: 10
  ))
  doAssert rejected == -1, "two actors must never share a tile"

  world.removeActor(slot)
  doAssert not world.claimed(tile)
  doAssert world.actors[slot].id == 0

echo "Testing removed slots are reused before the seq grows"
block:
  let world = newWorld(testSetup())
  world.populate()
  let first = world.addActor(Actor(
    kind: MonsterActor, home: TileRef(level: 1, x: 5, z: 5),
    hp: 1, maxHp: 1))
  let
    length = world.actors.len
    firstId = world.actors[first].id
  world.removeActor(first)
  let second = world.addActor(Actor(
    kind: MonsterActor, home: TileRef(level: 1, x: 6, z: 5),
    hp: 1, maxHp: 1))
  doAssert second == first, "a free slot should be reused"
  doAssert world.actors.len == length
  doAssert world.actors[second].id > firstId,
    "ids must keep increasing even when a slot is reused"

echo "Testing rebuildClaims matches the incremental claims"
block:
  let world = newWorld(testSetup())
  world.populate()
  let before = hashWorld(world)
  world.rebuildClaims()
  doAssert hashWorld(world) == before,
    "claims drifted from what actor homes imply"

echo "Testing tileKnown reports party memory and private sight"
block:
  let world = newWorld(testSetup())
  world.populate()
  let tile = TileRef(level: 2, x: 70, z: 70)
  doAssert world.tileKnown(0, tile) == 0
  world.markExplored(tile)
  doAssert world.tileKnown(0, tile) == 1
  doAssert world.tileKnown(1, tile) == 1, "memory is shared by the party"
  world.markVisible(0, tile)
  doAssert world.tileKnown(0, tile) == 2
  doAssert world.tileKnown(1, tile) == 1, "sight is not shared by the party"

echo "Testing tile indexing covers the world without collision"
block:
  var seen = newSeq[bool](WorldTiles)
  for level in 0 ..< LevelCount:
    for z in 0 ..< GridTiles:
      for x in 0 ..< GridTiles:
        let index = TileRef(
          level: int8(level), x: uint8(x), z: uint8(z)).tileIndex
        doAssert index >= 0 and index < WorldTiles
        doAssert not seen[index], "tile index collision"
        seen[index] = true

echo "Testing the same seed builds the same world"
block:
  let first = newWorld(testSetup())
  let second = newWorld(testSetup())
  doAssert hashWorld(first) == hashWorld(second)
  var other = testSetup()
  other.seed = 2027
  let third = newWorld(other)
  doAssert hashWorld(third) != hashWorld(first),
    "a different seed must produce a different world"

echo "Testing encumbrance scales speed in steps"
block:
  var actor = Actor(kind: HeroActor, class: uint8(FighterClass))
  let capacity = actor.carryCapacity
  doAssert capacity == ClassCarryWeight[FighterClass]
  doAssert actor.encumbrance(capacity) == 0
  actor.carriedWeight = capacity div 2
  doAssert actor.encumbrance(capacity) == 2
  actor.carriedWeight = capacity
  doAssert actor.encumbrance(capacity) == 3
  actor.carriedWeight = capacity * 10
  doAssert actor.encumbrance(capacity) == 3, "encumbrance must saturate"

echo "Testing CTA movement stays linear across tile boundaries"
block:
  layers = @[flatLayer(6)]
  computeWalkable()

  let
    world = newWorld(Setup(seed: 1988))
    slot = world.addActor(Actor(
      home: TileRef(level: 0, x: 0, z: 0),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
  doAssert slot == 0

  for x in 1'u8 .. 5'u8:
    world.actors[slot].path.add PathStep(
      tile: TileRef(level: 0, x: x, z: 0),
      direction: East
    )

  for tick in 1'i32 .. 20'i32:
    discard world.advancePath(slot)
    doAssert world.actors[slot].moving,
      "the test path must continue through every sampled tick"
    let
      expected = fixed(tick) * fixed(ClassSpeeds[RogueClass]) / fixed(PhaseUnits)
      travelled = world.actors[slot].eastwardPos
    doAssert abs(travelled - expected) <= Fixed(512),
      "movement drifted at tile boundary on tick " & $tick
    doAssert abs(world.actors[slot].body.pos.y - 0.5'fx) <= Fixed(8)

echo "Testing stepToward only sets the path"
block:
  layers = @[flatLayer(6)]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    slot = world.addActor(Actor(
      home: TileRef(level: 0, x: 0, z: 0),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
    goal = TileRef(level: 0, x: 5, z: 0)
    before = world.actors[slot].body.pos
  doAssert world.stepToward(slot, goal)
  doAssert world.actors[slot].body.pos == before,
    "a walk command must not also steer that tick"
  doAssert world.pathGoal(slot) == goal
  discard world.advancePath(slot)
  doAssert world.actors[slot].body.pos != before,
    "movement must happen in the path phase"

echo "Testing paths route around occupied tiles"
block:
  var floor = QuadLayer(
    width: 3,
    depth: 5,
    tiles: newSeq[Tile](15)
  )
  for tile in floor.tiles.mitems:
    tile = flatTile()
  layers = @[floor]
  computeWalkable()
  let
    world = newWorld(Setup(seed: 1988))
    walker = world.addActor(Actor(
      home: TileRef(level: 0, x: 1, z: 0),
      speed: ClassSpeeds[RogueClass],
      hp: 1,
      maxHp: 1
    ))
    blocker = world.addActor(Actor(
      home: TileRef(level: 0, x: 1, z: 2),
      speed: ClassSpeeds[FighterClass],
      hp: 1,
      maxHp: 1
    ))
    goal = TileRef(level: 0, x: 1, z: 4)
  doAssert walker >= 0 and blocker >= 0
  doAssert world.setPath(walker, goal),
    "an occupied corridor must still have a way around"
  doAssert world.pathGoal(walker) == goal
  for step in world.actors[walker].path:
    doAssert not (step.tile == world.actors[blocker].home),
      "the route walked through the standing hero"

echo "Testing live history seek does not skip recorded actions"
block:
  ## The graphical scrubber restores a live checkpoint whose stored cursor
  ## is still 0, then catches up through recorded hero commands.
  let
    game = newGame(2026, 200)
    recorder = initReplayRecorder(game.world.setup)
    player = ReplayPlayer(data: recorder.data)
  game.recorder = recorder

  proc walkTile(tile: TileRef): TileRef =
    ## Returns a neighboring walkable tile, or the original tile.
    result = tile
    for facing in Facing:
      let next = tile.neighbor(facing)
      if next.walkable:
        return next

  proc liveDecide(game: Game, slot: int32) =
    ## Records one walk so the live tape is not empty.
    let actor = game.world.actors[slot]
    if actor.kind != HeroActor or not actor.alive or actor.busy:
      return
    let
      dest = walkTile(actor.home)
      action = ReplayAction(
        tick: uint32(game.world.tick),
        heroId: actor.id,
        kind: ActionWalkTo,
        first: int32(dest.level),
        second: int32(dest.x),
        third: int32(dest.z)
      )
    recorder.recordAction(
      action.tick,
      action.heroId,
      action.kind,
      action.first,
      action.second,
      action.third
    )
    discard game.applyHeroAction(slot, action)

  proc replayDecide(game: Game, slot: int32) =
    ## Replays every recorded command for this hero on this tick.
    let actor = game.world.actors[slot]
    if actor.kind != HeroActor:
      return
    var action: ReplayAction
    while player.takeActionAt(uint32(game.world.tick), actor.id, action):
      discard game.applyHeroAction(slot, action)

  const
    SnapAfter = 20
    LiveTicks = 40
  var snapshot: World
  for i in 1 .. LiveTicks:
    game.tickWorld(liveDecide)
    recorder.recordHash(game.stateHash())
    if i == SnapAfter:
      snapshot = game.world.clone()
  doAssert recorder.data.actions.len > 0,
    "heroes issued no commands during the live window"
  doAssert player.actionIndex == 0,
    "live recording must not advance the playback cursor"
  let
    frontierTick = game.world.tick
    frontierHash = game.stateHash()
  game.world.restore(snapshot)
  player.data = recorder.data
  player.syncCursor(uint32(game.world.tick))
  while game.world.tick < frontierTick:
    game.tickWorld(replayDecide)
  doAssert game.world.tick == frontierTick
  doAssert game.stateHash() == frontierHash,
    "catching up from a live seek diverged from the recorded frontier"

echo "Testing viewLevel follows the uppermost selected hero"
block:
  var game = Game(world: newWorld(testSetup()))
  game.world.populate()
  game.world.actors[0].home.level = 3
  game.world.actors[1].home.level = 1
  game.world.actors[2].home.level = 4
  game.world.actors[3].home.level = 2
  var selected: array[PartySize, bool]
  selected[0] = true
  selected[1] = true
  selected[2] = true
  doAssert game.viewLevel(selected) == 1,
    "the cutaway must follow the selected hero closest to the surface"
  selected[1] = false
  doAssert game.viewLevel(selected) == 3
  selected[0] = false
  selected[2] = false
  selected[3] = true
  doAssert game.viewLevel(selected) == 2
  var none: array[PartySize, bool]
  doAssert game.viewLevel(none) == 1,
    "with no selection the cutaway still follows the highest living hero"

echo "Testing a hero walks a ramp without falling into a wall"
block:
  const
    Low = 0'i16
    High = 64'i16
    Rise = 8'i16
    RampTiles = int(High - Low) div int(Rise)
  proc flatAt(originX, originZ, width, depth: int, height: int16): QuadLayer =
    result = QuadLayer(
      originX: originX,
      originZ: originZ,
      width: width,
      depth: depth,
      tiles: newSeq[Tile](width * depth)
    )
    for tile in result.tiles.mitems:
      tile = Tile(
        tops: [height, height, height, height],
        flags: TileExists or TileConnectedEast or TileConnectedSouth
      )
  let lower = flatAt(0, 0, 4, 3, Low)
  var ramp = QuadLayer(
    originX: 4, originZ: 1, width: RampTiles, depth: 1,
    tiles: newSeq[Tile](RampTiles)
  )
  for i in 0 ..< RampTiles:
    let
      near = Low + Rise * int16(i)
      far = Low + Rise * int16(i + 1)
    ramp.tiles[i] = Tile(
      tops: [near, far, near, far],
      flags: TileExists or TileConnectedEast or TileConnectedSouth
    )
  layers = @[lower, ramp, flatAt(12, 0, 4, 3, High)]
  computeWalkable()
  let world = newWorld(Setup(seed: 1988))
  let slot = world.addActor(Actor(
    home: TileRef(level: 0, x: 0, z: 1),
    speed: ClassSpeeds[RogueClass],
    hp: 1,
    maxHp: 1
  ))
  doAssert world.setPath(slot, TileRef(level: 2, x: 3, z: 1))
  for _ in 1 .. 400:
    discard world.advancePath(slot)
    let home = world.actors[slot].home
    doAssert isWalkable(int(home.level), int(home.x), int(home.z)),
      "the hero left walkable tiles at " & $home
  doAssert world.actors[slot].home.level == 2,
    "the hero never reached the upper floor"
  doAssert not world.actors[slot].moving

echo "Testing a hero faces the direction of travel"
block:
  proc flatAt(originX, originZ, width, depth: int, height: int16): QuadLayer =
    result = QuadLayer(
      originX: originX,
      originZ: originZ,
      width: width,
      depth: depth,
      tiles: newSeq[Tile](width * depth)
    )
    for tile in result.tiles.mitems:
      tile = Tile(
        tops: [height, height, height, height],
        flags: TileExists or TileConnectedEast or TileConnectedSouth
      )
  layers = @[flatAt(0, 0, 16, 16, 0)]
  computeWalkable()
  let world = newWorld(Setup(seed: 7))
  let slot = world.addActor(Actor(
    home: TileRef(level: 0, x: 2, z: 2),
    facing: East,
    speed: ClassSpeeds[RogueClass],
    hp: 1,
    maxHp: 1
  ))
  doAssert world.setPath(slot, TileRef(level: 0, x: 10, z: 10))
  for _ in 1 .. 30:
    discard world.advancePath(slot)
  let dir = direction(world.actors[slot].body.facing)
  doAssert abs(dir.x) > 0.25'fx and abs(dir.y) > 0.25'fx,
    "the hero snapped to a cardinal instead of facing the diagonal"

echo "Testing a hero can drop a carried item"
block:
  let
    game = newGame(2026, 240)
    slot = 0'i32
    hero = game.world.actors[slot]
    itemId = game.world.nextItemId
  game.world.items.add Item(
    id: itemId,
    kind: HealingPotionLoot,
    tile: hero.home,
    carrier: hero.id,
    weight: LootWeights[HealingPotionLoot]
  )
  inc game.world.nextItemId
  game.world.actors[slot].inventory[0] = itemId
  doAssert game.applyHeroAction(slot, ReplayAction(
    heroId: 100,
    kind: ActionDropItem,
    first: 0
  ))
  doAssert game.metrics.read(int(slot), 0).commands == 1
  doAssert not game.applyHeroAction(slot, ReplayAction(
    heroId: 100,
    kind: ActionDropItem,
    first: 0
  ))
  doAssert not game.applyHeroAction(slot, ReplayAction(
    heroId: 100,
    kind: ActionWalkTo,
    first: -1
  ))
  doAssert game.metrics.read(int(slot), 0).commands == 1
  doAssert game.world.actors[slot].inventory[0] == 0
  let index = game.world.itemIndex(itemId)
  doAssert index >= 0
  doAssert game.world.items[index].carrier == 0
  doAssert game.world.items[index].tile == hero.home

echo "test_sim: all checks passed"

echo "Testing standings require a living returned hero"
block:
  let world = newWorld(testSetup())
  world.populate()
  world.bankedGold = [10'i32, 20, 30, 999]
  doAssert world.scores() == @[0, 0, 0, 0]
  world.returned[0] = true
  doAssert world.scores() == @[1, 0, 0, 0]
  world.returned[1] = true
  doAssert world.scores() == @[0, 1, 0, 0]
  world.bankedGold[0] = 20
  doAssert world.scores() == @[1, 1, 0, 0]
  world.returned[3] = true
  world.actors[3].hp = 0
  doAssert world.scores() == @[1, 1, 0, 0]
  world.actors[0].hp = 0
  world.actors[1].hp = 0
  doAssert world.scores() == @[0, 0, 0, 0]

echo "Testing personal gold is banked before carried gold is cleared"
block:
  let game = newGame(2026, 240)
  game.world.phase = ReturningPhase
  for slot in 0 ..< PartySize:
    game.world.actors[slot].carriedValue = int32(slot + 1) * 100
  proc noDecision(game: Game, slot: int32) =
    ## Leaves the heroes at the surface for the banking test.
    discard
  game.tickWorld(noDecision)
  doAssert game.world.returned == [true, true, true, true]
  doAssert game.world.bankedGold == [100'i32, 200, 300, 400]
  doAssert game.world.banked == 1000
  for slot in 0 ..< PartySize:
    doAssert game.world.actors[slot].carriedValue == 0
  doAssert game.world.scores() == @[0, 0, 0, 1]
  let snapshot = game.world.clone()
  game.world.bankedGold[3] = 0
  game.world.returned[3] = false
  game.world.restore(snapshot)
  doAssert game.world.scores() == @[0, 0, 0, 1]

echo "Testing effective healing and statistics checkpoint restoration"
block:
  let game = newGame(2026, 240)
  let initial = game.stateHash()
  game.world.stats.add(0, DamageMetric)
  doAssert game.stateHash() != initial
  let snapshot = game.world.clone()
  game.world.actors[0].hp -= 7
  game.world.actors[0].action = HealingPotion
  game.world.actors[0].actionTicks =
    Abilities[HealingPotion].impactTicks - 1
  game.tickWorld(proc(game: Game, slot: int32) = discard)
  doAssert game.world.stats.values[0][HealingMetric] == 7
  doAssert snapshot.stats.values[0][HealingMetric] == 0
  game.world.restore(snapshot)
  doAssert game.world.stats.values[0][HealingMetric] == 0
  game.world.actors[0].carriedValue = 100
  game.world.bankedGold[0] = 250
  game.sampleMetrics()
  doAssert game.metrics.read(0, 0).values[GoldMetric] == 100
  doAssert game.metrics.read(0, 0).values[BankedMetric] == 250
  game.world.actors[0].hp = 0
  game.sampleMetrics()
  doAssert game.metrics.read(0, 0).values[GoldMetric] == 0

echo "Testing heroes keep walking to treasure a corner hides"
block:
  ## A corner can hide a pile from the next tile on the way to it. A hero
  ## already walking there must keep it as its target, or it turns back to
  ## where the pile shows again and paces between the two tiles forever.
  let game = newGame(2026, 240)
  let hero = game.world.actors[0]
  var tile = hero.home
  for dx in 3'i32 .. 6'i32:
    let candidate = TileRef(
      level: hero.home.level,
      x: uint8(int32(hero.home.x) + dx),
      z: hero.home.z
    )
    if candidate.walkable and not game.world.claimed(candidate):
      tile = candidate
      break
  doAssert tile != hero.home, "no open tile beside the party"
  let id = game.world.nextItemId
  game.world.items.add Item(id: id, kind: GoldPile, tile: tile, value: 10)
  inc game.world.nextItemId
  clearBits(game.world.visible[0])
  doAssert game.nearestLoot(0) < 0, "unseen treasure must stay unknown"
  doAssert game.world.setPath(0, tile)
  let index = game.nearestLoot(0)
  doAssert index >= 0 and game.world.items[index].id == id,
    "the hero dropped the pile it is walking to"
  doAssert game.applyHeroAction(0, ReplayAction(
    heroId: hero.id,
    kind: ActionPickupTarget,
    first: id
  ))
  doAssert game.world.pathGoal(0) == tile

echo "Testing every ability winds up, releases, then recovers"
block:
  for ability in succ(NoAbility) .. Ability.high:
    if ability == ChainAxe:
      continue  # picking up loot is instant, never an action
    let spec = Abilities[ability]
    doAssert spec.anticipationTicks > 0 and spec.releaseTicks > 0 and
      spec.recoverTicks > 0, $ability & " skips a phase"
    doAssert spec.phaseAt(1) == AnticipationPhase
    doAssert spec.phaseAt(spec.anticipationTicks) == AnticipationPhase
    doAssert spec.phaseAt(spec.anticipationTicks + 1) == ReleasePhase
    doAssert spec.phaseAt(spec.impactTicks) == ReleasePhase
    doAssert spec.phaseAt(spec.impactTicks + 1) == RecoverPhase
  for rank in MonsterRank:
    doAssert Abilities[RankAttacks[rank]].damage > 0

echo "Testing a blow lands on its last release tick and commits the swing"
block:
  let
    game = newArenaGame(2026, 4000, [FighterClass], [BarrowWardenSpecies])
    fighter = int32(FighterClass.ord)
    warden = int32(PartySize)
    wardenId = game.world.actors[warden].id
  proc attack(game: Game, slot: int32) =
    ## Sends the fighter at the warden whenever he is free to act.
    discard game.applyHeroAction(slot, ReplayAction(
      heroId: game.world.actors[slot].id,
      kind: ActionAttackTarget,
      first: wardenId
    ))
  # A plain swing, with his skills out of the way.
  for skill in ClassSkills[FighterClass]:
    game.world.actors[fighter].cooldowns[int(skill)] = 30_000
  var ticks = 0
  while not game.world.actors[fighter].busy and ticks < 600:
    game.tickWorld(attack)
    inc ticks
  doAssert game.world.actors[fighter].busy, "the fighter never swung"
  let spec = Abilities[game.world.actors[fighter].action]
  doAssert game.world.actors[fighter].actionPhase == AnticipationPhase
  var
    hp = game.world.actors[warden].hp
    landed = 0
    planted = game.world.actors[fighter].body.pos
  while game.world.actors[fighter].busy:
    let phase = game.world.actors[fighter].actionPhase
    if phase == RecoverPhase:
      doAssert not game.applyHeroAction(fighter, ReplayAction(
        heroId: game.world.actors[fighter].id,
        kind: ActionAttackTarget,
        first: wardenId
      )), "a recovering hero took another command"
    game.tickWorld(attack)
    if game.world.actors[warden].hp < hp:
      inc landed
      doAssert game.world.actors[fighter].actionTicks == spec.impactTicks,
        "the blow landed outside the last release tick"
      hp = game.world.actors[warden].hp
    if game.world.actors[fighter].busy:
      doAssert game.world.actors[fighter].body.pos == planted,
        "a swinging hero moved"
  doAssert landed == 1
  doAssert game.world.actors[warden].action in
    {NoAbility, RankAttacks[ChampionRank]}

echo "Testing an area lands on every foe inside its ring and no other"
block:
  let
    game = newArenaGame(2026, 4000, [WizardClass],
      [BarrowWardenSpecies, BarrowWardenSpecies, BarrowWardenSpecies])
    wizard = int32(WizardClass.ord)
    first = game.world.actors[PartySize].home
  doAssert game.world.actors[PartySize + 1].home ==
    TileRef(level: first.level, x: first.x, z: first.z + 2)
  doAssert tileDistance(first, game.world.actors[PartySize + 2].home) >= 3
  # Holds every warden in place through a slam that reaches no hero.
  for slot in PartySize ..< PartySize + 3:
    game.world.actors[slot].action = CrushingSlam
    game.world.actors[slot].aim = game.world.actors[slot].home
  game.world.actors[wizard].action = ArcaneMeteor
  game.world.actors[wizard].target = game.world.actors[PartySize].id
  game.world.actors[wizard].aim =
    TileRef(level: first.level, x: first.x, z: first.z + 1)
  var before: array[3, int16]
  for index in 0 .. 2:
    before[index] = game.world.actors[PartySize + index].hp
  while game.world.actors[wizard].busy:
    game.tickWorld(proc(game: Game, slot: int32) = discard)
  doAssert game.world.actors[PartySize].hp < before[0]
  doAssert game.world.actors[PartySize + 1].hp < before[1]
  doAssert game.world.actors[PartySize + 2].hp == before[2]

echo "Testing the battle horn guards the party"
block:
  let game = newGame(2026, 240)
  game.world.actors[0].action = BattleHorn
  game.world.actors[0].target = game.world.actors[0].id
  while game.world.actors[0].busy:
    if game.world.actors[0].actionTicks < Abilities[BattleHorn].impactTicks:
      doAssert game.world.actors[1].guardTicks == 0,
        "the horn sounded before its release"
    game.tickWorld(proc(game: Game, slot: int32) = discard)
  for slot in 0 ..< PartySize:
    doAssert game.world.actors[slot].guardTicks > 0

echo "Testing the archer's kit"
block:
  doAssert HeroAbilities[RogueClass] ==
    [BowAttack, PiercingArrow, ShadowCloak, HailOfArrows]
  doAssert ClassAttacks[RogueClass] == @[BowAttack]
  for ability in [BowAttack, PiercingArrow, HailOfArrows]:
    doAssert Abilities[ability].rangeTiles > 1, "the archer has no melee"
  let
    bow = Abilities[BowAttack]
    piercing = Abilities[PiercingArrow]
    hail = Abilities[HailOfArrows]
    cloak = Abilities[ShadowCloak]
  doAssert bow.cooldownTicks < piercing.cooldownTicks
  doAssert piercing.cooldownTicks < hail.cooldownTicks
  doAssert piercing.shape == LineArea and piercing.staggerTicks > 0
  doAssert hail.shape == RoundArea and hail.staggerTicks == 0
  doAssert hail.damage > piercing.damage and hail.damage > bow.damage
  doAssert cloak.cooldownTicks > hail.cooldownTicks
  doAssert hail.anticipationTicks > piercing.anticipationTicks

echo "Testing a line through the grid and a disc on it"
block:
  let
    game = newArenaGame(2026, 4000, [RogueClass], [BarrowWardenSpecies])
    origin = TileRef(level: 0, x: 10, z: 10)
  # The line goes through its aim, whichever way it leans, and carries on.
  doAssert lineTile(origin, TileRef(level: 0, x: 15, z: 12), 5)[1] ==
    TileRef(level: 0, x: 15, z: 12)
  doAssert lineTile(origin, TileRef(level: 0, x: 5, z: 8), 5)[1] ==
    TileRef(level: 0, x: 5, z: 8)
  doAssert lineTile(origin, TileRef(level: 0, x: 12, z: 10), 6)[1] ==
    TileRef(level: 0, x: 16, z: 10)
  # The arena's east wall stops one fired at it.
  let
    home = game.world.actors[RogueClass.ord].home
    east = TileRef(level: home.level, x: home.x + 2, z: home.z)
  doAssert game.world.lineReach(home, east, 9) < 9
  let
    hail = Abilities[HailOfArrows]
    aim = TileRef(level: 0, x: 20, z: 20)
  proc under(dx, dz: int): bool =
    game.world.inArea(hail, origin, aim, Actor(home: TileRef(
      level: 0, x: uint8(20 + dx), z: uint8(20 + dz))))
  doAssert under(0, 0) and under(2, 0) and under(2, 1) and under(-1, -2)
  doAssert not under(2, 2) and not under(3, 0) and not under(-3, 1)

proc placeActor(game: Game, slot: int, x, z: int32) =
  ## Puts an actor's body and tile down somewhere new.
  game.world.actors[slot].home.x = uint8(x)
  game.world.actors[slot].home.z = uint8(z)
  game.world.actors[slot].next = game.world.actors[slot].home
  game.world.actors[slot].body.pos =
    fixedVec2(fixed(x) + 0.5'fx, fixed(z) + 0.5'fx)

echo "Testing a piercing arrow hits and staggers its whole line"
block:
  let
    game = newArenaGame(2026, 4000, [RogueClass],
      [BarrowWardenSpecies, BarrowWardenSpecies, BarrowWardenSpecies])
    rogue = int32(RogueClass.ord)
    home = game.world.actors[rogue].home
    x = int32(home.x)
    z = int32(home.z)
  game.placeActor(PartySize, x - 3, z)
  game.placeActor(PartySize + 1, x - 5, z)
  game.placeActor(PartySize + 2, x - 4, z + 2)
  game.world.rebuildClaims()
  # Holds every warden in place through a slam that reaches no hero.
  for slot in PartySize ..< PartySize + 3:
    game.world.actors[slot].action = CrushingSlam
    game.world.actors[slot].aim = game.world.actors[slot].home
  var before: array[3, int16]
  for index in 0 .. 2:
    before[index] = game.world.actors[PartySize + index].hp
  game.world.actors[rogue].action = PiercingArrow
  game.world.actors[rogue].target = game.world.actors[PartySize].id
  game.world.actors[rogue].aim = game.world.actors[PartySize].home
  while game.world.actors[rogue].busy:
    let ticks = game.world.actors[rogue].actionTicks
    if ticks < Abilities[PiercingArrow].impactTicks:
      doAssert game.world.actors[PartySize].hp == before[0]
    game.tickWorld(proc(game: Game, slot: int32) = discard)
  doAssert game.world.actors[PartySize].hp < before[0]
  doAssert game.world.actors[PartySize + 1].hp < before[1]
  doAssert game.world.actors[PartySize + 2].hp == before[2]
  doAssert game.world.actors[PartySize].staggered
  doAssert game.world.actors[PartySize + 1].staggered
  doAssert not game.world.actors[PartySize + 2].staggered

echo "Testing a tracking skill follows its target until release"
block:
  let
    game = newArenaGame(2026, 4000, [RogueClass], [BarrowWardenSpecies])
    rogue = int32(RogueClass.ord)
    warden = PartySize
    home = game.world.actors[rogue].home
    x = int32(home.x)
    z = int32(home.z)
  game.placeActor(warden, x - 5, z)
  game.world.rebuildClaims()
  game.world.actors[warden].action = CrushingSlam
  game.world.actors[rogue].action = HailOfArrows
  game.world.actors[rogue].target = game.world.actors[warden].id
  game.world.actors[rogue].aim = game.world.actors[warden].home
  game.tickWorld(proc(game: Game, slot: int32) = discard)
  game.placeActor(warden, x - 5, z - 3)
  game.tickWorld(proc(game: Game, slot: int32) = discard)
  doAssert game.world.actors[rogue].aim == game.world.actors[warden].home,
    "the aim stayed behind"
  let pinned = game.world.actors[rogue].aim
  while game.world.actors[rogue].actionPhase == AnticipationPhase:
    game.tickWorld(proc(game: Game, slot: int32) = discard)
  game.placeActor(warden, x - 7, z - 3)
  game.tickWorld(proc(game: Game, slot: int32) = discard)
  doAssert game.world.actors[rogue].aim == pinned,
    "the aim moved after the release"

echo "Testing stagger stops a monster's feet and nothing else"
block:
  let
    game = newArenaGame(2026, 4000, [RogueClass], [BarrowWardenSpecies])
    warden = PartySize
  game.world.actors[warden].staggerTicks = 12
  let start = game.world.actors[warden].body.pos
  proc standStill(game: Game, slot: int32) =
    discard
  while game.world.actors[warden].staggered:
    game.tickWorld(standStill)
    doAssert game.world.actors[warden].body.pos == start,
      "a staggered monster walked"
  for tick in 0 ..< 24:
    game.tickWorld(standStill)
  doAssert game.world.actors[warden].body.pos != start,
    "the monster never walked again"
  # Still swinging: its feet stopped, not its arms.
  let
    rogue = RogueClass.ord
    home = game.world.actors[rogue].home
  game.placeActor(warden, int32(home.x) - 1, int32(home.z))
  game.world.rebuildClaims()
  game.world.actors[warden].staggerTicks = 12
  game.tickWorld(standStill)
  doAssert game.world.actors[warden].busy, "stagger stopped a blow"

echo "Testing shadow cloak"
block:
  let
    game = newArenaGame(2026, 4000, [RogueClass], [CryptAcolyteSpecies])
    rogue = int32(RogueClass.ord)
    caster = int32(PartySize)
    home = game.world.actors[rogue].home
  game.placeActor(caster, int32(home.x) - 3, int32(home.z))
  game.world.rebuildClaims()
  doAssert game.nearestEnemy(caster, 50) == rogue
  game.world.actors[rogue].action = ShadowCloak
  game.world.actors[rogue].target = game.world.actors[rogue].id
  proc standStill(game: Game, slot: int32) =
    discard
  game.world.actors[caster].action = HexBolt
  game.world.actors[caster].target = game.world.actors[rogue].id
  game.world.actors[caster].aim = home
  while game.world.actors[rogue].busy:
    game.tickWorld(standStill)
  doAssert game.world.actors[rogue].cloaked
  doAssert game.world.actors[rogue].cooldowns[int(ShadowCloak)] >=
    Abilities[ShadowCloak].cooldownTicks - 1
  doAssert game.nearestEnemy(caster, 50) < 0, "a cloaked hero was targeted"
  let hp = game.world.actors[rogue].hp
  while game.world.actors[caster].busy:
    game.tickWorld(standStill)
  doAssert game.world.actors[rogue].hp == hp, "a blow found a cloaked hero"
  for tick in 0 .. 72:
    game.tickWorld(standStill)
  doAssert not game.world.actors[rogue].cloaked, "the cloak never ran out"
  doAssert game.nearestEnemy(caster, 50) == rogue

echo "Testing a cloaked archer backs away from what is near"
block:
  let
    game = newArenaGame(2026, 4000, [RogueClass],
      [BarrowWardenSpecies, BarrowWardenSpecies])
    rogue = int32(RogueClass.ord)
    home = game.world.actors[rogue].home
  game.placeActor(PartySize, int32(home.x) - 1, int32(home.z))
  game.placeActor(PartySize + 1, int32(home.x) - 2, int32(home.z) + 1)
  game.world.rebuildClaims()
  game.world.actors[rogue].cloakTicks = 72
  for ability in ClassSkills[RogueClass]:
    game.world.actors[rogue].cooldowns[int(ability)] = 5000
  let wardenId = game.world.actors[PartySize].id
  proc attack(game: Game, slot: int32) =
    discard game.applyHeroAction(slot, ReplayAction(
      heroId: game.world.actors[slot].id,
      kind: ActionAttackTarget,
      first: wardenId
    ))
  for tick in 0 ..< 60:
    game.tickWorld(attack)
  let farthest = min(
    tileDistance(game.world.actors[rogue].home,
      game.world.actors[PartySize].home),
    tileDistance(game.world.actors[rogue].home,
      game.world.actors[PartySize + 1].home))
  doAssert farthest >= 4, "the archer stayed in reach: " & $farthest

echo "Testing the archer's skills go off as soon as they are ready"
block:
  let
    game = newArenaGame(2026, 12_000, [RogueClass], [BarrowWardenSpecies])
    rogue = int32(RogueClass.ord)
    warden = int32(PartySize)
    wardenId = game.world.actors[warden].id
  game.world.actors[warden].hp = 30_000
  game.world.actors[warden].maxHp = 30_000
  game.world.actors[rogue].hp = 30_000
  game.world.actors[rogue].maxHp = 30_000
  proc attack(game: Game, slot: int32) =
    discard game.applyHeroAction(slot, ReplayAction(
      heroId: game.world.actors[slot].id,
      kind: ActionAttackTarget,
      first: wardenId
    ))
  var
    primed = false
    casts: seq[Ability]
    seen = NoAbility
  for tick in 0 ..< 1_500:
    game.tickWorld(attack)
    let hero = game.world.actors[rogue]
    if primed:
      doAssert hero.busy, "a ready skill sat unused on tick " & $tick
    primed = false
    if hero.action != seen:
      seen = hero.action
      if seen != NoAbility and seen != BowAttack:
        casts.add seen
    if not hero.busy and game.world.actorCanSee(rogue, warden):
      let distance =
        tileDistance(hero.home, game.world.actors[warden].home)
      for skill in ClassSkills[RogueClass]:
        if hero.cooldowns[int(skill)] == 0 and
            distance <= int32(Abilities[skill].rangeTiles):
          primed = true
  doAssert casts.len >= 3
  doAssert casts[0 .. 2] == @[HailOfArrows, PiercingArrow, ShadowCloak]
  doAssert PiercingArrow in casts[3 .. ^1], "the piercing arrow fired once"
  doAssert game.world.actors[rogue].mana == game.world.actors[rogue].maxMana

proc sendAt(game: Game, slot, target: int32) =
  ## Orders one hero at a monster, the way a bot does.
  discard game.applyHeroAction(slot, ReplayAction(
    heroId: game.world.actors[slot].id,
    kind: ActionAttackTarget,
    first: game.world.actors[target].id
  ))

proc idle(game: Game, slot: int32) =
  discard

echo "Testing the fighter's bar is what he fights with"
block:
  doAssert HeroAbilities[FighterClass] ==
    [SwordAttack, Taunt, Heat, BlazingBlade]
  doAssert ClassAttacks[FighterClass] == @[SwordAttack]
  for ability in HeroAbilities[FighterClass]:
    doAssert ability in ClassAttacks[FighterClass] or
      ability in ClassSkills[FighterClass], $ability & " sits unused"
  var icons: seq[string]
  for name in AbilityIconFiles:
    doAssert name.len == 0 or name notin icons, name & " is used twice"
    icons.add name
  doAssert Abilities[BlazingBlade].shape == ConeArea
  doAssert Abilities[BlazingBlade].slowTicks == TickRate * 3 div 2
  doAssert Abilities[BlazingBlade].damage > Abilities[SwordAttack].damage * 3
  doAssert Abilities[Heat].damage < Abilities[SwordAttack].damage
  doAssert Abilities[Taunt].onSelf and Abilities[Heat].onSelf
  doAssert TauntGuardPercent == 50

echo "Testing a cone takes a slice of the floor in front of its caster"
block:
  let
    game = newArenaGame(2026, 4000, [FighterClass], [BarrowWardenSpecies])
    blade = Abilities[BlazingBlade]
    origin = TileRef(level: 0, x: 20, z: 20)
    east = TileRef(level: 0, x: 21, z: 20)
    southEast = TileRef(level: 0, x: 21, z: 21)
  proc caught(aim: TileRef, dx, dz: int32): bool =
    let victim = Actor(
      home: TileRef(level: 0, x: uint8(20 + dx), z: uint8(20 + dz)))
    victim.body.pos = fixedVec2(
      fixed(20 + dx) + 0.5'fx, fixed(20 + dz) + 0.5'fx)
    game.world.inArea(blade, origin, aim, victim)
  doAssert caught(east, 1, 0) and caught(east, 2, 0)
  doAssert caught(east, 1, 1) and caught(east, 1, -1) and caught(east, 2, 1)
  doAssert not caught(east, 3, 0) and not caught(east, 2, 2)
  doAssert not caught(east, 0, 1) and not caught(east, -1, 0)
  doAssert not caught(east, 1, 2)
  doAssert caught(southEast, 1, 1) and caught(southEast, 1, 0)
  doAssert caught(southEast, 0, 1) and caught(southEast, 2, 1)
  doAssert not caught(southEast, 1, -1) and not caught(southEast, -1, 1)
  doAssert not caught(southEast, -1, -1)

echo "Testing the blazing blade cuts and slows only what is in front of him"
block:
  let
    game = newArenaGame(2026, 4000, [FighterClass],
      [BarrowWardenSpecies, BarrowWardenSpecies])
    fighter = int32(FighterClass.ord)
    front = int32(PartySize)
    behind = front + 1
    home = game.world.actors[fighter].home
  game.placeActor(int(front), int32(home.x), int32(home.z) - 1)
  game.placeActor(int(behind), int32(home.x), int32(home.z) + 1)
  game.world.rebuildClaims()
  game.world.actors[fighter].hp = 30_000
  game.world.actors[fighter].maxHp = 30_000
  game.world.actors[fighter].cooldowns[int(Taunt)] = 30_000
  game.world.actors[fighter].cooldowns[int(Heat)] = 30_000
  let
    frontHp = game.world.actors[front].hp
    behindHp = game.world.actors[behind].hp
    pace = game.world.actors[front].speed
  game.sendAt(fighter, front)
  doAssert game.world.actors[fighter].action == BlazingBlade
  while game.world.actors[fighter].busy:
    game.tickWorld(idle)
  doAssert game.world.actors[front].hp < frontHp
  doAssert frontHp - game.world.actors[front].hp >= 46
  doAssert game.world.actors[behind].hp == behindHp
  doAssert game.world.actors[front].slowTicks > 0
  doAssert game.world.actors[front].speed == pace * SlowPercent div 100
  doAssert game.world.actors[behind].speed == pace
  for _ in 0 ..< Abilities[BlazingBlade].slowTicks:
    game.tickWorld(idle)
  doAssert game.world.actors[front].slowTicks == 0
  doAssert game.world.actors[front].speed == pace

echo "Testing a taunt turns the monsters round him on him and guards him"
block:
  let
    game = newArenaGame(2026, 4000, [FighterClass, ClericClass],
      [DustlingSpecies, DustlingSpecies, DustlingSpecies])
    fighter = int32(FighterClass.ord)
    cleric = int32(ClericClass.ord)
    near = int32(PartySize)
    far = near + 1
    elbow = near + 2
    home = game.world.actors[fighter].home
    x = int32(home.x)
    z = int32(home.z)
  # The near one has the cleric at its elbow and the fighter three tiles off,
  # so nothing but the taunt would pick him. The last sets the taunt off.
  game.placeActor(int(cleric), x - 4, z)
  game.placeActor(int(near), x - 3, z)
  game.placeActor(int(far), x - 8, z)
  game.placeActor(int(elbow), x, z - 1)
  game.world.rebuildClaims()
  game.world.rebuildVision()
  game.world.actors[fighter].hp = 30_000
  game.world.actors[fighter].maxHp = 30_000
  game.world.actors[cleric].hp = 30_000
  game.world.actors[cleric].maxHp = 30_000
  game.world.actors[fighter].cooldowns[int(Heat)] = 30_000
  game.world.actors[fighter].cooldowns[int(BlazingBlade)] = 30_000
  game.sendAt(fighter, elbow)
  doAssert game.world.actors[fighter].action == Taunt
  doAssert game.world.actors[fighter].target == game.world.actors[fighter].id
  doAssert game.world.actors[fighter].aim == home
  while game.world.actors[fighter].action == Taunt and
      game.world.actors[near].tauntTicks == 0:
    game.tickWorld(idle)
  doAssert game.world.actors[near].tauntedBy == game.world.actors[fighter].id
  doAssert game.world.actors[far].tauntTicks == 0, "the far one heard it"
  doAssert game.world.actors[fighter].guardTicks > 0
  doAssert game.world.actors[fighter].guardPercent == TauntGuardPercent
  var turned = false
  for _ in 0 ..< TauntTicks - 1:
    game.tickWorld(idle)
    let monster = game.world.actors[near]
    if monster.busy and monster.actionTicks == 1:
      doAssert monster.target == game.world.actors[fighter].id,
        "a taunted monster went for someone else"
      turned = true
  doAssert turned, "the taunted monster never reached him"
  doAssert game.world.actors[near].tauntTicks == 0
  doAssert game.world.actors[fighter].guardTicks == 0

echo "Testing a guard lets through exactly its share of a blow"
block:
  proc firstHit(percent: int16): int =
    let
      game = newArenaGame(2026, 4000, [FighterClass], [BarrowWardenSpecies])
      fighter = int32(FighterClass.ord)
      warden = int32(PartySize)
      home = game.world.actors[fighter].home
    game.placeActor(int(warden), int32(home.x), int32(home.z) - 1)
    game.world.rebuildClaims()
    game.world.actors[fighter].hp = 30_000
    game.world.actors[fighter].maxHp = 30_000
    game.world.actors[fighter].guardTicks = 1000
    game.world.actors[fighter].guardPercent = percent
    while game.world.actors[fighter].hp == 30_000:
      game.tickWorld(idle)
    30_000 - int(game.world.actors[fighter].hp)
  doAssert firstHit(50) == firstHit(100) div 2
  doAssert firstHit(GuardPercent) == firstHit(100) * 40 div 100

echo "Testing heat burns what stands near him and goes where he goes"
block:
  let
    game = newArenaGame(2026, 4000, [FighterClass],
      [BarrowWardenSpecies, BarrowWardenSpecies])
    fighter = int32(FighterClass.ord)
    near = int32(PartySize)
    far = near + 1
    home = game.world.actors[fighter].home
    x = int32(home.x)
    z = int32(home.z)
  game.placeActor(int(near), x, z - 1)
  game.placeActor(int(far), x - 6, z)
  game.world.rebuildClaims()
  game.world.rebuildVision()
  game.world.actors[fighter].hp = 30_000
  game.world.actors[fighter].maxHp = 30_000
  game.world.actors[fighter].cooldowns[int(Taunt)] = 30_000
  game.world.actors[fighter].cooldowns[int(BlazingBlade)] = 30_000
  for slot in [near, far]:
    game.world.actors[slot].hp = 30_000
    game.world.actors[slot].maxHp = 30_000
    game.world.actors[slot].staggerTicks = 30_000
  game.sendAt(fighter, near)
  doAssert game.world.actors[fighter].action == Heat
  doAssert game.world.actors[fighter].target == game.world.actors[fighter].id
  var
    hp = game.world.actors[near].hp
    burns = 0
    lit = 0
  for tick in 0 ..< 400:
    game.tickWorld(idle)
    if game.world.actors[fighter].heatTicks > 0:
      inc lit
    if game.world.actors[near].hp != hp:
      inc burns
      doAssert hp - game.world.actors[near].hp in 3 .. 4, "not a small burn"
      hp = game.world.actors[near].hp
  doAssert burns == HeatTicks div HeatPeriodTicks, "burned " & $burns
  doAssert lit == HeatTicks - 1
  doAssert game.world.actors[far].hp == 30_000, "it reached across the room"
  # Lit again beside the far one, the aura has come with him.
  game.placeActor(int(fighter), x - 5, z)
  game.world.rebuildClaims()
  game.world.actors[fighter].heatTicks = HeatPeriodTicks
  game.tickWorld(idle)
  doAssert game.world.actors[far].hp < 30_000
  doAssert game.world.actors[near].hp == hp

echo "Testing the fighter's skills go off as soon as they are ready"
block:
  let
    game = newArenaGame(2026, 12_000, [FighterClass], [BarrowWardenSpecies])
    fighter = int32(FighterClass.ord)
    warden = int32(PartySize)
  game.world.actors[warden].hp = 30_000
  game.world.actors[warden].maxHp = 30_000
  game.world.actors[fighter].hp = 30_000
  game.world.actors[fighter].maxHp = 30_000
  proc attack(game: Game, slot: int32) =
    game.sendAt(slot, warden)
  var
    casts: array[Ability, int]
    seen = NoAbility
  for tick in 0 ..< 1_500:
    game.tickWorld(attack)
    let hero = game.world.actors[fighter]
    if hero.action != seen:
      seen = hero.action
      inc casts[seen]
  doAssert casts[NoAbility] > 0
  for skill in HeroAbilities[FighterClass]:
    doAssert casts[skill] >= 3, $skill & " cast " & $casts[skill] & " times"

echo "Testing a pickup is instant, claims its item, and cools down"
block:
  let
    game = newArenaGame(2026, 4000, [FighterClass, RogueClass], [])
    fighter = int32(FighterClass.ord)
    rogue = int32(RogueClass.ord)
    home = game.world.actors[fighter].home
  doAssert game.world.actors[rogue].home.z == home.z + 2
  proc drop(kind: LootKind, x, z: int): int32 =
    result = game.world.nextItemId
    game.world.items.add Item(id: result, kind: kind, value: 10,
      weight: LootWeights[kind], tile: TileRef(
        level: home.level, x: uint8(int(home.x) + x), z: uint8(int(home.z) + z)))
    inc game.world.nextItemId
  proc pick(slot, id: int32): bool =
    game.applyHeroAction(slot, ReplayAction(
      heroId: game.world.actors[slot].id, kind: ActionPickupTarget, first: id))
  let
    between = drop(GoldPile, 0, 1)
    beside = drop(GoldPile, -1, 0)
    potion = drop(HealingPotionLoot, -1, 2)
  # Within reach of both heroes, the first to ask has it at once.
  doAssert pick(fighter, between)
  doAssert game.world.itemIndex(between) < 0
  doAssert game.world.actors[fighter].carriedValue == 10
  doAssert not game.world.actors[fighter].busy, "a pickup locked the hero"
  doAssert not pick(rogue, between), "a claimed item was taken twice"
  # The next one waits out the cooldown.
  var waited = 0
  while game.world.itemIndex(beside) >= 0:
    doAssert pick(fighter, beside)
    if game.world.itemIndex(beside) >= 0:
      game.tickWorld(idle)
      inc waited
  doAssert waited == Abilities[ChainAxe].cooldownTicks, "waited " & $waited
  doAssert game.world.actors[fighter].carriedValue == 20
  # Gear goes into the bag, and is gone from the floor for everyone else.
  doAssert pick(rogue, potion)
  let potionIndex = game.world.itemIndex(potion)
  doAssert game.world.items[potionIndex].carrier == game.world.actors[rogue].id
  doAssert game.world.actors[rogue].inventory[0] == potion
  doAssert game.nearestLoot(fighter) < 0

echo "Testing the druid's bar is what it fights with"
block:
  doAssert HeroAbilities[ClericClass] == [HammerAttack, Bloom, Entangle, SunOrb]
  doAssert ClassAttacks[ClericClass] == @[HammerAttack]
  doAssert ClassSkills[ClericClass] == @[Entangle, SunOrb]
  doAssert Abilities[HammerAttack].cooldownTicks == 0
  doAssert Abilities[Bloom].cooldownTicks == TickRate * 20
  doAssert Abilities[Entangle].cooldownTicks == TickRate * 15
  doAssert Abilities[SunOrb].cooldownTicks == TickRate * 20
  doAssert VineTicks == TickRate * 3
  # A disc of radius 1 takes in tiles within a tile and a half.
  doAssert Abilities[Entangle].shape == RoundArea and
    Abilities[Entangle].radiusTiles == 1

proc castAt(game: Game, slot: int32, ability: Ability, aim: TileRef) =
  ## Plays one ability through by hand at a tile, whatever the hero would
  ## pick, holding its aim there.
  game.world.actors[slot].action = ability
  game.world.actors[slot].actionTicks = 0
  game.world.actors[slot].target = game.world.actors[slot].id
  game.world.actors[slot].aim = aim
  while game.world.actors[slot].busy:
    game.tickWorld(idle)

echo "Testing vines slow what stands in them to a stop, then let go"
block:
  let
    game = newArenaGame(2026, 4000, [ClericClass],
      [BarrowWardenSpecies, BarrowWardenSpecies])
    druid = int32(ClericClass.ord)
    held = int32(PartySize)
    free = held + 1
    home = game.world.actors[druid].home
    x = int32(home.x)
    z = int32(home.z)
  game.placeActor(int(held), x - 5, z)
  game.placeActor(int(free), x - 5, z + 2)
  game.world.rebuildClaims()
  game.world.rebuildVision()
  for slot in [druid, held, free]:
    game.world.actors[slot].hp = 30_000
    game.world.actors[slot].maxHp = 30_000
  for slot in [held, free]:
    game.world.actors[slot].staggerTicks = 30_000
  let pace = game.world.actors[held].speed
  game.castAt(druid, Entangle, game.world.actors[held].home)
  doAssert game.world.vines.len == 1
  let patch = game.world.vines[0]
  doAssert patch.center == game.world.actors[held].home
  doAssert patch.side == HeroActor
  doAssert game.world.inVines(patch, game.world.actors[held])
  doAssert not game.world.inVines(patch, game.world.actors[free])
  doAssert not game.world.inVines(patch, game.world.actors[druid])
  # Each tick in the vines takes another share of its speed away.
  while not game.world.actors[held].rooted:
    let inside = game.world.actors[held].entangledTicks
    doAssert inside > 0
    doAssert game.world.actors[held].speed == max(pace *
      (100 * int32(VineRootTicks - inside) div int32(VineRootTicks)) div 100,
      1), "speed " & $game.world.actors[held].speed & " after " & $inside
    game.tickWorld(idle)
  doAssert game.world.tick - patch.sprouted == int32(VineRootTicks) - 1
  # Rooted, it stays put though nothing else holds it.
  game.world.actors[held].staggerTicks = 0
  let rootedAt = game.world.actors[held].body.pos
  while game.world.vines[0].holding(game.world.tick + 1):
    game.tickWorld(idle)
    doAssert game.world.actors[held].body.pos == rootedAt, "it walked off"
  doAssert game.world.actors[free].entangledTicks == 0
  doAssert game.world.actors[free].speed == pace
  # The vines let go after three seconds, and it walks again.
  game.tickWorld(idle)
  doAssert game.world.tick - patch.sprouted == int32(VineTicks)
  doAssert game.world.actors[held].entangledTicks == 0
  doAssert game.world.actors[held].speed == pace
  # Spent vines linger, holding nothing, while they wither away.
  doAssert game.world.vines.len == 1
  while game.world.tick - patch.sprouted < int32(VineTicks + VineWitherTicks):
    game.tickWorld(idle)
    doAssert game.world.actors[held].entangledTicks == 0
  doAssert game.world.vines.len == 0
  doAssert game.world.actors[held].body.pos != rootedAt, "it never got free"

echo "Testing the slower sun orb damages and consumes vines only on arrival"
block:
  let
    game = newArenaGame(2026, 4000, [ClericClass], [BarrowWardenSpecies])
    druid = int32(ClericClass.ord)
    victim = int32(PartySize)
    home = game.world.actors[druid].home
    aim = TileRef(level: home.level, x: home.x - 3, z: home.z)
  game.placeActor(int(victim), int32(aim.x), int32(aim.z))
  game.world.rebuildClaims()
  game.world.rebuildVision()
  for slot in [druid, victim]:
    game.world.actors[slot].hp = 30_000
    game.world.actors[slot].maxHp = 30_000
  game.world.actors[victim].staggerTicks = 30_000
  game.castAt(druid, Entangle, aim)
  let caster = game.world.actors[druid]
  caster.action = SunOrb
  caster.actionTicks = 0
  caster.target = caster.id
  caster.aim = aim
  # It launches on anticipation + 1. The original five flight ticks now
  # take ten: no hit or consumed vines may occur before that arrival.
  let arrival = int(Abilities[SunOrb].anticipationTicks) + 1 + 10
  for _ in 1 ..< arrival:
    game.tickWorld(idle)
    doAssert game.world.actors[victim].hp == 30_000, "orb hit before arrival"
    doAssert game.world.vines[0].holding(game.world.tick), "vines consumed before arrival"
    doAssert game.world.vines[0].burned == 0
  game.tickWorld(idle)
  doAssert game.world.actors[victim].hp < 30_000, "orb did not hit on arrival"
  doAssert game.world.vines[0].burned == game.world.tick
  doAssert not game.world.vines[0].holding(game.world.tick)
  doAssert game.world.actors[victim].entangledTicks == 0
  for _ in 1 .. int(VineBurnTicks):
    game.tickWorld(idle)
  doAssert game.world.vines.len == 0, "consumed vines remained in the world"

echo "Testing a sun orb ignites only a patch it lands inside, burning all of it"
block:
  let
    game = newArenaGame(2026, 4000, [ClericClass],
      [BarrowWardenSpecies, BarrowWardenSpecies, BarrowWardenSpecies])
    druid = int32(ClericClass.ord)
    vines = int32(PartySize)  # in the vines only
    both = vines + 1          # in the vines and the orb's blast
    blast = vines + 2         # in the orb's blast only
    home = game.world.actors[druid].home
    x = int32(home.x)
    z = int32(home.z)
  game.placeActor(int(vines), x - 5, z + 1)
  game.placeActor(int(both), x - 5, z - 1)
  game.placeActor(int(blast), x - 5, z - 2)
  game.world.rebuildClaims()
  game.world.rebuildVision()
  game.world.actors[druid].hp = 30_000
  game.world.actors[druid].maxHp = 30_000
  for slot in [vines, both, blast]:
    game.world.actors[slot].hp = 30_000
    game.world.actors[slot].maxHp = 30_000
    game.world.actors[slot].staggerTicks = 30_000
  proc tile(dx, dz: int32): TileRef =
    TileRef(level: home.level, x: uint8(x + dx), z: uint8(z + dz))
  # An orb that falls short of the vines leaves them be.
  game.castAt(druid, Entangle, tile(-5, 0))
  game.castAt(druid, SunOrb, tile(-5, -3))
  doAssert game.world.vines[0].holding(game.world.tick)
  doAssert game.world.actors[vines].hp == 30_000
  doAssert game.world.actors[blast].hp < 30_000
  # A ground landing beside the patch must not ignite it, even when
  # the orb's normal damage area overlaps the vines.
  for slot in [vines, both, blast]:
    game.world.actors[slot].hp = 30_000
  game.castAt(druid, SunOrb, tile(-5, -2))
  doAssert game.world.vines[0].holding(game.world.tick)
  doAssert game.world.vines[0].burned == 0
  doAssert game.world.actors[vines].hp == 30_000
  doAssert game.world.actors[both].hp < 30_000
  doAssert game.world.actors[blast].hp < 30_000
  # A landing inside the near edge ignites the whole patch, including
  # the far edge outside the orb's normal damage area.
  for slot in [vines, both, blast]:
    game.world.actors[slot].hp = 30_000
  game.world.vines.setLen(0)
  game.castAt(druid, Entangle, tile(-5, 0))
  doAssert game.world.actors[vines].entangledTicks > 0
  let orb = Abilities[SunOrb]
  game.castAt(druid, SunOrb, tile(-5, -1))
  let patch = game.world.vines[0]
  doAssert patch.burned > 0 and patch.burnedFrom == tile(-5, -1)
  doAssert not patch.holding(game.world.tick)
  doAssert game.world.actors[vines].entangledTicks == 0, "still held"
  proc lost(slot: int32): int = 30_000 - int(game.world.actors[slot].hp)
  doAssert lost(vines) in int(orb.damage) .. int(orb.damage + orb.spread)
  doAssert lost(blast) in int(orb.damage) .. int(orb.damage + orb.spread)
  doAssert lost(both) in 2 * int(orb.damage) ..
    2 * int(orb.damage + orb.spread), "lost " & $lost(both)
  # Burned vines hold nothing while they burn away.
  while game.world.vines.len > 0:
    doAssert game.world.actors[vines].entangledTicks == 0
    game.tickWorld(idle)
  doAssert game.world.tick - patch.burned == int32(VineBurnTicks)

echo "Testing the druid's skills go off as soon as they are ready"
block:
  let
    game = newArenaGame(2026, 12_000, [ClericClass], [BarrowWardenSpecies])
    druid = int32(ClericClass.ord)
    warden = int32(PartySize)
  game.world.actors[warden].hp = 30_000
  game.world.actors[warden].maxHp = 30_000
  game.world.actors[druid].hp = 30_000
  game.world.actors[druid].maxHp = 30_000
  game.world.actors[druid].mana = 30_000
  game.world.actors[druid].maxMana = 30_000
  proc attack(game: Game, slot: int32) =
    game.sendAt(slot, warden)
  var
    casts: array[Ability, int]
    order: seq[Ability]
    seen = NoAbility
  for tick in 0 ..< 1_500:
    game.tickWorld(attack)
    let hero = game.world.actors[druid]
    if hero.action != seen:
      seen = hero.action
      inc casts[seen]
      if seen != NoAbility:
        order.add seen
      if seen == Entangle:
        doAssert hero.target == game.world.actors[warden].id,
          "the vines were not aimed at the foe"
  doAssert order[0 .. 1] == @[Entangle, SunOrb]
  doAssert casts[Entangle] >= 3, "entangled " & $casts[Entangle] & " times"
  doAssert casts[SunOrb] >= 2, "orbed " & $casts[SunOrb] & " times"
  doAssert casts[HammerAttack] > 0

proc druidArena(foes: int): (Game, int32) =
  ## The druid alone with `foes` Dustlings that do not die, its sun orb put
  ## away, everyone placed by hand.
  var monsters: seq[Species]
  for _ in 0 ..< foes:
    monsters.add DustlingSpecies
  let
    game = newArenaGame(2026, 4000, [ClericClass], monsters)
    druid = int32(ClericClass.ord)
  for slot in 0 ..< game.world.actors.len:
    if game.world.actors[slot].alive:
      game.world.actors[slot].hp = 30_000
      game.world.actors[slot].maxHp = 30_000
  game.world.actors[druid].cooldowns[int(SunOrb)] = 30_000
  (game, druid)

echo "Testing entangle aims at the middle of a pack, ahead of it as it walks"
block:
  let
    (game, druid) = druidArena(3)
    home = game.world.actors[druid].home
    x = int32(home.x)
    z = int32(home.z)
    target = int32(PartySize) + 1
  for index in 0'i32 .. 2:
    game.placeActor(int(PartySize + index), x - 7, z - 1 + index)
  game.world.rebuildClaims()
  game.world.rebuildVision()
  # Standing still, the pack's middle is the middle one.
  game.sendAt(druid, target)
  doAssert game.world.actors[druid].action == Entangle
  doAssert game.world.actors[druid].aim == game.world.actors[target].home
  game.world.actors[druid].action = NoAbility
  # Walking at the druid, the vines go down where the pack will be once
  # they have landed and are half way to rooting it.
  for index in 0'i32 .. 2:
    let slot = PartySize + index
    doAssert game.world.stepToward(slot, TileRef(level: home.level,
      x: uint8(x - 1), z: uint8(z - 1 + index)))
  game.sendAt(druid, target)
  doAssert game.world.actors[druid].action == Entangle
  let
    aim = game.world.actors[druid].aim
    ahead = Abilities[Entangle].impactTicks + VineLeadTicks
    tiles = ahead * SpeciesSpeeds[DustlingSpecies] div PhaseUnits
  doAssert aim.z == home.z, "the aim left the pack's middle row"
  doAssert int32(aim.x) - (x - 7) in tiles - 1 .. tiles + 1,
    "led by " & $(int32(aim.x) - (x - 7)) & " tiles, not about " & $tiles

echo "Testing the druid gives ground to a crowd and stays out of one"
block:
  let
    (game, druid) = druidArena(3)
    home = game.world.actors[druid].home
    x = int32(home.x) - 3
    z = int32(home.z)
  proc stand(column: int32, foes: int) =
    ## Puts the first `foes` Dustlings in a column, held there, and the
    ## rest out of the way, well clear of both the druid and the column.
    for index in 0'i32 .. 2:
      let slot = int(PartySize + index)
      if index < foes:
        game.placeActor(slot, column, z - 1 + index)
      else:
        game.placeActor(slot, x - 5, z + 1 + index)
      game.world.actors[slot].staggerTicks = 30_000
    game.world.actors[druid].action = NoAbility
    game.world.clearPath(druid)
    game.placeActor(druid, x, z)
    game.world.actors[druid].cooldowns[int(Entangle)] = 30_000
    game.world.rebuildClaims()
    game.world.rebuildVision()
  proc backsOff(): bool =
    ## Whether the druid is walking somewhere farther from every Dustling.
    let goal = game.world.pathGoal(druid)
    if game.world.actors[druid].busy or not game.world.actors[druid].moving:
      return false
    for index in 0'i32 .. 2:
      let foe = game.world.actors[PartySize + index].home
      if tileDistance(goal, foe) < tileDistance(game.world.actors[druid].home,
          foe):
        return false
    true
  # Three closing in: it backs off rather than swing.
  stand(x - 2, 3)
  game.sendAt(druid, PartySize)
  doAssert backsOff(), "it stood its ground against three"
  # Two at its elbow are already too many.
  stand(x - 1, 2)
  game.sendAt(druid, PartySize)
  doAssert backsOff(), "it stood its ground against two"
  # Three at its elbow hem it in: pushing at them would only stop it
  # swinging, so it swings.
  stand(x - 1, 3)
  game.sendAt(druid, PartySize)
  doAssert game.world.actors[druid].action == HammerAttack
  # One alone at its elbow: it swings.
  stand(x - 1, 1)
  game.sendAt(druid, PartySize)
  doAssert game.world.actors[druid].action == HammerAttack
  # Three together further off: it holds rather than walk in among them.
  stand(x - 5, 3)
  game.sendAt(druid, PartySize)
  doAssert not game.world.actors[druid].busy
  doAssert not game.world.actors[druid].moving, "it walked into a crowd"
  # One alone over there: it goes and fights it.
  stand(x - 5, 1)
  game.sendAt(druid, PartySize)
  doAssert game.world.actors[druid].moving

echo "Testing the druid gets clear, then throws its sun orb into its vines"
block:
  let
    (game, druid) = druidArena(4)
    home = game.world.actors[druid].home
    x = int32(home.x) - 2
    z = int32(home.z)
    loner = int32(PartySize) + 3
  proc tile(dx, dz: int32): TileRef =
    TileRef(level: home.level, x: uint8(x + dx), z: uint8(z + dz))
  proc ready(held: int, sprouted: int32, chaser = tile(-5, 4)) =
    ## Puts `held` Dustlings rooted in a patch of vines four tiles off, the
    ## rest well away, one more at `chaser`, and readies the druid's orb.
    game.placeActor(int(druid), x, z)
    for index in 0'i32 .. 2:
      let slot = int(PartySize + index)
      if index < held:
        game.placeActor(slot, x - 4, z - 1 + index)
        game.world.actors[slot].entangledTicks = VineRootTicks
      else:
        game.placeActor(slot, x - 4, z - 3 - index)
        game.world.actors[slot].entangledTicks = 0
      game.world.actors[slot].staggerTicks = 30_000
    game.placeActor(int(loner), int32(chaser.x), int32(chaser.z))
    game.world.actors[loner].staggerTicks = 30_000
    game.world.vines.setLen(0)
    game.world.vines.add VinePatch(side: HeroActor, center: tile(-4, 0),
      sprouted: sprouted)
    game.world.actors[druid].action = NoAbility
    game.world.clearPath(druid)
    game.world.actors[druid].cooldowns[int(SunOrb)] = 0
    game.world.actors[druid].cooldowns[int(Entangle)] = 30_000
    game.world.rebuildClaims()
    game.world.rebuildVision()
  # Three held and nothing on its heels: the orb goes into the middle of
  # the vines, not at the Dustling the druid was after.
  ready(3, game.world.tick)
  game.sendAt(druid, loner)
  doAssert game.world.actors[druid].action == SunOrb
  doAssert game.world.actors[druid].aim == tile(-4, 0)
  while game.world.actors[druid].busy:
    game.tickWorld(idle)
  doAssert game.world.vines[0].burned > 0, "the vines did not burn"
  # One on its heels: it gets clear first, staying in the orb's reach.
  ready(3, game.world.tick, chaser = tile(-1, 2))
  game.sendAt(druid, loner)
  doAssert not game.world.actors[druid].busy, "it threw with a foe on it"
  doAssert game.world.actors[druid].moving
  doAssert tileDistance(game.world.pathGoal(druid), tile(-4, 0)) <=
    int32(Abilities[SunOrb].rangeTiles)
  # Two held: it keeps the orb for the vines rather than throw it at its
  # target, while more may still walk in.
  ready(2, game.world.tick)
  game.sendAt(druid, loner)
  doAssert game.world.actors[druid].action != SunOrb
  # Vines about to let go take the orb now, however few they hold and
  # whatever is on its heels.
  ready(2, game.world.tick + int32(Abilities[SunOrb].impactTicks) -
    int32(VineTicks) + RepositionTicks, chaser = tile(-1, 2))
  game.sendAt(druid, loner)
  doAssert game.world.actors[druid].action == SunOrb
  doAssert game.world.actors[druid].aim == tile(-4, 0)
  # Vines that will have let go before it lands are no use: at its target.
  ready(3, game.world.tick - int32(VineTicks) +
    int32(Abilities[SunOrb].impactTicks))
  game.sendAt(druid, loner)
  doAssert game.world.actors[druid].action == SunOrb
  doAssert game.world.actors[druid].aim == game.world.actors[loner].home
