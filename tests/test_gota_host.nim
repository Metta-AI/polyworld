import
  std/[os, tempfiles],
  polyworld/[basic, cli],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

const ObservationProgram = """
dim ids(63)
dim levels(63)
dim mana(63)
dim facingX(63)
dim facingY(63)
dim targets(63)
dim velX(63)
dim velY(63)
dim items(383)
dim counts(383)
dim spells(15)
dim casters(15)
dim spellXs(15)
dim spellYs(15)
dim impacts(15)
scale = worldScale
ticksPerSecond = tickRate
speed = selfMoveSpeed
attackRange = selfAttackRange
damage = selfAttackDamage
target = selfTarget
cooldown = selfAttackCooldown
landed = selfAttacksLanded
level = selfLevel
myMana = selfMana
objects = objectCount()
i = 0
while i < objects
  ids(i) = objectId(i)
  levels(i) = objectLevel(i)
  mana(i) = objectMana(i)
  facingX(i) = objectFacingX(i)
  facingY(i) = objectFacingY(i)
  targets(i) = objectTarget(i)
  velX(i) = objectVelX(i)
  velY(i) = objectVelY(i)
  if ids(i) = selfId then
    me = i
  end if
  slot = 0
  while slot < 6
    items(i * 6 + slot) = objectItemId(i, slot)
    counts(i * 6 + slot) = objectItemCount(i, slot)
    slot = slot + 1
  wend
  i = i + 1
wend
invalidObjects = objectLevel(-1) = 0 and objectLevel(objects) = 0
invalidObjects = invalidObjects and objectMana(-1) = 0
invalidObjects = invalidObjects and objectMana(objects) = 0
invalidObjects = invalidObjects and objectItemId(-1, 0) = 0
invalidObjects = invalidObjects and objectItemCount(objects, 0) = 0
invalidObjects = invalidObjects and objectFacingX(-1) = 0
invalidObjects = invalidObjects and objectFacingY(objects) = 0
invalidObjects = invalidObjects and objectTarget(-1) = 0
invalidObjects = invalidObjects and objectTarget(2147483647) = 0
invalidObjects = invalidObjects and objectVelX(-1) = 0
invalidObjects = invalidObjects and objectVelY(objects) = 0
invalidSlots = objectItemId(me, -1) = 0 and objectItemId(me, 6) = 0
invalidSlots = invalidSlots and objectItemCount(me, -1) = 0
invalidSlots = invalidSlots and objectItemCount(me, 2147483647) = 0
warnings = spellCount()
i = 0
while i < warnings
  spells(i) = spellAbility(i)
  casters(i) = spellCasterId(i)
  spellXs(i) = spellX(i)
  spellYs(i) = spellY(i)
  impacts(i) = spellImpactTick(i)
  i = i + 1
wend
invalidSpells = spellAbility(-1) = -1 and spellAbility(warnings) = -1
invalidSpells = invalidSpells and spellCasterId(-1) = 0
invalidSpells = invalidSpells and spellCasterId(warnings) = 0
invalidSpells = invalidSpells and spellX(-1) = 0
invalidSpells = invalidSpells and spellX(warnings) = 0
invalidSpells = invalidSpells and spellY(-1) = 0
invalidSpells = invalidSpells and spellY(warnings) = 0
invalidSpells = invalidSpells and spellImpactTick(-1) = 0
invalidSpells = invalidSpells and spellImpactTick(warnings) = 0
"""

proc objectIndex(vm: HeroVm, id: int32): int32 =
  ## Finds a stable object ID in the values actually observed by BASIC.
  for index in 0 ..< vm.runtime.getGlobal("objects"):
    if vm.runtime.getArray("ids", index) == id:
      return index
  -1

proc reveal(world: World, position: WorldPoint) =
  ## Reveals exactly one tile to the red observer's team.
  let
    x = mapCoordinate(position.x)
    z = mapCoordinate(position.z)
  world.teamVisible[RedTeam.ord][int(z) * mapTiles() + int(x)] = 255

proc observe(game: Game, vm: HeroVm) =
  ## Runs the host through the VM and checks all invalid-input results.
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("invalidObjects") != 0
  doAssert vm.runtime.getGlobal("invalidSlots") != 0
  doAssert vm.runtime.getGlobal("invalidSpells") != 0

proc checkHostObservations() =
  ## Checks the complete observation surface through successive real VM turns.
  let
    directory = createTempDir("gota-host-", "")
    path = directory / "observations.bas"
    game = newGame(generateMap(54), 240, 10, false, ReplayData())
    world = game.world
    hero = world.heroes[0]
    ally = world.heroes[1]
    enemy = world.heroes[5]
    hidden = world.heroes[6]
  defer:
    removeDir(directory)
  writeFile(path, ObservationProgram)
  game.loadBots([BotGroup(path: path, count: 10)])
  let vm = game.heroVms[0]
  for i in 1 ..< game.heroVms.len:
    game.heroVms[i] = nil
  world.tick = 100
  for team in Team:
    for cell in world.teamVisible[team.ord].mitems:
      cell = 0
  hero.class = VanguardKnight
  hero.level = 3
  hero.inventory[0] = RangerBoots
  hero.itemCounts[0] = 1
  hero.inventory[1] = CrimsonDagger
  hero.itemCounts[1] = 1
  hero.inventory[2] = ManaPotion
  hero.itemCounts[2] = 3
  hero.refreshHeroStats()
  hero.mana = 47
  hero.position = WorldPoint()
  hero.facing = heading(WorldScale * 3, -WorldScale * 4)
  hero.velocity = heading(1234, -5678)
  hero.attackObjectId = enemy.id
  hero.swingTicks = 3
  hero.damageLanded = false
  hero.attacksLanded = 17
  ally.position = WorldPoint(x: WorldScale * 8)
  ally.attackObjectId = hidden.id
  enemy.position = WorldPoint(x: WorldScale)
  enemy.level = 7
  enemy.refreshHeroStats()
  enemy.mana = 11
  enemy.inventory[5] = VitalityElixir
  enemy.itemCounts[5] = 2
  enemy.facing = heading(0, WorldScale * 2)
  enemy.velocity = heading(-789, 234)
  enemy.attackObjectId = hero.id
  hidden.position = WorldPoint(x: WorldScale * 6)
  world.towers = @[
    Tower(
      id: 10, team: RedTeam, hp: 900, maxHp: 900,
      facing: heading(-WorldScale * 4, 0), targetId: enemy.id
    )
  ]
  world.footmen = @[
    Footman(
      id: 1000, team: BlueTeam, hp: 60, position: enemy.position,
      facing: heading(0, -WorldScale * 12),
      velocity: heading(321, 789), targetHeroId: hero.id
    )
  ]
  world.reveal(hero.position)
  world.reveal(enemy.position)
  world.casts = @[
    SpellCast(
      ability: HealingBloom, heroId: ally.id, position: ally.position,
      started: 90, impact: 120, ends: 132
    ),
    SpellCast(
      ability: MeteorStrike, heroId: enemy.id, position: hero.position,
      started: 90, impact: 130, ends: 142
    ),
    SpellCast(
      ability: FrostLance, heroId: hidden.id, position: hero.position,
      started: 90, impact: 140, ends: 152
    ),
    SpellCast(
      ability: ArcaneMeteor, heroId: hidden.id, position: hidden.position,
      started: 90, impact: 140, ends: 152
    ),
    SpellCast(
      ability: LionGuard, heroId: hero.id, position: hero.position,
      started: 100, impact: 100, ends: 112, resolved: true
    )
  ]

  echo "Testing object and self observations through a real BASIC VM"
  game.observe(vm)
  let
    ownIndex = vm.objectIndex(hero.id)
    enemyIndex = vm.objectIndex(enemy.id)
    allyIndex = vm.objectIndex(ally.id)
    towerIndex = vm.objectIndex(10)
    fortIndex = vm.objectIndex(world.forts[RedTeam.ord].id)
    creepIndex = vm.objectIndex(1000)
    windup = heroAttackTicks(hero.class) * 45 div 100
  doAssert ownIndex >= 0 and enemyIndex >= 0 and allyIndex >= 0
  doAssert towerIndex >= 0 and fortIndex >= 0 and creepIndex >= 0
  doAssert vm.objectIndex(hidden.id) == -1
  doAssert vm.runtime.getGlobal("scale") == 60_000
  doAssert vm.runtime.getGlobal("ticksPerSecond") == 24
  doAssert vm.runtime.getGlobal("speed") ==
    heroMovePerTick(VanguardKnight, 3) + RangerBoots.itemSpec.movePerTick
  doAssert vm.runtime.getGlobal("attackRange") ==
    heroAttackRange(VanguardKnight)
  doAssert vm.runtime.getGlobal("damage") ==
    heroDamage(VanguardKnight, 3) + CrimsonDagger.itemSpec.damage
  doAssert vm.runtime.getGlobal("target") == enemy.id
  doAssert vm.runtime.getGlobal("cooldown") == windup - 3
  doAssert vm.runtime.getGlobal("landed") == 17
  doAssert vm.runtime.getArray("levels", ownIndex) == 3
  doAssert vm.runtime.getArray("levels", enemyIndex) == 7
  doAssert vm.runtime.getArray("mana", ownIndex) == 47
  doAssert vm.runtime.getArray("mana", enemyIndex) == 11
  doAssert vm.runtime.getArray("items", ownIndex * 6) == RangerBoots.ord
  doAssert vm.runtime.getArray("counts", ownIndex * 6) == 1
  doAssert vm.runtime.getArray("items", ownIndex * 6 + 2) == ManaPotion.ord
  doAssert vm.runtime.getArray("counts", ownIndex * 6 + 2) == 3
  doAssert vm.runtime.getArray("items", enemyIndex * 6 + 5) ==
    VitalityElixir.ord
  doAssert vm.runtime.getArray("counts", enemyIndex * 6 + 5) == 2
  doAssert abs(vm.runtime.getArray("facingX", ownIndex) - 36_000) <= 2
  doAssert abs(vm.runtime.getArray("facingY", ownIndex) + 48_000) <= 2
  doAssert vm.runtime.getArray("facingX", enemyIndex) == 0
  doAssert vm.runtime.getArray("facingY", enemyIndex) == WorldScale
  doAssert vm.runtime.getArray("velX", ownIndex) == 1234
  doAssert vm.runtime.getArray("velY", ownIndex) == -5678
  doAssert vm.runtime.getArray("velX", enemyIndex) == -789
  doAssert vm.runtime.getArray("velY", enemyIndex) == 234
  doAssert vm.runtime.getArray("targets", ownIndex) == enemy.id
  doAssert vm.runtime.getArray("targets", enemyIndex) == hero.id
  doAssert vm.runtime.getArray("targets", allyIndex) == 0
  doAssert vm.runtime.getArray("targets", towerIndex) == enemy.id
  doAssert vm.runtime.getArray("targets", creepIndex) == hero.id
  doAssert vm.runtime.getArray("facingX", towerIndex) == -WorldScale
  doAssert vm.runtime.getArray("facingY", creepIndex) == -WorldScale
  doAssert vm.runtime.getArray("velX", creepIndex) == 321
  doAssert vm.runtime.getArray("velY", creepIndex) == 789
  for index in [fortIndex, towerIndex, creepIndex]:
    doAssert vm.runtime.getArray("levels", index) == 0
    doAssert vm.runtime.getArray("mana", index) == 0
    for slot in 0'i32 ..< InventorySlots.int32:
      doAssert vm.runtime.getArray("items", index * 6 + slot) == 0
      doAssert vm.runtime.getArray("counts", index * 6 + slot) == 0
  for index in [fortIndex, towerIndex]:
    doAssert vm.runtime.getArray("velX", index) == 0
    doAssert vm.runtime.getArray("velY", index) == 0
  doAssert vm.runtime.getArray("facingX", fortIndex) == 0
  doAssert vm.runtime.getArray("facingY", fortIndex) == 0
  doAssert vm.runtime.getArray("targets", fortIndex) == 0

  echo "Testing visible warnings preserve coordinates and hide unseen casters"
  doAssert vm.runtime.getGlobal("warnings") == 3
  for i in 0'i32 ..< 3:
    let spell = world.casts[i]
    doAssert vm.runtime.getArray("spells", i) == spell.ability.ord
    doAssert vm.runtime.getArray("spellXs", i) ==
      mapCoordinate(spell.position.x)
    doAssert vm.runtime.getArray("spellYs", i) ==
      mapCoordinate(spell.position.z)
    doAssert vm.runtime.getArray("impacts", i) == spell.impact
  doAssert vm.runtime.getArray("casters", 0) == ally.id
  doAssert vm.runtime.getArray("casters", 1) == enemy.id
  doAssert vm.runtime.getArray("casters", 2) == 0

  echo "Testing equipment, level, cooldown and visibility update next decision"
  inc world.tick
  hero.level = 4
  hero.inventory[0] = NoItem
  hero.itemCounts[0] = 0
  hero.inventory[1] = SunsteelLongsword
  hero.refreshHeroStats()
  hero.mana = 19
  hero.attackObjectId = 0
  hero.swingTicks = heroAttackTicks(hero.class) - 2
  hero.damageLanded = true
  hero.attacksLanded = 18
  enemy.level = 8
  enemy.refreshHeroStats()
  enemy.mana = 0
  enemy.inventory[5] = ManaPotion
  world.reveal(hidden.position)
  game.observe(vm)
  doAssert vm.runtime.getGlobal("speed") == heroMovePerTick(VanguardKnight, 4)
  doAssert vm.runtime.getGlobal("damage") ==
    heroDamage(VanguardKnight, 4) + SunsteelLongsword.itemSpec.damage
  doAssert vm.runtime.getGlobal("target") == 0
  doAssert vm.runtime.getGlobal("cooldown") == 2 + windup
  doAssert vm.runtime.getGlobal("landed") == 18
  doAssert vm.runtime.getGlobal("level") == 4
  doAssert vm.runtime.getGlobal("myMana") == 19
  doAssert vm.runtime.getArray("levels", vm.objectIndex(hero.id)) == 4
  doAssert vm.runtime.getArray("mana", vm.objectIndex(hero.id)) == 19
  doAssert vm.runtime.getArray("items", vm.objectIndex(hero.id) * 6) == 0
  doAssert vm.runtime.getArray("counts", vm.objectIndex(hero.id) * 6) == 0
  doAssert vm.runtime.getArray("levels", vm.objectIndex(enemy.id)) == 8
  doAssert vm.runtime.getArray("mana", vm.objectIndex(enemy.id)) == 0
  doAssert vm.runtime.getArray("items", vm.objectIndex(enemy.id) * 6 + 5) ==
    ManaPotion.ord
  doAssert vm.objectIndex(hidden.id) >= 0
  doAssert vm.runtime.getArray("targets", vm.objectIndex(ally.id)) == hidden.id
  doAssert vm.runtime.getGlobal("warnings") == 4
  doAssert vm.runtime.getArray("casters", 2) == hidden.id

  echo "Testing fog removes enemy objects, targets and warnings"
  inc world.tick
  for cell in world.teamVisible[RedTeam.ord].mitems:
    cell = 0
  world.casts[0].resolved = true
  hero.swingTicks = -1
  game.observe(vm)
  doAssert vm.objectIndex(enemy.id) == -1
  doAssert vm.objectIndex(hidden.id) == -1
  doAssert vm.objectIndex(1000) == -1
  doAssert vm.runtime.getArray("targets", vm.objectIndex(ally.id)) == 0
  doAssert vm.runtime.getArray("targets", vm.objectIndex(10)) == 0
  doAssert vm.runtime.getGlobal("warnings") == 0
  doAssert vm.runtime.getGlobal("cooldown") == windup
  doAssert vm.runtime.getGlobal("landed") == 18

proc checkActionSnapshots() =
  ## Ensures actions cannot change observations frozen for the current decision.
  let
    directory = createTempDir("gota-host-snapshot-", "")
    path = directory / "snapshot.bas"
    game = newGame(generateMap(54), 240, 10, false, ReplayData())
    hero = game.world.heroes[0]
  defer:
    removeDir(directory)
  writeFile(path, """
if consumed = 0 then
  consumed = useItem(0)
end if
observedSelfMana = selfMana
i = 0
while i < objectCount()
  if objectId(i) = selfId then
    observedMana = objectMana(i)
    observedItem = objectItemId(i, 0)
    observedCount = objectItemCount(i, 0)
  end if
  i = i + 1
wend
""")
  game.loadBots([BotGroup(path: path, count: 10)])
  let vm = game.heroVms[0]
  for i in 1 ..< game.heroVms.len:
    game.heroVms[i] = nil
  game.world.tick = 100
  hero.mana = 1
  hero.maxMana = 200
  hero.inventory[0] = ManaPotion
  hero.itemCounts[0] = 2
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("consumed") == 1
  doAssert hero.mana == 1 + ManaPotion.itemSpec.restore
  doAssert hero.itemCounts[0] == 1
  doAssert vm.runtime.getGlobal("observedSelfMana") == 1
  doAssert vm.runtime.getGlobal("observedMana") == 1,
    "An action before the first object query must not change its snapshot."
  doAssert vm.runtime.getGlobal("observedItem") == ManaPotion.ord
  doAssert vm.runtime.getGlobal("observedCount") == 2
  inc game.world.tick
  game.runBotDecisions()
  doAssert not vm.failed, vm.lastError
  doAssert vm.runtime.getGlobal("observedSelfMana") == hero.mana
  doAssert vm.runtime.getGlobal("observedMana") == hero.mana
  doAssert vm.runtime.getGlobal("observedItem") == ManaPotion.ord
  doAssert vm.runtime.getGlobal("observedCount") == 1,
    "The next decision must observe the previous action's inventory change."

checkHostObservations()
echo "Testing actions preserve the current decision's observation snapshot"
checkActionSnapshots()
