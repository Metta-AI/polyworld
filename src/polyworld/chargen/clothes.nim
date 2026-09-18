import
  std/tables,
  chroma, gltf,
  parts

type
  ClothSurface = object
    material: Material
    original: Color
    shade: float32

  ClothMaterials* = object
    category*: string
    enabled*: bool
    tint*: array[3, float32]
    surfaces: seq[ClothSurface]

proc initClothMaterials*(
  nodes: Table[string, Node], manifest: Manifest
): seq[ClothMaterials] =
  ## Binds fabric per slot while retaining buckles, soles, and fixed trim.
  for category in manifest.categories:
    var cloth = ClothMaterials(category: category.key, tint: [1'f, 1'f, 1'f])
    for item in category.items:
      for shade in item.clothShades:
        if shade.node notin nodes:
          raise newException(ChargenError, "Missing fabric: " & shade.node)
        let primitives = nodes[shade.node].mesh.primitives
        if shade.primitive < 0 or shade.primitive >= primitives.len:
          raise newException(ChargenError, "Invalid fabric: " & shade.node)
        let material = primitives[shade.primitive].material
        cloth.surfaces.add ClothSurface(
          material: material,
          original: material.baseColorFactor,
          shade: shade.shade
        )
    if cloth.surfaces.len > 0:
      result.add cloth

proc applyClothTint*(clothes: openArray[ClothMaterials]) =
  ## Applies independent garment colors or restores their authored palette.
  for cloth in clothes:
    for surface in cloth.surfaces:
      surface.material.baseColorFactor =
        if cloth.enabled:
          color(
            clamp(cloth.tint[0] * surface.shade, 0, 1),
            clamp(cloth.tint[1] * surface.shade, 0, 1),
            clamp(cloth.tint[2] * surface.shade, 0, 1),
            1
          )
        else:
          surface.original

proc applyClothPreset*(clothes: var seq[ClothMaterials], preset: Preset) =
  ## Resets fabric overrides before applying the outfit's optional RGB colors.
  for cloth in clothes.mitems:
    cloth.enabled = false
    for part in preset.parts:
      if part.category != cloth.category or part.rgb.len == 0:
        continue
      if part.rgb.len != 3:
        raise newException(ChargenError, "Fabric RGB needs three channels.")
      cloth.enabled = true
      for i in 0 ..< 3:
        if not (part.rgb[i] >= 0 and part.rgb[i] <= 1):
          raise newException(ChargenError, "Fabric RGB is outside zero to one.")
        cloth.tint[i] = part.rgb[i]
  clothes.applyClothTint()
