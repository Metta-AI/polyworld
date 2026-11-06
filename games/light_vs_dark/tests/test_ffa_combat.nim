## Default local configuration: never force diplomacy to make combat pass.
import jsony
import polyworld/tapes
import ../[content, multiplayer, presets, replays, sim]

block defaultMilitaryAutoattack:
  let game = newLocalMatch(defaultConfig(2), ["", ""])
  let w = game.world
  let c = w.map.side div 2
  let attacker = w.spawnUnit(0, SoldierUnit, tile2(c, c))
  let target = w.spawnUnit(1, PeonUnit, tile2(c + 1, c))
  w.rebuildVision()
  let hp = w.units[w.unitIndex(target)].hp
  for tick in 1 .. 96: w.tickWorld(nil)
  let index = w.unitIndex(target)
  let finalHp = if index < 0: 0'i32 else: w.units[index].hp
  echo "DEFAULT AUTOATTACK relation=", w.diplomacy.relation(0, 1).state,
    " targetHp=", hp, " -> ", finalHp, " attacker=", attacker
  doAssert finalHp < hp, "Default FFA military must auto-acquire and damage another player"
  for tick in 1 .. 240: w.tickWorld(nil)
  doAssert not w.entityAlive(target), "Normal attacks must kill the target"

block defaultSettingsAndOptionalDiplomacy:
  for count in [2, 4]:
    let config = parseConfig(defaultConfig(count).toJson())
    let w = newLocalMatch(config, newSeq[string](count)).world
    for a in 0'i32 ..< int32(count):
      doAssert not w.atWar(a, a)
      for b in 0'i32 ..< int32(count):
        if a != b: doAssert w.atWar(a, b)
    doAssert not w.atWar(0, -1)
  doAssert not parseConfig("{}").diplomacySettings.neutralStart
  var config = defaultConfig(2)
  config.diplomacySettings.neutralStart = true
  let neutral = newLocalMatch(parseConfig(config.toJson()), ["", ""])
  doAssert not neutral.world.atWar(0, 1)
  doAssert neutral.recorder.data.header.setup.diplomacySettings.neutralStart

block explicitAttackMoveAndWorkerCapability:
  for kind in [SoldierUnit, PeonUnit]:
    for attackMove in [false, true]:
      let w = newLocalMatch(defaultConfig(2), ["", ""]).world
      let c = w.map.side div 2
      let attacker = w.spawnUnit(0, kind, tile2(c - 1, c))
      let target = w.spawnUnit(1, PeonUnit, tile2(c + 1, c))
      w.rebuildVision()
      if attackMove:
        doAssert w.applyAttackMove(0, attacker, c + 4, c)
      else:
        doAssert w.applyAttack(0, attacker, target)
      for tick in 1 .. 240: w.tickWorld(nil)
      let index = w.unitIndex(target)
      let hp = if index < 0: 0'i32 else: w.units[index].hp
      echo "ORDER kind=", kind, " attackMove=", attackMove, " targetHp=40 -> ", hp
      doAssert hp < 40

block idlePeonsAndArmorAreIntentional:
  let w = newLocalMatch(defaultConfig(2), ["", ""]).world
  let c = w.map.side div 2
  let a = w.spawnUnit(0, PeonUnit, tile2(c, c))
  let b = w.spawnUnit(1, PeonUnit, tile2(c + 1, c))
  w.rebuildVision()
  for tick in 1 .. 96: w.tickWorld(nil)
  doAssert w.units[w.unitIndex(a)].hp == 40
  doAssert w.units[w.unitIndex(b)].hp == 40
  doAssert attackDamage(unitOf(0, PeonUnit), 0) == 1
  doAssert attackDamage(unitOf(0, PeonUnit), unitOf(1, SoldierUnit).armor) == 0

block ffaPeaceThenAlliance:
  let w = newLocalMatch(defaultConfig(2), ["", ""]).world
  let enemyHome = w.map.hallOrigin[1]
  doAssert w.atWar(0, 1)
  doAssert not w.visible(0, enemyHome)
  doAssert w.applyDiplomacy(0, 1, OfferPeace)
  let peace = w.diplomacy.relation(0, 1).offerId
  doAssert w.atWar(0, 1), "An unaccepted offer cannot prevent damage"
  doAssert not w.applyDiplomacy(0, 1, AcceptOffer, peace)
  doAssert not w.applyDiplomacy(1, 0, AcceptOffer, peace + 1)
  doAssert w.applyDiplomacy(1, 0, AcceptOffer, peace)
  doAssert not w.atWar(0, 1)
  doAssert not w.diplomacy.sharesVision(0, 1)
  doAssert not w.visible(0, enemyHome)
  # The sender's offer cooldown survives acceptance; the recipient can offer
  # alliance immediately, or the original sender must wait warGraceSeconds.
  doAssert w.applyDiplomacy(1, 0, OfferAlliance)
  let alliance = w.diplomacy.relation(0, 1).offerId
  doAssert not w.visible(0, enemyHome)
  doAssert w.applyDiplomacy(0, 1, AcceptOffer, alliance)
  doAssert w.diplomacy.sharesVision(0, 1)
  doAssert w.visible(0, enemyHome)
  doAssert not w.atWar(0, 1)

block gameplayCompatibility:
  doAssert ReplayGameVersion >= 27
  var old = newLocalMatch(defaultConfig(2), ["", ""]).recorder.data
  old.header.gameVersion = 26
  var refused = false
  try: old.validate()
  except ReplayError: refused = true
  doAssert refused, "Version 26 requires its archived client"
