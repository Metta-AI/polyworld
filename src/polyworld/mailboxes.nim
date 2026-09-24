import std/unicode

const
  MaxMailboxPlayers* = 64
  MaxMailboxMessages* = 64
  MaxChatBytes* = 1024
  GlobalMailboxId* = -2
  TeamMailboxId* = -1
  NoMailboxId* = -3

type
  MailboxError* = object of CatchableError
  MailChannel* = enum
    DirectMailbox, TeamMailbox, GlobalMailbox
  MailMessage* = object
    sender*, target*: int
    tick*: int32
    channel*: MailChannel
    text*: string
  MailRule* = proc(message: MailMessage, recipient: int): bool {.closure.}
  Mailbox = object
    messages: array[MaxMailboxMessages, MailMessage]
    first, count: int
    last: MailMessage
  Mailboxes* = ref object
    teams*: seq[int32]
    rule*: MailRule
    boxes: seq[Mailbox]
    tick: int32

proc newMailboxes*(players: int): Mailboxes =
  ## Creates private queues with an unrestricted common team by default.
  if players < 1 or players > MaxMailboxPlayers:
    raise newException(MailboxError, "Mailbox player count must be 1 .. 64")
  Mailboxes(
    teams: newSeq[int32](players), boxes: newSeq[Mailbox](players), tick: -1
  )

proc players*(mailboxes: Mailboxes): int =
  ## Reports the number of zero-based player addresses.
  if mailboxes == nil: 0 else: mailboxes.boxes.len

proc clear*(mailboxes: Mailboxes) =
  ## Releases unread and last-read messages without changing game rules.
  for box in mailboxes.boxes.mitems:
    box = Mailbox()

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

proc channelName*(channel: MailChannel): string =
  ## Returns the BASIC channel name associated with an envelope.
  case channel
  of DirectMailbox: "dm"
  of TeamMailbox: "team"
  of GlobalMailbox: "global"

proc id*(message: MailMessage): int =
  ## Returns a broadcast address or the sender of a direct message.
  if message.text.len == 0:
    return NoMailboxId
  case message.channel
  of DirectMailbox: message.sender
  of TeamMailbox: TeamMailboxId
  of GlobalMailbox: GlobalMailboxId

proc send*(
  mailboxes: Mailboxes, sender, target: int, text: string
): int32 =
  ## Fans out a message through the game's audience and delivery rules.
  if mailboxes == nil or sender < 0 or sender >= mailboxes.players or
    text.len == 0 or text.len > MaxChatBytes or text.validateUtf8() >= 0:
      return 0
  if target < GlobalMailboxId or target >= mailboxes.players:
    return 0
  let channel =
    case target
    of GlobalMailboxId: GlobalMailbox
    of TeamMailboxId: TeamMailbox
    else: DirectMailbox
  let message = MailMessage(
    sender: sender,
    target: target,
    tick: mailboxes.tick, channel: channel, text: text
  )
  for index, box in mailboxes.boxes.mpairs:
    let recipient = index
    case channel
    of DirectMailbox:
      if recipient != target:
        continue
    of TeamMailbox:
      if mailboxes.teams[index] != mailboxes.teams[sender]:
        continue
    of GlobalMailbox:
      discard
    if box.count == MaxMailboxMessages:
      continue
    if mailboxes.rule != nil and not mailboxes.rule(message, recipient):
      continue
    box.messages[(box.first + box.count) mod MaxMailboxMessages] = message
    inc box.count
    inc result

proc count*(mailboxes: Mailboxes, recipient: int): int32 =
  ## Counts this recipient's unread messages without consuming them.
  if mailboxes != nil and recipient in 0 ..< mailboxes.players:
    result = int32(mailboxes.boxes[recipient].count)

proc pull*(mailboxes: Mailboxes, recipient: int): MailMessage =
  ## Pops one FIFO message, or returns an empty envelope when drained.
  if mailboxes == nil or recipient notin 0 ..< mailboxes.players:
    return
  let box = addr mailboxes.boxes[recipient]
  box.last = MailMessage()
  if box.count == 0:
    return
  result = move(box.messages[box.first])
  box.last = result
  box.first = (box.first + 1) mod MaxMailboxMessages
  dec box.count

proc last*(mailboxes: Mailboxes, recipient: int): MailMessage =
  ## Reads metadata for the recipient's most recent pull operation.
  if mailboxes != nil and recipient in 0 ..< mailboxes.players:
    result = mailboxes.boxes[recipient].last
