# Rock generator

Run from the Polyworld repository:

```sh
nim r experiments/rockgen/rockgen.nim
```

Rockgen follows the Treegen editor layout and uses the same Silky controls,
toon renderer, orbit camera, and sun shadows. Nine presets provide tall
angular rocks, low compact boulders, slabs, pebbles, and leaning shards.
The seed controls the silhouette, trim selection, face shading, and details.
Compare three seeds shows the selected rock between its neighboring seeds.

## Controls

- Shape sets dimensions, side planes, crown cuts, irregularity, taper,
  crown slope, lean, shoulder height, corner clipping, and local chips.
  Remove bottom triangles omits the flat ground-contact cap, including its
  fill and trim. It defaults to off and applies to the preview and export.
  Floor (%) cuts away 0 to 90 percent of the original height and lowers
  the remaining rock to ground level. At 50 percent, half the rock remains;
  at 90 percent, only the top tenth remains. Any positive floor cut leaves
  an open base automatically. The preview floor meets this open boundary,
  so there is no horizontal rock face competing with the ground surface.
- Surface sets trim width, worn-edge probability, detail probability,
  square size, detail offset, crack or scuff selection, variation between
  faces, and a subtle surface wash carried by vertex colors. Fill
  subdivisions defaults to 0. Set it to 1 or 2 for finer surface shading
  at the cost of more triangles. Disabling Surface wash skips subdivisions.
- Colors multiplies the gray atlas by an RGB tint and adjusts the sun.
- Face regions colors trim amber, fill teal, and detail patches pink.
- Wireframe reveals the actual mesh triangulation. Combine it with Face
  regions to inspect how the triangles meet around each square.

Drag to orbit, middle drag to pan, and scroll to zoom. R randomizes the
seed, F fits the rock, W toggles wireframe, D toggles face regions, Space
toggles rotation, and Tab hides the panel. The parameter area scrolls.

Save preset writes `presets/custom.json`. Load restores it. Export GLB
writes `exports/rock-SEED.glb` with vertex normals, UVs, face shading, the
selected tint, and the texture embedded. Exports contain the selected
center rock with the textured material, including while inspecting regions.

## Construction

1. Shape an uneven block with independently tilted side planes. Cut its
   vertical corners, then cut the shoulders above an adjustable height.
   Keep a slanted crown and use shallow cuts around the base. Finally,
   select individual corners and chip them with local planes. Reject cuts
   that produce sliver faces or tiny edges. Scale the solid to the requested
   dimensions and place its bottom at ground height.
2. Project each face into its own two-dimensional coordinate system.
   Contract its polygon toward an interior point to form the trim boundary.
   Trim width is this fractional contraction, from 0 to 0.4. It therefore
   follows the face proportions rather than a fixed distance in world units.
3. Triangulate the perimeter band and map selected worn edges to a short
   section of one of the four top-row strips. The outer vertices sample the
   bright ridge and the inner vertices sample plain rock above it in the
   atlas. Other edges use the solid fill. Setting Trim width to zero maps
   the band to solid fill as well.
4. Optionally place a rotated square inside the remaining face. Its size
   and offset are limited by clearance to every edge. Tiny faces and the
   underside omit details.
5. Extend rays through the four square corners to the inner trim boundary.
   Insert their intersection points into both the trim and fill boundaries.
   Triangulate the four surrounding sectors and give the square exactly
   two triangles. All subdivisions retain the original plane and normal.
6. Triangulate each fill polygon using its boundary vertices. A polygon
   with N corners uses N minus 2 triangles. Faces with no trim or details
   omit the inner ring completely. Sample seeded smooth noise into vertex
   colors for a subtle wash. Optional subdivisions add interior samples
   and flip interior diagonals to improve their spacing. They preserve
   the rock silhouette, flat face normals, trim, and detail squares.
7. If Floor (%) is positive, clip the textured triangles at that height
   and translate the remaining geometry down to ground level. Interpolate
   UVs and vertex colors along cut edges, preserving texture placement.
   Details intersecting the floor become partial patches. Do not add a cap
   to the cut, and update the bounds and counts to the exposed geometry.

The default mesh uses 322 to 440 triangles across the nine presets at seed
42, down from 1,616 to 2,146. The extra triangles in the previous version
only made the vertex wash more detailed. The trim texture, cracks, chips,
and silhouette do not require them. Keep Fill subdivisions at 0 for normal
gameplay rocks; use 1 or 2 when the finer wash is useful in close-up views.

The solid keeps shared positions across face boundaries. Removing the
bottom leaves an open boundary at ground height. Normals
and UVs split at those boundaries for flat shading and independent texture
placement. Tint changes only the material. Geometry rebuilds when shape,
surface settings, seed, or the inspection mode changes.

The reference rocks rely on three different scales: large blocky planes,
smaller chipped corners, and painted surface variation. A tapered prism
with equally strong trim around every face overemphasizes its construction.
The revised generator treats these three scales separately. The preview
uses continuous lighting, a high light from the left, and softer shadows.
The atlas's solid fill is still almost uniform, so the vertex wash is a
lightweight approximation of the reference's richer painted texture.

## Texture

`assets/rock-trim-atlas.png` is the exact 1254 by 1254 image supplied for
this experiment. It uses the normalized four-by-four layout:

| Row | Column 1 | Column 2 | Column 3 | Column 4 |
| --- | --- | --- | --- | --- |
| 1 | Edge trim | Edge trim | Edge trim | Edge trim |
| 2 | Solid fill | Crack | Branched crack | Vertical crack |
| 3 | Fissure | Impact crack | Paired cracks | Scuff |
| 4 | Scrapes | Chip | Wear | Crack and scuff |

The visible top lip occupies a narrow part of the first row. Trim triangles
sample atlas V from 0.020 at the outer edge to 0.008 at the inner boundary.
This uses the bright upper ridge and omits its dark underside. Each worn
edge uses a seeded 0.08-wide section inside one trim cell, making its chips
larger and avoiding a repeated gravel-like line around the rock. Solid fill
samples the center of row 2, column 1. Detail UVs use a 0.003 atlas-space
inset to stay inside their cells.

The atlas is sampled with linear filtering and no mipmaps to avoid bleeding
between neighboring cells. At very small screen sizes the thin trim can
alias. The supplied tile boundaries have small pixel differences, so the
experiment maps one strip across each edge instead of wrapping within it.
The export adapter preserves this sampling configuration in the GLB because
the current shared writer omits base-color sampler settings.

## Checks and captures

```sh
nim check experiments/rockgen/rockgen.nim
nim r experiments/rockgen/tests/tests.nim
nim r experiments/rockgen/tests/bench_rocks.nim
nim c -o:experiments/rockgen/rockgen experiments/rockgen/rockgen.nim
experiments/rockgen/rockgen --preset=0 --seed=42 --gallery
experiments/rockgen/rockgen --preset=1 --smoke --screenshot=tmp/rock.png
experiments/rockgen/rockgen --regions --wireframe --smoke
experiments/rockgen/rockgen --sheet --screenshot=tmp/rockgen-sheet.png
experiments/rockgen/rockgen --fill-subdivisions=2 --preset=0
experiments/rockgen/rockgen --preset=0 --export=tmp/rock.glb
experiments/rockgen/rockgen --load=experiments/rockgen/presets/custom.json
```

Preset indices are 0 through 8 in dropdown order. `--sheet` renders all nine
presets as a 3 by 3 image using consecutive seeds. `--frames=N` runs a
hidden preview for N frames. `--screenshot=PATH` defaults to four hidden
frames. `--no-panel` captures only the preview. `--yaw=RADIANS` and
`--pitch=RADIANS` set the camera. `--export=PATH` runs without a window.
`--fill-subdivisions=0|1|2` overrides the preset for preview, sheet, or export.

Tests verify seeded determinism, closed mesh edges, triangle winding,
face area coverage, coplanarity, square patches, UV region selection,
parameter bounds, preset serialization, and an embedded-texture GLB
round trip. They also exercise corner cuts and surface controls at their
limits, enforce the default triangle budget, and verify that changing fill
density preserves the shape and textured regions. The benchmark measures
complete CPU geometry generation, including triangulation and vertex wash.
