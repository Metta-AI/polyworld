import
  std/[json, math, os, sets, tables],
  gltf, vmath,
  polyworld/[assets, characters, chargen, common, terrainsurfaces],
  ../examples/heartleaf/[appearances, content, layouts, scenery]

proc checkArt() =
  ## Checks the runtime asset closure against the art repository's inventory.
  let
    catalog = parseFile(DataRoot / "licenses/assets.json")
    manifest = readManifest(GnomeLibrary)
  var
    licenses: Table[string, string]
    gnomes: HashSet[string]
  for entry in catalog["files"]:
    licenses[entry["path"].getStr] = entry["license"].getStr

  proc checkCc0(path: string) =
    ## Rejects missing or unreviewed art instead of accepting legacy fallbacks.
    let name = path.assetName()
    doAssert fileExists(path), "Missing art: " & path
    doAssert licenses.getOrDefault(name) == "CC0-1.0", name

  for preset in manifest.presets:
    if preset.group == "Gnomes":
      gnomes.incl preset.name
  doAssert gnomes.len == VillagerCount
  for path in [manifest.rig, manifest.skinPalette, manifest.hairPalette,
    manifest.hatPalette, manifest.pupilPalette]:
      checkCc0(GnomeLibrary / path)
  for slot, name in GnomePresets:
    doAssert name in gnomes
    let inventory = manifest.presetManifest(manifest.namedPreset(name))
    for category in inventory.categories:
      for item in category.items:
        for path in item.files:
          checkCc0(GnomeLibrary / path)
        for path in [item.texture, item.pupilMask]:
          if path.len > 0:
            checkCc0(GnomeLibrary / path)
    let model = loadGnome(manifest, slot)
    doAssert model.file.root.getAABounds().max.y > 0
    for animation in AnimationSlot:
      let clip = model.clipIndex(GnomeClips[animation])
      doAssert model.clipDuration(clip) > 0
      for spec in manifest.clips:
        if spec.name == GnomeClips[animation]:
          checkCc0(GnomeLibrary / spec.file)
    echo "Loaded ", name, " with all four animations."

  for name in VillageModels:
    let path = VillageRoot & name & ".glb"
    checkCc0(path)
    let file = readGltfFile(path)
    doAssert file.root.getAABounds().max.y > 0
    doAssert file.root.animations.len == 0
    for node in file.root.walkNodes:
      doAssert node.skin == nil
      if node.mesh != nil:
        for primitive in node.mesh.primitives:
          doAssert primitive.material.baseColor != nil
    echo "Loaded generated village model: ", name
  checkCc0(DetailsPath)
  checkCc0(DataRoot / "themes/heartleaf/heartleaf_logo.png")
  var detailNames: HashSet[string]
  for node in readGltfFile(DetailsPath).root.walkNodes:
    if node.mesh != nil:
      detailNames.incl node.name
      doAssert node.skin == nil
  for name in ["bench", "fence", "lantern", "market", "laundry",
    "beehive", "sign", "flowers_white", "flowers_blue", "flowers_purple",
    "flowers_gold", "lupins", "sunflowers", "tree_curb", "plaza_paving"]:
      doAssert name in detailNames, "Missing village detail: " & name
  for directory in ["tiles", "stamps"]:
    for family in ["grass", "path", "paving"]:
      for variant in 1 .. 3:
        for suffix in [".rgb.png", ".height.png"]:
          checkCc0(DataRoot / "terrain" / directory /
            ("heartleaf-" & family & "-" & $variant & suffix))
  let
    houses = houseNodes()
    originalHouse = readGltfFile(VillageRoot & "hobbit_house.glb")
    originalBounds = originalHouse.root.getAABounds()
    originalSize = originalBounds.max - originalBounds.min
  doAssert houses.len == VillagerCount
  let
    target = TownCameraTarget
    eye = target + vec3(0, sin(TownCameraPitch), cos(TownCameraPitch)) *
      TownOverviewDistance
    extent = TownOverviewDistance * TownCameraScale
    aspect = 1920'f / 1080'f
    projection = ortho(-extent * aspect, extent * aspect,
      -extent, extent, 0.1'f, 1000'f)
    view = lookAt(eye, target, vec3(0, 1, 0))
  var doorColors: HashSet[string]
  for i, house in houses:
    doorColors.incl $house.mesh.primitives[1].material.baseColorFactor
    let
      bounds = house.getAABounds()
      size = bounds.max - bounds.min
      ratios = vec3(size.x / originalSize.x,
        size.y / originalSize.y, size.z / originalSize.z)
    doAssert abs(ratios.x - ratios.y) < 0.00001'f and
      abs(ratios.x - ratios.z) < 0.00001'f,
      "The cottage must preserve the original model's proportions"
    let roof = houseRoof(house)
    doAssert roof.len > 0
    doAssert roofHeight(roof, 0, HouseHillCenterZ) > 3
    doAssert roofHeight(roof, 0, HouseHillCenterZ - 2) > 2,
      "The round mound must extend behind the facade"
    doAssert roofHeight(roof, 0, -8) == 0
    for x in [bounds.min.x, bounds.max.x]:
      for y in [bounds.min.y, bounds.max.y]:
        for z in [bounds.min.z, bounds.max.z]:
          let
            angle = houseYaw(i)
            rotated = vec3(cos(angle) * x - sin(angle) * z,
              y, sin(angle) * x + cos(angle) * z)
            position = rotated + vec3(
              TownHouses[i][0].float32 + 0.5'f, 0,
              TownHouses[i][1].float32 + 0.5'f
            )
          let clip = projection * view * vec4(position, 1)
          doAssert abs(clip.x / clip.w) < 0.8'f
          doAssert abs(clip.y / clip.w) < 0.86'f,
            "Opening camera clips a cottage or puts it behind the HUD"
  doAssert doorColors.len == VillagerCount,
    "Cottage door stains were lost during import"
  for directory in ["tiles", "stamps"]:
    for name in SurfaceNames:
      for suffix in [".rgb.png", ".height.png"]:
        checkCc0(DataRoot / "terrain" / directory / (name & suffix))
  for path in TreegenTextures:
    checkCc0(path)
  checkCc0(RockgenTexture)
  let box = placeholderNode()
  doAssert box.mesh.primitives[0].indices32.len == 36
  doAssert box.getAABounds().max - box.getAABounds().min == vec3(1)
  echo "Heartleaf uses reviewed CC0 scene assets."

checkArt()
