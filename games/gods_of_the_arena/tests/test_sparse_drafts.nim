## Sparse drafts use occupied lobby seats, not a fixed ten-player counter.
import jsony
import polyworld/[rooms, roomclients, tapes]
import ../[bots, content, controls, game, maps, multiplayer, replays, sim]

let base = readFile("games/gods_of_the_arena/players/base.bas")
for seats in [@[8], @[3, 8], @[0, 4, 8], @[0, 1, 3, 4, 5, 7, 9]]:
  var sources: array[10, string]
  for seat in seats:
    if seat != seats[0]: sources[seat] = base
  initializeLocalMatch(parseConfig("{\"maxTicks\":3,\"draftMode\":\"open\"}"), sources, seats[0])
  doAssert run.world.heroes.len == seats.len
  doAssert run.world.draftOrder.len == seats.len
  let humanId = FirstHeroId + seats[0].int32
  var humanPicked = false
  while not run.finished():
    run.tickWorld(proc() =
      if run.world.draftHeroId() == humanId:
        queueDraft(humanId, 0)
        humanPicked = true
      let turn = run.world.draftHeroId()
      run.flushPlayerCommands()
      if turn == 0 or turn == run.world.draftHeroId(): run.runBotDecisions()
    )
    doAssert run.world.tick < 240, "Local sparse bots must not wait for absent slots"
  doAssert humanPicked and run.world.draftTurn == seats.len
  for hero in run.world.heroes: doAssert hero.drafted
  let data = decodeReplay(encodeReplay(run.recorder.data))
  let replay = newGame(run.map, data.config.spawnIntervalTicks, 0, true, data)
  replay.historyPlayback = true
  replay.replayPlayer = initReplayPlayer(data)
  for i in 0 ..< data.hashes.len: replay.tickWorld(nil)
  doAssert replay.hashCheck.mismatches == 0 and replay.stateHash() == run.stateHash()
  echo "Local human+bot sparse draft seats=", seats, " picks=", run.world.draftTurn,
    " draftTicks=", run.world.draftTicks, " replay mismatches=0"

for seats in [@[8], @[3, 8], @[0, 4, 8], @[0, 1, 3, 4, 5, 7, 9], @[0, 2, 4]]:
  for mode in ["unique", "team", "open"]:
    for timeout in [false, true]:
      let config = parseConfig("{\"maxTicks\":3,\"draftMode\":\"" & mode & "\"}")
      var snapshot = RoomMessage(kind: RoomState, revision: 1, tickRate: 24,
        payload: config.toJson(), seats: newSeq[Seat](10),
        participants: @[Participant(id: 99, name: "Peer")])
      for seat in seats:
        snapshot.participants.add Participant(id: uint32(seat + 1), name: "Player " & $seat)
        snapshot.seats[seat] = Seat(owner: uint32(seat + 1), name: "Human")
      let a = RoomClient(began: true, welcomed: true, match: 1, participant: uint32(seats[0] + 1), snapshot: snapshot)
      let b = RoomClient(began: true, welcomed: true, match: 1, participant: 99, snapshot: snapshot)
      let first = prepareNetworkMatch(a, newSeq[string](10))
      let second = prepareNetworkMatch(b, newSeq[string](10))
      let world = first.game.world
      doAssert world.heroes.len == seats.len and world.draftOrder.len == seats.len
      doAssert first.game.durationTicks() == 3 + seats.len.int32 * DraftPickTicks
      for i, hero in world.heroes:
        doAssert hero.id == FirstHeroId + seats[i].int32
      # Independent expected alternating-team order, retaining original seats.
      var remaining = seats
      var team = world.heroes[world.draftOrder[0]].team.ord
      var expected: seq[int32]
      while remaining.len > 0:
        var selected = -1
        for i, seat in remaining:
          if seat div 5 == team:
            selected = i
            break
        if selected >= 0:
          expected.add FirstHeroId + remaining[selected].int32
          remaining.delete(selected)
        team = 1 - team
      for i, index in world.draftOrder:
        doAssert world.heroes[index].id == expected[i]
      let begin = RoomMessage(kind: BeginMatch, revision: 1, match: 1, hash: first.game.networkHash())
      doAssert begin.hash == second.game.networkHash()
      first.start(begin)
      second.start(begin)
      var tick = 0'u32
      while not first.finished:
        inc tick
        let oldTurn = world.draftTurn
        var packet = RoomMessage(kind: TickPacket, match: 1, tick: tick)
        if world.phase == Drafting:
          doAssert world.draftHeroId() == expected[oldTurn]
          if not timeout:
            var classId = 0'i32
            while not world.heroAvailable(classId): inc classId
            let id = world.draftHeroId()
            packet.commands.add Command(participant: uint32(id - FirstHeroId + 1), seat: uint32(id - FirstHeroId),
              payload: GameSubmission(action: ReplayAction(heroId: id, kind: ActionDraft,
                first: classId)).encodeSubmission())
        first.applyPacket(packet)
        second.applyPacket(packet)
        doAssert first.game.stateHash() == second.game.stateHash()
        if timeout and oldTurn < seats.len:
          doAssert world.draftTurn == min(int(tick) div DraftPickTicks, seats.len)
        a.outgoing.setLen(0)
        b.outgoing.setLen(0)
        doAssert int(tick) <= seats.len * DraftPickTicks + 3
      let draftTicks = if timeout: seats.len * DraftPickTicks else: seats.len
      doAssert world.phase == Playing and world.draftHeroId() == 0
      doAssert world.draftTurn == seats.len and world.draftTicks == draftTicks
      doAssert world.tick == draftTicks + 3 and world.battleTick() == 3
      for hero in world.heroes: doAssert hero.drafted
      let data = decodeReplay(encodeReplay(first.game.recorder.data))
      data.validate()
      doAssert data.header.setup.heroes.len == seats.len
      doAssert data.actions.len == (if timeout: 0 else: seats.len)
      let replay = newGame(generateMap(data.config.seed, data.config.mapPreset),
        data.config.spawnIntervalTicks, 0, true, data)
      replay.historyPlayback = true
      replay.replayPlayer = initReplayPlayer(data)
      var checkpoint: World
      for i in 0 ..< data.hashes.len:
        replay.tickWorld(nil)
        if i == 0: checkpoint = replay.world.clone()
      doAssert replay.hashCheck.mismatches == 0
      doAssert replay.stateHash() == first.game.stateHash()
      replay.world.restore(checkpoint)
      replay.replayPlayer.syncCursor(checkpoint.tick.uint32)
      for i in checkpoint.tick.int ..< data.hashes.len: replay.tickWorld(nil)
      doAssert replay.hashCheck.mismatches == 0
      doAssert replay.stateHash() == first.game.stateHash()
      echo "Sparse draft seats=", seats, " mode=", mode, " timeout=", timeout,
        " picks=", world.draftTurn, " draftTicks=", world.draftTicks,
        " peer/replay/seek mismatches=0"
