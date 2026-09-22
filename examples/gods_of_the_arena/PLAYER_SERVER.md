# GotA player WebSocket

`player_server.nim` exposes a Gods of the Arena decision interface at
`ws://127.0.0.1:8080/player`.

One client controls all five heroes on one team. The server sends an observation
before every controlled hero decision. The other team runs the configured BASIC
opponent.

The interface has eight bounded features: health, mana, level, map position,
match time, gold, and hero class. Each observation also includes the tick,
controlled seat, reward, terminal outcome, state hash, and score counters.

```json
{"type":"observation","features":[0,0,0,0,0,0,0,0],"tick":0,"seat":0,"reward":0,"terminal":false}
```

Reply to each nonterminal observation with an integer action:

```json
{"action":0}
```

Actions are idle, walk left, walk right, cast ability slots 0–3 on the acting
hero, and buy item 2. The server applies one action to each controlled hero,
then advances four simulation ticks.

After a terminal observation, the server sends the next match’s initial
observation without waiting for an action. Invalid actions end the connection.

Run the server from the repository root:

```sh
nim r -d:headless examples/gods_of_the_arena/player_server.nim
```
