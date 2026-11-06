## Presentation-only human communication. Never drains simulation mailboxes.
import std/unicode
import polyworld/[mailboxes, rooms, tapes, configs]
import bots, sim, multiplayer, diplomacies
export diplomacies

const MaxHumanChatLines* = 100

type
  HumanChatLine* = object
    player*: int32
    name*, text*: string
  HumanCommunication* = object
    typing*, diplomacyOpen*, blockedFrame*: bool
    draft*, status*: string
    feed*: seq[HumanChatLine]
    observedTick: uint32
    diplomacyPage*: int

proc reset*(state: var HumanCommunication) =
  state = HumanCommunication()

proc blocksGameplay*(state: HumanCommunication): bool =
  state.typing or state.diplomacyOpen or state.blockedFrame

proc finishFrame*(state: var HumanCommunication) =
  state.blockedFrame = false

proc addLine(state: var HumanCommunication, game: Game, sender: int32, text: string) =
  if state.feed.len >= MaxHumanChatLines: state.feed.delete(0)
  state.feed.add HumanChatLine(player: sender,
    name: game.config.players[sender].displayName(int(sender)), text: text)

proc chatRune*(state: var HumanCommunication, rune: Rune): bool =
  if not state.typing: return false
  result = true # Consume even rejected input; it must never become a hotkey.
  let value = int(rune)
  if value < 32 or value in 127 .. 159 or value > 0x10ffff or
      value in 0xd800 .. 0xdfff: return
  let encoded = rune.toUTF8()
  if state.draft.len + encoded.len <= MaxChatBytes:
    state.draft.add encoded

proc chatEnter*(state: var HumanCommunication, game: Game, player: int32): bool =
  if game == nil or game.replayMode or player notin 0'i32 ..< int32(game.inboxes.len):
    return false
  state.blockedFrame = true
  if not state.typing:
    state.typing = true
    state.diplomacyOpen = false
    state.draft = ""
    state.status = ""
    return true
  if unicode.strip(state.draft).len == 0:
    state.typing = false
    state.draft = ""
    return true
  if game.sendChat(int(player), -2, state.draft) > 0:
    if not game.networked: state.addLine(game, player, state.draft)
    state.typing = false
    state.draft = ""
    state.status = ""
  else:
    state.status = "Chat queue full; try again."
  true

proc chatBackspace*(state: var HumanCommunication) =
  if not state.typing or state.draft.len == 0: return
  var index = state.draft.high
  while index > 0 and (ord(state.draft[index]) and 0xc0) == 0x80: dec index
  state.draft.setLen(index)

proc cancelCommunication*(state: var HumanCommunication): bool =
  result = state.typing or state.diplomacyOpen
  if result:
    state.typing = false
    state.diplomacyOpen = false
    state.draft = ""
    state.blockedFrame = true

proc diplomacyChoices*(game: Game, player, other: int32): set[DiplomacyCommand] =
  ## Validate against a detached copy; never change authoritative relations.
  if game == nil or game.replayMode or game.world == nil: return
  let world = game.world
  if player < 0 or other < 0 or player >= world.players.len or
      other >= world.players.len or player == other or
      world.players[player].defeated or world.players[other].defeated: return
  for command in DiplomacyCommand:
    var preview = world.diplomacy
    # Explicit copy keeps preview independent under every Nim memory manager.
    preview.pairs = @[]
    for pair in world.diplomacy.pairs: preview.pairs.add pair
    let relation = world.diplomacy.relation(player, other)
    if preview.apply(player, other, world.tick, command, relation.offerId):
      result.incl command

proc submitHumanDiplomacy*(game: Game, player, other: int32,
    command: DiplomacyCommand, offerId = 0'i32): bool =
  if command notin game.diplomacyChoices(player, other): return false
  if command in {AcceptOffer, DeclineOffer, WithdrawOffer} and
      offerId != game.world.diplomacy.relation(player, other).offerId: return false
  game.applyDiplomacy(player, other, command, offerId)

proc observeHumanPacket*(state: var HumanCommunication, session: NetworkMatch,
    packet: RoomMessage) =
  ## Call AFTER successful applyPacket, once for each applied tick. Use the
  ## authoritative command seat for attribution: broadcast mailbox IDs are -2
  ## and cannot identify a sender. Reading/popping bot inboxes is incorrect.
  if session == nil or packet.kind != TickPacket or
      packet.match != session.client.match or
      packet.tick != uint32(session.game.world.tick) or
      packet.tick <= state.observedTick: return
  state.observedTick = packet.tick
  for command in packet.commands:
    if command.seat >= uint32(session.client.snapshot.seats.len) or
        session.client.snapshot.seats[command.seat].name != "Human": continue
    var reader = PacketReader(data: command.payload)
    if reader.get32() != 0: continue
    let sender = cast[int32](reader.get32())
    let target = cast[int32](reader.get32())
    let text = reader.getString(MaxChatBytes)
    if sender == int32(command.seat) and target == -2 and text.len > 0 and
        validateUtf8(text) == -1:
      state.addLine(session.game, sender, text)
