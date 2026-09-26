import
  std/algorithm,
  ../examples/gods_of_the_arena/[content, maps, observations, sim]

proc observationWorld(): World =
  ## Builds spell observations with independent caster and warning visibility.
  result = World(
    tick: 20,
    heroes: @[
      Hero(id: 100, team: RedTeam),
      Hero(id: 101, team: RedTeam),
      Hero(id: 105, team: BlueTeam, position: WorldPoint(x: WorldScale * 4))
    ]
  )
  for team in Team:
    result.teamVisible[team.ord] = newSeq[uint8](mapTiles() * mapTiles())

proc reveal(world: World, team: Team, position: WorldPoint) =
  ## Reveals exactly one tile to keep the test's fog boundaries explicit.
  let
    x = mapCoordinate(position.x)
    z = mapCoordinate(position.z)
  world.teamVisible[team.ord][int(z) * mapTiles() + int(x)] = 255

proc objects(world: World, heroId: int32): seq[WorldObject] =
  for i in 0 ..< world.worldObjectCount(heroId):
    var value: WorldObject
    doAssert world.worldObjectAt(heroId, i, value)
    result.add value

echo "Testing team observations stay frozen and refresh for the next frame"
block:
  let world = observationWorld()
  world.heroes[0].hp = 100
  let
    red = world.objects(100)
    blue = world.objects(105)
  doAssert red != blue
  doAssert world.objects(100) == red
  world.heroes[0].hp = 75
  doAssert world.objects(100) == red
  world.heroes[0].hp = 100
  doAssert world.freezeObservations()
  doAssert world.objects(100) == red
  world.heroes[0].hp = 50
  doAssert world.objects(105) == blue
  doAssert world.objects(101) == red
  world.thawObservations()
  doAssert world.freezeObservations()
  let next = world.objects(101)
  doAssert next != red
  doAssert world.objects(100) == next
  world.thawObservations()

proc warning(heroId: int32, x = 0'i32): SpellCast =
  ## Creates a delayed spell whose aim position differs from its origin.
  SpellCast(
    heroId: heroId,
    ability: MeteorStrike,
    origin: WorldPoint(x: WorldScale * 4),
    position: WorldPoint(x: x),
    started: 10,
    impact: 30,
    ends: 42
  )

proc checkWarningFrames() =
  ## Verifies frozen warning ordering without mutating live spell storage.
  var expected: array[2, seq[SpellCast]]
  for reversed in [false, true]:
    for rotated in [false, true]:
      let world = observationWorld()
      world.casts = @[
        warning(101, WorldScale * 8),
        warning(105, WorldScale * 5),
        warning(105, WorldScale * 3)
      ]
      for cells in world.teamVisible.mitems:
        for cell in cells.mitems:
          cell = 255
      if reversed:
        world.casts.reverse()
      if rotated:
        for hero in world.heroes:
          hero.team = if hero.team == RedTeam: BlueTeam else: RedTeam
          hero.position.x = -hero.position.x
          hero.position.z = -hero.position.z
        for spell in world.casts.mitems:
          spell.origin.x = -spell.origin.x
          spell.origin.z = -spell.origin.z
          spell.position.x = -spell.position.x
          spell.position.z = -spell.position.z
      let original = world.casts
      doAssert world.freezeObservations()
      doAssert not world.freezeObservations()
      doAssert world.casts == original, "Sorting changed live cast storage."
      for index, observer in [100'i32, 105'i32]:
        var actual: seq[SpellCast]
        for i in 0 ..< world.visibleSpellCount(observer):
          var spell: SpellCast
          doAssert world.visibleSpellAt(observer, i, spell)
          if rotated:
            spell.origin.x = -spell.origin.x
            spell.origin.z = -spell.origin.z
            spell.position.x = -spell.position.x
            spell.position.z = -spell.position.z
          actual.add spell
        if not reversed and not rotated:
          expected[index] = actual
        else:
          doAssert actual == expected[index]
      world.casts.setLen(0)
      doAssert world.visibleSpellCount(100) == 3
      world.thawObservations()
      doAssert world.visibleSpellCount(100) == 0

echo "Testing allied spells and visible enemy warnings use team vision"
block:
  let world = observationWorld()
  world.casts = @[
    warning(101, WorldScale * 8),
    warning(105),
    warning(105, WorldScale * 2)
  ]
  doAssert world.visibleSpellCount(100) == 1
  world.reveal(RedTeam, WorldPoint())
  doAssert world.visibleSpellCount(100) == 2
  doAssert world.visibleSpellCount(101) == 2
  doAssert world.visibleSpellCount(105) == 2
  var spell: SpellCast
  doAssert world.visibleSpellAt(100, 0, spell)
  doAssert spell == world.casts[0]
  doAssert world.visibleSpellCasterId(100, spell) == 101
  doAssert world.visibleSpellAt(100, 1, spell)
  doAssert spell == world.casts[1]
  doAssert spell.position != spell.origin
  doAssert world.visibleSpellCasterId(100, spell) == 0
  world.reveal(RedTeam, world.heroes[2].position)
  doAssert world.visibleSpellCasterId(100, spell) == 105
  doAssert world.visibleSpellCount(100) == 2

echo "Testing pending warning lifetime includes impact but excludes afterglow"
block:
  let world = observationWorld()
  world.casts = @[warning(101)]
  world.tick = 9
  doAssert world.visibleSpellCount(100) == 0
  world.tick = 10
  doAssert world.visibleSpellCount(100) == 1
  world.tick = 30
  doAssert world.visibleSpellCount(100) == 1
  world.casts[0].resolved = true
  doAssert world.visibleSpellCount(100) == 0
  doAssert world.visibleSpellCasterId(100, world.casts[0]) == 0
  world.casts[0].resolved = false
  world.tick = 31
  doAssert world.visibleSpellCount(100) == 0

echo "Testing projectile warnings and already resolved instant spells"
block:
  let world = observationWorld()
  var
    projectile = warning(101)
    instant = warning(101)
  projectile.ability = FrostLance
  instant.ability = LionGuard
  instant.started = world.tick
  instant.impact = world.tick
  instant.resolved = true
  world.casts = @[instant, projectile]
  var spell: SpellCast
  doAssert world.visibleSpellCount(100) == 1
  doAssert world.visibleSpellAt(100, 0, spell)
  doAssert spell.ability == FrostLance
  doAssert spell.impact == 30

echo "Testing spell enumeration rejects invalid observers, indices and casters"
block:
  let world = observationWorld()
  world.casts = @[warning(101), warning(999)]
  var spell = warning(105)
  let previous = spell
  doAssert world.visibleSpellCount(100) == 1
  doAssert not world.visibleSpellAt(100, -1, spell)
  doAssert not world.visibleSpellAt(100, 1, spell)
  doAssert not world.visibleSpellAt(100, int.high, spell)
  doAssert spell == previous
  doAssert world.visibleSpellCount(999) == 0
  doAssert not world.visibleSpellAt(999, 0, spell)
  doAssert world.visibleSpellCasterId(999, world.casts[0]) == 0
  doAssert world.visibleSpellCasterId(100, world.casts[1]) == 0
  let absent: World = nil
  doAssert absent.visibleSpellCount(100) == 0
  doAssert not absent.visibleSpellAt(100, 0, spell)
  doAssert absent.visibleSpellCasterId(100, world.casts[0]) == 0

echo "Testing warning frames ignore cast storage order and rotate with teams"
checkWarningFrames()
