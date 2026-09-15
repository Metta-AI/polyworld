# Tree generator

Run from the Polyworld repository:

```sh
nim r experiments/treegen/treegen.nim
```

The left panel contains nine presets across leafless, evergreen, and round
broadleaf trees. Cycle Previous Preset and Next Preset, randomize the seed,
then tune the Trunk, Branches, Canopy, Leaves, and Colors tabs.
Drag the parameter tracks.
The parameter area scrolls independently. The current seed is displayed
above Randomize Seed. RGB controls use values from 0 to 1.
The six leafy presets average about 100 leaf cards, using one foliage shell.
Increase Density, Leaf overlap, or Inner shells for fuller canopies.

Drag in the preview to orbit. Middle drag pans and the wheel zooms.
R randomizes the seed, F fits the view, W toggles wireframe, Space toggles
the turntable, and Tab hides the panel. Compare three seeds shows the
selected seed in the center with its immediate neighbors on either side.

Save preset writes `presets/custom.json`. Load restores that recipe.
Export GLB writes `exports/tree-SEED.glb` with embedded textures and
separate bark and foliage materials. Exports use the selected center seed.

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
The default presets retain about 100 cards on average with separation enabled.
Very crowded settings can omit more cards rather than reintroduce crossings.

The trim outlines in `trims.nim` are generated from the atlas alpha at 0.45.
After replacing the foliage atlas, regenerate them with
`python3 experiments/treegen/tools/gen_trims.py` (requires Pillow).
The source PNG is read unchanged.

The supplied v8 foliage atlas is copied unchanged into `assets`.
Its first row contains four top-down cap textures. Evergreens use the first
tile, and broadleaf trees choose one of the other three from their seed.
The middle two rows contain eight broadleaf trims, and the bottom row
contains four downward-pointing evergreen sprays.
Leaf transparency and painted detail are preserved, including the subtle
darkening at each branch attachment and the brighter leaf tips. Presets use
zero Shade variation so whole leaf cards receive the same brightness factor.
The Shade variation slider remains available for deliberate variation.

Bark uses the separate, supplied tileable `assets/bark.png` texture.
Its luminance is neutralized in memory so the Bark RGB controls set its color.
The Colors tab has Bark texture for contrast and Bark density for repeats
per world unit. Higher density gives smaller details. UVs follow measured
ring perimeters and surface distances along each trunk, branch, and root,
so smaller limbs sample less texture instead of squeezing in a whole tile.
The orientation follows bends without flipping. Cut ends use planar UVs at
the same density. Both texture axes repeat, including in exported GLBs.

Both materials use the shared `polyworld/toon`
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
/tmp/treegen --preset=0 --export=/tmp/tree.glb
/tmp/treegen --load=experiments/treegen/presets/custom.json
```

Preset indices follow the dropdown order, from 0 to 8. `--frames=N`
runs a hidden preview for a bounded number of frames. `--screenshot=PATH`
captures the final frame and defaults to four frames. `--export=PATH`
exports directly without opening a window.
`--yaw=RADIANS` and `--pitch=RADIANS` set the initial camera angle for
repeatable captures around and above the crown.
