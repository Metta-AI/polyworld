## Browser packing must include all files referenced by the wood axe preset.
import
  std/[os, sets],
  polyworld/[assets, chargen, common],
  ../[assets, content]

let
  manifest = readManifest(ChargenLibrary)
  roster = readCharacterRoster()
  inventory = manifest.presetManifest(woodAxePreset(
    roster.players[0][PeonUnit.ord].preset
  ))
  declared = generatedCharacterAssets()
var modelPaths, imagePaths: HashSet[string]
for asset in declared:
  case asset.kind
  of ModelAsset: modelPaths.incl asset.source
  of ImageAsset: imagePaths.incl asset.source
  else: discard
var foundAxe = false
for category in inventory.categories:
  for item in category.items:
    if category.key == "Right hand":
      doAssert item.name == "Berserker axe"
      foundAxe = true
    for path in item.files:
      let source = (DataRoot / "characters/chargen" / path).assetName
      doAssert fileExists(ChargenLibrary / path), source
      doAssert source in modelPaths, "Missing browser model: " & source
    for path in [item.texture, item.pupilMask]:
      if path.len > 0:
        let source = (DataRoot / "characters/chargen" / path).assetName
        doAssert fileExists(ChargenLibrary / path), source
        doAssert source in imagePaths, "Missing browser image: " & source
doAssert foundAxe
echo "Woodcutting character browser asset declaration passed."
