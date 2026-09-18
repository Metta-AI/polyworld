import
  std/tables,
  chroma, gltf,
  parts

type
  HairSurface = object
    material: Material
    shade: float32

  HairMaterials* = object
    surfaces: seq[HairSurface]

proc initMaterials(
  nodes: Table[string, Node], shades: openArray[HairShade]
): HairMaterials =
  ## Binds explicit exported shades without relying on material names.
  for surface in shades:
    if surface.node notin nodes:
      continue
    let primitives = nodes[surface.node].mesh.primitives
    if surface.primitive < 0 or surface.primitive >= primitives.len:
      raise newException(
        ChargenError, "Missing tinted surface: " & surface.node
      )
    result.surfaces.add HairSurface(
      material: primitives[surface.primitive].material,
      shade: surface.shade
    )

proc initHairMaterials*(
  nodes: Table[string, Node], manifest: Manifest
): HairMaterials =
  ## Binds scalp and facial hair surfaces to the shared hair color.
  initMaterials(nodes, manifest.hairShades)

proc initHatMaterials*(
  nodes: Table[string, Node], manifest: Manifest
): HairMaterials =
  ## Binds hat fabric while preserving mushroom spots and decorations.
  initMaterials(nodes, manifest.hatShades)

proc applyHairTint*(hair: HairMaterials, tint: array[3, float32]) =
  ## Recolors every style and restores its shades after the weight preview.
  for surface in hair.surfaces:
    surface.material.baseColorFactor = color(
      clamp(tint[0] * surface.shade, 0, 1),
      clamp(tint[1] * surface.shade, 0, 1),
      clamp(tint[2] * surface.shade, 0, 1),
      1
    )

proc applyHatTint*(hats: HairMaterials, tint: array[3, float32]) =
  ## Recolors the explicitly bound hat surfaces independently of hair.
  hats.applyHairTint(tint)
