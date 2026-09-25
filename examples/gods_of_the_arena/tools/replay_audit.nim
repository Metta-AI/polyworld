## Audit a hosted replay. Replays recorded actions only; never generates games.
## Build with pinned POLYWORLD_DEPS and -d:headless -d:replayEvents -d:ssl.
import std/[os, strutils, httpclient, json, tables]
import zippy
import polyworld/tapes
import ../[maps, replays, sim, content]

if paramCount() != 2:
  quit("Usage: replay_audit <hosted-url-or-replay-path> <output-prefix>", 1)
let source = paramStr(1)
let prefix = paramStr(2)
createDir(prefix.parentDir)
let path =
  if source.startsWith("https://"):
    let client = newHttpClient()
    defer: client.close()
    let target = prefix & ".replay"
    let bytes = client.getContent(source)
    writeFile(target, if bytes.startsWith("\x1f\x8b"): uncompress(bytes) else: bytes)
    target
  else: source
let bytes = readFile(path)
let replay = decodeReplay(if bytes.startsWith("\x1f\x8b"): uncompress(bytes) else: bytes)
let game = newGame(generateMap(replay.config.seed, replay.config.mapPreset),
  replay.config.spawnIntervalTicks, 0, true, replay)
game.replayPlayer = initReplayPlayer(replay)
game.historyPlayback = true

proc actionName(kind: uint8): string =
  case kind
  of ActionWalkTo: "walk"
  of ActionAttackTarget: "attackTarget"
  of ActionBuyItem: "buyItem"
  of ActionUseItem: "useItem"
  of ActionAttackMove: "attackMove"
  of ActionCastTarget: "castTarget"
  of ActionCastPoint: "castPoint"
  of ActionUseItemAt: "useItemAt"
  of ActionLevelAbility: "levelAbility"
  of ActionBuyback: "buyback"
  of ActionDraft: "draft"
  else: "unknown"

proc bump(node: JsonNode, key: string, amount = 1'i64) =
  node[key] = %(if node.hasKey(key): node[key].getBiggestInt + amount else: amount)

var summaries = newJArray()
var byId = initTable[int32, int]()
for i, hero in replay.header.setup.heroes:
  byId[hero.id] = i
  summaries.add %*{
    "seat": i, "player": replay.config.players[i].name, "heroId": hero.id,
    "team": hero.team, "initialClass": $HeroClass(hero.class),
    "actions": {}, "rejections": {}, "events": {}, "damageByTargetKind": {},
    "damageByCause": {}, "purchases": [], "levels": [], "casts": {},
    "deaths": [], "openingActions": [], "snapshots": [],
    "receivedXpSources": {}, "receivedXpEvents": {}, "killTargetKinds": {},
    "portals": [], "healingReceived": {}}
let actionLog = open(prefix & ".actions.jsonl", fmWrite)
for action in replay.actions:
  let seat = byId[action.heroId]
  let j = %*{"tick": action.tick, "seat": seat, "kind": actionName(action.kind),
    "slot": action.slot, "first": action.first, "second": action.second,
    "offset": $action.offset}
  actionLog.writeLine($j)
  summaries[seat]["actions"].bump(actionName(action.kind))
  if summaries[seat]["openingActions"].len < 40:
    summaries[seat]["openingActions"].add j
let eventLog = open(prefix & ".events.jsonl", fmWrite)
for tick in 0 .. replay.hashes.len:
  if tick > 0:
    game.tickWorld(nil)
    game.hashCheck.requireReplayComplete(uint32(game.world.tick), tick)
  for event in game.world.events:
    eventLog.writeLine($(%event))
    let seat = int(event.actor.player)
    if seat >= 0 and seat < summaries.len:
      let s = summaries[seat]
      s["events"].bump($event.kind)
      case event.kind
      of ActionRejected:
        s["rejections"].bump(actionName(event.action) & ":" & $event.error)
      of ItemPurchased:
        s["purchases"].add %*{"tick": tick, "item": $itemFromId(event.detail)}
      of AbilityLeveled:
        s["levels"].add %*{"tick": tick, "ability": $Ability(event.detail),
          "rank": event.after}
      of SpellReleased:
        s["casts"].bump($Ability(event.detail))
      of Damage:
        s["damageByTargetKind"].bump($event.target.kind, event.amount)
        s["damageByCause"].bump($event.cause, event.amount)
      of Death:
        s["killTargetKinds"].bump($event.target.kind)
      of PortalStarted, PortalCompleted, PortalInterrupted:
        s["portals"].add %event
      else: discard
    let targetSeat = int(event.target.player)
    if targetSeat >= 0 and targetSeat < summaries.len:
      let s = summaries[targetSeat]
      if event.kind == XpGained and event.amount > 0:
        let key = $event.actor.kind & ":" & $event.cause
        s["receivedXpSources"].bump(key, event.amount)
        s["receivedXpEvents"].bump(key)
      elif event.kind == Healing and event.amount > 0:
        s["healingReceived"].bump($event.cause, event.amount)
    if event.kind == Death and event.target.player >= 0:
      summaries[event.target.player.int]["deaths"].add %event
  if tick mod (24 * 30) == 0 or tick == replay.hashes.len:
    for i, hero in game.world.heroes:
      summaries[i]["snapshots"].add %*{"tick": tick, "class": $hero.class,
        "x": hero.position.x, "z": hero.position.z, "hp": hero.hp,
        "maxHp": hero.maxHp, "mana": hero.mana, "level": hero.level,
        "gold": hero.gold, "deaths": hero.deaths, "inventory": $hero.inventory,
        "totalXp": hero.totalXp,
        "attackObjectId": hero.attackObjectId, "attackingFort": hero.attackingFort,
        "moveX": hero.moveTileX, "moveY": hero.moveTileY,
        "hasMoveTarget": hero.hasMoveTarget}
if not game.replayPlayer.finished:
  raise newException(ReplayError, "Replay has unconsumed actions")
let output = %*{"source": source, "gameVersion": ReplayGameVersion,
  "seed": replay.config.seed, "recordedTicks": replay.hashes.len,
  "verifiedHashes": replay.hashes.len, "mismatches": game.hashCheck.mismatches,
  "players": summaries}
writeFile(prefix & ".summary.json", output.pretty & "\n")
actionLog.close()
eventLog.close()
echo "Verified ", replay.hashes.len, " hashes; wrote ", prefix, ".summary.json"
