const
  MaxMailboxPlayers* = 64
  MaxMailboxMessages* = 128
  MaxChatBytes* = 1024
  GlobalMailboxId* = -2
  TeamMailboxId* = -1
  NoMailboxId* = -3

type
  MailboxError* = object of CatchableError
  MailChannel* = enum
    DirectMailbox, TeamMailbox, GlobalMailbox
  MailMessage* = ref object
    sender*, target*: int
    tick*: int32
    channel*: MailChannel
    length: int
    bytes: array[MaxChatBytes, char]
  MailRule* = proc(message: MailMessage, recipient: int): bool {.closure.}
  Mailbox = ref object
    messages: array[MaxMailboxMessages, MailMessage]
    first, count: int
    last: MailMessage
  Mailboxes* = ref object
    teams*: array[MaxMailboxPlayers, int32]
    rule*: MailRule
    boxes: array[MaxMailboxPlayers, Mailbox]
    draft: MailMessage
    playerCount: int
    tick: int32

proc newMailboxes*(players: int): Mailboxes =
  ## Creates private queues with an unrestricted common team by default.
  if players < 1 or players > MaxMailboxPlayers:
    raise newException(MailboxError, "Mailbox player count must be 1 .. 64")
  result = Mailboxes(playerCount: players, draft: MailMessage(), tick: -1)
  for i in 0 ..< players:
    result.boxes[i] = Mailbox(last: MailMessage())
    for slot in 0 ..< MaxMailboxMessages:
      result.boxes[i].messages[slot] = MailMessage()

proc players*(mailboxes: Mailboxes): int =
  ## Reports the number of zero-based player addresses.
  if mailboxes == nil: 0 else: mailboxes.playerCount

proc clear*(mailboxes: Mailboxes) =
  ## Empties queues without allocating or releasing their backing storage.
  if mailboxes == nil:
    return
  for i in 0 ..< mailboxes.players:
    let box = mailboxes.boxes[i]
    box.first = 0
    box.count = 0
    box.last.length = 0
    box.last.tick = 0
  mailboxes.draft.length = 0

proc reset*(mailboxes: var Mailboxes, players: int) =
  ## Starts a new roster while retaining rules for an unchanged game size.
  if mailboxes == nil or mailboxes.players != players:
    mailboxes = newMailboxes(players)
  else:
    mailboxes.clear()
    mailboxes.tick = -1

proc beginTick*(mailboxes: Mailboxes, tick: int32) =
  ## Preserves unread mail across ticks and clears it on a match reset.
  if mailboxes == nil:
    return
  if tick < mailboxes.tick:
    mailboxes.clear()
  mailboxes.tick = tick

proc len*(message: MailMessage): int {.raises: [].} =
  ## Returns the occupied byte count, including zero for an empty pull.
  if message == nil: 0 else: message.length

template withText*(message: MailMessage, text, body: untyped) =
  ## Borrows bytes until the next pull, clear, or roster reset.
  block:
    let envelope = message
    assert envelope != nil
    template text: untyped =
      envelope.bytes.toOpenArray(0, envelope.length - 1)
    body

proc matches*(message: MailMessage, text: openArray[char]): bool =
  ## Compares a message without constructing a temporary string.
  if message.len != text.len:
    return false
  for i in 0 ..< text.len:
    if message.bytes[i] != text[i]:
      return false
  true

proc id*(message: MailMessage): int =
  ## Returns a broadcast address or the sender of a direct message.
  if message.len == 0:
    return NoMailboxId
  case message.channel
  of DirectMailbox: message.sender
  of TeamMailbox: TeamMailboxId
  of GlobalMailbox: GlobalMailboxId

proc validText(text: openArray[char]): bool =
  ## Rejects malformed, overlong, surrogate, and out-of-range UTF-8 sequences.
  var i = 0
  while i < text.len:
    let first = ord(text[i])
    var
      extra = 0
      low = 0x80
      high = 0xbf
    case first
    of 0 .. 0x7f:
      inc i
      continue
    of 0xc2 .. 0xdf:
      extra = 1
    of 0xe0 .. 0xef:
      extra = 2
      if first == 0xe0:
        low = 0xa0
      elif first == 0xed:
        high = 0x9f
    of 0xf0 .. 0xf4:
      extra = 3
      if first == 0xf0:
        low = 0x90
      elif first == 0xf4:
        high = 0x8f
    else:
      return false
    if extra >= text.len - i or ord(text[i + 1]) notin low .. high:
      return false
    for j in 2 .. extra:
      if ord(text[i + j]) notin 0x80 .. 0xbf:
        return false
    i += extra + 1
  true

proc write(
  message: MailMessage, sender, target: int, tick: int32,
  channel: MailChannel, text: openArray[char]
) =
  ## Copies payload bytes into an existing envelope without replacing it.
  message.sender = sender
  message.target = target
  message.tick = tick
  message.channel = channel
  message.length = text.len
  for i in 0 ..< text.len:
    message.bytes[i] = text[i]

proc send*(
  mailboxes: Mailboxes, sender, target: int, text: openArray[char]
): int32 =
  ## Fans out a message through the game's audience and delivery rules.
  if mailboxes == nil or sender < 0 or sender >= mailboxes.players or
    text.len == 0 or text.len > MaxChatBytes or not validText(text):
      return 0
  if target < GlobalMailboxId or target >= mailboxes.players:
    return 0
  let channel =
    case target
    of GlobalMailboxId: GlobalMailbox
    of TeamMailboxId: TeamMailbox
    else: DirectMailbox
  mailboxes.draft.write(sender, target, mailboxes.tick, channel, text)
  for recipient in 0 ..< mailboxes.players:
    let box = mailboxes.boxes[recipient]
    case channel
    of DirectMailbox:
      if recipient != target:
        continue
    of TeamMailbox:
      if mailboxes.teams[recipient] != mailboxes.teams[sender]:
        continue
    of GlobalMailbox:
      discard
    if box.count == MaxMailboxMessages:
      continue
    if mailboxes.rule != nil and not mailboxes.rule(mailboxes.draft, recipient):
      continue
    box.messages[(box.first + box.count) mod MaxMailboxMessages].write(
      sender, target, mailboxes.tick, channel, text
    )
    inc box.count
    inc result

proc count*(mailboxes: Mailboxes, recipient: int): int32 =
  ## Counts this recipient's unread messages without consuming them.
  if mailboxes != nil and recipient in 0 ..< mailboxes.players:
    result = int32(mailboxes.boxes[recipient].count)

proc pull*(mailboxes: Mailboxes, recipient: int): MailMessage =
  ## Borrows the popped envelope until this player's next pull or reset.
  if mailboxes == nil or recipient notin 0 ..< mailboxes.players:
    return
  let box = mailboxes.boxes[recipient]
  box.last.length = 0
  box.last.tick = 0
  if box.count == 0:
    return box.last
  swap(box.last, box.messages[box.first])
  result = box.last
  box.first = (box.first + 1) mod MaxMailboxMessages
  dec box.count

proc last*(mailboxes: Mailboxes, recipient: int): MailMessage =
  ## Reads metadata for the recipient's most recent pull operation.
  if mailboxes != nil and recipient in 0 ..< mailboxes.players:
    result = mailboxes.boxes[recipient].last
