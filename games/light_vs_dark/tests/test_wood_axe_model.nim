## Tests the real LvD cached woodcutting model and its faction variants.
import
  std/tables,
  gltf,
  polyworld/[characters, chargen],
  ../[appearances, assets, content, factions]

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([Emerald, WetAsphalt])
  entry = roster.players[0][PeonUnit.ord]
var cache: UnitModelCache

when compiles(cache.loadUnitModel(manifest, entry, PeonUnit, woodAxe = true)):
  let
    normal = cache.loadUnitModel(manifest, entry, PeonUnit)
    axe = cache.loadUnitModel(manifest, entry, PeonUnit, woodAxe = true)
    normalNodes = partNodes(normal.file.root)
    axeNodes = partNodes(axe.file.root)
    axeName = "GotaWeapon_berserker_right_hand"
    inventory = manifest.presetManifest(entry.preset)
  doAssert axe != normal
  doAssert axeName notin normalNodes
  doAssert axeName in axeNodes and axeNodes[axeName].visible
  doAssert axe.mergedMeshes.len == 1
  doAssert axe.clipDuration(axe.clipIndex("Sword_Attack")) > 0
  doAssert cache.loadUnitModel(manifest, entry, PeonUnit, woodAxe = true) == axe
  doAssert cache.loadUnitModel(manifest, entry, PeonUnit) == normal
  for name in inventory.skinNodes:
    let tint = axeNodes[name].mesh.primitives[0].material.baseColorFactor
    doAssert tint.r == entry.skinRgb[0]
    doAssert tint.g == entry.skinRgb[1]
    doAssert tint.b == entry.skinRgb[2]
  var other = entry
  other.skinRgb = roster.players[1][PeonUnit.ord].skinRgb
  let
    tinted = cache.loadUnitModel(manifest, other, PeonUnit, woodAxe = true)
    tintedNodes = partNodes(tinted.file.root)
    fresh = block:
      var independent: UnitModelCache
      independent.loadUnitModel(manifest, other, PeonUnit, woodAxe = true)
  doAssert tinted != axe
  doAssert tintedNodes[axeName].visible
  for name in inventory.skinNodes:
    let tint = tintedNodes[name].mesh.primitives[0].material.baseColorFactor
    doAssert tint.r == other.skinRgb[0]
    doAssert tint.g == other.skinRgb[1]
    doAssert tint.b == other.skinRgb[2]
  for i, primitive in tinted.mergedMeshes[0].mesh.primitives:
    doAssert primitive.colors == fresh.mergedMeshes[0].mesh.primitives[i].colors
  doAssert cache.loadUnitModel(manifest, other, PeonUnit, woodAxe = true) == tinted
  echo "Cached woodcutting model, axe, factions and merged colors passed."
else:
  doAssert false, "UnitModelCache lacks the woodAxe variant"
