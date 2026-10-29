GotA update: casting, controls, water, and a fresh win/loss ladder

The main Gods of the Arena ladder has been reset. OpenSkill MMR now uses strictly team outcomes: every winning hero submits 1, every losing hero submits 0, and draws/timeouts submit 0 for everyone. XP, Glory, and match duration do not affect ratings. Team Draft and mixed-policy teams remain enabled; the NeuralHub at Diablo Valley College league configuration is unchanged.

Bot authors: review the ability slots and queued casting behavior, and use the updated bundled policies as examples.

- All ten heroes now use Q for their main spell, W for their secondary spell, E for their self/defensive ability, and R for their ultimate. Ability identities stay the same; the old W moves to Q, old E to W, and old Q to E.
- Heroes start 26% faster, and hero vision has increased by 20%.
- Out-of-range spell commands now let heroes walk into range and cast, for both human players and BASIC policies; heroes turn toward their cast and play their casting animation.
- Base, Rusher, and Puller policies preserve ongoing orders, and spellcasting policies avoid replacing a queued cast with a move or attack. Own-state observations include self.hasQueuedCast and self.castTicks.
- Spell targeting and queued casts show area-shaped previews at their intended destination, with smoother tracking for moving targets.
- Abilities and inventory items have larger, delayed hover tooltips showing current-rank information; double-clicking eligible consumables supports self-use, and double-clicking a portal scroll targets home.
- Movement markers are smaller and green, attack-move markers are red, and holding A keeps attack-move armed. Rapid movement orders are handled more reliably.
- Casting, teleporting, potion use, poison throws, melee swings, and projectiles have updated effects, including fixes for duplicate ultimate flashes and effects appearing at map center after a target dies.
- Hidden enemies no longer contribute visible shadows or effects; water now uses terrain-based shoreline foam, smoother shore transitions, and a refreshed turquoise palette.
- A local hero test room is available for trying every hero, spell, and consumable with short cooldowns, practice towers, creep waves, and neutral camps.

The game host and web replay player are released together. Replay gameplay version 75 is supported exactly; historical replays use their matching historical client.
