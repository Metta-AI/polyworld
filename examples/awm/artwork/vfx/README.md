# VFX assets

`textures/lightning-strike.png` is an 887 × 1774 transparent RGBA sprite generated
with the built-in image generation tool. See [PROMPTS.md](PROMPTS.md) for its
source prompt. It is independent of the Bolt card illustration.

The renderer maps the vertical strike onto a segmented camera-facing ribbon, with
terminals near the center at 5% and 95% of the texture height. Keep those anchors
and transparent margins when replacing the sprite. Midpoint displacement adds
large bends and smaller kinks, with both terminals pinned. Each cast varies its
approach, ribbon width, and discharge timing. Every 55–80 ms the path, texture
mirroring, and branch brightness change together, with a brief faint afterimage.
Mipmaps keep fine filaments smooth at board scale.

Impact particles remain procedural: 88 short trails spread at varied speeds
and elevations, while 40 small blue particles drift and fade around the target.
Each cast's visual seed changes the shower, but each particle follows a stable
trajectory throughout that cast. No game randomness is consumed. Capture builds
accept `AWM_VFX_SEED` to reproduce a variation. The bubble, hover halo, target halo, and damage
flash remain procedural as well.

`previews/lightning-randomized.mp4` shows three different casts.
`previews/lightning.png` captures one of their discharges.
`previews/lightning-textured.mp4` preserves the earlier fixed silhouette for comparison.
