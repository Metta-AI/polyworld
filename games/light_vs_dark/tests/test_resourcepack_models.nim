import
  std/[os, sets, tables],
  gltf, vmath,
  polyworld/[assets, characters, chargen],
  ../[appearances, assets, backpacks, content, factions, resourcepacks]

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([PeterRiver, Emerald])
  packaged = generatedCharacterAssets()
var cache: UnitModelCache
for player in 0 .. 1:
  let
    entry = roster.players[player][PeonUnit.ord]
    ordinary = cache.loadUnitModel(manifest, entry, PeonUnit)
  for pack in WoodPack .. GoldPack:
    let
      model = cache.loadBackpackModel(manifest, entry, pack)
      nodes = partNodes(model.file.root)
      name = if pack == WoodPack: "ResourcePack_wood" else: "ResourcePack_gold"
    doAssert name in nodes and nodes[name].visible
    doAssert model != ordinary
    doAssert model == cache.loadBackpackModel(
      manifest, entry, pack
    )
    doAssert model.baseTransform == ordinary.baseTransform
    doAssert model.mergedMeshes.len == 1
    doAssert model.mergedMeshes[0].mesh.primitives.len == 1
    var joints: HashSet[pointer]
    for node in model.file.root.walkNodes:
      joints.incl cast[pointer](node)
    for joint in model.mergedMeshes[0].skin.joints:
      doAssert cast[pointer](joint) in joints
    for primitive in nodes[name].mesh.primitives:
      doAssert primitive.points.len > 0
      for weights in primitive.jointWeights:
        doAssert abs(weights.x + weights.y + weights.z + weights.w - 1) < 0.001
    for clipName in CharacterClips:
      doAssert model.clipDuration(model.clipIndex(clipName)) > 0
    let inventory = manifest.presetManifest(resourcePackPreset(entry.preset, pack))
    for category in inventory.categories:
      if category.key == "Back":
        for item in category.items:
          for file in item.files:
            var found = false
            for asset in packaged:
              if asset.kind == ModelAsset and
                asset.source == "characters/chargen" / file:
                  found = true
            doAssert found, "Backpack missing from browser pack: " & file
    for part in entry.preset.parts:
      if part.category == "Back":
        doAssert part.item == "None"
echo "Backpacks merge, share cached geometry, preserve outfits and ship to WASM"
