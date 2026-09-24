import
  std/[os, strutils],
  bassy,
  polyworld/cli,
  ../[bots, content, maps, replays, sim],
  balance_policies, balances

type
  Scenario = enum
    ManaMissing, ManaFull, ManaSmallGap, Locked, Cooling, Empty, Silenced,
    StunnedCaster, ChannelingCaster, AllyHurt, AllyFull, AllyFar, AllyDead,
    EnemyHurt, NoMana, SelfHurt, EquippedAlly, LeveledAlly

proc scenario(policy: string, team: Team, test: Scenario,
    spellSlot: HeroAbilitySlot): bool =
  ## Exercises real policy decisions and spell effects on both map sides.
  let
    game = newGame(generateMap(7), 100_000, 10, false,
      ReplayData(), drafting = false)
    class =
      if test <= ChannelingCaster: Arcanist else: DruidWarden
    sign = if team == RedTeam: 1'i32 else: -1'i32
    origin = WorldPoint(x: -570_000 * sign, z: 630_000 * sign)
  game.loadBots([BotGroup(path: policy, count: 10)])
  game.recorder = initReplayRecorder(game.currentSetup(1000))
  let
    hero = game.world.heroes[0]
    ally = game.world.heroes[1]
  for index, unit in game.world.heroes:
    unit.team = team
    unit.class = if index == 0: class else: VanguardKnight
    unit.level = 1
    unit.refreshHeroStats()
    unit.place(origin)
    unit.hp = unit.maxHp
    unit.mana = unit.maxMana
    unit.gold = 0
    unit.abilityLevels = default(typeof(unit.abilityLevels))
    if index != 0:
      game.heroVms[index] = nil
      unit.hp = 0
      unit.state = Dying
  hero.abilityLevels[spellSlot] = 1
  hero.charges[spellSlot] = 1
  hero.spellsReady = true
  let spec = heroAbility(class, spellSlot).abilitySpec(1)
  if test <= ChannelingCaster:
    hero.mana = hero.maxMana - spec.restore
    case test
    of ManaFull: hero.mana = hero.maxMana
    of ManaSmallGap: hero.mana = hero.maxMana - spec.restore + 1
    of Locked:
      hero.abilityLevels[spellSlot] = 0
      hero.abilityLevels[PrimaryAbility] = 1
    of Cooling: hero.cooldowns[spellSlot] = 12
    of Empty: hero.charges[spellSlot] = 0
    of Silenced: hero.controls[SilenceControl].ends = 100
    of StunnedCaster: hero.controls[StunControl].ends = 100
    of ChannelingCaster: hero.portalEnds = 100
    else: discard
  else:
    ally.hp = ally.maxHp - 100
    ally.state = Marching
    ally.place(WorldPoint(x: origin.x + 3 * WorldScale * sign, z: origin.z))
    case test
    of AllyFull: ally.hp = ally.maxHp
    of AllyFar:
      ally.place(WorldPoint(x: origin.x + 5 * WorldScale * sign, z: origin.z))
    of AllyDead:
      ally.hp = 0
      ally.state = Dying
    of EnemyHurt: ally.team = Team(1 - team.ord)
    of NoMana: hero.mana = 0
    of SelfHurt:
      ally.hp = ally.maxHp
      hero.hp = hero.maxHp - 100
    of EquippedAlly:
      ally.inventory[0] = SteelHelmet
      ally.refreshHeroStats()
      ally.hp = ally.maxHp - spec.heal
    of LeveledAlly:
      ally.level = 9
      ally.refreshHeroStats()
      ally.hp = ally.maxHp - spec.heal
    else: discard
  for cells in game.world.teamVisible.mitems:
    for cell in cells.mitems:
      cell = 255
  game.world.tick = 6
  game.runBotDecisions()
  doAssert not game.heroVms[0].failed, game.heroVms[0].lastError
  for action in game.recorder.data.actions:
    if action.kind == ActionCastTarget and action.slot == spellSlot.ord:
      result = true
      let expected =
        if class == Arcanist or test == SelfHurt: hero.id else: ally.id
      doAssert action.first == expected, $test
  if result:
    doAssert hero.cooldowns[spellSlot] > 0, $test
    if class == Arcanist:
      doAssert hero.mana == hero.maxMana, "Mana Crystal must restore mana"
    else:
      let
        patient = if test == SelfHurt: hero else: ally
        before = patient.hp
      for index in 0 ..< 15:
        game.tickWorld(nil)
      doAssert patient.hp >= before + spec.heal,
        "The selected ally must actually receive healing"

proc main() =
  ## Tests corrected support behavior without playing additional full matches.
  doAssert paramCount() == 2, "Expected original and temporary output policy"
  let
    source = readFile(paramStr(1))
    tuning = readFile(currentSourcePath().parentDir / "../content.nim")
    corrected = supportPolicy(source, tuning)
  createDir(paramStr(2).parentDir)
  writeFile(paramStr(2), corrected)
  doAssert "abilityRestore(supportSlot)" in corrected
  var rejected = false
  try:
    discard supportPolicy(corrected, tuning)
  except BalanceError:
    rejected = true
  doAssert rejected, "Duplicate patches must not silently accumulate"
  var count = 0
  for team in Team:
    doAssert not scenario(paramStr(1), team, ManaMissing, PassiveAbility),
      "The original policy reproduces the missing restoration behavior"
    doAssert not scenario(paramStr(1), team, AllyHurt, PrimaryAbility),
      "The original policy reproduces the missing ally healing behavior"
    for test in Scenario:
      for slot in [PrimaryAbility, SecondaryAbility]:
        let
          selected = if test <= ChannelingCaster: PassiveAbility else: slot
          actual = scenario(paramStr(2), team, test, selected)
          expected = test in
            [ManaMissing, AllyHurt, SelfHurt, EquippedAlly, LeveledAlly]
        doAssert actual == expected, $team & " " & $test & " " & $slot
        inc count
  echo "Passed ", count, " support scenarios, including real spell effects"

main()
