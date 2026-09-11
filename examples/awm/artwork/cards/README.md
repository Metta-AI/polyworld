# Card artwork

All face components remain independently editable:

- `art/`: standalone illustrations; names match lowercase card names.
- `frames/`: 600 × 850 SVG frames with transparent illustration apertures.
- `icons/`: energy, power, toughness, and arcane symbol SVG images.
- `fonts/`: bundled Grenze fonts and their SIL Open Font License.
- `previews/`: generated examples of the final composition, never gameplay data.

`cardfaces.nim` layers illustration, frame, symbols, and live card text. Rules
come from the card's rule factory; current toughness can override the printed
value and uses a warm red color when damaged. Spells have no creature stats.
The game may cache the resulting face in an atlas for efficient drawing.

Cards use a 546 × 417 illustration aperture at (27, 113); center the subject in
a landscape image. New cards without a matching illustration display the
separate `art/unknown.svg` placeholder. Names and rules shrink to their safe
areas as needed. Font files are local, so card rendering works offline.

SVG gradients live directly below the root SVG element because the bundled
Pixie SVG parser skips `defs`. Gradients on strokes are avoided for the same
renderer compatibility. SVG assets can still be edited in standard tools.

Regenerate the preview sheet from the project root:

```sh
nim c -r --out:/tmp/awm-render-cards tools/render_cards.nim
```
