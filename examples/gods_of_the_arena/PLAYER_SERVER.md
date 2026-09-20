# GotA player WebSocket

`player_server.nim` exposes the native Gods of the Arena decision interface at
`ws://127.0.0.1:8080/player`.

One client controls all five heroes on one team. The server sends an observation
before every controlled hero decision. The other team runs the configured BASIC
opponent.

The default policy has eight bounded features and eight actions. Compile-time
definitions can select another fixed contract. Each observation also includes
the tick, controlled seat, reward, terminal outcome, state hash, and score
counters.

```json
{"type":"observation","features":[0,0,0,0,0,0,0,0],"tick":0,"seat":0,"reward":0,"terminal":false}
```

Reply with one action before the next observation:

```json
{"action":0}
```

Run the server from the repository root:

```sh
nim r examples/gods_of_the_arena/player_server.nim
```
