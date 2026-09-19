## Deterministic, bounded Gods of the Arena replay summary.

import
  std/[os, parseutils, strformat, strutils],
  polyworld/tapes,
  ../[events, maps, replays, sim]

const
  DefaultReplayPath = "examples/gods_of_the_arena/replays/demo.replay"
  DefaultCheckpointSeconds = 120
  DefaultEvidenceLimit = 10
  MaximumEventWindow = 480
  MaximumRawEvents = 200
  FortObjectKind = 1'i32
  HeroObjectKind = 2'i32
  FootmanObjectKind = 3'i32
  TowerObjectKind = 4'i32
  BarracksObjectKind = 5'i32

type
  Options = object
    replayPath: string
    checkpointSeconds: int
    evidenceLimit: int
    eventStart, eventEnd: int
  HeroSummary = object
    actions: array[15, int64]
    rejected: int64
    damageDone, damageTaken, healingDone: int64
    heroKills, creepKills, structuresDestroyed: int64
    deaths, assists, goldGained, goldSpent, xpGained: int64
  Summary = object
    events: array[EventKind, int64]
    errors: array[ActionError, int64]
    heroes: seq[HeroSummary]
    firstEvidence, lastEvidence: seq[string]
    omittedEvidence: int
    rawEvents: seq[string]
    omittedRawEvents: int
    matchEnd: string

proc usage() =
  echo """usage: replay_extractor [OPTIONS] [REPLAY]

Resimulate a GotA replay and print a compact diagnostic handoff.

  --checkpoint-seconds N  progression sample interval (default: 120; 0 disables)
  --evidence N            first and last notable events retained (default: 10)
  --events START[:END]    include at most 480 ticks and 200 raw event records
  -h, --help              show this help

The default replay is examples/gods_of_the_arena/replays/demo.replay."""

proc natural(value, flag: string): int =
  if value.parseInt(result) != value.len or result < 0:
    quit(flag & " requires a non-negative integer", 1)

proc eventWindow(value: string): tuple[first, last: int] =
  let bounds = value.split(':')
  if bounds.len < 1 or bounds.len > 2:
    quit("--events requires START or START:END", 1)
  result.first = natural(bounds[0], "--events")
  result.last = result.first
  if bounds.len == 2:
    result.last = natural(bounds[1], "--events")
  if result.last < result.first:
    quit("--events END must not precede START", 1)
  if result.last - result.first + 1 > MaximumEventWindow:
    quit("--events spans more than " & $MaximumEventWindow & " ticks", 1)

proc options(): Options =
  result = Options(
    replayPath: DefaultReplayPath,
    checkpointSeconds: DefaultCheckpointSeconds,
    evidenceLimit: DefaultEvidenceLimit,
    eventStart: -1,
    eventEnd: -1
  )
  var positional = false
  var i = 1
  while i <= paramCount():
    let argument = paramStr(i)
    case argument
    of "-h", "--help":
      usage()
      quit(0)
    of "--checkpoint-seconds", "--evidence", "--events":
      if i == paramCount():
        quit(argument & " requires a value", 1)
      inc i
      if argument == "--events":
        (result.eventStart, result.eventEnd) = eventWindow(paramStr(i))
      else:
        let value = natural(paramStr(i), argument)
        if argument == "--checkpoint-seconds":
          result.checkpointSeconds = value
        else:
          result.evidenceLimit = value
    else:
      if argument.startsWith("-"):
        quit("unknown option: " & argument, 1)
      if positional:
        quit("only one replay path is accepted", 1)
      result.replayPath = argument
      positional = true
    inc i

proc actionName(kind: uint8): string =
  case kind
  of ActionWalkTo: "walk"
  of ActionAttackTarget: "attack-target"
  of ActionBuyItem: "buy"
  of ActionUseItem: "use-item"
  of ActionAttackMove: "attack-move"
  of ActionCastTarget: "cast-target"
  of ActionCastPoint: "cast-point"
  of ActionManualSpells: "manual-spells"
  else: "unknown-" & $kind

proc playerName(replay: ReplayData, slot: int): string =
  if slot >= 0 and slot < replay.config.players.len:
    result = replay.config.players[slot].name.strip()
  if result.len == 0:
    result = "Player " & $(slot + 1)
  result = result.replace("\n", " ").replace("\r", " ")

proc heroLabel(replay: ReplayData, entity: EventEntity): string =
  if entity.player >= 0:
    replay.playerName(entity.player.int) & "#" & $entity.id
  elif entity.id != 0:
    "entity#" & $entity.id
  else:
    "world"

proc remember(summary: var Summary, line: string, limit: int) =
  if limit == 0:
    return
  if summary.firstEvidence.len < limit:
    summary.firstEvidence.add line
  else:
    if summary.lastEvidence.len == limit:
      summary.lastEvidence.delete(0)
      inc summary.omittedEvidence
    summary.lastEvidence.add line

proc hero(summary: var Summary, entity: EventEntity): ptr HeroSummary =
  if entity.player >= 0 and entity.player.int < summary.heroes.len:
    addr summary.heroes[entity.player.int]
  else:
    nil

proc collect(
    summary: var Summary,
    replay: ReplayData,
    event: GameEvent,
    opts: Options
) =
  inc summary.events[event.kind]
  let actor = summary.hero(event.actor)
  let target = summary.hero(event.target)
  case event.kind
  of Damage:
    if actor != nil: actor[].damageDone += event.amount
    if target != nil: target[].damageTaken += event.amount
  of Healing:
    if actor != nil: actor[].healingDone += event.amount
  of Death:
    if actor != nil:
      case event.target.kind
      of HeroObjectKind: inc actor[].heroKills
      of FootmanObjectKind: inc actor[].creepKills
      of FortObjectKind, TowerObjectKind, BarracksObjectKind:
        inc actor[].structuresDestroyed
      else: discard
    if target != nil: inc target[].deaths
    if event.target.kind == HeroObjectKind or
        event.target.kind == FortObjectKind or
        event.target.kind == TowerObjectKind or
        event.target.kind == BarracksObjectKind:
      summary.remember(
        &"tick {event.tick}: death {replay.heroLabel(event.target)} " &
          &"by {replay.heroLabel(event.actor)} ({event.cause})",
        opts.evidenceLimit
      )
  of Assist:
    if actor != nil: inc actor[].assists
  of GoldGained:
    if target != nil: target[].goldGained += event.amount
  of GoldSpent:
    if target != nil: target[].goldSpent += abs(event.amount)
  of XpGained:
    if target != nil: target[].xpGained += event.amount
  of ActionRejected:
    if actor != nil: inc actor[].rejected
    inc summary.errors[event.error]
  of MatchEnded:
    summary.matchEnd = &"tick {event.tick}: {event.cause}, winner={event.amount}"
    summary.remember(summary.matchEnd, opts.evidenceLimit)
  else:
    discard
  if event.tick >= opts.eventStart and event.tick <= opts.eventEnd:
    if summary.rawEvents.len < MaximumRawEvents:
      summary.rawEvents.add $event
    else:
      inc summary.omittedRawEvents

proc progression(game: Game, tick, tickRate: int) =
  var
    alive, levels, gold: array[2, int]
  for hero in game.world.heroes:
    let team = hero.team.ord
    if hero.hp > 0 and hero.state != Dying:
      inc alive[team]
    levels[team] += hero.level
    gold[team] += hero.gold
  echo &"  tick={tick} seconds={tick div tickRate} " &
    &"fort_hp={game.world.forts[0].hp}/{game.world.forts[1].hp} " &
    &"alive={alive[0]}/{alive[1]} levels={levels[0]}/{levels[1]} " &
    &"gold={gold[0]}/{gold[1]} " &
    &"hero_kills={game.world.teamHeroKills[0]}/{game.world.teamHeroKills[1]}"

proc printCounts[T: enum](heading: string, counts: array[T, int64]) =
  echo heading
  for value in T:
    if counts[value] > 0:
      echo &"  {value}: {counts[value]}"

proc printHero(replay: ReplayData, game: Game, slot: int, value: HeroSummary) =
  let hero = game.world.heroes[slot]
  echo &"  slot={slot} name={replay.playerName(slot)} id={hero.id} " &
    &"team={hero.team} class={hero.class} level={hero.level} " &
    &"hp={hero.hp}/{hero.maxHp} gold={hero.gold}"
  var actions: seq[string]
  for kind, count in value.actions:
    if count > 0:
      actions.add actionName(kind.uint8) & "=" & $count
  echo "    decisions: " & actions.join(" ") & &" rejected={value.rejected}"
  echo &"    combat: damage_done={value.damageDone} damage_taken={value.damageTaken} " &
    &"healing={value.healingDone} hero_kills={value.heroKills} " &
    &"creep_kills={value.creepKills} structures={value.structuresDestroyed} " &
    &"deaths={value.deaths} assists={value.assists}"
  echo &"    economy: gold_gained={value.goldGained} gold_spent={value.goldSpent} " &
    &"xp_gained={value.xpGained}"

let
  opts = options()
  replay = loadReplay(opts.replayPath)
  game = newGame(
    generateMap(replay.config.seed, replay.config.mapPreset),
    replay.config.spawnIntervalTicks,
    0,
    true,
    replay
  )
var summary = Summary(heroes: newSeq[HeroSummary](game.world.heroes.len))

for action in replay.actions:
  let slot = game.world.heroIndex(action.heroId)
  if slot >= 0 and action.kind.int < summary.heroes[slot].actions.len:
    inc summary.heroes[slot].actions[action.kind.int]

game.replayPlayer = initReplayPlayer(replay)
game.historyPlayback = true

echo "REPLAY"
echo &"  path={opts.replayPath} version={ReplayGameVersion} " &
  &"seed={replay.config.seed} ticks={replay.hashes.len} " &
  &"seconds={replay.hashes.len div replay.header.setup.tickRate.int} " &
  &"actions={replay.actions.len}"
echo "PROGRESSION red/blue"
let tickRate = replay.header.setup.tickRate.int
progression(game, 0, tickRate)
let checkpointTicks = opts.checkpointSeconds * tickRate
for tick in 1 .. replay.hashes.len:
  game.tickWorld(nil)
  game.hashCheck.requireReplayComplete(uint32(game.world.tick), tick)
  for event in game.world.events:
    summary.collect(replay, event, opts)
  if checkpointTicks > 0 and
      (tick mod checkpointTicks == 0 or tick == replay.hashes.len):
    progression(game, tick, tickRate)

if not game.replayPlayer.finished:
  raise newException(ReplayError, "Replay has unconsumed actions")

echo "HEROES"
for slot, value in summary.heroes:
  printHero(replay, game, slot, value)
printCounts("EVENT_COUNTS", summary.events)
printCounts("REJECTION_COUNTS", summary.errors)
echo "EVIDENCE"
for line in summary.firstEvidence:
  echo "  " & line
if summary.omittedEvidence > 0:
  echo &"  ... {summary.omittedEvidence} notable events omitted ..."
for line in summary.lastEvidence:
  echo "  " & line
if opts.eventStart >= 0:
  echo &"RAW_EVENTS ticks={opts.eventStart}:{opts.eventEnd}"
  for line in summary.rawEvents:
    echo "  " & line
  if summary.omittedRawEvents > 0:
    echo &"  ... {summary.omittedRawEvents} raw events omitted ..."
echo "VERIFICATION"
echo &"  hashes={replay.hashes.len} mismatches={game.hashCheck.mismatches} " &
  &"actions_consumed={game.replayPlayer.actionIndex}/{replay.actions.len}"
echo "  match_end=" & (if summary.matchEnd.len > 0: summary.matchEnd else: "not recorded")
