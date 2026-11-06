## LvD owns gameplay bytes; the universal relay only orders seat commands.
import jsony, polyworld/[rooms, roomclients, tapes, metrics, bodies, hashes, mailboxes],
  bots, content, controls, presets, replays, sim

const LvdNetworkProtocol* = 3'u32

type NetworkMatch* = ref object
  client*: RoomClient
  game*: Game
  revision*: uint32
  playerSeats*: seq[int] ## Packed simulation player -> stable lobby seat.
  started*, finished*: bool
  decisionTick: int32 = -1

proc lvdIdentity*(): GameIdentity =
  GameIdentity(game: ReplayGame, gameplay: uint32(ReplayGameVersion),
    protocol: LvdNetworkProtocol)

proc networkHash*(game: Game): uint64 =
  var hash = HashySeed
  hash.addHashy(game.config.toJson())
  hash.addHashy(game.recorder.data.header.setup.toJson())
  for action in game.networkActions:
    hash.addHashy(action.toJson())
  (uint64(hash) shl 32) or game.stateHash()

proc humanSeatFor*(snapshot: RoomMessage, participant: uint32): int =
  result = -1
  for i, seat in snapshot.seats:
    if participant != 0 and seat.owner == participant and seat.name == "Human":
      if result >= 0: reject("Each participant can control only one human slot")
      result = i

proc claimHumanSeat*(client: RoomClient, seat: int, previous = -1) =
  if client.participant == 0 or seat notin 0 ..< client.snapshot.seats.len or
    client.snapshot.seats[seat].owner notin [0'u32, client.participant]:
      reject("Cannot take another participant's slot")
  for i, current in client.snapshot.seats:
    if i != seat and (i == previous or
      (current.owner == client.participant and current.name == "Human")) and
      current.owner in [0'u32, client.participant]:
        client.send(RoomMessage(kind: ReleaseSeat, seat: uint32(i)))
  client.send(RoomMessage(kind: ClaimSeat, seat: uint32(seat), name: "Human"))

proc encodeSubmission*(action: ReplayAction): string =
  for value in [int32(action.kind), action.playerId, action.entityId,
      action.first, action.second, action.third,
      int32(action.offset.x), int32(action.offset.y), int32(action.append)]:
    result.put32(cast[uint32](value))

proc decodeSubmission*(bytes: string): ReplayAction =
  var reader = PacketReader(data: bytes)
  let kind = reader.get32()
  if kind < uint32(ActionMove) or kind > uint32(ActionKindHigh):
    reject("Unknown LvD action")
  result.kind = uint8(kind)
  result.playerId = cast[int32](reader.get32())
  result.entityId = cast[int32](reader.get32())
  result.first = cast[int32](reader.get32())
  result.second = cast[int32](reader.get32())
  result.third = cast[int32](reader.get32())
  result.offset.x = Fixed(cast[int32](reader.get32()))
  result.offset.y = Fixed(cast[int32](reader.get32()))
  let append = reader.get32()
  if append > 1: reject("Invalid LvD append flag")
  result.append = append == 1
  if reader.cursor != bytes.len or not result.offset.validTileOffset:
    reject("Invalid LvD command length or tile offset")

proc encodeChat*(chat: ChatSubmission): string =
  result.put32(0)
  result.put32(cast[uint32](chat.player))
  result.put32(cast[uint32](chat.target))
  result.putString(chat.text)

proc decodeChat(bytes: string): ChatSubmission =
  var reader = PacketReader(data: bytes)
  if reader.get32() != 0: reject("Unknown LvD mailbox payload")
  result.player = cast[int32](reader.get32())
  result.target = cast[int32](reader.get32())
  result.text = reader.getString(MaxChatBytes)
  if reader.cursor != bytes.len: reject("Trailing LvD mailbox bytes")

proc newLocalMatch*(config: LvdConfig, sources: openArray[string]): Game =
  config.validate()
  if sources.len != config.playerCount:
    reject("Policies must match the complete player roster")
  let map = generateMap(config.seed, config.playerCount, config.mapSettings)
  map.validateMap()
  result = newGame(map, config.maxTicks, config.diplomacySettings)
  var setup = Setup(mapSeed: config.seed, tickRate: uint16(TickRate),
    gridTiles: uint16(map.side), decisionTicks: uint16(DecisionTicks),
    maximumTicks: uint32(config.maxTicks), mapHash: map.hash,
    contentHash: contentHash(), mapSettings: config.mapSettings,
    diplomacySettings: config.diplomacySettings)
  for i, origin in map.hallOrigin:
    setup.players.add ReplayPlayerSetup(id: int32(i),
      startX: int32(origin.x), startY: int32(origin.y))
  result.recorder = initReplayRecorder(setup)
  result.recorder.data.config = config.gameConfig()
  result.replayPlayer = ReplayPlayer(data: result.recorder.data)
  result.loadBots(sources)
  clearPlayerCommands()

proc prepareNetworkMatch*(client: RoomClient,
    sources: openArray[string]): NetworkMatch =
  let snapshot = client.snapshot
  var config = parseConfig(snapshot.payload)
  if client.identity != lvdIdentity() or snapshot.tickRate != uint32(TickRate) or
    snapshot.seats.len != config.playerCount:
      reject("LvD identity, roster, or tick rate differs from room setup")
  config.playerSlot = 0
  let potentialPlayers = config.players
  config.players = @[]
  var owned: seq[string]
  var playerSeats: seq[int]
  for i, seat in snapshot.seats:
    if seat.owner == 0: continue
    discard snapshot.humanSeatFor(seat.owner)
    let player = config.players.len
    config.players.add potentialPlayers[i]
    playerSeats.add i
    owned.add ""
    config.players[player].name = seat.name
    if seat.name == "Human":
      config.players[player].name = ""
      for participant in snapshot.participants:
        if participant.id == seat.owner:
          config.players[player].name = participant.name
      if config.players[player].name.len == 0:
        reject("Human seat has no named participant")
    elif seat.owner == client.participant and i < sources.len:
      owned[player] = sources[i]
  config.playerCount = config.players.len
  if config.playerCount == 0: reject("At least one occupied seat is required")
  let game = newLocalMatch(config, owned)
  game.networked = true
  NetworkMatch(client: client, game: game, revision: snapshot.revision,
    playerSeats: playerSeats)

proc reopenedLobby*(session: NetworkMatch): bool =
  ## The owner may reopen while another participant still views the results.
  ## Yield the finished renderer so the frontend can prepare the next revision.
  session != nil and session.started and session.client != nil and
    session.client.snapshot.room.len > 0 and session.client.snapshot.phase == Lobby

proc playerForSeat*(session: NetworkMatch, seat: int): int =
  result = -1
  for player, stableSeat in session.playerSeats:
    if stableSeat == seat: return player

proc humanPlayerFor*(session: NetworkMatch, participant: uint32): int =
  session.playerForSeat(session.client.snapshot.humanSeatFor(participant))

proc submissionSeat(session: NetworkMatch, player: int32): uint32 =
  if player < 0 or player >= session.playerSeats.len:
    reject("LvD submission player is outside the occupied roster")
  uint32(session.playerSeats[player])

proc flushSubmissions*(session: NetworkMatch) =
  session.game.flushPlayerCommands()
  for action in session.game.submissions:
    if action.playerId < 0 or not session.client.submit(
      session.submissionSeat(action.playerId), action.encodeSubmission()):
        reject("Unable to queue a local LvD command")
  session.game.submissions.setLen(0)
  for chat in session.game.chatSubmissions:
    if chat.player < 0 or not session.client.submit(
      session.submissionSeat(chat.player), chat.encodeChat()):
        reject("Unable to queue a local LvD mailbox message")
  session.game.chatSubmissions.setLen(0)

proc decide(session: NetworkMatch) =
  if session.decisionTick == session.game.world.tick or session.finished:
    return
  session.decisionTick = session.game.world.tick
  if session.game.world.tick mod DecisionTicks == 0:
    session.game.runBotDecisions()
  session.flushSubmissions()

proc start*(session: NetworkMatch, event: RoomMessage) =
  if session.started or event.kind != BeginMatch or
    event.match != session.client.match or event.revision != session.revision:
      reject("LvD setup changed before startup")
  if event.hash != session.game.networkHash():
    reject("LvD initial state differs from agreed hash")
  session.client.send(RoomMessage(kind: ReportHash, match: session.client.match,
    tick: 0, hash: session.game.networkHash()))
  session.started = true
  session.decide()

proc applyPacket*(session: NetworkMatch, packet: RoomMessage) =
  let game = session.game
  let client = session.client
  if not session.started or session.finished or packet.kind != TickPacket or
    packet.match != client.match or packet.tick != uint32(game.world.tick + 1):
      reject("LvD received an unexpected simulation tick")
  var actions: seq[ReplayAction]
  var chats: seq[ChatSubmission]
  for command in packet.commands:
    if command.participant == 0 or command.seat >= uint32(client.snapshot.seats.len) or
      client.snapshot.seats[command.seat].owner != command.participant:
        reject("Command participant does not own this seat")
    var reader = PacketReader(data: command.payload)
    if reader.get32() == 0:
      let chat = decodeChat(command.payload)
      if chat.player != int32(session.playerForSeat(int(command.seat))) or chat.target < -2 or
        chat.target == -1 or chat.target >= game.world.players.len:
          reject("Invalid LvD mailbox sender or target")
      chats.add chat
      continue
    var action = decodeSubmission(command.payload)
    action.tick = packet.tick
    try:
      action.validateAction(game.recorder.data.header.setup)
    except ReplayError as error:
      reject(error.msg)
    if action.playerId != int32(session.playerForSeat(int(command.seat))):
      reject("LvD command player does not belong to this seat")
    if action.kind != ActionDiplomacy:
      let index = game.world.unitIndex(action.entityId)
      if (index >= 0 and game.world.units[index].owner != action.playerId) or
        (action.entityId.isPlayerBuildingId and
          game.world.buildingOwner(action.entityId) >= 0 and
          game.world.buildingOwner(action.entityId) != action.playerId):
            reject("LvD entity belongs to another player")
    actions.add action
  for chat in chats:
    discard game.deliverChat(int(chat.player), int(chat.target), chat.text)
  game.networkActions.add actions
  proc apply(w: World) =
    for pending in game.networkActions:
      var action = pending
      action.tick = uint32(w.tick)
      if w.applyReplayAction(action):
        game.recorder.record(action)
        game.metrics.command(int(action.playerId), w.tick)
    game.networkActions.setLen(0)
  game.world.tickWorld(apply)
  if uint32(game.world.tick) != packet.tick:
    reject("LvD failed to execute authoritative tick")
  game.recorder.recordHash(game.stateHash())
  session.finished = game.world.over or game.world.tick >= game.maximumTicks
  game.sampleMetrics(session.finished)
  game.metrics.finishTick(game.world.tick)
  client.appliedTick(packet.tick)
  if packet.tick mod uint32(TickRate) == 0:
    client.send(RoomMessage(kind: ReportHash, match: client.match,
      tick: packet.tick, hash: game.networkHash()))
  if session.finished:
    client.send(RoomMessage(kind: FinishMatch, match: client.match,
      tick: packet.tick, hash: game.networkHash()))
  else:
    session.decide()

proc advance*(session: NetworkMatch): bool =
  var packet: RoomMessage
  if session.started and not session.finished and session.client.takeTick(packet):
    session.applyPacket(packet)
    result = true

proc pump*(session: NetworkMatch, maxTicks = 8): int =
  while result < maxTicks and session.advance(): inc result

proc abort*(session: NetworkMatch, detail: string) =
  session.client.error = detail
  session.client.snapshot.phase = Desynced
  session.client.send(RoomMessage(kind: AbortMatch, match: session.client.match,
    detail: detail))
