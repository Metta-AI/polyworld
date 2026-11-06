import
  std/sets,
  polyworld/chargen,
  ../../games/light_vs_dark/[assets, content, factions],
  lvd_presets

let
  roster = readCharacterRoster()
  directory = ChargenLibrary
var manifest = readManifest(directory)
let originalCount = manifest.presets.len
manifest.addLvdPresets(directory)
doAssert manifest.presets.len == originalCount + 16,
  "Every LvD faction/role preset must appear in the viewer"
var names: HashSet[string]
for player, units in roster.players:
  for kind in UnitKind:
    let entry = units[kind.ord]
    var found = false
    for preset in manifest.presets:
      if preset.name != entry.preset.name:
        continue
      doAssert not found and preset.name notin names
      found = true
      names.incl preset.name
      doAssert preset.group == "LvD"
      var expected = entry.preset
      doAssert preset.parts == expected.parts
      doAssert preset.hairColor == entry.preset.hairColor
      doAssert preset.pupilColor == entry.preset.pupilColor
      doAssert preset.hatColor == entry.preset.hatColor
      doAssert preset.pose == entry.preset.pose
      let skin = manifest.skins[preset.skin].color
      for channel in 0 .. 2:
        doAssert abs(skin[channel] - entry.skinRgb[channel]) < 0.00001
      var selection: seq[int]
      manifest.applyPreset(selection, preset)
      discard manifest.presetManifest(preset)
    doAssert found, entry.preset.name
# All referenced parts must exist in the full viewer model and be selectable.
let model = readCharacter(directory, manifest)
let nodes = partNodes(model.root)
for preset in manifest.presets[originalCount .. ^1]:
  var selection: seq[int]
  manifest.applyPreset(selection, preset)
  nodes.applySelection(manifest, selection)
  nodes.applySkin(manifest, preset.skin)
  doAssert model.root.animations.len > 0
# Repeated integration must not duplicate the roster.
manifest.addLvdPresets(directory)
doAssert manifest.presets.len == originalCount + 16
echo "LvD viewer presets: 16 roster appearances verified"
