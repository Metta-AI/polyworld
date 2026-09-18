# Chargen assets

Run the utility from the Polyworld repository:

```sh
nim r experiments/chargen/chargen.nim
```

The default library is `../polyworld_data/characters/chargen`. Set
`CHARGEN_LIBRARY` to open another library or a game-specific export.

The Python authoring toolkit lives with the assets in
`../polyworld_data/characters/chargen/source/scripts`. This includes Blender
geometry builders, animation imports, texture cutters, packers, and checks.
The viewer, runtime, and render utilities remain Nim code in Polyworld.

For the authoring commands below, start in the Polyworld repository and set:

```sh
export CHARGEN_SCRIPTS=../polyworld_data/characters/chargen/source/scripts
```

The scripts resolve asset paths from their own location, so Blender and Python
can run them from any working directory. Intermediate exports and preview
renders still use the sibling `polyworld/tmp/chargen` folder. No authoring
scripts or Blender files are included in game-specific packs.

## Folder layout

| Folder | Contents |
| --- | --- |
| `source/scripts` | Python and Blender authoring tools |
| `body` | Body, hands, and feet as separate GLBs, grouped by a part sidecar |
| `heads`, `noses`, `ears` | Independently selectable head and facial geometry |
| `hair`, `beards` | One GLB and JSON sidecar per style |
| `eyes` | One PNG, iris mask, GLB surface, and JSON sidecar per generated pair |
| `mouths`, `eyebrows` | One PNG, GLB surface, and JSON sidecar per generated style |
| `colors` | Editable skin, hair, and eye preset lists |
| `clothing/torsos` | Eight medieval tops and a tucked shirt |
| `clothing/pants`, `clothing/boots` | Four trousers, cuffed shorts, and five boots |
| `clothing/jackets` | Open jacket, long coat, and vest |
| `clothing/belts`, `clothing/suspenders` | Buckle belt, suspenders, and overall bib |
| `hats` | Six recolorable gnome hats, each in its own GLB |
| `clothing/backs`, `clothing/gloves` | Future clothing parts |
| `earrings`, `eyewear`, `props/left`, `props/right` | Future accessories |
| `rig` | Shared humanoid skeleton and bone preview metadata |
| `animations` | One GLB per animation clip |
| `source` | The single editable `character.blend` and authoring textures |

A GLB is binary glTF. Every part includes its bind skeleton so it can also be
opened independently. At runtime, Chargen rebinds those joints to one shared
skeleton. Animation files contain the skeleton and a single animation, with no
character geometry. All current animations are retained.

The master face sheets remain in `source` for authoring. Runtime face images are
individual transparent cutouts. Eyes and mouths remain unlit. Iris masks tint
only the iris, preserving the white and dark details. White eyebrows follow the
hair color unless the viewer's white eyebrow option is selected.

## Shared gnome features

Select `Gnome 01` through `Gnome 09` in the preset picker, or enable
`Nine gnomes` in the animation panel. `Gnome T pose` restores the reference
layout. The normal animation, scrub, pause, shading, and polygon controls also
work on the lineup. Each model copies the main skeleton's evaluated pose, so
cross-fades and scrubbing stay synchronized without loading nine clip sets.

These presets share `Gnome kind` eyes, `Gnome bulb` nose, `Gnome cups` ears,
`Gnome pointed` beard with moustache, and the existing `01 Soft arch` brows.
The nine presets vary the hair, iris, and hat colors and choose from six hat
styles. Their outfits layer new outerwear over the existing shirts and trousers.
Each also selects a slightly different fair skin shade from peach, ivory,
rose, cream, and warm beige variations in the shared skin palette.
Presets can optionally
specify `hairColor`, `pupilColor`, and `hatColor` by palette name. `group`
identifies a lineup's presets.

Launch directly into the lineup with:

```sh
GNOME_LINEUP=1 nim r experiments/chargen/chargen.nim
```

The generated eye source and prompt are in `source/gnomes`. The iris has a
subtle gray gradient; the tint mask preserves white sclera, black pupils,
highlights, and the upper eyelid stroke. Regenerate the cutout and add the
facial geometry to the master Blender file without rebuilding other parts:

```sh
python3 "$CHARGEN_SCRIPTS/cut_gnomes.py"
blender -b --python-exit-code 1 --python "$CHARGEN_SCRIPTS/build_gnomes.py"
```

The full `build_model.py` pipeline also includes these shared parts. The
additive builder refreshes the assembled verification export, while runtime
parts remain separate files in `eyes`, `noses`, `ears`, and `beards`.

## Gnome hats

The `Headgear` picker offers pointed, folded, wide-brimmed, mushroom, leaf, and
feather hats. The last two reuse the pointed and folded crown designs with
simple decorations. All six follow the head bone and hide the current scalp
hairstyles while equipped. Removing a hat restores the selected hair.

Hat palette buttons and RGB sliders recolor only the surfaces listed in each
part's `hatShades`. Mushroom spots and lining, green leaves, and blue/cream
feathers retain their colors. The palette lives in `colors/hats.json`; custom
libraries without a hat palette still load normally. Set `HAT_COLOR=Blue` at
launch to choose a palette color. The nine gnome presets select their own
hat colors.

Hat fabric and mushroom caps use smooth normals, preserving edges at sharp
folds and rims. Mushroom spots have their own pure white unlit material, so
normal boundaries and toon lighting cannot break their color into facets.
The cream lining remains a separate shaded material.

Rebuild the hats in the master Blender file and export their individual GLBs:

```sh
blender -b --python-exit-code 1 --python "$CHARGEN_SCRIPTS/build_hats.py"
nim r experiments/chargen/render_hats.nim
```

The renderer writes front, side, and back review sheets to `tmp/chargen/hats`.
The full `build_model.py` pipeline includes the hats too. Game packs can ship
any subset of the six GLBs, keeping the same shared skeleton and animations.

## Gnome clothing

The `Jacket`, `Belt`, and `Suspenders` slots layer independently over `Chest`
and `Leg`. The nine new parts are an open jacket, long coat, vest, cuffed
shorts, buckle belt, suspenders, overall bib, tucked shirt, and pointed-cuff
boots. They reuse
outer fabric from the existing long-sleeved shirt and trousers, preserving
body-derived weights. Lapels, cuffs, pockets, buttons, and brass buckles are
small mesh details. The bib works best over `Gnome tucked shirt` so its straps
meet the waistband instead of hanging over a loose hem.

Gnomes 05 and 07 share the fuller long coat with broad lapels and a gently
flared hem, colored gray and blue respectively. Gnome 06 wears taller boots
with V-shaped cuffs and contrasting brown piping. The boots hide the feet
and the lowest trouser sections while retaining trousers behind the front V.

Each part is a separate GLB in its part folder. `clothShades` identifies the
fabric primitives to tint; fixed metal, boot soles, and contrasting trim keep
their colors. A preset part can include `rgb: [r, g, b]` in the zero-to-one
range. Enable `Custom <slot> color` in the viewer to adjust that slot's RGB.
Games can use `initClothMaterials`, `applyClothPreset`, and `applyClothTint`.

```sh
blender -b --python-exit-code 1 --python "$CHARGEN_SCRIPTS/build_garments.py"
nim r experiments/chargen/render_garments.nim
CLOTHING_DETAILS=1 nim r experiments/chargen/render_garments.nim
blender -b --python-exit-code 1 --python "$CHARGEN_SCRIPTS/verify_garments.py"
```

Review sheets and geometry/posed-clearance diagnostics go in
`tmp/chargen/garments`. The detail sheets hide heads and outerwear to expose
bib and suspender fit. The complete model builder includes these garments.
The nine presets retain the current body proportions and use simplified
outfits rather than all decorative details from the concept.

## Adding a part

The root `manifest.json` maps each UI category to a folder. The loader discovers
all `*.json` sidecars in that folder in filename order. There is no fixed style
count. A new torso can use this sidecar at `clothing/torsos/linen.json`:

```json
{
  "id": "clothing/torsos/linen",
  "name": "Linen shirt",
  "nodes": ["Shirt_Linen"],
  "files": ["clothing/torsos/linen.glb"],
  "hides": ["Body"]
}
```

Export the mesh with the same named joints, hierarchy, bind transforms, and
coordinate system as `rig/humanoid.glb`. Mesh nodes must have unique names and
attach directly under a named rig node. GLB and glTF files can be loaded. Every
path in a sidecar is relative to the library root. A part can list several files,
for example the left and right ear. Set `hides` only when a part actually
replaces that body geometry.

Optional fields:

- `alignment`: `"good"`, `"evil"`, or `"both"` (the default when omitted).
  Good random includes good-only and shared parts. Evil random includes
  evil-only and shared parts. Random includes everything. Hover over a selected
  part's name to see its tag. Manual selection always allows every part.
- `skinNodes`: Mesh names to tint with the selected skin color.
- `hairShades`: Entries with `node`, `primitive`, and `shade` for hair tinting.
- `texture`: The individual face PNG.
- `pupilMask`: A matching PNG whose red channel controls iris tinting.
- `tint`: Use `"hair"` for a white eyebrow decal.
- `style` and `color`: Group clothing color variants for the color picker.
- `singleFile`: Keep a garment's mesh sections together when rebuilding its GLB.

Put texture references in the glTF material as well as the sidecar. Face
materials use an unlit alpha cutout. New face GLBs use UVs within their own PNG;
the packer remaps these when building an atlas. New categories can be registered
by adding a `key`, `directory`, and optional `defaultItem` to the root manifest.
Restart the utility after adding files.

## Body-derived clothing

The `Chest`, `Leg`, and `Foot` pickers now include the 16 approved medieval
clothing designs. Shirts and trousers are cut from the actual body surface and
offset outward. Boots also use the existing foot geometry. Cuts interpolate
the original bone weights. Extruded tunic hems sample nearby body weights so
they follow the hips and upper legs. Open necklines, cuffs, and hems have a
thin modeled rim. The body remains smooth shaded.

Each complete garment ships as one GLB and one sidecar. Trousers have seamless
internal mesh sections at the four boot heights. Boot sidecars hide the lower
sections covered by their shafts and the bare feet. Removing boots restores
those sections. This uses the existing `hides` selection mechanism and works
in selective game exports too. No animation clips or original kit meshes are
changed. The clothes are skinned meshes, without cloth simulation.

To rebuild only clothing while retaining the current body and animations:

```sh
PYTHONDONTWRITEBYTECODE=1 \
  /Applications/Blender.app/Contents/MacOS/Blender --background \
  --python "$CHARGEN_SCRIPTS/build_clothes.py"
```

`clothes.py` is also part of the full model build. `render_clothes.py` and
`clothing_sheets.py` produce the matching front/back contact sheet under
`tmp/chargen/clothing_reviews`. `verify_clothes.py` checks weights and topology
and records sampled body clearance for inspecting extreme poses. Numeric
clearance alone is not a collision test because nearby body regions overlap
in bent poses. Check the actual rendered outfits when changing their fit.

## Shipping selected parts

The Python tools require Pillow. List stable part IDs and available clips:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 "$CHARGEN_SCRIPTS/pack.py" --list
```

For example, export two eye options and only the walking and idle animations:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 "$CHARGEN_SCRIPTS/pack.py" \
  --output tmp/chargen/my_game \
  --parts body/base heads/base noses/tiny hair/01_french_crop \
    eyes/02_focused eyes/04_calm mouths/01_relaxed_smile \
    eyebrows/01_soft_arch \
  --clips Idle Walk
CHARGEN_LIBRARY="$PWD/tmp/chargen/my_game" \
  nim r experiments/chargen/chargen.nim
```

Choose a fresh output directory for each export. The packer copies only selected
parts, palettes, the rig, and selected animation clips. Required transition
clips are included automatically, such as JumpAir when choosing JumpStart.
It builds separate eye, mouth, and eyebrow atlases from the selected images,
including a matching eye mask atlas. `pack.json` records each rectangle. The
same runtime loader reads individual images or packed atlases. `--no-atlas`
keeps the selected images separate. Omitting `--parts` or `--clips` includes all
parts or all clips respectively. An empty `--clips` exports a static library.

Select the union of parts needed by a game's characters. The exporter does not
include the `.blend`, master sheets, authoring prompts, or unused models.

Nim games can `import polyworld/chargen`, call `readManifest(directory)` and
`readCharacter(directory, manifest)`, and use `applySelection` with
`manifest.defaultSelection()`. `attachPart(root, directory, path)` can attach a
compatible mesh later. Animate the returned model's `root` with
`polyworld/animblend`. Apply skin, hair, eyebrow, and pupil colors through the
exported tint functions, as shown in `chargen.nim`.

## Rebuilding and checking

The default animation group is Quaternius Universal Standard, with 43 entries
including its T-pose. The complete downloaded source pack lives in
`polyworld_data/animations/quaternius/universal_standard`, together with its
CC0 license, setup images, and both in-place and root-motion exports.
Chargen uses the in-place GLB. Its retargeted clips are individually exported
under `characters/chargen/animations/universal`. The existing RPG animations
and Layer Lab poses remain in separate viewer groups.

`universal.py` maps all 22 Chargen bones using the source's explicit T-pose,
preserves fixed limb lengths, and bakes at 30 fps. No arm mirroring or runtime
wrist correction is applied. Universal clips animate only the Chargen model.
The optional original comparison stays in bind pose for those clips.

To update animations without rebuilding geometry, run Blender in background
with `--python "$CHARGEN_SCRIPTS/import_animations.py"`. Set
`CHARGEN_PYTHON=/opt/homebrew/bin/python3` when that interpreter has Pillow.
Run Blender with `--python "$CHARGEN_SCRIPTS/verify_universal.py"` to check
all exported bone rotations, hip movement, and limb lengths against the source.
Full model builds also include the Universal library.

`defaultAnimation` in the library manifest selects the initial clip.
One-shots can use `next` to chain into a loop, or `hold: true` to keep their
final pose. Death and the aiming poses hold, while jumping, sitting, and spell
transitions lead into their respective loops.

The monster eyes and evil mouths use approved sheets under
`source/eyes/monster_v1` and `source/mouths/evil_v1`. To repeat their cuts,
run `python3 "$CHARGEN_SCRIPTS/cut_faces.py"` with Pillow and ImageMagick
installed, then rebuild. The cutter records per-part projection data in
`source/faces.json`. Corrected individual images in each sheet's `overrides`
folder replace the matching cut by filename. This includes the goblin grin
with the extra lower tooth removed.
The insect eye cell is excluded from the humanoid library. Its position in
the source sheet is retained, so the other part names keep their numbers.

```sh
PYTHONDONTWRITEBYTECODE=1 \
  /Applications/Blender.app/Contents/MacOS/Blender --background \
  --python "$CHARGEN_SCRIPTS/build_model.py"
nim check experiments/chargen/chargen.nim
nim check experiments/chargen/tests.nim
nim c -r --nimcache:tmp/chargen/nimcache_tests \
  -o:tmp/chargen/tests experiments/chargen/tests.nim
PYTHONDONTWRITEBYTECODE=1 python3 "$CHARGEN_SCRIPTS/verify_library.py"
PYTHONDONTWRITEBYTECODE=1 python3 "$CHARGEN_SCRIPTS/test_packs.py" \
  --runtime-tests tmp/chargen/tests
```

`build_model.py` regenerates the authoring Blender file, temporary assembled
GLB, and split runtime library. Use `CHARGEN_PYTHON` if Pillow is installed in a
specific Python interpreter. `export_library.py` can rerun just the split and
crop step from `tmp/chargen/character.glb`. Generated style files are replaced
when rebuilding. Additional sidecars, color palettes, category defaults, and
custom categories are retained. Each part's `alignment` tag is also retained
when its geometry is rebuilt or it is packed into a game-specific library.
Edit that field in the part's JSON sidecar to retag it. Supported tags are
`both`, `good`, `evil`, and `gnome`. Good and evil rolls exclude gnome-only
features and hats. Gnome clothing uses `good`, so it stays available to good
rolls. Unfiltered Random includes all tags.

`Random gnome` prefers gnome-tagged parts in each slot, with shared and good
parts filling the remaining slots. It always includes a nose, ears, hat,
shirt, trousers, and footwear when eligible choices exist. It uses fair skin,
hair, eye, and clothing color suggestions from the nine gnome presets.
The other random buttons use the complete skin, hair, and eye palettes.
For reproducible rolls, launch with `RANDOM_SEED=19 RANDOM_ALIGNMENT=gnome`
(or `good`, `evil`, or `both`).
Random characters have a 50% chance of facial hair, independent of how many
beard styles are available.

Run `python3 "$CHARGEN_SCRIPTS/count_polygons.py"` for per-gnome triangle,
vertex, and material primitive counts. The Markdown and JSON reports go to
`tmp/chargen/polygons`. Counts resolve preset visibility masks and include
covered surfaces that still render.

Enable `Custom skin RGB` below the skin preset to edit red, green, and blue
from 0 to 255. This affects skin meshes, including ears and nose, while eyes,
mouths, eyebrows, and hair keep their own colors. Choosing a skin preset or
randomizing restores a preset color. `SKIN_RGB=75,140,195` also sets a custom
color when launching the viewer.

The procedural build replaces manual edits to
the authoring Blender file, as before.

Renders, comparisons, build logs, and assembled intermediate exports belong in
`tmp/chargen`. The original `experiments/modular_chars` utility and its assets
remain separate.
