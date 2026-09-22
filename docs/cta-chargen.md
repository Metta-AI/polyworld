# CtA generated characters

The approved existing-asset roster now runs in CtA. No geometry was modeled
for this integration. Runtime recipes live in
`../polyworld_data/characters/chargen/cta.json`.

| Hero role | GotA preset | Equipment |
| --- | --- | --- |
| Fighter | Vanguard Knight | Sword and shield |
| Wizard | Arcanist | Staff and arcane orbs |
| Rogue | Ranger | Bow, arrow and quiver |
| Cleric | Druid Warden | Staff and nature orb |

| Dungeon floor | Skin | Runt | Raider | Caster | Champion |
| --- | --- | --- | --- | --- | --- |
| 1 | Beige undead | Dustling | Grave Stalker | Crypt Acolyte | Barrow Warden |
| 2 | Green orcs | Bog Runt | Tusk Raider | Mire Shaman | Ironhide Chief |
| 3 and 4 | Purple vampires | Dusk Thrall | Velvet Stalker | Blood Cantor | Dread Count |
| 5, final vault | Red demons | Cinder Imp | Ash Reaver | Ember Hexer | Infernal Duke |

Monster sizes are 70%, 90%, 110% and 140% of the hero height. Each rank
increases health and attack damage. Spawn chances are 40%, 30%, 20% and 10%,
respectively. Deeper floors retain the existing health multiplier.

All characters use existing equipped chargen parts and Quaternius Universal
Standard animations. Hero portraits match the imported GotA presets. Floor
loot uses the existing gold, treasure and ability icons. Both native and
browser declarations omit the old character packs and unused terrain props.
The terrain pass also replaces all CartoonTerrain textures with existing
generated grass, marsh, crypt rock, stone, flagstone, lava and tan cobbles.
See [the terrain mapping](cta-terrain.md).

Replay game version is now 23 because monster IDs, spawning and tuning
changed. Older replays cannot reproduce this simulation and are rejected.

Validation: the full headless suite passes. The standalone
`tests/test_cta_characters.nim` loads all 20 characters, checks equipment,
grounding and animated bounds, and checks the browser asset declaration
for missing files and the excluded legacy character assets.

To build and play from the repository root:

```sh
nim c --out:tmp/cta-play/cta examples/call_to_adventure/cta.nim
tmp/cta-play/cta --player --bot examples/call_to_adventure/players/base.bas:3 --play=false
```

Space starts or pauses. Right-click walks, attacks an enemy or picks up loot.
Left-click also attacks enemies or picks up loot. F and G use the two carried
items; Shift-F and Shift-G drop them. The first slot is the human knight;
the other three heroes use the reference bot.
