# GotA map editor

Run from the Polyworld repository root:

```sh
nim r examples/gods_of_the_arena/editor.nim
```

For a standalone executable, run `nim r tools/build_gota_editor.nim`.
On macOS this builds `tmp/GotA Map Editor.app`, which can be opened in Finder.
The built editor locates the repository and compiler automatically.

To open an existing map:

```sh
nim r examples/gods_of_the_arena/editor.nim path/to/arena.json
```

With no argument, an existing default `examples/gods_of_the_arena/maps/arena.json`
is opened if present. Otherwise the editor generates a starting map.

The editor uses the same native renderer, terrain, trees, water, and pathfinder
as GotA. Edit terrain, draw solid castle walls, and place the structures used
by a match. Elevation levels are separate from the renderer's geometry layers.
Existing base platforms remain protected from terrain brushes. Lane anchors
remain fixed, with routes connecting them to your placed barracks.

## Controls

- Left drag paints the selected tool. Brush radius zero edits one tile.
- Keys 1 through 5 select flat elevation levels at -1, 0, 1, 2, and 3 tiles.
  These steps are half the height of the original editor.
- Ramp joins two terraces along the dominant drag axis. Drag across the cliff
  from a flat low tile to a flat high tile. Make the ramp long enough for its
  height difference. Its width is twice the brush radius plus one tile.
- Smooth blends shared terrain corners. Drag to soften a ridge or hold the
  brush still for repeated passes. It preserves water surfaces, trees, walls,
  and protected base geometry. Shared vertices remain joined.
- Half height and Double height rescale all existing ground, water, and slab
  heights together. Each operation is undoable. Loading an older map preserves
  its heights until you explicitly rescale it.
- Water sets the bed to the selected elevation with 3/8 tile of shallow water.
  Units walk on the bed. Dry removes water without changing the bed height.
- Trees paint blocking forest tiles. Clear trees removes those trees and their
  collision. Block and Open change movement independently of elevation.
- Right drag orbits. Middle drag pans. The wheel zooms.
- Top view and Game view change the camera angle. Fit map recenters it.
- Ctrl/Cmd S saves. Ctrl/Cmd Z undoes. Ctrl/Cmd Shift Z or Ctrl/Cmd Y redoes.
- Escape cancels a stroke or requests closing the editor.

Undo stores up to 64 actions, including terrain, walls, and building placements.
Fast pointer movement fills intermediate tiles. The editor protects base
platforms from painting, but routes outside them may still be blocked by edits.

## Walls and buildings

Open the Build tab and select a team.

- Draw wall paints solid masonry with adjustable height and width. Drag freely
  to draw connected walls, including diagonal runs and corners.
- Erase wall cuts openings in your walls. Leave openings for gates and paths.
  Walls occupy a separate layer, so erasing one restores the original ground
  and its movement state. Walls block both movement and vision.
- Tower, Barracks, and God select the placement type. Pick the lane and tower
  tier where applicable. A preview follows the cursor. Click open terrain to
  place that role or move its existing structure.
- Select picks an existing building and loads its properties. Click elsewhere
  to move it. R or Rotate turns the placement preview by 90 degrees.
- Remove deletes a clicked building. Undo restores it.

Each team has one god, three lane barracks, and up to three tower tiers per
lane. Placement edits these gameplay roles rather than adding unlimited copies.
Towers retain their team, lane, tier, health, and combat behavior. Barracks
set the lane's spawn point. Gods move the team's objective and healing center.
The editor and playtest use the same structure models and saved positions.
A playable map needs all six barracks and both gods; drafts may omit them.

## Inspection and playtesting

The Inspect tab offers elevation colors, traversable edge markers, lane anchors,
and a two-click path test. The moving path marker follows the actual computed
route. Point at terrain and press V to preview ground and tree occlusion within
20 tiles. Press V again to clear it. This preview samples the ground surface;
the full game also includes elevated fort surfaces and shared team vision.

Check all battle routes verifies every lane segment and both bases' required
entrances, ramparts, and fountains. It also checks required building roles,
placement surfaces, and routes from buildings to their lanes.
Draft maps can be saved with blocked routes.
The game and Playtest button reject them with a descriptive error.

Playtest saves the current map, compiles GotA in the background using the
installed Nim compiler, and opens a separate playable game with nine bots.
The editor stays open. Close the playtest before launching another.

To load a saved map directly in the game:

```sh
nim r examples/gods_of_the_arena/gota.nim --map path/to/arena.json \
  --player --bot:examples/gods_of_the_arena/players/base.bas:9
```

Replays of an authored map need the same JSON file supplied with `--map`.
The replay verifies the map hash. Map JSON is not embedded in the replay.

## JSON format version 2

The file starts with these metadata fields, followed by the complete layers:

```json
{
  "format": "gota-map",
  "version": 2,
  "heightUnitsPerTile": 8,
  "name": "My arena",
  "seed": 2026,
  "authoredBuildings": true,
  "buildings": [],
  "layers": []
}
```

The empty arrays above illustrate metadata only. Editor files have five layers
in this order: `ground`, `redFort`, `blueFort`, `water`, and `walls`. Each layer
stores its name, originX, originZ, width, depth, slab, water, blocking, and tiles.
Ground, water, and walls cover the full map. The walls layer is a solid slab
layer with `blocking: true`; its volumes block overlapping navigation surfaces.
The other layers have `blocking: false`. Fort layers are 25 by 25 at origins
(8, 8) and (95, 95). Tiles are in row order, at index `z * width + x`.

One grass tile looks like this:

```json
{"tops":[0,0,0,0],"bottoms":[0,0,0,0],"surface":"grass","exists":true,"blocked":false,"east":true,"south":true}
```

- `tops` and `bottoms` contain four integer heights in eighths of a tile.
  Corner order is northwest, northeast, southwest, southeast.
- `surface` is `grass`, `road`, `rock`, `marsh`, `stone`, `trees`, `redFort`,
  or `blueFort`. Trees must be blocked.
- `exists` indicates geometry. The ground layer must be complete.
- `blocked` explicitly blocks walking.
- `east` and `south` permit joining the neighboring geometry. The pathfinder
  also checks corner heights and slopes, so a cliff still blocks movement.
- `bottoms` define slab undersides and must not exceed the corresponding tops.

A tower record looks like this:

```json
{"kind":"TowerBuilding","team":0,"lane":0,"tier":0,"layer":0,"x":60,"z":30,"rotation":90}
```

- `kind` is `TowerBuilding`, `BarracksBuilding`, or `GodBuilding`.
- `team` is 0 for red or 1 for blue.
- `lane` is 0 for top, 1 for middle, or 2 for bottom.
- Tower `tier` is 0 for outer, 1 for inner, or 2 for gate.
- `x` and `z` are global tile coordinates, from 0 through 127.
- `layer` selects the supporting geometry layer. Height is sampled from it.
- `rotation` is a clockwise angle in degrees. Editor controls turn by 90 degrees.
- God lane/tier and barracks tier are ignored.

`authoredBuildings: true` makes the list authoritative. Missing towers stay
absent; missing gods or barracks prevent playtesting. When false, the game uses
its generated structure placement. Duplicate team/lane/tier roles are rejected.

Version 1 maps still load without changing their terrain heights. Opening one
in the editor adds an empty wall layer and editable default building records;
saving writes version 2. The reader also accepts four layers in version 2 when
no wall layer is present. Building records and solid wall geometry participate
in the deterministic map hash.

The seed controls deterministic decoration and simulation initialization.
Loading a saved file never regenerates its terrain from that seed. The file
stores no mesh buffers, path caches, visibility grids, or gameplay units.
The loader validates the format before installing terrain and rebuilds derived
navigation and the map hash. Saves replace the destination after writing the
complete JSON to a sibling `.saving` file.
