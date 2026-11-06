## Death HUD state and formatting use simulation ticks, never wall time.
import std/strutils
import content, sim

proc respawnCountdown*(ticks: int32): string =
  ## Round upward so a positive remainder never appears as zero seconds.
  let seconds = (max(0'i64, ticks.int64) + TickRate - 1) div TickRate
  $(seconds div 60) & ":" & align($(seconds mod 60), 2, '0')

proc deathHudText*(world: World, playerSlot: int32, replayMode: bool,
    spectator = false): string =
  ## playerSlot is the local one-based packed hero index, never selection.
  if world == nil or world.phase == Drafting or replayMode or spectator or
      playerSlot <= 0 or playerSlot > world.heroes.len:
    return ""
  let hero = world.heroes[playerSlot - 1]
  if hero == nil or hero.state != Dying:
    return ""
  "DEAD " & respawnCountdown(hero.respawnTicks())
