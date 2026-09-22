# Tree generator

Run from the Polyworld repository:

```sh
nim r experiments/treegen/treegen.nim
```

The left panel contains ten presets across leafless, evergreen, round
broadleaf trees, and stumps. Cycle Previous Preset and Next Preset,
randomize the seed,
then tune the Trunk, Branches, Canopy, Leaves, and Colors tabs.
Drag the parameter tracks.
The parameter area scrolls independently. The current seed is displayed
above Randomize Seed. RGB controls use values from 0 to 1.
The leafy presets use one foliage shell. Evergreens generate 50% more cards
for a fuller canopy.
Increase Density, Leaf overlap, or Inner shells for fuller canopies.

Drag in the preview to orbit. Middle drag pans and the wheel zooms.
R randomizes the seed, F fits the view, W toggles wireframe, Space toggles
the turntable, and Tab hides the panel. Compare three seeds shows the
selected seed in the center with its immediate neighbors on either side.

Save preset writes `presets/custom.json`. Load restores that recipe.
Export GLB writes `exports/tree-SEED.glb` with embedded textures and
separate bark, foliage, or cut-wood materials as needed.
Exports use the selected center seed.

## Use in a game

The shared generator lives in `src/polyworld/treegen.nim`. Import it directly:

```nim
import polyworld/treegen

let
  settings = preset(3, seed = 42)
  tree = generate(settings)
```

`generate` returns a standard glTF `Node` with meshes, tinted materials, and
textures ready for the game's renderer. Add it to your scene or pass it to
the toon renderer's `draw` procedure. GPU upload happens when it is rendered.
The 512-pixel textures load from `polyworld_data/terrain/treegen` at runtime.
Run native programs from the Polyworld repository. Browser builds package
these shared textures in `.data`, outside `.wasm`.

`generateGeometry` returns the flat `TreeGeometry` data for callers that need
mesh statistics or direct vertex access. `loadMaterials`, `tint`, and
`treeNode` let callers reuse materials when assembling several trees.
The experiment uses these same shared procedures for its preview.
Preset JSON and GLB export remain editor utilities in `views.nim`.

## Stumps

The Stump preset keeps the roots and a short trunk with a flat cut surface.
Cut height in the Trunk tab ranges from 0.3 to 3 world units. Radius, taper,
bend, polygon resolution, and the root controls also apply. The trunk keeps
a broad top, and roots stay below the cut. Stumps have no branches or leaves.
The cut surface shares the trunk's rim positions and maps the supplied
`polyworld_data/terrain/treegen/stump-rings.png` texture once across the disk.
Its UVs stay inside
the painted wood so the texture's transparent border cannot create holes.
Ring spacing stays constant in world units. Narrow cuts zoom into the
painted ring center and show fewer rings; wider cuts reveal more rings.

## Canopy construction

Foliage is arranged in horizontal rings around the trunk. Each ring is
rotated relative to its neighbors and receives seeded height, angle,
radius, and center offsets. Evergreen ring radii follow a tapered cone.
Evergreen cards wrap around the envelope and point down its local slope.
Their centerline length stays constant at every height. Card edges narrow
near the tip to fit the small ring instead of sticking out as flat wings.
Wider lower rings add more cards instead of enlarging them. Counts use
the strip midpoint radius, and angular jitter stays within each card slot
to avoid large gaps between neighboring sprays.
Evergreens apply a 1.5 multiplier to card density in the shared generator,
including custom game settings. Card sizes and the cone profile stay the same.
Leaf randomness adds seeded size variation independent of ring height.
Broadleaf radii follow a rounded envelope. Sphere coverage defaults to 0.75,
omitting rings in the lowest quarter of the full sphere's height. This removes
small hidden rings underneath while keeping the upper canopy and cap in place.
Set coverage to 1 for the full sphere or 0.5 for its upper half.
Inner shells fill the crown.
Leaf overlap adds cards and rings to keep neighboring sprays tightly packed.
Density scales the card count. The Clear stem control keeps foliage and
branches above a visible stem. Root tips have a short downward claw,
with editable length and angle. The default slope is 30 degrees.
Each card runs outward and downward from its attachment and samples one
atlas tile. Two joined panels form a crease across its width to follow
the ring. Each card uses four triangles, reduced from the original six.
The cards are fixed in world space, so the tree can be inspected from any angle.
A single circular cap replaces the top ring. It has 24 connected triangle
slices sharing a raised center and a lower rim, with one continuous UV map
across the whole cap texture. Cap size adjusts its radius in the Canopy tab.
Evergreen caps follow the crown profile automatically. Broadleaf caps also
have an editable Cap slope. Droop and Card curl apply to broadleaf cards;
evergreen orientation comes from the crown profile.
Leafless trees keep their bare branches.
The upper leaf ring sits close beneath the cap, with less random displacement
near the tip. Evergreen caps taper to a point with the same cone silhouette.

Prevent leaf crossings in the Leaves tab is enabled by default. A spatial
grid finds nearby cards during generation. Collision checks use convex
outlines of the visible leaf textures, allowing transparent corners to
overlap. Cards shift slightly up or down to avoid cutting through each
other. A card is omitted if it cannot fit within the allowed displacement
and stem clearance. The crown cap stays fixed. Its exclusion area follows
the visible cap texture, allowing surrounding leaves into its transparent
border while keeping them beneath its opaque area.
This also applies to exported trees and does not run physics each frame.
Leaf separation remains enabled for the denser evergreen canopies.
Very crowded settings can omit more cards rather than reintroduce crossings.

The outlines in `src/polyworld/treegen/trims.nim` come from atlas alpha at 0.45.
After replacing the foliage atlas, regenerate them with
`python3 tools/gen_tree_trims.py` (requires Pillow).
The source PNG is read unchanged.

All three assets in `polyworld_data/terrain/treegen` are 512 by 512 pixels.
The supplied v8 foliage
atlas and bark texture are downsampled with alpha-aware Lanczos filtering;
the supplied 512-pixel stump texture is copied unchanged. Source images are
preserved. The foliage atlas keeps the same normalized UV layout, with
128-pixel cells in its four-by-four grid.
Its first row contains four top-down cap textures. Evergreens use the first
tile, and broadleaf trees choose one of the other three from their seed.
The middle two rows contain eight broadleaf trims, and the bottom row
contains four downward-pointing evergreen sprays.
Leaf transparency and painted detail are preserved, including the subtle
darkening at each branch attachment and the brighter leaf tips. Presets use
zero Shade variation so whole leaf cards receive the same brightness factor.
The Shade variation slider remains available for deliberate variation.

Bark uses the supplied tileable `polyworld_data/terrain/treegen/bark.png`.
Its luminance is neutralized in memory so the Bark RGB controls set its color.
The Colors tab has Bark texture for contrast and Bark density for repeats
per world unit. Higher density gives smaller details. UVs follow measured
ring perimeters and surface distances along each trunk, branch, and root,
so smaller limbs sample less texture instead of squeezing in a whole tile.
The orientation follows bends without flipping. Cut ends use planar UVs at
the same density. Both texture axes repeat, including in exported GLBs.

All materials use the shared `polyworld/toon`
renderer, and alpha-cutout leaves participate in its sun shadow pass.

Generation uses local random streams for wood and foliage. The same seed
and settings produce the same mesh. Colors do not affect geometry.
Forks inherit thickness at their actual attachment point. Minimum thickness
stops branches and skips forks before they become tiny twigs.

## Reproducible runs

```sh
nim check experiments/treegen/treegen.nim
nim r experiments/treegen/tests/tests.nim
nim c -o:/tmp/treegen experiments/treegen/treegen.nim
/tmp/treegen --preset=3 --seed=42 --gallery
/tmp/treegen --preset=6 --smoke --screenshot=/tmp/treegen-bare.png
/tmp/treegen --preset=9 --pitch=0.65 --smoke --screenshot=/tmp/stump.png
/tmp/treegen --preset=0 --export=/tmp/tree.glb
/tmp/treegen --load=experiments/treegen/presets/custom.json
```

Preset indices follow the dropdown order, from 0 to 9. `--frames=N`
runs a hidden preview for a bounded number of frames. `--screenshot=PATH`
captures the final frame and defaults to four frames. `--export=PATH`
exports directly without opening a window.
`--yaw=RADIANS` and `--pitch=RADIANS` set the initial camera angle for
repeatable captures around and above the crown.
