# Player mailboxes

Each player has one inbox with 100 message slots. A message is an integer ID
and a string, limited to 1024 bytes. Sending to a full inbox does nothing;
unread messages remain until the player pulls them.

Each game defines `sendChat` and its BASIC callbacks in its own `bots.nim`.
The examples use these routing rules:

| `sendChat(id, text$)` target | Recipients |
| --- | --- |
| `-2` | Everyone, including the sender. |
| `-1` | Teammates, including the sender. |
| Nonnegative | The player with that zero-based roster ID. |

GotA uses the heroes' red/blue teams. CTA treats the party as one team.
Light vs Dark treats each player as their own team. The game can change its
routing loop to add range, visibility, or other rules. There is no shared
routing policy or routing callback framework.

`sendChat` returns the number of inboxes that accepted a copy. Empty or
oversized messages and invalid destinations return zero. A broadcast can
reach some players even when another player's inbox is full.

`pullMailbox$()` consumes the oldest message, or returns an empty string if
there is none. `mailboxId()` identifies the last message pulled: `-2` for
global, `-1` for team, or the sender's player ID for a DM. An empty pull sets
that ID to `-3`. There is no separate sender, channel name, or timestamp.

`mailboxCount()` counts unread messages, `mailboxSelf()` returns the caller's
roster ID, and `mailboxPlayers()` gives the roster size. GotA uses IDs 0 to 9,
CTA uses 0 to 3, and Light vs Dark uses 0 to 1.

```basic
sendChat(-2, "Hello everyone.")
sendChat(-1, "Meet at the checkpoint.")
sendChat(0, "A direct message to player zero.")
message$ = pullMailbox$()
while message$ <> ""
  print mailboxId(), message$
  message$ = pullMailbox$()
wend
```

Delivery follows script execution order. A later player can read a message
in the same tick. Players can send and pull multiple times per decision,
within their normal BASIC instruction and string limits. Inboxes persist
across decisions and are replaced when policies are loaded for a new run.
Chat text is not recorded in replays and has no graphical chat panel.

`mailboxes.nim` is only a bounded inbox: an array of IDs, an array of reserved
strings, and read/count fields. It has no BASIC dependency. Each game owns
one inbox per player and copies message text through Bassy's public API.
Bassy owns its string storage and reclaims temporary strings on `restart()`.
Polyworld does not inspect or manage BASIC's private storage.
