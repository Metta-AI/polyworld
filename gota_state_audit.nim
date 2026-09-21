import std/[os, json, strutils]
import examples/gods_of_the_arena/[replays, sim, maps, content, observations]

# Compact state audit using the game's own replay-action dispatcher.
# Policy/player identities must be joined through the hosted participant IDs.
let data = loadReplay(paramStr(1))
let sampleEvery = if paramCount() >= 2: parseInt(paramStr(2)) else: 250
doAssert sampleEvery > 0
let sampleFrom = if paramCount() >= 3: parseInt(paramStr(3)) else: 1
let sampleThrough = if paramCount() >= 4: parseInt(paramStr(4)) else: data.hashes.len
doAssert sampleFrom >= 1 and sampleThrough >= sampleFrom
let game = newGame(generateMap(data.config.seed, data.config.mapPreset),
  int32(data.header.setup.spawnIntervalTicks), data.header.setup.heroes.len,
  true, data)
game.historyPlayback = true
game.replayPlayer = initReplayPlayer(data)
var mismatches = 0
var samples = newJArray()
var guardWarningTicks: array[2, int]
var fullInventoryExecutionTicks = newSeq[int](game.world.heroes.len)
var fullInventoryExecutionWindows = newSeq[int](game.world.heroes.len)
var lastExecutionTick = newSeq[int](game.world.heroes.len)
var lastExecutionTarget = newSeq[int32](game.world.heroes.len)
var executionWindowStarts = newJArray()
for tick in 1 .. data.hashes.len:
  game.tickWorld(proc() = discard)
  if game.stateHash() != data.hashes[tick - 1]:
    inc mismatches
  # End-tick selected-target opportunities, not re-executed policy decisions.
  for heroIndex, h in game.world.heroes:
    if h.hp <= 0 or h.gold < 40 or NoItem in h.inventory or PoisonPotion in h.inventory:
      continue
    let targetIndex = game.world.heroIndex(h.attackObjectId)
    if targetIndex < 0:
      continue
    let target = game.world.heroes[targetIndex]
    if target.team == h.team or target.hp <= 0 or target.hp > 35:
      continue
    let dx = mapCoordinate(h.position.x) - mapCoordinate(target.position.x)
    let dy = mapCoordinate(h.position.z) - mapCoordinate(target.position.z)
    let scaledRange = h.class.heroAttackRange() div 1000
    if (dx * dx + dy * dy) * 3600 <= scaledRange * scaledRange:
      inc fullInventoryExecutionTicks[heroIndex]
      if lastExecutionTick[heroIndex] != tick - 1 or lastExecutionTarget[heroIndex] != target.id:
        inc fullInventoryExecutionWindows[heroIndex]
        executionWindowStarts.add %*{"tick": tick, "heroId": h.id,
          "targetId": target.id, "targetHp": target.hp, "gold": h.gold}
      lastExecutionTick[heroIndex] = tick
      lastExecutionTarget[heroIndex] = target.id
  # Exact every-tick structural precondition for the v68 warning hypothesis.
  # Own living towers are always visible; use geometry, not guardsGod.
  # This counts eligibility, not actual policy decisions or anchor activation.
  for fort in game.world.forts:
    var nearbyCount = 0
    var nearbyHp = 0'i32
    for tower in game.world.buildings:
      if tower.team == fort.team and tower.kind == TowerBuilding and tower.hp > 0:
        let dx = mapCoordinate(tower.position.x) - mapCoordinate(fort.center.x)
        let dy = mapCoordinate(tower.position.z) - mapCoordinate(fort.center.z)
        if dx * dx + dy * dy <= 100:
          inc nearbyCount
          nearbyHp = tower.hp
    if fort.hp > 0 and ((nearbyCount == 1 and nearbyHp <= 300) or
        game.world.fortExposed(fort.team)):
      inc guardWarningTicks[fort.team.ord]
  # Restrict output, not playback: hashes are still checked for the full replay.
  if tick >= sampleFrom and tick <= sampleThrough and
      (tick mod sampleEvery == 0 or tick == data.hashes.len):
    var heroes = newJArray()
    for h in game.world.heroes:
      var nearestDistance = int64.high
      var destinationDistance = int64.high
      var nearestFootman = newJNull()
      var destinationFootman = newJNull()
      var observedStructures = newJArray()
      var observedEnemyHeroes = newJArray()
      var observedEnemyFootmen = newJArray()
      var observedSpells = newJArray()
      for spellIndex in 0 ..< game.world.visibleSpellCount(h.id):
        var warning: SpellCast
        if game.world.visibleSpellAt(h.id, spellIndex, warning):
          observedSpells.add %*{"ability": warning.ability.ord,
            "casterId": game.world.visibleSpellCasterId(h.id, warning),
            "x": mapCoordinate(warning.position.x),
            "y": mapCoordinate(warning.position.z), "impactTick": warning.impact}
      var visible: WorldObject
      for objectIndex in 0 ..< game.world.worldObjectCount(h.id):
        if game.world.worldObjectAt(h.id, objectIndex, visible):
          # Only script-visible fields; never expose simulator guardsGod here.
          if visible.kind in [1'i32, 4'i32]:
            observedStructures.add %*{"id": visible.id, "kind": visible.kind,
              "team": visible.team.ord, "hp": visible.hp, "maxHp": visible.maxHp,
              "targetId": visible.targetId,
              "alive": visible.alive, "x": mapCoordinate(visible.position.x),
              "y": mapCoordinate(visible.position.z)}
          if visible.kind == 2 and visible.team != h.team and visible.alive:
            observedEnemyHeroes.add %*{"id": visible.id,
              "x": mapCoordinate(visible.position.x),
              "y": mapCoordinate(visible.position.z), "hp": visible.hp,
              "targetId": visible.targetId}
          if visible.kind == 3 and visible.team != h.team and visible.alive:
            observedEnemyFootmen.add %*{"id": visible.id,
              "x": mapCoordinate(visible.position.x),
              "y": mapCoordinate(visible.position.z), "hp": visible.hp,
              "targetId": visible.targetId}
        if game.world.worldObjectAt(h.id, objectIndex, visible) and
            visible.alive and visible.kind == 3 and visible.team == h.team:
          let x = mapCoordinate(visible.position.x)
          let y = mapCoordinate(visible.position.z)
          let dx = int64(x - mapCoordinate(h.position.x))
          let dy = int64(y - mapCoordinate(h.position.z))
          let mx = int64(x - h.moveTileX)
          let my = int64(y - h.moveTileY)
          if dx * dx + dy * dy < nearestDistance:
            nearestDistance = dx * dx + dy * dy
            nearestFootman = %*{"id": visible.id, "x": x, "y": y,
              "distanceSquared": nearestDistance}
          if mx * mx + my * my < destinationDistance:
            destinationDistance = mx * mx + my * my
            destinationFootman = %*{"id": visible.id, "x": x, "y": y,
              "distanceSquared": destinationDistance}
      # Simulator diagnostics below include private resources/cooldowns.
      # Only observed* arrays above establish what a policy could observe.
      heroes.add %*{"id": h.id, "class": h.class.ord, "team": h.team.ord,
        "x": mapCoordinate(h.position.x), "y": mapCoordinate(h.position.z),
        "hp": h.hp, "maxHp": h.maxHp, "xp": h.totalXp,
        "mana": h.mana, "charges": h.charges, "cooldowns": h.cooldowns,
        "swingTicks": h.swingTicks, "damageLanded": h.damageLanded,
        "gold": h.gold, "level": h.level, "inventory": h.inventory,
        "attacksLanded": h.attacksLanded, "attackObjectId": h.attackObjectId,
        "moveX": h.moveTileX, "moveY": h.moveTileY,
        "observedStructures": observedStructures,
        "observedSpells": observedSpells,
        "observedEnemyHeroes": observedEnemyHeroes,
        "observedEnemyFootmen": observedEnemyFootmen,
        "nearestVisibleFriendlyFootman": nearestFootman,
        "visibleFriendlyFootmanNearestDestination": destinationFootman}
    var buildings = newJArray()
    for b in game.world.buildings:
      buildings.add %*{"id": b.id, "team": b.team.ord, "hp": b.hp,
        "x": mapCoordinate(b.position.x), "y": mapCoordinate(b.position.z),
        "kind": b.kind.ord, "guardsGod": b.guardsGod}
    var forts = newJArray()
    for f in game.world.forts:
      forts.add %*{"team": f.team.ord, "hp": f.hp}
    samples.add %*{"tick": tick, "heroes": heroes, "buildings": buildings,
      "spells": game.world.casts,
      "forts": forts}
echo $(%*{"seed": data.config.seed, "ticks": data.hashes.len,
  "sampleEvery": sampleEvery, "sampleFrom": sampleFrom,
  "sampleThrough": sampleThrough,
  "hashMismatches": mismatches, "setup": data.header.setup.heroes,
  "guardWarningStructuralTicksByTeam": guardWarningTicks,
  "fullInventorySelectedExecutionTicksByHero": fullInventoryExecutionTicks,
  "fullInventorySelectedExecutionWindowsByHero": fullInventoryExecutionWindows,
  "fullInventoryExecutionWindowStarts": executionWindowStarts,
  "gameOver": game.world.gameOver, "scores": game.world.scores(),
  "samples": samples})
if mismatches > 0:
  quit(1)
