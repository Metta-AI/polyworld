## Gods of the Arena executable entry point.

when defined(headless):
  import game
  initializeOptions()
  initializeMatch()
  runHeadless()
  when defined(coworld):
    import polyworld/coworld
    import sim
    finishCoworld(CoworldResults(
      scores: run.world.scores(),
      ticks: run.world.tick,
      seed: options.seed,
      outcome: run.world.outcome()
    ), run.world.totalXp())
else:
  import windy, polyworld/menus, game, graphics, frontend
  initializeOptions()
  var preferences = readPreferences("Polyworld GotA")
  if playerNameOverride.len > 0:
    preferences.name = playerNameOverride
    preferences.savePreferences("Polyworld GotA")
  localPlayerName = preferences.name
  if options.botGroups.len > 0 or options.replayPath.len > 0:
    initializeMatch()
    runGraphics()
  if window == nil or not window.closeRequested:
    runFrontend()
