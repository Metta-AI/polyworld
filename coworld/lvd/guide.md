# Light vs Dark

Two BASIC overlords gather resources, build armies, and fight. The simulation winner scores one win, including its existing time-limit resolution.

Slot 0 commands Light. Slot 1 commands Dark. Platform slots are zero-based. Upload a `.bas` file containing BASIC source. The game reads the staged file directly, with no player container or network connection.

Start with the bundled `players/base.bas`. The [game documentation](https://github.com/Metta-AI/polyworld/blob/main/examples/light_vs_dark/docs/index.html) describes observations and available BASIC commands. The same source is available under `examples/light_vs_dark/bots.nim` and `content.nim`.

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle messages go to the owning player's private log. Each log is limited to 10 MiB. Runtime limit errors disable that VM; other seats continue. Invalid BASIC syntax fails the episode with a player failure diagnostic. Public game logs and action replays contain no BASIC source or private print output.

Matches run up to 28,800 deterministic ticks (20 simulated minutes), without real-time pacing. Replays run entirely in the browser with playback, seeking, speed, and loop controls. The server exposes `/healthz`; legacy clients are static stubs.

The Competition league runs every 30 minutes with at least two episodes per entrant. Separate baseline filler policies complete short rosters. Fillers are not ranked entrants. Standings use binary win scores and platform Elo.

## BASIC numbers and coordinates

BASIC uses [Bassy](https://github.com/treeform/bassy) with [Fixxy](https://github.com/treeform/fixxy) Q16.16 decimals enabled. Globals and arrays retain fractional values across decisions. `/` performs decimal division; `\` performs integer division. Decimal operands must fit -32768 through 32767.99998. Integer-only calculations retain the full signed 32-bit range. When converting large world-unit observations, divide them as integers first, for example `(selfAttackRange \ 100) / (worldScale \ 100)` in GotA.

`and`, `or`, `xor`, and `not` are bitwise. Comparisons produce -1 for true and 0 for false; conditions accept any nonzero number. Host flags and action results remain 1 or 0, so use `flag = 0` instead of `not flag` to negate a host flag.

`moveUnit(id, x, y)` and `attackMove(id, x, y)` accept fractional tile coordinates. Integers continue to name tile centers. Building placement and rally tiles remain whole tiles. IDs, slots, indices, and terrain queries require exact integers. Passing a fractional value to an integer argument raises a BASIC error instead of truncating it. Accepted fractional destinations are preserved in action replays.
