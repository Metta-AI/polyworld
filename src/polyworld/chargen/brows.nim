import
  std/tables,
  chroma, gltf,
  parts

const WhiteBrows* = [1.0'f, 1.0'f, 1.0'f]

type
  BrowMaterials* = object
    materials: seq[Material]

proc initBrowMaterials*(root: Node, manifest: Manifest): BrowMaterials =
  ## Finds tintable eyebrow decals from part metadata without fixed counts.
  let nodes = partNodes(root)
  for category in manifest.categories:
    for item in category.items:
      if item.tint == "hair":
        for name in item.nodes:
          if name in nodes:
            for primitive in nodes[name].mesh.primitives:
              result.materials.add primitive.material

proc applyBrowTint*(brows: BrowMaterials, tint: array[3, float32]) =
  ## Tints white eyebrows without changing skin or other face artwork.
  for material in brows.materials:
    material.baseColorFactor = color(
      clamp(tint[0], 0, 1),
      clamp(tint[1], 0, 1),
      clamp(tint[2], 0, 1),
      1
    )
