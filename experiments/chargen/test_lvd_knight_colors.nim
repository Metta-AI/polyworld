import
  std/tables,
  chroma,
  polyworld/chargen,
  polyworld/chargen/teamcolors,
  ../../games/light_vs_dark/factions,
  lvd_presets

let directory = ChargenLibrary
var manifest = readManifest(directory)
manifest.addLvdPresets(directory)
for (name, faction) in [("LvD Armored knight A", PeterRiver),
                        ("LvD Armored knight B", Amethyst)]:
  let preset = manifest.namedPreset(name)
  let nodes = partNodes(readPresetCharacter(directory, manifest, preset, []).root)
  let rgb = faction.skinRgb()
  let expected = color(rgb[0], rgb[1], rgb[2], 1)
  for (node, primitive, shade) in [
    ("Gota_vanguard_knight_BluePlume31", 0, 1'f),
    ("Gota_vanguard_knight_Cape26", 0, 1'f),
    ("Gota_vanguard_knight_Cape26", 1, 0.8'f),
    ("GotaWeapon_vanguard_knight_left_hand", 1, 1'f)
  ]:
    let actual = nodes[node].mesh.primitives[primitive].material.baseColorFactor
    doAssert abs(actual.r - expected.r * shade) < 0.00001 and
      abs(actual.g - expected.g * shade) < 0.00001 and
      abs(actual.b - expected.b * shade) < 0.00001,
      name & ": wrong faction color on " & node
  let gold = nodes["GotaWeapon_vanguard_knight_left_hand"].mesh.primitives[0].material.baseColorFactor
  doAssert abs(gold.r - 220'f / 255) < 0.00001
  doAssert abs(gold.g - 166'f / 255) < 0.00001
  doAssert abs(gold.b - 66'f / 255) < 0.00001
  let ivory = nodes["Gota_vanguard_knight_HelmetShell"].mesh.primitives[0].material.baseColorFactor
  doAssert abs(ivory.r - 238'f / 255) < 0.00001
  doAssert abs(ivory.g - 231'f / 255) < 0.00001
  doAssert abs(ivory.b - 212'f / 255) < 0.00001

# Non-LvD presets retain the original blue; all factions can override it.
let original = manifest.namedPreset("Vanguard Knight")
let defaultNodes = partNodes(readPresetCharacter(directory, manifest, original, []).root)
let originalPlume = defaultNodes["Gota_vanguard_knight_BluePlume31"].mesh.primitives[0].material.baseColorFactor
doAssert abs(originalPlume.r - 22'f / 255) < 0.00001
doAssert abs(originalPlume.g - 75'f / 255) < 0.00001
doAssert abs(originalPlume.b - 204'f / 255) < 0.00001
for faction in Faction:
  var preset = original
  let rgb = faction.skinRgb()
  preset.tintVanguardTeam(rgb)
  let nodes = partNodes(readPresetCharacter(directory, manifest, preset, []).root)
  for (name, index, shade) in [
    ("Gota_vanguard_knight_BluePlume31", 0, 1'f),
    ("Gota_vanguard_knight_Cape26", 0, 1'f),
    ("Gota_vanguard_knight_Cape26", 1, 0.8'f),
    ("GotaWeapon_vanguard_knight_left_hand", 1, 1'f)
  ]:
    let actual = nodes[name].mesh.primitives[index].material.baseColorFactor
    doAssert abs(actual.r - rgb[0] * shade) < 0.00001
    doAssert abs(actual.g - rgb[1] * shade) < 0.00001
    doAssert abs(actual.b - rgb[2] * shade) < 0.00001
echo "LvD knight team color: blue/purple cape, plume and shield verified"
