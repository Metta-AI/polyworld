# AWM run API

POST /v1/games/awm/run runs Archers Warriors Mages using its unmodified Coworld
executable. The request and response contract is in [/docs/llms.txt](/docs/llms.txt).

The fixed default configuration matches the Competition variant of league
league_ad6dc809-4696-46f5-99a5-fc2b1c58d082: five players, classes drawn from the
seed, and up to 28,800 game actions. The two-player Duel variant and custom
classes are not exposed by this endpoint.

The game loads submitted BASIC and ZIP policies through its production loader.
BASIC source is limited to 256 KiB; complete ZIP packages to 16 MiB. Compilation
failures fail that game with 422. Runtime errors disable the affected bot using
the game's normal behavior; inspect your uploaded seat's log and dashboard bot
count. Replays contain public actions and state hashes, not private PRINT output.

The last surviving hero scores one win; draws and timeouts score zero. The game
uses no external LLM calls. Fast-XP stages local files, starts the executable at
nice +10, collects completed outputs, and terminates its process group. Game
execution includes startup and recording; pure gameplay timing is unavailable.
