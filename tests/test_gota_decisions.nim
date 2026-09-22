import
  std/[os, tempfiles],
  bassy,
  polyworld/[cli, pathing],
  ../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

const Source = """
if selfId = 100 then
  used = useItem(0)
  cast = castPoint(2, selfX, selfY)
end if
seenHp = 0
for i = 0 to objectCount() - 1
  if objectId(i) = 100 then
    seenHp = objectHp(i)
  end if
next i
warnings = spellCount()
"""

proc observe(first: int): tuple[hp, warnings: int32] =
  ## Runs a potion user and its observer in either actual BASIC execution order.
  let
    directory = createTempDir("gota-decisions-", "")
    path = directory / "snapshot.bas"
    game = newGame(generateMap(7), 100_000, 10, false,
      ReplayData(), drafting = false)
    caster = game.world.heroes[0]
    observer = game.world.heroes[5]
    point = lanePathPoints[1][lanePathPoints[1].len div 2]
  defer:
    removeFile(path)
    removeDir(directory)
  writeFile(path, Source)
  game.loadBots([BotGroup(path: path, count: 10)])
  for i, hero in game.world.heroes:
    if i != 0 and i != 5:
      game.heroVms[i] = nil
      hero.hp = 0
      hero.state = Dying
  caster.class = Arcanist
  caster.refreshHeroStats()
  caster.hp = caster.maxHp div 2
  caster.mana = caster.maxMana
  caster.inventory[0] = VitalityElixir
  caster.itemCounts[0] = 1
  caster.abilityLevels[SecondaryAbility] = 1
  caster.charges[SecondaryAbility] = 1
  caster.spellsReady = true
  const Unit = WorldScale div PathUnitsPerTile
  for hero in [caster, observer]:
    hero.place(WorldPoint(x: point.x * Unit, y: point.y * Unit,
      z: point.z * Unit))
  for cells in game.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255
  let hp = caster.hp
  game.world.tick = 1
  game.world.heroTurnStart = first
  game.runBotDecisions()
  for i in [0, 5]:
    doAssert not game.heroVms[i].failed, game.heroVms[i].lastError
  doAssert caster.hp > hp
  doAssert game.world.casts.len == 1
  let runtime = game.heroVms[5].runtime
  result = (runtime.getGlobal("seenHp"), runtime.getGlobal("warnings"))
  doAssert result.hp == hp, "An earlier command leaked into observations."
  doAssert result.warnings == 0, "An earlier cast leaked into observations."
  inc game.world.tick
  game.heroVms[0] = nil
  game.runBotDecisions()
  doAssert runtime.getGlobal("seenHp") == caster.hp
  doAssert runtime.getGlobal("warnings") == 1

echo "Testing all BASIC decisions observe the same command-phase snapshot"
doAssert observe(0) == observe(5)
