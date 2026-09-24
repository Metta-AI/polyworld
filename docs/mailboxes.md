# Player mailboxes and chat

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
`mailboxTick()` gives the send tick, `mailboxCount()` counts unread messages,
and `mailboxChannel$()` optionally returns `dm`, `team`, or `global`.
An empty pull clears the last envelope, making `mailboxId()` return -3,
`mailboxSender()` return -1, and `mailboxChannel$()` return an empty string.

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
Changing `mailboxes.teams` updates team routing for future sends. Rules must
not mutate or recursively send through the router while checking delivery.

Each queue holds at most 64 unread messages of up to 1024 UTF-8 bytes each.
Empty, invalid UTF-8, oversized, and invalid-destination messages are refused.
A full queue rejects new copies while retaining unread messages; other
recipients can still accept a broadcast. Messages persist until pulled and
are cleared on policy reload or a backward tick reset. Chat belongs to the
live agent session. Replay actions preserve resulting gameplay, but this port
does not store chat text in replays or add a graphical chat panel.
