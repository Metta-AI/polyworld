import
  std/strutils,
  bassy,
  polyworld/[chats, mailboxes]

echo "Testing private queues, broadcasts, DMs, and received message IDs"
block:
  let mail = newMailboxes(3)
  mail.beginTick(12)
  doAssert mail.pull(0).text == ""
  doAssert mail.last(0).id == NoMailboxId
  doAssert mail.send(0, -2, "hello") == 3
  doAssert mail.send(1, 0, "private") == 1
  doAssert mail.pull(0).text == "hello"
  doAssert mail.last(0).id == -2
  doAssert mail.last(0).sender == 0
  doAssert mail.pull(0).text == "private"
  doAssert mail.last(0).id == 1
  doAssert mail.last(0).sender == 1
  doAssert mail.last(0).target == 0
  doAssert mail.last(0).tick == 12
  doAssert mail.pull(0).text == ""
  doAssert mail.last(0).id == NoMailboxId
  doAssert mail.pull(1).text == "hello"
  doAssert mail.pull(2).text == "hello"
  doAssert mail.count(1) == 0 and mail.count(2) == 0

echo "Testing team membership and per-recipient game rules"
block:
  let mail = newMailboxes(3)
  doAssert mail.send(0, -1, "default team") == 3
  doAssert mail.pull(2).id == -1
  mail.clear()
  mail.teams = @[0'i32, 0'i32, 1'i32]
  doAssert mail.send(0, -1, "allies") == 2
  doAssert mail.count(2) == 0
  mail.clear()
  var positions = @[0, 1, 100]
  mail.rule = proc(message: MailMessage, recipient: int): bool =
    ## Models a game restricting every channel to local hearing range.
    abs(positions[message.sender] - positions[recipient]) <= 5
  doAssert mail.send(0, -2, "nearby") == 2
  doAssert mail.send(0, 2, "too far") == 0
  positions[2] = 3
  doAssert mail.send(0, 2, "now near") == 1
  doAssert mail.pull(2).text == "now near"

echo "Testing mailbox memory bounds, wraparound, and reset"
block:
  let mail = newMailboxes(2)
  mail.beginTick(10)
  doAssert mail.send(0, 1, "") == 0
  doAssert mail.send(0, 2, "invalid target") == 0
  doAssert mail.send(0, -3, "invalid channel") == 0
  doAssert mail.send(0, 1, repeat('x', MaxChatBytes + 1)) == 0
  doAssert mail.send(0, 1, "\xff") == 0
  for i in 0 ..< MaxMailboxMessages:
    doAssert mail.send(0, 1, $i) == 1
  doAssert mail.send(0, 1, "overflow") == 0
  for i in 0 ..< 10:
    doAssert mail.pull(1).text == $i
    doAssert mail.send(0, 1, $(i + MaxMailboxMessages)) == 1
  for i in 10 ..< MaxMailboxMessages + 10:
    doAssert mail.pull(1).text == $i
  doAssert mail.pull(1).text == ""
  discard mail.send(0, -2, "old match")
  mail.beginTick(11)
  doAssert mail.count(1) == 1
  mail.beginTick(0)
  doAssert mail.count(1) == 0

echo "Testing BASIC mailbox strings, sender IDs, and seat isolation"
block:
  let
    mail = newMailboxes(2)
    sender = newChatHost(0)
    receiver = newChatHost(1)
  sender.mailboxes = mail
  receiver.mailboxes = mail
  var
    firstHost = initHost()
    secondHost = initHost()
  sender.addFunctions(firstHost)
  receiver.addFunctions(secondHost)
  var first = initRuntime(compile("""
sent = sendChat(1, "Hello from BASIC.")
own$ = pullMailbox$()
""", firstHost), firstHost)
  var second = initRuntime(compile("""
message$ = pullMailbox$()
from = mailboxId()
sentAt = mailboxTick()
left = mailboxCount()
empty$ = pullMailbox$()
missing = mailboxId()
""", secondHost), secondHost)
  sender.bindRuntime(first)
  receiver.bindRuntime(second)
  sender.beginTick(9)
  receiver.beginTick(9)
  discard first.run()
  discard second.run()
  doAssert first.getGlobal("sent") == 1
  doAssert first.getString(first.getGlobalValue("own$")) == ""
  doAssert second.getString(second.getGlobalValue("message$")) ==
    "Hello from BASIC."
  doAssert second.getGlobal("from") == 0
  doAssert second.getGlobal("sentAt") == 9
  doAssert second.getGlobal("left") == 0
  doAssert second.getGlobal("missing") == NoMailboxId
  doAssert second.getString(second.getGlobalValue("empty$")) == ""
