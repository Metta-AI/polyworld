import
  std/[strutils, tables],
  chroma, gltf,
  parts

const
  HairColors* = [
    (name: "Jet black", rgb: [0.008'f, 0.009'f, 0.012'f]),
    (name: "Soft black", rgb: [0.025'f, 0.020'f, 0.017'f]),
    (name: "Espresso", rgb: [0.055'f, 0.022'f, 0.012'f]),
    (name: "Dark brown", rgb: [0.115'f, 0.040'f, 0.018'f]),
    (name: "Chestnut", rgb: [0.320'f, 0.078'f, 0.037'f]),
    (name: "Auburn", rgb: [0.400'f, 0.062'f, 0.023'f]),
    (name: "Copper", rgb: [0.600'f, 0.145'f, 0.028'f]),
    (name: "Caramel", rgb: [0.480'f, 0.240'f, 0.070'f]),
    (name: "Honey blond", rgb: [0.680'f, 0.430'f, 0.130'f]),
    (name: "Sandy blond", rgb: [0.650'f, 0.490'f, 0.290'f]),
    (name: "Platinum blond", rgb: [0.820'f, 0.760'f, 0.600'f]),
    (name: "Ash gray", rgb: [0.200'f, 0.220'f, 0.240'f]),
    (name: "Silver", rgb: [0.600'f, 0.650'f, 0.700'f]),
    (name: "White", rgb: [0.920'f, 0.920'f, 0.880'f]),
    (name: "Lavender", rgb: [0.520'f, 0.270'f, 0.780'f]),
    (name: "Violet", rgb: [0.280'f, 0.025'f, 0.650'f]),
    (name: "Cobalt", rgb: [0.025'f, 0.100'f, 0.800'f]),
    (name: "Cyan", rgb: [0.015'f, 0.650'f, 0.950'f]),
    (name: "Teal", rgb: [0.015'f, 0.420'f, 0.330'f]),
    (name: "Mint", rgb: [0.250'f, 0.850'f, 0.550'f]),
    (name: "Lime", rgb: [0.480'f, 0.950'f, 0.025'f]),
    (name: "Rose", rgb: [0.850'f, 0.230'f, 0.400'f]),
    (name: "Hot pink", rgb: [0.950'f, 0.015'f, 0.300'f]),
    (name: "Crimson", rgb: [0.720'f, 0.015'f, 0.025'f]),
    (name: "Electric orange", rgb: [0.950'f, 0.200'f, 0.010'f])
  ]

type
  HairSurface = object
    material: Material
    shade: float32

  HairMaterials* = object
    surfaces: seq[HairSurface]

proc hairColor*(name: string): int =
  ## Finds a named hair preset for reproducible viewer launches.
  for i, item in HairColors:
    if cmpIgnoreCase(item.name, name) == 0:
      return i
  raise newException(BlenderCharsError, "Unknown hair color: " & name)

proc initHairMaterials*(
  nodes: Table[string, Node], manifest: Manifest
): HairMaterials =
  ## Binds explicit exported hair shades without relying on material names.
  for surface in manifest.hairShades:
    if surface.node notin nodes:
      raise newException(
        BlenderCharsError, "Missing hair mesh: " & surface.node
      )
    let primitives = nodes[surface.node].mesh.primitives
    if surface.primitive < 0 or surface.primitive >= primitives.len:
      raise newException(
        BlenderCharsError, "Missing hair surface: " & surface.node
      )
    result.surfaces.add HairSurface(
      material: primitives[surface.primitive].material,
      shade: surface.shade
    )
  if result.surfaces.len == 0:
    raise newException(BlenderCharsError, "The model has no hair materials.")

proc applyHairTint*(hair: HairMaterials, tint: array[3, float32]) =
  ## Recolors every style and restores its shades after the weight preview.
  for surface in hair.surfaces:
    surface.material.baseColorFactor = color(
      clamp(tint[0] * surface.shade, 0, 1),
      clamp(tint[1] * surface.shade, 0, 1),
      clamp(tint[2] * surface.shade, 0, 1),
      1
    )
