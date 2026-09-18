# Chargen assets

Run the utility from the Polyworld repository:

```sh
nim r experiments/chargen/chargen.nim
```

The default library is `../polyworld_data/characters/chargen`. Set
`CHARGEN_LIBRARY` to open another library or a game-specific export.

## Folder layout

| Folder | Contents |
| --- | --- |
| `body` | Body, hands, and feet as separate GLBs, grouped by a part sidecar |
| `heads`, `noses`, `ears` | Independently selectable head and facial geometry |
| `hair`, `beards` | One GLB and JSON sidecar per style |
| `eyes` | One PNG, iris mask, GLB surface, and JSON sidecar per generated pair |
| `mouths`, `eyebrows` | One PNG, GLB surface, and JSON sidecar per generated style |
| `colors` | Editable skin, hair, and eye preset lists |
| `clothing/torsos`, `clothing/backs`, `clothing/gloves` | Future clothing parts |
| `clothing/pants`, `clothing/boots`, `hats` | Future clothing parts |
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

Put texture references in the glTF material as well as the sidecar. Face
materials use an unlit alpha cutout. New face GLBs use UVs within their own PNG;
the packer remaps these when building an atlas. New categories can be registered
by adding a `key`, `directory`, and optional `defaultItem` to the root manifest.
Restart the utility after adding files.

## Shipping selected parts

The Python tools require Pillow. List stable part IDs and available clips:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 experiments/chargen/pack.py --list
```

For example, export two eye options and only the walking and idle animations:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 experiments/chargen/pack.py \
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
with `--python experiments/chargen/import_animations.py`. Set
`CHARGEN_PYTHON=/opt/homebrew/bin/python3` when that interpreter has Pillow.
Run Blender with `--python experiments/chargen/verify_universal.py` to check
all exported bone rotations, hip movement, and limb lengths against the source.
Full model builds also include the Universal library.

`defaultAnimation` in the library manifest selects the initial clip.
One-shots can use `next` to chain into a loop, or `hold: true` to keep their
final pose. Death and the aiming poses hold, while jumping, sitting, and spell
transitions lead into their respective loops.

The monster eyes and evil mouths use approved sheets under
`source/eyes/monster_v1` and `source/mouths/evil_v1`. To repeat their cuts,
run `python3 experiments/chargen/cut_faces.py` with Pillow and ImageMagick
installed, then rebuild. The cutter records per-part projection data in
`source/faces.json`. Corrected individual images in each sheet's `overrides`
folder replace the matching cut by filename. This includes the goblin grin
with the extra lower tooth removed.
The insect eye cell is excluded from the humanoid library. Its position in
the source sheet is retained, so the other part names keep their numbers.

```sh
PYTHONDONTWRITEBYTECODE=1 \
  /Applications/Blender.app/Contents/MacOS/Blender --background \
  --python experiments/chargen/build_model.py
nim check experiments/chargen/chargen.nim
nim check experiments/chargen/tests.nim
nim c -r --nimcache:tmp/chargen/nimcache_tests \
  -o:tmp/chargen/tests experiments/chargen/tests.nim
PYTHONDONTWRITEBYTECODE=1 python3 experiments/chargen/verify_library.py
PYTHONDONTWRITEBYTECODE=1 python3 experiments/chargen/test_packs.py \
  --runtime-tests tmp/chargen/tests
```

`build_model.py` regenerates the authoring Blender file, temporary assembled
GLB, and split runtime library. Use `CHARGEN_PYTHON` if Pillow is installed in a
specific Python interpreter. `export_library.py` can rerun just the split and
crop step from `tmp/chargen/character.glb`. Generated style files are replaced
when rebuilding. Additional sidecars, color palettes, category defaults, and
custom categories are retained. Each part's `alignment` tag is also retained
when its geometry is rebuilt or it is packed into a game-specific library.
Edit that field in the part's JSON sidecar to retag it. Skin, hair, and eye
color presets remain shared by both random buttons. For reproducible rolls,
launch with `RANDOM_SEED=19 RANDOM_ALIGNMENT=good` (or `evil` or `both`).
Random characters have a 50% chance of facial hair, independent of how many
beard styles are available.

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
