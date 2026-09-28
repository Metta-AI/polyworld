## Runs event-enabled variants together so the simulation compiles once.

when not defined(replayEvents):
  {.error: "These tests require -d:replayEvents.".}

{.warning[UnusedImport]: off.}
import
  test_gota_events,
  test_gota_phases,
  test_gota_controls,
  test_gota_camps,
  test_gota_portals,
  test_gota_potions,
  test_gota_progression,
  test_gota_drafts

echo "GOTA replay event tests passed"
