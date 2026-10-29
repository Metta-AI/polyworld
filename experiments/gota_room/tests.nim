import
  polyworld/pathing,
  ../../examples/gods_of_the_arena/[content, controls, game, maps, sim]

run = newTestGame(Arcanist)
doAssert mapTiles() == 28
doAssert run.world.heroes.len == 1
doAssert run.world.buildings.len == 2
for building in run.world.buildings:
  doAssert building.hp == building.maxHp
  doAssert building.footprint.len > 0
  for tile in building.footprint:
    doAssert not navigationOpen(tile.layer, tile.x, tile.z)
doAssert run.world.camps.len == 2
doAssert run.world.footmen.len == 14
var campCounts: array[2, int]
for unit in run.world.footmen:
  if unit.camp > 0:
    inc campCounts[unit.camp - 1]
    if unit.camp == 1:
      doAssert unit.campTier == 3 and unit.position.x < 0
    else:
      doAssert unit.campTier == 1 and unit.position.x > 0
    doAssert unit.position.z > 0
doAssert campCounts == [7, 1]
doAssert not isWalkable(0, 0, 0)
doAssert isWalkable(0, 14, 14)

echo "Creeps cannot attack absent gods at the room center."
block:
  let game = newTestGame()
  game.world.footmen.setLen(0)
  game.world.camps.setLen(0)
  game.world.buildings.setLen(0)
  var creep = Footman(
    id: game.world.nextFootmanId,
    team: RedTeam,
    hp: 100,
    swingTicks: -1
  )
  creep.place(WorldPoint(x: WorldScale))
  game.world.footmen.add creep
  for tick in 0 ..< 2 * TickRate:
    game.tickWorld(nil)
    doAssert not game.world.footmen[0].attackingFort
    doAssert game.world.attackEffects.len == 0

echo "Walking through the real command and simulation pipeline."
queueWalkTo(FirstHeroId, 18, 14)
for i in 0 ..< 4 * TickRate:
  advanceGame()
doAssert run.world.heroes[0].position.x > 3 * WorldScale
doAssert run.world.footmen.len >= 2
doAssert not run.world.gameOver
doAssert run.recorder == nil

echo "Casting, recharging, and resetting every hero."
for class in HeroClass:
  clearPlayerCommands()
  run.resetTestHero(class)
  let hero = run.world.heroes[0]
  doAssert hero.class == class and hero.level == HeroMaxLevel
  doAssert hero.position == hero.spawnPosition
  doAssert hero.hp == hero.maxHp and hero.mana == hero.maxMana
  for slot in HeroAbilitySlot:
    doAssert hero.abilityLevels[slot] == abilityMaxLevel(slot)
  queueCastPoint(FirstHeroId, UltimateAbility.ord.int32, 15, 14)
  advanceGame()
  doAssert run.world.heroes[0].lastActionError == NoActionError
  doAssert run.world.casts.len > 0
  doAssert hero.castPoseUntil > run.world.tick
  doAssert run.world.heroes[0].cooldowns[UltimateAbility] <= TickRate
  for i in 0 ..< TickRate:
    advanceGame()
  doAssert run.world.heroes[0].cooldowns[UltimateAbility] == 0
  doAssert run.world.heroes[0].recharges[UltimateAbility] == 0
  run.resetTestHero(class)
  doAssert run.world.casts.len == 0

echo "Consumed stacks decrease and can run out."
run.resetTestHero(DruidWarden)
doAssert run.world.heroes[0].inventory == [HealthPotion, ManaPotion,
  PoisonPotion, PortalScroll, VitalityElixir, ManaElixir]
run.woundTestHero()
queueUseItem(FirstHeroId, 0)
advanceGame()
doAssert run.world.heroes[0].itemCounts[0] == 98
doAssert run.world.itemUses.len == 1
doAssert run.world.itemUses[0].item == HealthPotion
for i in 0 ..< TickRate - 1:
  advanceGame()
doAssert run.world.heroes[0].itemCounts[0] == 98
advanceGame()
doAssert run.world.heroes[0].itemCounts[0] == 98

run.world.heroes[0].itemCounts[4] = 1
run.woundTestHero()
queueUseItem(FirstHeroId, 4)
advanceGame()
doAssert run.world.heroes[0].inventory[4] == NoItem
for i in 0 ..< TickRate:
  advanceGame()
doAssert run.world.heroes[0].inventory[4] == NoItem
doAssert run.world.heroes[0].itemCounts[4] == 0

echo "Mana potions remain usable between test casts."
run.resetTestHero(Arcanist)
queueCastPoint(FirstHeroId, PrimaryAbility.ord.int32, 15, 14)
advanceGame()
doAssert run.world.heroes[0].mana < run.world.heroes[0].maxMana
queueUseItem(FirstHeroId, 5)
advanceGame()
doAssert run.world.heroes[0].itemCounts[5] == 98
doAssert run.world.itemUses.len == 1
doAssert run.world.itemUses[0].item == ManaElixir

echo "Double-clicking a scroll lands beside the upper-right tower."
run.resetTestHero(Arcanist)
clearPlayerCommands()
activatePlayerItem(run.world, FirstHeroId, 3, 20.0)
activatePlayerItem(run.world, FirstHeroId, 3, 20.5, doubleClick = true)
advanceGame()
doAssert run.world.heroes[0].portalEnds > run.world.tick
doAssert run.world.heroes[0].itemCounts[3] == 98
for i in 0 ..< PortalChannelTicks:
  advanceGame()
doAssert within(run.world.heroes[0].position,
  run.world.heroes[0].portalHome(), WorldScale)
doAssert run.world.heroes[0].portalEnds == 0
clearPlayerCommands()

echo "Test room checks passed."

echo "Out-of-range spells walk into range without spending early."
run.resetTestHero(Arcanist)
let
  charges = run.world.heroes[0].charges[PrimaryAbility]
  range = FrostLance.abilitySpec(abilityMaxLevel(PrimaryAbility)).range
queueCastPoint(FirstHeroId, PrimaryAbility.ord.int32, 24, 14)
advanceGame()
doAssert run.world.heroes[0].hasQueuedCast
doAssert run.world.casts.len == 0
doAssert run.world.heroes[0].charges[PrimaryAbility] == charges
let snapshot = run.world.clone()
for i in 0 ..< 10 * TickRate:
  advanceGame()
  if run.world.casts.len > 0:
    break
doAssert run.world.casts.len == 1
let
  spell = run.world.casts[0]
  releasedHash = run.stateHash()
  releasedTick = run.world.tick
doAssert within(spell.origin, spell.position, range)
doAssert not within(spell.origin, spell.position, WorldScale)
doAssert run.world.heroes[0].facing.x > 0
doAssert not run.world.heroes[0].hasMoveTarget
doAssert not run.world.heroes[0].hasQueuedCast
doAssert run.world.heroes[0].castPoseUntil > run.world.tick
run.world.restore(snapshot)
while run.world.tick < releasedTick:
  advanceGame()
doAssert run.stateHash() == releasedHash

echo "New movement cancels queued casts."
run.resetTestHero(Arcanist)
queueCastPoint(FirstHeroId, PrimaryAbility.ord.int32, 24, 14)
advanceGame()
doAssert run.world.heroes[0].hasQueuedCast
queueWalkTo(FirstHeroId, 12, 14)
advanceGame()
doAssert not run.world.heroes[0].hasQueuedCast
for i in 0 ..< 3 * TickRate:
  advanceGame()
doAssert run.world.casts.len == 0
doAssert run.world.heroes[0].charges[PrimaryAbility] == charges

echo "Object casts track moving targets and cancel when targets disappear."
run.resetTestHero(Arcanist)
let target = Hero()
target[] = run.world.heroes[0][]
target.id = FirstHeroId + 1
target.team = BlueTeam
target.hp = 100_000
target.maxHp = 100_000
target.controls[StunControl].ends = int32.high
target.place(WorldPoint(x: 8 * WorldScale))
run.world.heroes.add target
run.world.rebuildVision()
queueCastTarget(FirstHeroId, PrimaryAbility.ord.int32, target.id)
advanceGame()
doAssert run.world.heroes[0].hasQueuedCast
run.world.heroes[1].place(WorldPoint(x: 9 * WorldScale, z: WorldScale))
for i in 0 ..< 10 * TickRate:
  advanceGame()
  if run.world.casts.len > 0:
    break
doAssert run.world.casts.len == 1
doAssert run.world.casts[0].targetId == target.id
doAssert within(run.world.casts[0].origin, run.world.heroes[1].position, range)
doAssert not within(run.world.casts[0].origin,
  run.world.heroes[1].position, WorldScale)

run.resetTestHero(Arcanist)
target.place(WorldPoint(x: 8 * WorldScale))
run.world.heroes.add target
run.world.rebuildVision()
queueCastTarget(FirstHeroId, PrimaryAbility.ord.int32, target.id)
advanceGame()
doAssert run.world.heroes[0].hasQueuedCast
run.world.heroes[1].place(WorldPoint(x: 12 * WorldScale, z: 12 * WorldScale))
advanceGame()
doAssert not run.world.heroes[0].hasQueuedCast
doAssert run.world.casts.len == 0
doAssert run.world.heroes[0].charges[PrimaryAbility] == charges

echo "Test room casting checks passed."

echo "Periodic waves meet and fight in the upper center."
run = newTestGame()
let firstNextId = run.world.nextFootmanId
var fought = [false, false]
for i in 0 ..< 16 * TickRate:
  advanceGame()
  for unit in run.world.footmen:
    if unit.camp == 0 and unit.state == Fighting and unit.targetId != 0:
      doAssert abs(unit.position.x) < 4 * WorldScale
      doAssert unit.position.z < -6 * WorldScale
      fought[unit.team.ord] = true
doAssert fought == [true, true]
doAssert run.world.nextFootmanId == firstNextId + 6
run.world.buildings[0].hp = 0
run.world.syncBuildings()
run.resetTestHero(Arcanist)
doAssert run.world.buildings[0].hp == run.world.buildings[0].maxHp
doAssert run.world.footmen.len == 14
doAssert not run.world.gameOver
echo "Test room combat checks passed."

echo "Enemy tower returns after exactly five seconds."
run = newTestGame()
run.world.buildings[1].hp = 0
run.finishTestTick()
for tile in run.world.buildings[1].footprint:
  doAssert navigationOpen(tile.layer, tile.x, tile.z)
for i in 0 ..< 5 * TickRate - 1:
  advanceGame()
  doAssert run.world.buildings[1].hp == 0
advanceGame()
doAssert run.world.buildings[1].hp == run.world.buildings[1].maxHp
for tile in run.world.buildings[1].footprint:
  doAssert not navigationOpen(tile.layer, tile.x, tile.z)
echo "Test room tower respawn checks passed."

echo "Rapid move commands keep the newest destination."
run = newTestGame()
clearPlayerCommands()
queueWalkTo(FirstHeroId, 16, 14)
queueWalkTo(FirstHeroId, 18, 16)
advanceGame()
doAssert run.world.heroes[0].moveTileX == 18
doAssert run.world.heroes[0].moveTileY == 16
for i in 0 ..< 4 * TickRate:
  advanceGame()
doAssert within(run.world.heroes[0].position,
  WorldPoint(x: 4 * WorldScale + WorldScale div 2,
    z: 2 * WorldScale + WorldScale div 2), WorldScale div 2)

echo "Finishing an old move cannot clear its replacement."
run = newTestGame()
queueWalkTo(FirstHeroId, 16, 14)
var arrivalTicks = 0
for i in 1 .. 4 * TickRate:
  advanceGame()
  if not run.world.heroes[0].hasMoveTarget:
    arrivalTicks = i
    break
doAssert arrivalTicks > 1
for offset in [-1, 0, 1]:
  run = newTestGame()
  clearPlayerCommands()
  queueWalkTo(FirstHeroId, 16, 14)
  for i in 0 ..< arrivalTicks + offset:
    advanceGame()
  queueWalkTo(FirstHeroId, 18, 16)
  advanceGame()
  doAssert run.world.heroes[0].hasMoveTarget
  doAssert run.world.heroes[0].moveTileX == 18
  doAssert run.world.heroes[0].moveTileY == 16
  for i in 0 ..< 4 * TickRate:
    advanceGame()
  doAssert within(run.world.heroes[0].position,
    WorldPoint(x: 4 * WorldScale + WorldScale div 2,
      z: 2 * WorldScale + WorldScale div 2), WorldScale div 2)
clearPlayerCommands()
echo "Rapid movement checks passed."
