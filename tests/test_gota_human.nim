## Exercise the same frame-input handler used by the native renderer.
import std/strutils, windy,
  ../examples/gods_of_the_arena/[content, controls, maps, replays, sim,
    humaninput, keybinds]

proc arena(class = Ranger): Game =
  resetHumanMatch()
  setControlPreset(MouseControls)
  castMode = QuickCast
  result = newGame(generateMap(2026), 240, 10, false, ReplayData())
  result.world.spawnTimerTicks = 100_000
  result.world.heroTurnTicks = 100_000
  for hero in result.world.heroes:
    hero.manualSpells = true
    hero.state = Dying
    hero.hp = 0
    hero.deathTicks = -100_000
  for tower in result.world.towers.mitems: tower.hp = 0
  let hero = result.world.heroes[0]
  hero.class = class
  hero.spellsReady = false
  hero.refreshHeroStats()
  hero.state = Marching
  hero.hp = hero.maxHp - 50
  hero.maxMana = 10_000
  hero.mana = 9000
  result.tickWorld(nil)

proc aimAt(hero: Hero): PlayerAim =
  PlayerAim(onMap: true, x: mapCoordinate(hero.position.x),
    y: mapCoordinate(hero.position.z) + 3)

echo "Testing all 40 ability hotkeys cast and report their actual cooldowns"
for class in HeroClass:
  let game = arena(class)
  let hero = game.world.heroes[0]
  var input: HumanInputState
  for slot in HeroAbilitySlot:
    let before = game.world.casts.len
    input.handlePlayerKeys(HumanKeys(pressed: {abilityKey(slot.ord)}, focused: true),
      game.world, hero.id, hero.id, hero.aimAt, true)
    doAssert game.world.casts.len == before, "input must wait for a decision tick"
    flushPlayerCommands(game)
    doAssert game.world.casts.len == before + 1, $class & " " & $slot & ": " & feedbackText
    let spec = heroAbility(class, slot).abilitySpec
    doAssert hero.cooldowns[slot] == spec.cooldownTicks
    doAssert hero.charges[slot] == spec.charges - 1
    input.handlePlayerKeys(HumanKeys(pressed: {abilityKey(slot.ord)}, focused: true),
      game.world, hero.id, hero.id, hero.aimAt, true)
    flushPlayerCommands(game)
    doAssert game.world.casts.len == before + 1
    doAssert feedbackError and feedbackText.contains("Ready in"), feedbackText

echo "Testing cursor aim ignores a stale inspection/combat target"
block:
  let game = arena()
  let hero = game.world.heroes[0]
  let enemy = game.world.heroes[5]
  enemy.state = Marching
  enemy.hp = enemy.maxHp
  enemy.place(WorldPoint(x: hero.position.x + 60_000, y: hero.position.y, z: hero.position.z))
  hero.attackObjectId = enemy.id
  var input: HumanInputState
  input.handlePlayerKeys(HumanKeys(pressed: {KeyW}, focused: true),
    game.world, hero.id, enemy.id, hero.aimAt, true)
  flushPlayerCommands(game)
  doAssert game.world.casts[^1].targetId == 0
  doAssert game.world.casts[^1].direction.z > 0

echo "Testing targeting, cancellation, self-cast HUD, and held-key behavior"
block:
  let game = arena(VanguardKnight)
  let hero = game.world.heroes[0]
  var input: HumanInputState
  castMode = NormalCast
  input.handlePlayerKeys(HumanKeys(pressed: {KeyW}, focused: true),
    game.world, hero.id, hero.id, hero.aimAt, true)
  flushPlayerCommands(game)
  doAssert armedAbility == PrimaryAbility.ord and game.world.casts.len == 0
  cancelPlayerAim()
  doAssert armedAbility == -1
  hudAbilityRequest = PassiveAbility.ord
  input.handlePlayerKeys(HumanKeys(focused: true), game.world, hero.id, hero.id, PlayerAim(), true)
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 1
  castMode = QuickCast
  input.handlePlayerKeys(HumanKeys(held: {KeyW}, focused: true),
    game.world, hero.id, hero.id, hero.aimAt, true)
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 1, "held keys must never schedule future casts"

echo "Testing frame-end key events survive to input processing without repeating"
block:
  clearPlayKeys()
  beginPlayInputFrame()
  doAssert capturePlayPress(KeyW) # arrives after this frame's input read
  doAssert KeyW notin pressedPlayButtons
  beginPlayInputFrame()
  let game = arena()
  let hero = game.world.heroes[0]
  var input: HumanInputState
  input.handlePlayerKeys(HumanKeys(pressed: pressedPlayButtons, held: heldPlayButtons, focused: true),
    game.world, hero.id, hero.id, hero.aimAt, true)
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 1
  beginPlayInputFrame()
  doAssert KeyW notin pressedPlayButtons and KeyW in heldPlayButtons
  doAssert not capturePlayPress(KeyW), "OS repeat is not a new cast"
  capturePlayRelease(KeyW)
  doAssert capturePlayPress(KeyW)
  clearPlayKeys()
  beginPlayInputFrame()
  doAssert pressedPlayButtons == {} and heldPlayButtons == {}

echo "Testing cooldown, charge, mana, dead, and off-map rejection reasons"
block:
  let game = arena()
  let hero = game.world.heroes[0]
  hero.charges[PrimaryAbility] = 0
  hero.recharges[PrimaryAbility] = 48
  doAssert game.world.abilityReadyReason(hero, PrimaryAbility).contains("charge")
  hero.charges[PrimaryAbility] = 1
  hero.mana = 0
  doAssert game.world.abilityReadyReason(hero, PrimaryAbility).contains("mana")
  hero.state = Dying
  doAssert game.world.abilityReadyReason(hero, PrimaryAbility).contains("Respawn")
  hero.state = Marching
  hero.mana = 9000
  doAssert not activateFromInput(game.world, hero.id, 1, PlayerAim(), hero.id)
  doAssert feedbackText.contains("battlefield")

echo "Testing WASD release, focus loss, pause, and stop prevent continued movement"
for interruption in 0 .. 2:
  let game = arena()
  let hero = game.world.heroes[0]
  setControlPreset(WasdControls)
  var input: HumanInputState
  input.handlePlayerKeys(HumanKeys(held: {KeyS}, focused: true),
    game.world, hero.id, hero.id, hero.aimAt, true)
  flushPlayerCommands(game)
  doAssert hero.hasMoveTarget, feedbackText
  input.handlePlayerKeys(HumanKeys(focused: interruption != 1),
    game.world, hero.id, hero.id, hero.aimAt, interruption != 2)
  if interruption == 2:
    resetPlayerCommands() # paused renderer clears transient intents every frame
    input.handlePlayerKeys(HumanKeys(focused: true),
      game.world, hero.id, hero.id, hero.aimAt, true)
  flushPlayerCommands(game)
  doAssert hero.holding and not hero.hasMoveTarget
  doAssert abilityKey(1) == Key2 and playKey(Stop) == KeyX

echo "Testing history cannot accept or retain player commands"
block:
  let game = arena()
  let hero = game.world.heroes[0]
  var input: HumanInputState
  input.handlePlayerKeys(HumanKeys(pressed: {KeyW}, focused: true),
    game.world, hero.id, hero.id, hero.aimAt, false)
  queueCastPoint(hero.id, 1, hero.aimAt.x, hero.aimAt.y)
  game.historyPlayback = true
  flushPlayerCommands(game)
  game.historyPlayback = false
  flushPlayerCommands(game)
  doAssert game.world.casts.len == 0

echo "Testing A and S are not mouse buttons unless mousekeys is selected"
block:
  setControlPreset(MouseControls)
  doAssert playKey(Stop) == KeyS and playKey(AttackMove) == KeyA
  doAssert playKey(SpellQ) == KeyQ
  setControlPreset(MouseKeyControls)
  doAssert playKey(Stop) == KeyX and playKey(AttackMove) == KeyZ
  setControlPreset(MouseControls)

echo "Human input tests passed"
