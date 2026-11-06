## The faction must color only the armored knight's blue team surfaces.
import
  std/tables,
  chroma,
  polyworld/[characters, chargen],
  ../[appearances, assets, content, factions]

proc closeColor(actual: Color, expected: array[3, float32], shade = 1'f): bool =
  abs(actual.r - expected[0] * shade) < 0.00001 and
    abs(actual.g - expected[1] * shade) < 0.00001 and
    abs(actual.b - expected[2] * shade) < 0.00001

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([Amethyst, Emerald, Alizarin, PeterRiver,
    Carrot, WetAsphalt, Turquoise, SunFlower])
var cache: UnitModelCache
for player, faction in roster.factions:
  let
    entry = roster.players[player][KnightUnit.ord]
    actual = cache.loadUnitModel(manifest, entry, KnightUnit)
    fresh = loadUnitModel(manifest, entry, KnightUnit)
    nodes = partNodes(actual.file.root)
    tint = faction.skinRgb()
  for (name, primitive, shade) in [
    ("Gota_vanguard_knight_BluePlume31", 0, 1'f),
    ("Gota_vanguard_knight_Cape26", 0, 1'f),
    ("Gota_vanguard_knight_Cape26", 1, 0.8'f),
    ("GotaWeapon_vanguard_knight_left_hand", 1, 1'f)
  ]:
    doAssert closeColor(nodes[name].mesh.primitives[primitive].material.baseColorFactor, tint, shade),
      $faction & " " & name & " primitive " & $primitive
  # Ivory armor and gold shield trim retain their authored appearance.
  doAssert closeColor(nodes["Gota_vanguard_knight_HelmetShell"].mesh.primitives[0].material.baseColorFactor,
    [0.933333337'f, 0.90588236'f, 0.83137256'f])
  doAssert closeColor(nodes["GotaWeapon_vanguard_knight_left_hand"].mesh.primitives[0].material.baseColorFactor,
    [0.8627451'f, 0.6509804'f, 0.25882354'f])
  doAssert actual.mergedMeshes.len == 1 and fresh.mergedMeshes.len == 1
  for i, primitive in actual.mergedMeshes[0].mesh.primitives:
    doAssert primitive.colors == fresh.mergedMeshes[0].mesh.primitives[i].colors
  echo faction, " knight team colors passed"
