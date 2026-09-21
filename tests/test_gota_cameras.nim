import
  vmath,
  polyworld/directors,
  ../examples/gods_of_the_arena/[cameras, sim]

proc subjects(world: World, hidden = 0'i32): seq[Subject] =
  ## Builds camera subjects without starting the renderer or simulation.
  for hero in world.heroes:
    result.add Subject(
      id: hero.id,
      owner: int32(hero.team),
      position: vec3(hero.position.x.float32, 0, hero.position.z.float32),
      visible: hero.id != hidden,
      alive: hero.hp > 0 and hero.state != Dying,
      hp: hero.hp,
      maxHp: 100,
      complete: true,
      combatScore: 100
    )
  let livingHeroes = prioritizeHeroes(world, result)
  result.add Subject(
    id: 3,
    owner: 0,
    position: vec3(50000, 0, 50000),
    visible: true,
    alive: true,
    hp: 100,
    maxHp: 100,
    complete: true,
    idleScore: 22,
    combatScore: 70,
    combatOnly: livingHeroes
  )

proc step(director: var Director, dt = 0.0'f) =
  ## Advances camera time without overview panels or a running game.
  director.advance(dt, true, false, true, false, 40)

echo "Testing idle GotA shots prefer heroes nearest the enemy god"
block:
  let world = World(
    forts: [
      Fort(team: RedTeam, center: WorldPoint(x: 0, z: 0)),
      Fort(team: BlueTeam, center: WorldPoint(x: 100000, z: 100000))
    ],
    heroes: @[
      Hero(id: 1, team: RedTeam, hp: 100,
        position: WorldPoint(x: 70000, z: 70000)),
      Hero(id: 2, team: BlueTeam, hp: 100,
        position: WorldPoint(x: 10000, z: 10000))
    ]
  )
  var director = initDirector()
  director.refresh(world.subjects())
  director.step()
  doAssert director.subject.id == 2
  world.heroes[0].position = WorldPoint(x: 99000, z: 99000)
  director.refresh(world.subjects())
  director.step(9)
  doAssert director.subject.id == 1

  echo "Testing creep spawns cannot steal idle shots, but combat can"
  let creep = director.subjects[2]
  director.noteEvent(creep, ProgressEvent, 38)
  director.step(9)
  doAssert director.subject.id == 1
  director.noteEvent(creep, AttackEvent, 70)
  director.step(9)
  doAssert director.subject.id == 3
  director.step(2.1)
  doAssert director.subject.id == 1

  echo "Testing creep fallback only while all heroes are dead"
  world.heroes[0].hp = 0
  world.heroes[1].state = Dying
  director.refresh(world.subjects())
  director.step()
  doAssert director.subject.id == 3
  world.heroes[1].state = Marching
  director.refresh(world.subjects())
  director.step()
  doAssert director.subject.id == 2

  echo "Testing hidden heroes do not expose themselves or enable idle creeps"
  director.refresh(world.subjects(hidden = 2))
  director.step()
  doAssert not director.locked
  doAssert not director.finalResults
  world.heroes[0].hp = 100
  director.refresh(world.subjects(hidden = 1))
  director.step()
  doAssert director.subject.id == 2

  echo "Testing GotA camera reset restores the preferred hero"
  director.reset()
  director.refresh(world.subjects())
  director.step()
  doAssert director.subject.id == 1
