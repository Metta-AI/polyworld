## Game-specific art and startup routing over the shared home screen.
proc opensMultiplayer*(room: string): bool =
  ## A server URL configures a future connection; only invites bypass home.
  room.len > 0

when not defined(headless):
  import silky, polyworld/menus, polyworld/homes as sharedHomes, assets
  export sharedHomes

  proc effectivePreferences*(stored: Preferences, queryServer,
    configuredServer: string): Preferences =
    ## Resolves preferences loaded at startup or after returning from a match.
    result = stored
    if queryServer.len > 0:
      result.server = queryServer
    elif configuredServer.len > 0 and configuredServer != Preferences().server:
      # The backend's default is not an explicit frontend override.
      result.server = configuredServer

  proc addHomeAssets*(builder: AtlasBuilder) =
    sharedHomes.addHomeAssets(builder, assets.MenuRoot, assets.MenuImages)
