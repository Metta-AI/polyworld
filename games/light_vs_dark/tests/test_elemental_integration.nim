## Game-visible Elemental naming and faction-colored character integration.
import
  std/[os, tables],
  chroma, gltf,
  polyworld/[assets, characters, chargen],
  ../[appearances, assets, content, factions, shortcuts, tooltips]

doAssert UnitNames[SummonUnit] == "Elemental"
doAssert unitDetails(SummonUnit).title == "Elemental"
doAssert ShortcutLabels[TrainSummonShortcut] == "Train Elemental"
echo "Elemental names passed"

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster([PeterRiver, Amethyst, Alizarin, Emerald,
    Carrot, WetAsphalt, Turquoise, SunFlower])
var cache: UnitModelCache
for player, faction in roster.factions:
  let
    entry = roster.players[player][SummonUnit.ord]
    expected = faction.skinRgb()
  doAssert entry.skinRgb == expected, $faction & " roster tint"
  let
    model = cache.loadUnitModel(manifest, entry, SummonUnit)
    fresh = loadUnitModel(manifest, entry, SummonUnit)
    nodes = partNodes(model.file.root)
    inventory = manifest.presetManifest(entry.preset)
  doAssert inventory.skinNodes.len > 0
  var foundCrown = false
  for category in inventory.categories:
    if category.key == "Headgear":
      for item in category.items:
        if item.name == "Elemental grand laurel crown":
          foundCrown = true
          for name in item.nodes:
            doAssert name in nodes and nodes[name].visible
          for file in item.files:
            var packaged = false
            for asset in generatedCharacterAssets():
              if asset.kind == ModelAsset and
                  asset.source == "characters/chargen" / file:
                packaged = true
            doAssert packaged, "Missing packaged laurel: " & file
  doAssert foundCrown, $faction & " missing grand laurel crown"
  for name in inventory.skinNodes:
    for primitive in nodes[name].mesh.primitives:
      let tint = primitive.material.baseColorFactor
      doAssert abs(tint.r - expected[0]) < 0.00001
      doAssert abs(tint.g - expected[1]) < 0.00001
      doAssert abs(tint.b - expected[2]) < 0.00001
  doAssert model.mergedMeshes.len == 1
  var offsets: array[2, int]
  var skinVertexCount = 0
  for node in model.file.root.walkNodes:
    if not node.visible or node.mesh == nil:
      continue
    for source in node.mesh.primitives:
      let group = (source.material.alphaMode == BlendAlphaMode).ord
      if node.name in inventory.skinNodes:
        let texture = source.material.baseColor
        doAssert texture == nil or (texture.width == 1 and texture.height == 1),
          "Unexpected multi-pixel skin texture"
        for i in 0 ..< source.points.len:
          var expectedColor = source.material.baseColorFactor
          if texture != nil:
            let pixel = texture.data[0]
            expectedColor.r *= pixel.r.float32 / 255
            expectedColor.g *= pixel.g.float32 / 255
            expectedColor.b *= pixel.b.float32 / 255
            expectedColor.a *= pixel.a.float32 / 255
          if source.colors.len > 0:
            let vertex = source.colors[i]
            expectedColor.r *= vertex.r.float32 / 255
            expectedColor.g *= vertex.g.float32 / 255
            expectedColor.b *= vertex.b.float32 / 255
            expectedColor.a *= vertex.a.float32 / 255
          let bytes = expectedColor.rgba
          doAssert model.mergedMeshes[0].mesh.primitives[group].colors[offsets[group] + i] == rgbx(bytes.r, bytes.g, bytes.b, bytes.a)
          inc skinVertexCount
      offsets[group] += source.points.len
  doAssert skinVertexCount > 0
  doAssert model.mergedMeshes.len == fresh.mergedMeshes.len
  for i, merged in model.mergedMeshes:
    doAssert merged.mesh.primitives.len == fresh.mergedMeshes[i].mesh.primitives.len
    for j, primitive in merged.mesh.primitives:
      doAssert primitive.colors == fresh.mergedMeshes[i].mesh.primitives[j].colors
  echo faction, " elemental roster and cached model tint passed"
