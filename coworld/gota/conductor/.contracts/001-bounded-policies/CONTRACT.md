---
title: Bounded embedded policies
description: Run GOTA policies in the native game with fixed formats, budgets and public outputs.
---

# Bounded embedded policies

## Rules

- Accept ten BASIC source policies with the declared seat order and byte limit. Do not execute uploaded native code.
- Keep per-tick decisions inside the game. Disable external model and oracle calls for this runtime.
- Use the existing engine and BASIC VM. Configuration cannot supply executable commands or image references.
- Enforce the engine tick limit, host wall-clock budget and outer attempt deadline. Stop the process group on failure.
- Publish scores and the compressed public replay only after the engine stops and output validation succeeds.
- Missing results, compilation failures and execution timeouts fail the attempt. Wait for the atomic result marker
  and terminate the remaining server before publishing outputs.
- Keep source programs, private logs and credentials out of the replay and result envelope.
- Build game and runner independently. Pin both images by digest for hosted qualification.

## Checks

Run this directory's `check.py` against the composed runner image. It exercises ten actual policies, a complete native
game, scores and compressed replay integrity. Inspect failure cleanup and qualify hosted resource isolation separately.
