# CtA generated terrain

CtA uses the existing generated texture library for both native and browser
rendering. No new images were generated and no source textures were edited.

| Use | Existing generated textures |
| --- | --- |
| Surface grass | `grass-1` through `grass-4`, with matching stamps |
| Roads and soil | `dirt-road-1` |
| Rocky walls and slab sides | `crypt-rock-1` |
| Old Halls floor and ramps | `crypt-flagstone-1` |
| Built stone walls | `crypt-stone-1` |
| Cave rubble | `crypt-rock-2` |
| Flooded Deep floor | `marsh-1`, with matching stamps |
| Lava Hall walls | `crypt-lava-1` |
| Lava Hall crust floor | `crypt-lava-2`, darkened at runtime |
| Vault floor | `cobble-tan-1`, gold-tinted at runtime |

Every tile uses its existing `.rgb.png` and `.height.png` pair. The shared
generated renderer also loads its nine standard tile/stamp pairs, including
forest floor, cobble road and gravel road. Seven dungeon pairs are appended.
Native and browser loading use the same generated texture names.

Material registration runs after `initTerrain`, which initializes the shared
base mappings. All 13 CtA tile kinds receive explicit generated material
indices. The dungeon seed controls grass variation and stamps.

The change affects presentation only. Tile geometry, map hashes, collision,
pathfinding, and replay game version remain unchanged.

The generated textures are covered by the shared asset repository's root
CC0 dedication. CtA no longer loads or packages `terrain/cartoon_textures`.
The source textures remain available for other games using that directory.
