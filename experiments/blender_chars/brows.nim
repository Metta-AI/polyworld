import
  std/strutils,
  chroma, gltf,
  parts

const WhiteBrows* = [1.0'f, 1.0'f, 1.0'f]

type
  BrowMaterials* = object
    materials: seq[Material]

proc initBrowMaterials*(root: Node): BrowMaterials =
  ## Finds the independently selectable white eyebrow decals.
  for node in root.walkNodes:
    if node.mesh == nil or not node.name.startsWith("Brow_Atlas"):
      continue
    for primitive in node.mesh.primitives:
      result.materials.add primitive.material
  if result.materials.len != 16:
    raise newException(BlenderCharsError, "Expected 16 eyebrow decals.")

proc applyBrowTint*(brows: BrowMaterials, tint: array[3, float32]) =
  ## Tints white eyebrows without changing skin or other face artwork.
  for material in brows.materials:
    material.baseColorFactor = color(
      clamp(tint[0], 0, 1),
      clamp(tint[1], 0, 1),
      clamp(tint[2], 0, 1),
      1
    )
