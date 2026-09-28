## Runs all tests locally, or one independent suite with -d:TestSuite=name.

{.warning[UnusedImport]: off.}

const TestSuite {.strdefine.} = "all"

when TestSuite notin ["all", "core", "gota", "policies", "cta", "lvd", "heartleaf"]:
  {.error: "Unknown TestSuite.".}

when TestSuite in ["all", "core"]:
  import
    test_assetpacks,
    test_actioncam,
    test_animblend_controls,
    test_directors,
    test_bodies,
    test_body_layers,
    test_chrome,
    test_characters,
    test_cli,
    test_clickmarks,
    test_controllers

when TestSuite in ["all", "cta"]:
  import
    test_cta_maps,
    test_cta_nav,
    test_cta_sim

when TestSuite in ["all", "core"]:
  import
    test_fxmeshes,
    test_gameuis

when TestSuite in ["all", "gota"]:
  import
    test_gota_abilities,
    test_gota_andre,
    test_gota_attacks,
    test_gota_base,
    test_gota_brushes,
    test_gota_buybacks,
    test_gota_cameras,
    test_gota_camps,
    test_gota_content,
    test_gota_controls,
    test_gota_creeps,
    test_gota_decisions,
    test_gota_drafts,
    test_gota_gods,
    test_gota_host,
    test_gota_neural

when TestSuite in ["all", "core"]:
  import
    test_policy_packages

when TestSuite in ["all", "gota"]:
  import
    test_gota_landscapes,
    test_gota_lanes,
    test_gota_lighting,
    test_gota_mapgen,
    test_gota_motions,
    test_gota_mirrors,
    test_gota_movement,
    test_gota_observations

when TestSuite in ["all", "policies"]:
  import
    test_gota_policies

when TestSuite in ["all", "gota"]:
  import
    test_gota_portals,
    test_gota_potions,
    test_gota_presets,
    test_gota_progression,
    test_gota_replays,
    test_gota_rotations,
    test_gota_rusher,
    test_gota_scores,
    test_gota_sizes,
    test_gota_spells,
    test_gota_symmetry,
    test_gota_targets,
    test_gota_terrains,
    test_gota_towers,
    test_gota_walls

when TestSuite in ["all", "core"]:
  import
    test_hashes

when TestSuite in ["all", "heartleaf"]:
  import
    test_hlf_content,
    test_hlf_maps,
    test_hlf_replays,
    test_hlf_sim,
    test_hlf_scorecard

when TestSuite in ["all", "core"]:
  import
    test_hudlayouts,
    test_inputs

when TestSuite in ["all", "lvd"]:
  import
    test_lvd_content,
    test_lvd_groves,
    test_lvd_maps,
    test_lvd_replays,
    test_lvd_sim

when TestSuite in ["all", "core"]:
  import
    test_mailboxes,
    test_chats,
    test_metrics,
    test_stats,
    test_nav,
    test_noises,
    test_pathing,
    test_picking,
    test_player,
    test_profiles,
    test_props,
    test_rngs,
    test_rtscameras,
    test_tapes,
    test_terrains,
    test_terrainmaps,
    test_aigen_blends,
    test_aigen_splats,
    test_tile_paths,
    test_viewers,
    test_visions,
    test_worldtexts

echo "Tests passed: ", TestSuite
