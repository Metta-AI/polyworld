# LvD and CtA art audit

CtA character replacement completed after this inventory on 2026-09-22:
the four heroes, their portraits, all monster models and the footman loot
placeholder have been replaced. Native CtA no longer loads unused trees,
rocks, grass or water assets. The seven CartoonTerrain ground materials
remain the next CtA replacement. The table below records the original audit;
see [the integration record](cta-chargen.md) for the current character setup.

Audit date: 2026-09-22. Scope: the current `examples/light_vs_dark` and
`examples/call_to_adventure` games, their native renderers, browser asset
declarations, and dependencies in the sibling `polyworld_data` repository.
GotA's existing audit and unrelated games, experiments, and old worktrees are
outside this inventory.

Code revision: `95d18dae8840bcc8d5476a156c809b92b9b11186`.
Data revision: `5e911e4f45a55ab6d50cfc60cd265a3554be45c0`.

For this first pass, “free to use” means that commercial use, modification,
and redistribution of development assets are allowed, with attribution and
license notices where required. CC0, CC BY 4.0, MIT, and OFL qualify under
that working policy. Noncommercial and Unity Asset Store content are replacement
targets. This is a cleanup policy, not a finding that every existing use is
unauthorized. A zero purchase price does not establish an open asset license.
The [Unity EULA](https://unity.com/legal/as-terms),
[CC BY terms](https://creativecommons.org/licenses/by/4.0/),
[CC BY-NC-SA terms](https://creativecommons.org/licenses/by-nc-sa/4.0/), and
[OFL](https://openfontlicense.org/) were consulted for these distinctions.

Counts below describe selected art, not every asset in a source pack. Unless
marked otherwise, the assets are loaded by both native and browser clients.
Paths in code formatting are relative to `polyworld_data`.

| Order | Game | Art currently used | License and evidence | Recommended action |
| --- | --- | --- | --- | --- |
| 1 | LvD | Tower Defense Kit: 15 selected props and 8 distinct portraits. Dark buildings, both factions' gold mines, construction props, and rubble. `terrain/tower_defense_kit.glb` and selected `tower_defense_kit.*.profile.png`. | CC BY-NC-SA 4.0, recorded in the [terrain notice](../../polyworld_data/terrain/license.md). | Replace the entire selected family first. Its noncommercial condition fails the working policy. Use generated buildings and resource props, then render new portraits. Replacing only the dark buildings leaves mines and temporary construction/rubble assets behind. |
| 2 | CtA | Four hero appearances: Fighter, Wizard, Rogue, Cleric. `characters/modular_chars/character.glb`, presets 5, 18, 11, 9, and four matching portraits. Includes imported mesh, rig, palette, and animations. | Unity Asset Store: Hero Core Vol.3 plus Tiny Hero Duo animations. [Combined provenance](../../polyworld_data/characters/modular_chars/license.md). | Replace meshes, materials, rig/animation dependencies, and portraits together. Reuse GotA's cleared generated character selections and Quaternius clips where suitable. Do not retain the old animations inside a replacement GLB. |
| 3 | LvD | 15 unit models from `characters/mini_legion/`, their 15 portraits, four external faction albedo textures, and embedded animations. | Unity Asset Store: RTS Mini Legions Fantasy HP. [Notice](../../polyworld_data/characters/mini_legion/license.md). | Replace all 15 unit appearances. Existing generated humanoids can cover several roles; workers, mounts, siege engines, and golems need role-specific work. Preserve readable faction differences and regenerate portraits. |
| 3 | LvD | Dark summon: `characters/rpg_monsters/demon_king.glb`, its portrait, `monsters_albedo.png`, and animations. | Unity Asset Store: RPG Monster BUNDLE PBR. [Notice](../../polyworld_data/characters/rpg_monsters/license.md). | Replace with a generated demon or another cleared summon. This is separate from the Mini Legions pack and must not be missed in that migration. |
| 4 | CtA | Four monster GLBs: `characters/orc.glb`, `footman.glb`, `lich.glb`, `rock_golem.glb`, including embedded materials and animation. The footman also renders every floor-loot pickup. | Unity Asset Store: individual Mini Legion products. [Notice and product IDs](../../polyworld_data/characters/license.md). | Replace all four. Give loot its own generated or procedural visuals, or ensure its shared replacement is cleared too. |
| 5 | CtA | Cartoon ground: seven browser materials, eight native materials. `terrain/cartoon_textures/`, including derived height maps. Browser copies are packed into KTX2. | Unity Asset Store: two free-download texture packs. [Notice](../../polyworld_data/terrain/cartoon_textures/license.md). | Replace with generated or CC0 color/height pairs. Existing generated terrain is a starting point, but CtA still needs dungeon-specific sand, cliff, stone, and volcanic coverage. |
| 6 | LvD; CtA native only | Handpainted trees. LvD selects two fir GLBs and `fir.png`. Native CtA loads five tree GLBs and 13 texture PNGs through default terrain initialization. | Unity Asset Store: Handpainted Forest MasterPACK. [Notice](../../polyworld_data/terrain/handpainted_trees/license.md). | Use the generated trees already used by GotA for LvD. Remove CtA's unused native tree loading by making its terrain settings explicit, matching its browser configuration. |
| 7 | LvD | Two painted rocks: `rock_large_02a`, `rock_medium_01a` from `terrain/toon_enchanted_meadow/rocks.glb`, with `terrain_stone_02d.png`. | Unity Asset Store: Toon Enchanted Meadow. [Notice](../../polyworld_data/terrain/toon_enchanted_meadow/license.md). | Replace with the existing generated rock renderer and its cleared trim texture. |
| Keep, add credits | LvD | Nine selected village buildings and nine portraits from `terrain/low_poly_village.glb`. Includes the dark faction's farm. | CC BY 4.0, jeebs. [Provenance and source link](../../polyworld_data/terrain/license.md). | Keep with creator/title/source/license attribution and a description of repacking/rendering changes. Replace only if the policy becomes CC0-only. |
| Keep, add credits | LvD; CtA native only | `terrain/low_poly_grass.glb`. | CC BY 4.0, Anskar. [Provenance](../../polyworld_data/terrain/license.md); [existing GotA attribution](../../polyworld_data/licenses/gota.md). | Keep and credit in LvD. Remove the unused native CtA load when aligning its terrain settings. |
| Remove unused load | CtA native only | `terrain/low_poly_rocks.glb`. | CC BY 4.0, Dreyx, with a recorded Sketchfab NoAI tag. [Notice](../../polyworld_data/terrain/license.md). | Native CtA initializes this pack but does not draw scattered rocks. Remove that load. If reused elsewhere, preserve attribution and review the recorded NoAI condition for that use. |
| Keep, preserve notice | LvD; CtA native only | `terrain/water_normals/water_1_normal.jpg` and `water_2_normal.jpg`. | MIT, Three.js authors. [Full notice](../../polyworld_data/terrain/water_normals/license.md). | Keep with the MIT notice in LvD. CtA's browser configuration already omits water assets; align native loading. |
| Keep | LvD | Generated ground: nine surface names, each with tile/stamp color and height maps, totaling 36 PNGs in `terrain/tiles/` and `terrain/stamps/`. | Owner-confirmed project-generated assets under the [root CC0 dedication](../../polyworld_data/LICENSE). | Keep. These are already separate from the Unity cartoon ground textures used by CtA. |
| Keep | Both | Shared HUD images: all 178 `icons/*.png`, 56 `themes/main/*.png`, and `ui/hero_portrait.png`. Each game also loads its own `themes/lvd/lvd_logo.png` or `themes/cta/cta_logo.png`. | Project artwork covered by the [root CC0 dedication](../../polyworld_data/LICENSE); no asset-specific exception found for these selected images. | Keep. Both atlas builders load whole PNG directories, including images that may not appear on a particular screen. |
| Keep | CtA | All 33 PNGs named by `AbilityIconFiles` in `abilities/`. | Project artwork under the [root CC0 dedication](../../polyworld_data/LICENSE). | Keep. The separate `items/` and effect-image libraries are not declared by this game. |
| Keep, preserve notices | Both | `fonts/Rubik-Regular.ttf`, `Rubik-Bold.ttf`, `OverpassMono-Regular.ttf`. | SIL OFL 1.1. [Font provenance](../../polyworld_data/fonts/license.md). | Keep and package the two applicable OFL notices. The IBM Plex font next to the theme PNGs is not loaded by these atlas builders. |
| Keep | Both | Code-generated particles, selection outlines, bars, click marks, and basic HUD shapes. | Project source code under [MIT](../LICENSE). No additional external image/model inputs found in these effect paths. | No art replacement identified. This row does not include CtA's model-based loot visuals, covered above. |

Orders 2 through 7 all need replacement or removal under this policy. Their
relative order reflects character visibility and breadth of use. The generated
tree/rock substitutions and removal of unused native CtA loads are smaller
tasks that can be completed earlier if quick reductions are preferred.

**Exact character selection.** LvD's paths below are inside
`characters/mini_legion/`, except the dark summon.

| Role | Light | Dark |
| --- | --- | --- |
| Worker | `human/worker.glb` | `warband/minion.glb` |
| Soldier | `human/footman.glb` | `warband/grunt.glb` |
| Archer | `human/archer.glb` | `warband/head_hunter.glb` |
| Mage | `human/mage.glb` | `warband/warlock.glb` |
| Knight | `human/horseman.glb` | `warband/hog_rider.glb` |
| Catapult | `human/siege_engine.glb` | `undead/siege_engine.glb` |
| Cleric | `sentinel/druid.glb` | `undead/lich.glb` |
| Summon | `sentinel/rock_golem.glb` | `characters/rpg_monsters/demon_king.glb` from the data root |

Every LvD unit also uses its adjacent `.profile.png`. CtA maps Fighter to
Preset 5, Wizard to Preset 18, Rogue to Preset 11, and Cleric to Preset 9.
Its species map Orc to `orc.glb`, Skeleton to `footman.glb`, Lich to `lich.glb`,
and Golem to `rock_golem.glb`. The two games therefore require replacement
of 24 character appearances, represented by 21 source character GLBs and
20 selected character portraits. This excludes building portraits.

**Exact prop and terrain selection.** The noncommercial kit contributes
`mineral1`, `mineral3`, `rock2`, `box1`, `barel1`, `wall1`, `rock1`, `stump1`,
`building1`, `building3`, `building2`, `tower_square_tall1`, `tower_tall1`,
`tower_square_tall2`, and `tower_square_small1`. Its eight selected portraits
are the seven building entries plus `mineral1`.

The keepable village pack contributes `house_lvl7`, `farm_lvl4`,
`farm_house_lvl5`, `farm_house_lvl3`, `tower_lvl5`, `farm_house_lvl6`,
`house_lvl4`, `farm_house_lvl2`, and `farm_lvl2`, each with a portrait.

CtA uses `grass`, `sand`, `cliff`, `marsh`, `stone`, `dirt`, and `volcanic`
color/height pairs. Native initialization additionally loads `underwater`.
Grass and marsh originate in Handpainted Grass & Ground Textures Free.
The other six materials originate in FREE Stylized PBR Textures Pack.

**Packaging work needed alongside replacement.** Neither game's current
`browserAssets()` declares license notices. The existing local browser stages,
last built on 2026-09-21, likewise contain no license/attribution text files.
Add per-game credits, the applicable OFL and MIT notices, and the root CC0
license to the final retained asset sets. LvD needs village and grass
attributions. Replacing the restricted assets alone does not fix this omission.

**Reuse boundary.** GotA already selects generated character parts, portraits,
forts, tree textures, and rock textures, plus CC0 Quaternius animation clips.
Reuse those specific cleared selections. Do not copy the entire
`characters/chargen/` tree: its [exception notice](../../polyworld_data/characters/chargen/license.md)
still identifies legacy Unity animations, imported eyes, unresolved eyes,
and mixed Blender source files. Its default license does not clear these
exceptions. New mounts, siege engines, monster shapes, and building silhouettes
still need fit and visual review.

**Evidence and limits.** Current declarations were evaluated using a temporary
Nim inventory helper, after `nim check` passed. PNG directories were expanded
and external image/buffer URIs in selected source GLBs were inspected. This
identified 339 unique source inputs for the LvD browser declaration, 296 for
CtA, and 38 for CtA's native terrain initialization. All those files exist.
These are source-input counts, not packed-file counts or visible-object counts.
The native-only loads were verified in the renderer, not inferred from browser
manifests. No game builds or fresh browser bundles were produced for this audit.

Primary code evidence:

- [LvD declarations](../examples/light_vs_dark/assets.nim) and
  [renderer](../examples/light_vs_dark/graphics.nim).
- [CtA declarations](../examples/call_to_adventure/assets.nim),
  [content mappings](../examples/call_to_adventure/content.nim), and
  [renderer](../examples/call_to_adventure/graphics.nim).
- [Shared asset declarations](../src/polyworld/assets.nim),
  [terrain initialization](../src/polyworld/quadterrain.nim), and
  [HUD loading](../src/polyworld/viewers.nim).
- [GotA's current cleared selection](../examples/gods_of_the_arena/assets.nim)
  and [license record](../../polyworld_data/licenses/gota.md).

Asset identities and source-license mappings come from the checked-in
provenance notices, primarily verified on 2026-08-25. The live Unity EULA and
Hero Core product page still identify the standard EULA. The older local
Hero Core notice additionally records a Unity-only publisher statement, which
was not independently reproduced in the current page text and is not needed
for its replacement classification here. Sketchfab source pages could not be
rechecked because web access failed or returned 403, so their recorded asset
licenses are not presented as newly verified publisher statements.

This audit changes no game assets, loading behavior, or licenses. It does not
clear the entire shared data repository or remove assets from Git history.
