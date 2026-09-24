# Player mailboxes and chat

Mailboxes are always available to BASIC scripts in Gods of the Arena,
Call to Adventure, and Light vs Dark. No enable or disable flag is needed.

Every player owns one private FIFO queue. There is no shared global queue or
team queue. Sending chooses which player queues receive their own copy:

| `sendChat(id, text$)` destination | Routing |
| --- | --- |
| `-2` | All players, including the sender. |
| `-1` | The sender's teammates, including the sender. |
| `0` through `mailboxPlayers()-1` | Only that player. |

Player IDs are zero-based roster slots, not game entity IDs. GotA uses 0 to 9,
CTA uses 0 to 3, and Light vs Dark uses 0 to 1. `mailboxSelf()` returns the
calling player's ID. The send function returns the number of player queues
that accepted the message, or zero if none did.

`pullMailbox$()` removes the oldest message from the caller's own queue and
returns its text. It returns an empty string immediately if there is no mail.
After each successful pull, `mailboxId()` identifies that message:

| Received `mailboxId()` | Meaning |
| --- | --- |
| `-2` | A global broadcast. |
| `-1` | A team broadcast. |
| Nonnegative | A DM from this player ID, not the recipient ID. |

`mailboxSender()` also provides the actual sender for broadcasts.
`mailboxTick()` gives the send tick and `mailboxCount()` counts unread messages.
Channel metadata uses numeric IDs exclusively.
An empty pull clears the last envelope, making `mailboxId()` return -3,
`mailboxSender()` return -1, and `mailboxTick()` return zero.

```basic
sendChat(-2, "Hello everyone.")
sendChat(-1, "Meet at the checkpoint.")
sendChat(0, "A direct message to player zero.")

message$ = pullMailbox$()
while message$ <> ""
  from = mailboxId()
  print from, message$
  message$ = pullMailbox$()
wend
```

Delivery is immediate in send order. Scripts may send and poll whenever they
run, including multiple pulls during one decision. A later script in a tick
can read an earlier script's message in that tick. A player whose turn has
already ended reads it on its next decision.
`examples/mailboxes/chat.bas` demonstrates draining a queue and all three
destination types.

`mailboxes.nim` owns the queues and fan-out rules. Each game's `Game.mailboxes`
owns the shared router, and each BASIC host is bound to its own player ID.
GotA supplies its red/blue teams, CTA puts the whole party on one team, and
each opposing Light vs Dark player has its own team. The generic router starts
with everyone on one team and no distance or visibility restrictions.

A game can set `Game.mailboxes.rule`, a callback receiving the message and
each candidate recipient's zero-based ID. It returns true to deliver or false
to reject that copy. The game can consult its current world for proximity,
hearing range, visibility, alive state, or other rules. This runs after the
normal destination routing, so a range rule can narrow a global broadcast
or refuse a distant DM without granting access to another player's queue.
Changing entries in the fixed `mailboxes.teams` array updates future team
routing. Rules must not mutate, retain, or recursively send through the router
while checking delivery. The rule's message reference is reused on the next
send. A custom rule must also avoid allocations to keep routing allocation-free.

Each queue holds at most 128 unread messages of up to 1024 UTF-8 bytes each.
Empty, invalid UTF-8, oversized, and invalid-destination messages are refused.
A full queue rejects new copies while retaining unread messages; other
recipients can still accept a broadcast. Messages persist until pulled and
are cleared on policy reload or a backward tick reset. Chat belongs to the
live agent session. Replay actions preserve resulting gameplay, but this port
does not store chat text in replays or add a graphical chat panel.
Temporary BASIC strings are reclaimed between decisions while global variables
and arrays retain their values.

All queue storage is allocated when the roster is created. Each mailbox is a
reference object with a fixed array of 128 preallocated message references,
plus one reusable last-read envelope. Message text uses fixed 1024-byte arrays,
not Nim strings. Pulling swaps references, and clearing only resets counters.
Send, pull, overflow, and same-roster reset do not allocate or free heap memory.
Creating a different roster allocates new storage outside the tick loop.

Nim callers receive a borrowed `MailMessage` reference, valid until that
player's next pull or a reset. `message.withText(bytes)` borrows the occupied
bytes within its block; `message.matches(text)` compares without allocating.
The BASIC bridge copies these bytes directly between the mailbox and the VM's
preallocated string arena. String compaction also uses scratch space reserved
when binding the VM. Allocation-counter tests cover these paths.
