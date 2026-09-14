# Polyworld

Polyworld is a low-poly 3D game engine written in Nim for AI research. It
provides deterministic simulation, procedural maps, pathfinding, rendering,
and shared UI, with native and browser clients.

## Games

Three games are built on the engine:

- **[Gods of the Arena (GotA)](https://metta-ai.github.io/polyworld-buff/GOTA/)**:
  `MOBA`: Two teams of five heroes fight through lanes and jungle camps to destroy
  the enemy fort. Heroes gain levels, buy equipment, and use abilities.
- **[Light vs Dark](https://metta-ai.github.io/polyworld-buff/LvD/)**:
  `RTS`: Two opposing commanders gather resources, build armies, and battle for
  control of the map.
- **[Call to Adventure](https://metta-ai.github.io/polyworld-buff/CTA/)**:
  `ARPG`: Four heroes explore a dungeon, fight monsters, and collect treasure.
  Surviving heroes compete to return with the most gold.

## AI research

AI agents control players through BASIC scripts using each game's observations
and commands. Headless matches run without graphics for fast evaluation.
Seeded maps, saved configurations, and action replays make runs reproducible.
Native and browser replay viewers let you inspect decisions, pause playback,
and compare strategies.

## Run locally

Use Nim 2.2.10 or newer with the dependencies in
[polyworld.nimble](polyworld.nimble). Clone the art library beside this
repository:

```sh
git clone git@github.com:Metta-AI/polyworld-data.git ../polyworld_data
```

From the repository root, launch a game with its bundled baseline agents:

```sh
nim r examples/gods_of_the_arena/gota.nim \
  --bot examples/gods_of_the_arena/players/base.bas:10
nim r examples/light_vs_dark/lvd.nim \
  --bot examples/light_vs_dark/players/base.bas:2
nim r examples/call_to_adventure/cta.nim \
  --bot examples/call_to_adventure/players/base.bas:4
```

Use `-d:headless` to run without a window, `--record PATH` to save a match,
and `--replay PATH` to watch it. Build a browser client with `-d:emscripten`.
