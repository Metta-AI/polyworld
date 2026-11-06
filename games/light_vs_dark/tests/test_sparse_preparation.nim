import std/unittest
import jsony, polyworld/[rooms, roomclients, tapes, mailboxes]
import ../[multiplayer, presets, sim, replays, content, controls]

proc sparseClient(id: uint32): RoomClient =
  var config = defaultConfig(4)
  config.maxTicks = 12
  config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
  result = RoomClient(identity: lvdIdentity(), participant: id, match: 1,
    began: true, welcomed: true)
  result.snapshot = RoomMessage(kind: RoomState, revision: 2, phase: Playing,
    tickRate: uint32(TickRate), payload: config.toJson(), seats: @[
      Seat(), Seat(owner: 1, name: "Human"), Seat(), Seat(owner: 2, name: "Human")],
    participants: @[Participant(id: 1, name: "Alice"), Participant(id: 2, name: "Bob")])

suite "LvD sparse preparation":
  test "packed human selection and empty stable seats stay distinct":
    let session = prepareNetworkMatch(sparseClient(2), [])
    check session.humanPlayerFor(1) == 0
    check session.humanPlayerFor(2) == 1
    check session.humanPlayerFor(99) == -1
    check session.playerForSeat(0) == -1
    check session.playerForSeat(2) == -1
    check session.playerForSeat(3) == 1

  test "private bots and chat use stable outer seats and packed inner players":
    let host = sparseClient(2)
    let peer = sparseClient(1)
    host.snapshot.seats[3].name = "Private bot"
    peer.snapshot.seats[3].name = "Private bot"
    let a = prepareNetworkMatch(host, ["ignored", "ignored", "ignored",
      "a = offerPeace(0)\na = sendChat(-2, \"hello\")"])
    let b = prepareNetworkMatch(peer, [])
    check a.game.networkHash() == b.game.networkHash()
    check a.game.brains[1] != nil
    check b.game.brains[1] == nil
    let event = RoomMessage(kind: BeginMatch, match: 1, revision: 2,
      hash: a.game.networkHash())
    a.start(event)
    b.start(event)
    var commands: seq[Command]
    for bytes in host.outgoing:
      let message = decode(bytes)
      if message.kind == SubmitCommand:
        check message.seat == 3
        commands.add Command(participant: 2, seat: message.seat,
          sequence: message.sequence, payload: message.payload)
    require commands.len == 2
    let packet = RoomMessage(kind: TickPacket, match: 1, tick: 1, commands: commands)
    a.applyPacket(packet)
    b.applyPacket(packet)
    check a.game.inboxes[0].count == 1
    check a.game.networkHash() == b.game.networkHash()
    check a.game.recorder.data.actions.len == 1
    check a.game.recorder.data.actions[0].playerId == 1

  test "a stable-seat payload cannot impersonate another packed player":
    let session = prepareNetworkMatch(sparseClient(2), [])
    session.start(RoomMessage(kind: BeginMatch, match: 1, revision: 2,
      hash: session.game.networkHash()))
    let baseline = session.game.networkHash()
    let spoof = ReplayAction(kind: ActionDiplomacy, playerId: 0,
      first: 1, second: int32(DeclareWar))
    expect RoomsError:
      session.applyPacket(RoomMessage(kind: TickPacket, match: 1, tick: 1,
        commands: @[Command(participant: 2, seat: 3, payload: spoof.encodeSubmission())]))
    check session.game.networkHash() == baseline
    check session.game.world.tick == 0

  test "occupied humans alone create deterministic packed worlds and replay":
    let a = prepareNetworkMatch(sparseClient(1), [])
    let b = prepareNetworkMatch(sparseClient(2), [])
    check a.game.world.players.len == 2
    check a.game.config.players[0].name == "Alice"
    check a.game.config.players[1].name == "Bob"
    check a.game.networkHash() == b.game.networkHash()
    let event = RoomMessage(kind: BeginMatch, match: 1, revision: 2,
      hash: a.game.networkHash())
    a.start(event)
    b.start(event)
    var commands: seq[Command]
    for player, session in [a, b]:
      var own = -1
      for i, unit in session.game.world.units:
        if unit.owner == int32(player): own = i; break
      require own >= 0
      let unit = session.game.world.units[own]
      queueMove(int32(player), unit.id, int32(unit.tile.x), int32(unit.tile.y))
      session.flushSubmissions()
      for bytes in session.client.outgoing:
        let message = decode(bytes)
        if message.kind == SubmitCommand:
          check message.seat == uint32(if player == 0: 1 else: 3)
          commands.add Command(participant: session.client.participant,
            seat: message.seat, sequence: message.sequence, payload: message.payload)
    require commands.len == 2
    for tick in 1'u32 .. 12'u32:
      let packet = RoomMessage(kind: TickPacket, match: 1, tick: tick,
        commands: (if tick == 1: commands else: @[]))
      a.applyPacket(packet)
      b.applyPacket(packet)
      check a.game.networkHash() == b.game.networkHash()
    let data = decodeReplay(encodeReplay(a.game.recorder.data))
    check data.actions.len == 2
    check data.header.setup.players.len == 2
    let playback = newGame(a.game.world.map, 12, data.header.setup.diplomacySettings)
    let cursor = initReplayPlayer(data)
    proc replay(w: World) =
      var action: ReplayAction
      while cursor.takeActionAt(uint32(w.tick), action):
        doAssert w.applyReplayAction(action)
    for tick in 1 .. data.hashes.len:
      playback.world.tickWorld(replay)
      check playback.stateHash() == data.hashes[tick - 1]
