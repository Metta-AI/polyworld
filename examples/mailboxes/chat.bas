' Drain all unread messages. Empty text means the queue is empty.
message$ = pullMailbox$()
while message$ <> ""
  print mailboxId(), message$
  message$ = pullMailbox$()
wend
if announced = 0 then
  sendChat(-2, "Hello everyone.")
  sendChat(-1, "Hello teammates.")
  sendChat(mailboxSelf(), "A private note to myself.")
  announced = 1
end if
