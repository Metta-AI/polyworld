## Compares spatial indexes on a verified replay, including each tick's rebuild.
## Compile with -d:headless and pass a GotA replay path.

import
  std/os,
  benchy, bumpy, spacy, vmath,
  polyworld/tapes,
  ../examples/gods_of_the_arena/[maps, replays, sim]

const
  SampleTicks = 60
  Repetitions = 30

type
  Actor = object
    id: int32
    point: WorldPoint
    available: array[Team, bool]
  Query = object
    entry: Entry
    point: WorldPoint
    radius: int32
    team: Team
    boundary: bool
  Frame = object
    actors: seq[Actor]
    queries: seq[Query]

if paramCount() != 1:
  quit("Usage: bench_gota_targeting path.replay", 1)

let
  replay = loadReplay(paramStr(1))
  game = newGame(
    generateMap(replay.config.seed, replay.config.mapPreset),
    replay.config.spawnIntervalTicks,
    0,
    true,
    replay
  )
var
  frames: seq[Frame]
  queries, actors: int
  reference: uint64

game.replayPlayer = initReplayPlayer(replay)
game.historyPlayback = true
for tick in 1 .. replay.hashes.len:
  game.tickWorld(nil)
  if tick mod SampleTicks != 0 or game.world.phase != Playing:
    continue
  let world = game.world
  var frame: Frame
  for index, unit in world.footmen:
    var actor = Actor(id: unit.id, point: unit.position)
    for team in Team:
      actor.available[team] = world.hostile(unit, team) and
        world.visible(team, unit.position)
    frame.actors.add actor
    if unit.hp > 0 and unit.state != Dying and unit.camp == 0 and
      unit.targetId == 0 and unit.targetHeroId == 0 and
      unit.targetBuildingId == 0:
        frame.queries.add Query(
          entry: Entry(
            id: uint32(index + 1),
            pos: vec2(unit.position.x.float32, unit.position.z.float32)
          ),
          point: unit.position,
          radius: FootmanSightRadius,
          team: unit.team
        )
  for tower in world.buildings:
    if tower.kind == TowerBuilding and tower.hp > 0 and tower.targetId == 0:
      frame.queries.add Query(
        entry: Entry(
          pos: vec2(tower.position.x.float32, tower.position.z.float32)
        ),
        point: tower.position,
        radius: TowerAttackRanges[tower.tier],
        team: tower.team,
        boundary: true
      )
  actors += frame.actors.len
  queries += frame.queries.len
  frames.add frame

game.hashCheck.requireReplayComplete(
  uint32(game.world.tick),
  replay.hashes.len
)
doAssert game.replayPlayer.finished
echo "Verified ", replay.hashes.len, " ticks; sampled ", frames.len,
  " rebuilds, ", queries, " acquisition queries, ", actors, " actors"

template benchmark(name: string, initial: untyped) =
  ## Measures reused indexes with integer range and stable target tie breaks.
  block:
    let space = initial
    var checksum: uint64
    timeIt name, Repetitions:
      checksum = 0
      for frame in frames:
        space.clear()
        for index, actor in frame.actors:
          let position = vec2(actor.point.x.float32, actor.point.z.float32)
          doAssert position.x.int32 == actor.point.x
          doAssert position.y.int32 == actor.point.z
          space.insert Entry(id: uint32(index + 1), pos: position)
        space.finalize()
        for query in frame.queries:
          var
            distance = int64(query.radius) * query.radius
            target: Actor
          for entry in space.findInRangeApprox(
            query.entry,
            query.radius.float + 1
          ):
            let actor = frame.actors[int(entry.id) - 1]
            if entry.id == query.entry.id or not actor.available[query.team]:
              continue
            let
              x = int64(actor.point.x) - query.point.x
              z = int64(actor.point.z) - query.point.z
              squared = x * x + z * z
              direction = if query.team == RedTeam: 1 else: -1
              before = target.id == 0 or
                (direction * actor.point.z, direction * actor.point.x,
                  actor.point.y, actor.id) <
                (direction * target.point.z, direction * target.point.x,
                  target.point.y, target.id)
            if squared < distance or
              (squared == distance and
              (target.id != 0 or query.boundary) and before):
                distance = squared
                target = actor
          checksum = checksum * 31 + uint64(target.id)
      if name == "BruteSpace":
        reference = checksum
    echo "  target checksum: ", checksum,
      (if checksum == reference: " matches" else: " INVALID")

let extent = replay.config.mapPreset.mapSize.float * WorldScale.float
benchmark("BruteSpace", newBruteSpace())
benchmark("SortSpace", newSortSpace())
for tiles in [5, 10, 20]:
  benchmark("HashSpace " & $tiles & " tiles",
    newHashSpace(tiles.float * WorldScale.float))
benchmark(
  "QuadSpace",
  newQuadSpace(rect(-extent, -extent, extent * 2, extent * 2))
)
benchmark(
  "KdSpace",
  newKdSpace(rect(-extent, -extent, extent * 2, extent * 2))
)
