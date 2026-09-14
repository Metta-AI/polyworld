# Gods of the Arena

Two teams of five BASIC heroes battle to destroy the enemy fort. Every hero on the winning team scores one win. A time limit without a fort victory gives everyone zero.

Slots 0–4 are Red and slots 5–9 are Blue. Platform slots are zero-based. Upload a `.bas` file containing BASIC source. The game reads the staged file directly, with no player container or network connection.

Start with the bundled `players/base.bas`. The [game documentation](https://github.com/Metta-AI/polyworld/blob/main/examples/gods_of_the_arena/docs/index.html) describes observations and available BASIC commands. The same source is available under `examples/gods_of_the_arena/bots.nim` and `content.nim`.

Every hero has a free single-target melee or ranged basic attack in addition to four abilities. Basic damage grows each level and includes equipment bonuses. Idle heroes automatically acquire nearby visible enemy creeps. `attackTarget(objectId)` takes priority; melee and ranged heroes both move into their own attack range and repeat basic attacks. `walkTo(x, y)` cancels the attack and suppresses automatic acquisition while walking. Basic attacks do not spend mana or spell charges.

BASIC can inspect the complete static terrain with `terrainKind(x, y)`, `terrainWalkable(x, y)`, `terrainHeight(x, y)`, and `terrainWaterDepth(x, y)`. These use global tile coordinates on `selfLayer`. Each has an explicit `At(x, y, layer)` version, such as `terrainKindAt(x, y, GroundLayer)`. Read-only constants expose `mapWidth`, `mapHeight`, `mapLayers`, the layer names, and terrain kinds. Height and water depth use eighths of a tile; invalid or absent tiles return zero. The Terrain API section of the game documentation lists all constants and edge cases. Static terrain is available through fog, while enemy objects remain visibility-filtered.

BASIC `PRINT` output, compiler diagnostics, runtime errors, and VM lifecycle messages go to the owning player's private log. Each log is limited to 10 MiB. Runtime limit errors disable that VM; other seats continue. Invalid BASIC syntax fails the episode with a player failure diagnostic. Public game logs and action replays contain no BASIC source or private print output.

Matches run up to 28,800 deterministic ticks (20 simulated minutes), without real-time pacing. Replays run entirely in the browser with playback, seeking, speed, and loop controls. The server exposes `/healthz`; legacy clients are static stubs.

The Competition league runs every 30 minutes with at least two episodes per entrant. Separate baseline filler policies complete short rosters. Fillers are not ranked entrants. Standings use binary win scores and platform Elo.
