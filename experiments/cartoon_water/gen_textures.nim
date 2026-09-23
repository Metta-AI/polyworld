# Exports the original procedural comparison textures for inspection.
# Imagegen artwork is stored separately in polyworld_art.
# Run with nim r experiments/cartoon_water/gen_textures.nim.

import
  std/os,
  pixie,
  assets, textures

proc main() =
  ## Saves the procedural masks without touching the imagegen artwork.
  createDir(TextureDirectory)
  let sheet = [
    ("foam_lattice", foamLattice()),
    ("sea_preview", seaPreview()),
    ("warp_map", warpMap()),
    ("shore_foam", shoreFoam()),
    ("shore_mask", shoreMask()),
    ("crest_foam", crestFoam()),
    ("band_foam", bandFoam()),
    ("shore_lattice", shoreLattice())
  ]
  for (name, image) in sheet:
    let path = TextureDirectory / name & ".png"
    image.writeFile(path)
    echo "wrote ", path

main()
