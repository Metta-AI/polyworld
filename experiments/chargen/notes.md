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
custom categories are retained. The procedural build replaces manual edits to
the authoring Blender file, as before.

Renders, comparisons, build logs, and assembled intermediate exports belong in
`tmp/chargen`. The original `experiments/modular_chars` utility and its assets
remain separate.
