# Heartleaf runtime art

Run from the Polyworld repository with the sibling `polyworld_art` checkout:

```sh
nim r examples/heartleaf/heartleaf.nim --bot examples/heartleaf/players/base.bas:9
```

The shared default window and screenshot size is 1920 by 1080, matching GotA,
Light vs. Dark and Call to Adventure. Use `--windowSize WIDTHxHEIGHT` to override
it for a particular run.

For screenshots, use the hidden capture mode. It writes a PNG and exits without
showing a game window. Seek to a tick or named event and pause to capture that
exact simulation state:

```sh
SCREENSHOT_PATH=tmp/heartleaf-dinner.png nim r -d:takeScreenshot \
  examples/heartleaf/heartleaf.nim \
  --bot examples/heartleaf/players/base.bas:9 \
  --seek-event day:1:dinner --play=false
```

Replace the event with `--seek-tick 4320` for an absolute tick. The same options
work with `--replay PATH`. `CAM_DIST`, `CAM_X`, and `CAM_Z` select the camera;
`SIM_SECONDS` remains available for the shared screenshot workflow.

The graphical client loads all scene assets from `polyworld_art`. It does not
load `polyworld_data`, Layer Lab characters, Unity environment packs, or their
portraits. The old `decor`, `houses` and `houseview` modules are legacy house-lab
recipes and are no longer imported by Heartleaf's graphical client.

| Scene content | Source | License |
| --- | --- | --- |
| Nine villagers | CharGen presets Gnome 01 through Gnome 09 | CC0-1.0 |
| Idle, walk, gather, gesture | Clean CharGen Quaternius clips | CC0-1.0 |
| Portraits | Rendered from the same nine gnomes at startup | CC0-1.0 |
| Loading logo | Supplied Heartleaf logo in `themes/heartleaf` | CC0-1.0 |
| Hill houses, well, two planters, chimney | `terrain/blender_village/models` | CC0-1.0 |
| Grass, roads and plaza | `terrain/tiles/heartleaf-*` | CC0-1.0 |
| Benches, lamps, fences, market, flowers and paving | `terrain/heartleaf/models` | CC0-1.0 |
| Forest trees and rocks | TreeGen and RockGen with Polyworld Art textures | CC0-1.0 textures |
| HUD fonts | Shared Rubik and Overpass fonts | OFL-1.1 |

Only five self-contained village GLBs were copied from the existing generated
village art. Their embedded textures are included in their recorded hashes.
See `polyworld_art/terrain/blender_village/license.md` and the
`heartleafVillage` source in `polyworld_art/licenses/assets.json` for provenance.
No Blender scenes, reference images, old portraits or Unity assets were copied.

The loading logo preserves the supplied PNG, including transparency. Its source
and relation to the existing generated project logo are recorded in
`polyworld_art/themes/heartleaf/license.md` and the `heartleafLogo` inventory entry.

The opening orthographic camera shows all nine cottages, the central tree plaza,
market, southern well garden and orchard. It stays in the town overview until
manual camera movement or the camera director is selected. The map follows the
supplied illustration, with deterministic winding lanes and matching house
footprints. The playable meadow ends at a rounded 49 by 72 tile boundary around
that town. Its sparse border has at most 24 seeded trees, with nine crown shapes,
varied sizes and irregular spacing. Cottage meshes use uniform scaling on all
three axes, preserving the approved width and the source model's circular mound.
Roof decorations follow the exported grass triangles, and collisions cover the
restored depth. Gnome height remains 3.4 units. Each facade,
door approach and planter group turns inward to follow the reference image.
The layout is about 75 percent of its previous width and depth, keeping the
accepted cottage and gnome model scales. Road centerlines are traced from the
reference image with changing widths, oblique entrances, offset forks and three
unequal corridors around the orchard and well. The southern lane bends between
the two bottom cottages before turning toward the exit. Tall border trees leave
this foreground junction visible.
Older recordings with the previous map hash are rejected explicitly.

The fifteen new village detail props were modeled in Blender from the supplied
reference and the existing CC0 painted trim. The art repository includes their
editable Blender source, rebuild script, provenance and fresh-import validation.
A judge reviewed four prop angles and four rounds of in-game comparison.

Missing village exports use procedural boxes. Harvestable vegetables retain
small colored placeholders above their planter beds.

`nim r tests/test_hlf_art.nim` loads all nine gnomes and their four animation
clips, checks the generated village models, and checks the scene assets against
the CC0 inventory. Existing map, simulation and replay tests cover game behavior.
