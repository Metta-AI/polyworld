import
  jsony,
  polyworld/[rooms, roomclients, tapes, metrics, mailboxes, bodies, hashes],
  bots, content, controls, maps, presets, replays, sim

const GotaNetworkProtocol* = 1'u32

type NetworkMatch* = ref object
  client*: RoomClient
  game*: Game
  revision*: uint32
  started*, finished*: bool
  decisionTick: int32 = -1

proc networkHash*(game: Game): uint64 =
  ## Includes immutable configuration alongside the normal replay state hash.
  var configHash = HashySeed
  configHash.addHashy(game.config.toJson())
  (uint64(configHash) shl 32) or game.stateHash()

proc gotaIdentity*(): GameIdentity =
  ## Identifies the exact gameplay and game-command protocol on this client.
  GameIdentity(
    game: ReplayGame, gameplay: uint32(ReplayGameVersion),
    protocol: GotaNetworkProtocol
  )

proc humanSeatFor*(snapshot: RoomMessage, participant: uint32): int =
  ## Finds a participant's human seat and rejects duplicate assignments.
  result = -1
  for i, seat in snapshot.seats:
    if seat.owner == participant and participant != 0 and seat.name == "Human":
      if result >= 0:
        reject("Each participant can control only one human slot")
      result = i

proc claimHumanSeat*(client: RoomClient, seat: int, previous = -1) =
  ## Moves the local human, including a claim still awaiting acknowledgement.
  if seat < 0 or seat >= client.snapshot.seats.len or
    client.snapshot.seats[seat].owner notin [0'u32, client.participant]:
      reject("Cannot take another participant's slot")
  for i, current in client.snapshot.seats:
    if i != seat and (i == previous or
      (current.owner == client.participant and current.name == "Human")):
        if current.owner in [0'u32, client.participant]:
          client.send(RoomMessage(kind: ReleaseSeat, seat: uint32(i)))
  client.send(RoomMessage(kind: ClaimSeat, seat: uint32(seat), name: "Human"))

proc encodeSubmission*(submission: GameSubmission): string =
  ## Encodes game-owned bytes that the relay never interprets.
  let action = submission.action
  result.put32(uint32(submission.mailbox))
  result.put32(cast[uint32](action.heroId))
  if submission.mailbox:
    result.put32(cast[uint32](action.first))
    result.putString(submission.text)
  else:
    result.put32(uint32(action.kind))
    result.put32(cast[uint32](action.slot))
    result.put32(cast[uint32](action.first))
    result.put32(cast[uint32](action.second))
    result.put32(cast[uint32](int32(action.offset.x)))
    result.put32(cast[uint32](int32(action.offset.y)))

proc decodeSubmission*(bytes: string): GameSubmission =
  ## Checks the complete game payload before it can reach the simulation.
  var reader = PacketReader(data: bytes)
  let kind = reader.get32()
  if kind > 1:
    reject("Unknown GotA command category")
  result.mailbox = kind == 1
  result.action.heroId = cast[int32](reader.get32())
  if result.mailbox:
    result.action.first = cast[int32](reader.get32())
    result.text = reader.getString(MaxChatBytes)
  else:
    let actionKind = reader.get32()
    if actionKind notin [uint32(ActionWalkTo), ActionAttackTarget,
      ActionBuyItem, ActionUseItem, ActionAttackMove, ActionCastTarget,
      ActionCastPoint, ActionUseItemAt, ActionLevelAbility, ActionBuyback,
      ActionDraft]:
        reject("Unknown GotA action")
    result.action.kind = uint8(actionKind)
    result.action.slot = cast[int32](reader.get32())
    result.action.first = cast[int32](reader.get32())
    result.action.second = cast[int32](reader.get32())
    result.action.offset.x = Fixed(cast[int32](reader.get32()))
    result.action.offset.y = Fixed(cast[int32](reader.get32()))
    if not result.action.offset.validTileOffset:
      reject("Invalid fractional tile offset")
  if reader.cursor != bytes.len:
    reject("Trailing GotA command bytes")

proc prepareNetworkMatch*(
    client: RoomClient, sources: openArray[string]
): NetworkMatch =
  ## Loads only locally owned policies and builds the shared initial world.
  let snapshot = client.snapshot
  if snapshot.tickRate != uint32(TickRate) or
    snapshot.seats.len != HeroClassCount:
      reject("GotA requires ten seats and 24 ticks per second")
  for seat in snapshot.seats:
    if seat.owner != 0 and seat.name == "Human":
      discard snapshot.humanSeatFor(seat.owner)
  var config = parseConfig(snapshot.payload)
  config.playerSlot = 0
  config.players.setLen(HeroClassCount)
  for i, seat in snapshot.seats:
    config.players[i].name = seat.name
  let
    map = generateMap(config.seed, config.mapPreset)
    game = newGame(
      map, config.spawnIntervalTicks, HeroClassCount, false, ReplayData(),
      draftMode = config.draftMode
    )
  game.networked = true
  game.recorder = initReplayRecorder(
    currentSetup(game, uint32(config.maxTicks)), map.preset
  )
  game.recorder.data.config = config
  game.replayPlayer = ReplayPlayer(data: game.recorder.data)
  var ownedSources = newSeq[string](HeroClassCount)
  for i, seat in snapshot.seats:
    if seat.owner == client.participant and i < sources.len:
      ownedSources[i] = sources[i]
  game.loadBotSources(ownedSources)
  result = NetworkMatch(client: client, game: game, revision: snapshot.revision)

proc flushSubmissions*(session: NetworkMatch) =
  ## Submits human and private bot intents through one ownership-checked path.
  session.game.flushPlayerCommands()
  for submission in session.game.submissions:
    let index = session.game.world.heroIndex(submission.action.heroId)
    if index < 0 or not session.client.submit(
      uint32(index), submission.encodeSubmission()
    ):
      reject("Unable to queue a local GotA command")
  session.game.submissions.setLen(0)

proc decide(session: NetworkMatch) =
  ## Runs each locally owned VM once per authoritative state, never on replay.
  if session.decisionTick == session.game.world.tick or session.finished:
    return
  session.decisionTick = session.game.world.tick
  session.game.runBotDecisions()
  session.flushSubmissions()

proc start*(session: NetworkMatch, message: RoomMessage) =
  ## Confirms the immutable setup before any VM or live tick executes.
  if message.revision != session.revision:
    reject("GotA setup revision changed before startup")
  session.client.send(RoomMessage(
    kind: ReportHash, match: session.client.match, tick: 0,
    hash: session.game.networkHash()
  ))
  if session.game.networkHash() != message.hash:
    reject("GotA initial state differs from the agreed setup hash")
  session.started = true
  session.decide()

proc applyPacket*(session: NetworkMatch, packet: RoomMessage) =
  ## Validates ownership and executes a server tick in canonical sim phases.
  let
    game = session.game
    client = session.client
  if not session.started or packet.kind != TickPacket or
    packet.match != client.match or packet.tick != uint32(game.world.tick + 1):
      reject("GotA received an unexpected simulation tick")
  # Validate the entire packet before applying any part of it.
  var submissions: seq[GameSubmission]
  for command in packet.commands:
    if command.seat >= uint32(client.snapshot.seats.len) or
      client.snapshot.seats[command.seat].owner != command.participant:
        reject("Command participant does not own this seat")
    let submission = decodeSubmission(command.payload)
    if submission.action.heroId != game.world.heroes[command.seat].id:
      reject("GotA command hero does not belong to this seat")
    submissions.add submission
  for submission in submissions:
    if submission.mailbox:
      discard game.deliverChat(
        game.world.heroIndex(submission.action.heroId),
        int(submission.action.first), submission.text
      )
    else:
      var action = submission.action
      action.tick = packet.tick
      game.networkActions.add action
  game.tickWorld(nil)
  if uint32(game.world.tick) != packet.tick:
    reject("GotA failed to execute the authoritative tick")
  for outcome in game.actionResults:
    game.publishActionResult(outcome.action.heroId, outcome.accepted)
    let seat = game.world.heroIndex(outcome.action.heroId)
    if outcome.action.kind == ActionBuyItem and seat >= 0 and
      client.snapshot.seats[seat].owner == client.participant and
      game.heroVms[seat] == nil:
        purchaseReceipt = PurchaseReceipt(
          serial: purchaseReceipt.serial + 1,
          heroId: outcome.action.heroId, itemId: outcome.action.first,
          accepted: outcome.accepted
        )
  game.actionResults.setLen(0)
  game.sampleMetrics(game.finished())
  game.metrics.finishTick(game.world.tick)
  client.appliedTick(packet.tick)
  if packet.tick mod uint32(TickRate) == 0:
    client.send(RoomMessage(
      kind: ReportHash, match: client.match, tick: packet.tick,
      hash: game.networkHash()
    ))
  session.finished = game.finished() or game.world.tick >= game.durationTicks()
  if session.finished:
    client.send(RoomMessage(
      kind: FinishMatch, match: client.match, tick: packet.tick,
      hash: game.networkHash()
    ))
  else:
    session.decide()

proc abort*(session: NetworkMatch, detail: string) =
  ## Stops explicitly on invalid input rather than recovering silently.
  session.client.error = detail
  session.client.snapshot.phase = Desynced
  session.client.send(RoomMessage(
    kind: AbortMatch, match: session.client.match, detail: detail
  ))
