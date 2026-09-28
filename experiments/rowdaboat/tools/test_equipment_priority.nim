## T003 isolated shopping decisions through the actual BASIC VM and host.
## Build with pinned POLYWORLD_DEPS, -d:headless and -d:replayEvents.
## Usage: test_equipment_priority <candidate.bas> [receipt.json]
## No complete games, score calculations, or policy matches are run.
import std/[os, json, sha1]
import bassy
import polyworld/[cli, tapes]
import ../../../examples/gods_of_the_arena/[bots, content, maps, replays, sim]

if paramCount() notin 1 .. 2:
  quit("Usage: test_equipment_priority <candidate.bas> [receipt.json]", 1)
let policy = absolutePath(paramStr(1))
doAssert fileExists(policy)

type Fixture = object
  game: Game
  hero: Hero
  vm: HeroVm

var
  checks = newJArray()
  maximumInstructions, maximumWork: int64

proc passed(name: string) =
  checks.add %name
  echo "PASS ", name

proc fixture(class: HeroClass, team: Team, gold: int,
    items: openArray[Item]): Fixture =
  result.game = newGame(generateMap(54), 100_000, 10, false,
    ReplayData(), drafting = false)
  let game = result.game
  game.loadBots([BotGroup(path: policy, count: 10)])
  let index = team.ord * 5
  result.hero = game.world.heroes[index]
  result.vm = game.heroVms[index]
  for i, hero in game.world.heroes:
    if i != index:
      game.heroVms[i] = nil
      hero.hp = 0
      hero.state = Dying
  for building in game.world.buildings.mitems:
    if building.team != team:
      building.hp = 0
  game.world.syncBuildings()
  game.world.footmen.setLen(0)
  game.world.tick = 100
  result.hero.class = class
  result.hero.inventory = default(typeof(result.hero.inventory))
  result.hero.itemCounts = default(typeof(result.hero.itemCounts))
  for slot, item in items:
    result.hero.inventory[slot] = item
    result.hero.itemCounts[slot] = 1
  result.hero.refreshHeroStats()
  result.hero.hp = result.hero.maxHp
  result.hero.mana = result.hero.maxMana
  result.hero.gold = gold
  result.hero.portalCooldownEnds = 100_000
  game.recorder = initReplayRecorder(game.currentSetup(1000))

proc owned(f: Fixture, item: Item): int32 =
  for slot, value in f.hero.inventory:
    if value == item:
      result += f.hero.itemCounts[slot]

proc purchases(f: Fixture): seq[Item] =
  f.game.world.tick += 6
  let before = f.game.recorder.data.actions.len
  f.game.runBotDecisions()
  doAssert not f.vm.failed, f.vm.lastError
  doAssert f.vm.lastInstructions <= f.vm.limits.maxInstructions
  doAssert f.vm.lastWork <= f.vm.limits.maxWorkUnits
  maximumInstructions = max(maximumInstructions, f.vm.lastInstructions)
  maximumWork = max(maximumWork, f.vm.lastWork)
  for index in before ..< f.game.recorder.data.actions.len:
    let action = f.game.recorder.data.actions[index]
    if action.kind == ActionBuyItem:
      result.add Item(action.first)

for (class, team, equipment, gold) in [
    (VanguardKnight, RedTeam, KnightArmor, 170),
    (Ranger, BlueTeam, RuneCrossbow, 190),
    (Arcanist, RedTeam, ArcaneSpellbook, 200)]:
  let f = fixture(class, team, gold, [RangerBoots])
  doAssert f.purchases() == @[equipment]
  doAssert f.owned(equipment) == 1 and f.hero.gold == 10
  doAssert f.hero.lastActionError == NoActionError
  passed($class & ": accepted existing role equipment before replenishment with boots already owned")

block:
  let f = fixture(VanguardKnight, BlueTeam, 150, [])
  doAssert f.purchases() == @[RangerBoots, HealthPotion]
  doAssert f.owned(RangerBoots) == 1 and f.owned(HealthPotion) == 1
  doAssert f.owned(KnightArmor) == 0 and f.hero.gold == 20
  passed("150-gold opening still buys boots then health potion")

block:
  let f = fixture(VanguardKnight, RedTeam, 500, [RangerBoots, KnightArmor])
  let replenishment = @[HealthPotion, PortalScroll, ManaPotion, VitalityElixir]
  doAssert f.purchases() == replenishment
  doAssert f.purchases() == replenishment
  doAssert f.purchases().len == 0
  doAssert f.owned(KnightArmor) == 1 and f.owned(RangerBoots) == 1
  for item in replenishment:
    doAssert f.owned(item) == 2
  doAssert f.hero.gold == 0
  passed("owned equipment is not duplicated; original consumable order and two-unit caps remain")

block:
  let f = fixture(VanguardKnight, RedTeam, 1000,
    [RangerBoots, SteelHelmet, LeatherGauntlets, SteelBuckler, RubyAmulet, SapphireRing])
  doAssert f.purchases().len == 0
  doAssert f.owned(KnightArmor) == 0 and f.hero.gold == 1000
  passed("full inventory makes no purchase attempts and preserves gold")

block:
  let f = fixture(VanguardKnight, BlueTeam, 1000, [RangerBoots])
  f.hero.place(WorldPoint())
  doAssert not f.hero.canShop
  doAssert f.purchases().len == 0
  doAssert f.owned(KnightArmor) == 0 and f.hero.gold == 1000
  passed("outside-shop gate still prevents equipment and consumable purchases")

let receipt = %*{"policy": policy, "policySha1": $secureHashFile(policy),
  "purpose": "Isolated BASIC/host shopping mechanism only; no local games or scores",
  "checksPassed": checks.len, "checks": checks,
  "maximumInstructionsObserved": maximumInstructions,
  "maximumWorkObserved": maximumWork}
if paramCount() == 2:
  writeFile(paramStr(2), receipt.pretty & "\n")
echo "Mechanism checks passed: ", checks.len, "; no score measured."
