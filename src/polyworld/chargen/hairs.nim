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

proc initHairMaterials*(
  nodes: Table[string, Node], manifest: Manifest
): HairMaterials =
  ## Binds explicit exported hair shades without relying on material names.
  for surface in manifest.hairShades:
    if surface.node notin nodes:
      continue
    let primitives = nodes[surface.node].mesh.primitives
    if surface.primitive < 0 or surface.primitive >= primitives.len:
      raise newException(
        ChargenError, "Missing hair surface: " & surface.node
      )
    result.surfaces.add HairSurface(
      material: primitives[surface.primitive].material,
      shade: surface.shade
    )

proc applyHairTint*(hair: HairMaterials, tint: array[3, float32]) =
  ## Recolors every style and restores its shades after the weight preview.
  for surface in hair.surfaces:
    surface.material.baseColorFactor = color(
      clamp(tint[0] * surface.shade, 0, 1),
      clamp(tint[1] * surface.shade, 0, 1),
      clamp(tint[2] * surface.shade, 0, 1),
      1
    )
