import
  std/os,
  jsony,
  polyworld/chargen,
  ../../games/light_vs_dark/[assets, content, factions]

proc addLvdPresets*(manifest: var Manifest, directory: string) =
  ## Exposes the real game roster and faction skin colors in the editor.
  let path = directory / "lvd.json"
  if not fileExists(path):
    return # Other CHARGEN_LIBRARY inventories need not contain an LvD roster.
  var roster: CharacterRoster
  try:
    roster = readFile(path).fromJson(CharacterRoster)
  except IOError, JsonError, ValueError:
    raise newException(ChargenError, "Cannot read LvD roster: " &
      getCurrentExceptionMsg())
  if roster.players.len != 2 or roster.factions.len != roster.players.len:
    raise newException(ChargenError, "LvD roster needs two player looks.")
  for player, units in roster.players:
    if units.len != UnitKind.high.ord + 1:
      raise newException(ChargenError, "LvD roster needs all eight roles.")
    for kind in UnitKind:
      let entry = units[kind.ord]
      if entry.kind != $kind:
        raise newException(ChargenError, "LvD roster is missing " & $kind)
      var preset = entry.preset
      var exists = false
      for existing in manifest.presets:
        if existing.name == preset.name:
          if existing.group != "LvD":
            raise newException(ChargenError, "Duplicate preset: " & preset.name)
          exists = true
      if exists:
        continue
      let rgb = roster.factions[player].skinRgb()
      for channel in rgb:
        if not (channel >= 0 and channel <= 1):
          raise newException(ChargenError, "Invalid LvD skin color.")
      let tint = [rgb[0], rgb[1], rgb[2], 1'f]
      var skin = -1
      for i, candidate in manifest.skins:
        if candidate.color == tint:
          skin = i
          break
      if skin < 0:
        skin = manifest.skins.len
        let name = "LvD " & $roster.factions[player]
        manifest.skins.add Skin(name: name, color: tint)
      preset.skin = skin
      preset.group = "LvD"
      # Fail early if an authored part or color no longer exists.
      discard manifest.presetManifest(preset)
      discard manifest.hairColors.colorIndex(preset.hairColor)
      discard manifest.pupilColors.colorIndex(preset.pupilColor)
      discard manifest.hatColors.colorIndex(preset.hatColor)
      manifest.presets.add preset
