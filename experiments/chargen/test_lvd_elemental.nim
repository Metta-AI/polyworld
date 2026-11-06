import
  std/[sets, tables],
  polyworld/chargen,
  ../../games/light_vs_dark/[assets, content, factions],
  lvd_presets

let directory = ChargenLibrary
var manifest = readManifest(directory)
manifest.addLvdPresets(directory)
let roster = readCharacterRoster()
for player, units in roster.players:
  let entry = units[SummonUnit.ord]
  let name = "LvD Elemental " & (if player == 0: "A" else: "B")
  doAssert entry.preset.name == name, "Elemental roster name"
  let preset = manifest.namedPreset(name)
  let skin = manifest.skins[preset.skin].color
  let team = roster.factions[player].skinRgb()
  for i in 0..2:
    doAssert abs(skin[i] - team[i]) < 0.00001, "Elemental team skin"
  var crown = false
  for part in preset.parts:
    if part.category == "Headgear":
      crown = part.item == "Elemental grand laurel crown"
  doAssert crown, "Elemental must wear the grand laurel crown"
  let inventory = manifest.presetManifest(preset)
  var crownNodes: HashSet[string]
  for category in inventory.categories:
    if category.key == "Headgear":
      for item in category.items:
        for node in item.nodes: crownNodes.incl node
  let nodes = partNodes(readPresetCharacter(directory, manifest, preset, []).root)
  for node in crownNodes:
    doAssert nodes.hasKey(node), "Missing crown mesh " & node
  doAssert crownNodes.len >= 10
for faction in Faction:
  let team = faction.skinRgb()
  # The game must derive skin from the actual faction, not the two baked looks.
  let entry = readCharacterRoster([faction]).players[0][SummonUnit.ord]
  for i in 0..2:
    doAssert abs(entry.skinRgb[i] - team[i]) < 0.00001,
      "Game roster must use every owning faction's color"
echo "Elemental roster, selectable crown, and faction colors verified"
