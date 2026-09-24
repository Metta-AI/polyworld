import
  std/strutils,
  bassy,
  polyworld/[chats, mailboxes]

when not defined(nimAllocStats):
  {.error: "Run this test with -d:nimAllocStats to measure allocations.".}

echo "Testing mailbox rings allocate only during initialization"
block:
  var mail = newMailboxes(4)
  let payload = repeat('x', MaxChatBytes)
  mail.rule = proc(message: MailMessage, recipient: int): bool =
    ## Applies a deterministic routing rule without allocating.
    message.sender >= 0 and recipient >= 0
  let before = getAllocStats()
  for round in 0 ..< 200:
    mail.beginTick(int32(round))
    for slot in 0 ..< MaxMailboxMessages:
      doAssert mail.send(0, GlobalMailboxId, payload) == 4
    doAssert mail.send(0, TeamMailboxId, "overflow") == 0
    doAssert mail.pull(0).matches(payload)
    doAssert mail.send(1, 0, payload) == 1
    for player in 0 ..< 4:
      while mail.count(player) > 0:
        doAssert mail.pull(player).matches(payload)
      doAssert mail.pull(player).len == 0
    doAssert mail.send(0, TeamMailboxId, "team") == 4
    mail.clear()
    doAssert mail.send(0, 1, "reset") == 1
    mail.beginTick(-1)
    doAssert mail.count(1) == 0
    mail.reset(4)
  let after = getAllocStats()
  doAssert after == before, $(after - before)

echo "Testing BASIC send, pull, and decision restart allocate no heap memory"
block:
  let
    mail = newMailboxes(1)
    chat = newChatHost(0, mail)
    payload = repeat('x', MaxChatBytes)
  var
    host = initHost()
    limits = defaultLimits()
  chat.addFunctions(host)
  limits.maxStringBytes = 256 * 1024
  limits.maxWorkUnits = 300_000
  let program = compile("""
sent = 0
for i = 1 to 128
  sent = sent + sendChat(mailboxSelf(), payload$)
next i
overflow = sendChat(-2, payload$)
received = 0
message$ = pullMailbox$()
while message$ <> ""
  received = received + 1
  sender = mailboxId()
  message$ = pullMailbox$()
wend
""", host, limits)
  var runtime = initRuntime(program, host, limits)
  chat.bindRuntime(runtime)
  runtime.setGlobal("payload$", payload)
  let before = getAllocStats()
  for tick in 0 ..< 1000:
    chat.beginTick(int32(tick))
    discard runtime.run()
  let after = getAllocStats()
  doAssert after == before, $(after - before)
  doAssert runtime.getGlobal("sent") == 128
  doAssert runtime.getGlobal("overflow") == 0
  doAssert runtime.getGlobal("received") == 128
