import
  std/[os, strutils],
  gltf, pixie,
  parts

const
  PupilColors* = [
    (name: "Gray", rgb: [1.0'f, 1.0'f, 1.0'f]),
    (name: "Black", rgb: [0.0'f, 0.0'f, 0.0'f]),
    (name: "Teal", rgb: [0.15'f, 0.85'f, 0.88'f]),
    (name: "Blue", rgb: [0.22'f, 0.55'f, 1.0'f]),
    (name: "Green", rgb: [0.30'f, 0.85'f, 0.25'f]),
    (name: "Amber", rgb: [1.0'f, 0.65'f, 0.16'f]),
    (name: "Brown", rgb: [0.65'f, 0.35'f, 0.15'f]),
    (name: "Violet", rgb: [0.72'f, 0.35'f, 1.0'f])
  ]

type
  EyeTextures* = object
    art*, mask*: Image
    primitives: seq[Primitive]
    applied: array[3, float32]
    hasApplied: bool

proc pupilColor*(name: string): int =
  ## Finds a named pupil color for reproducible viewer launches.
  for i, item in PupilColors:
    if cmpIgnoreCase(item.name, name) == 0:
      return i
  raise newException(BlenderCharsError, "Unknown pupil color: " & name)

proc tintPupils*(art, mask: Image, tint: array[3, float32]): Image =
  ## Multiplies masked iris shades while preserving highlights and alpha.
  if art.width != mask.width or art.height != mask.height:
    raise newException(BlenderCharsError, "Eye art and mask sizes differ.")
  result = newImage(art.width, art.height)
  for i, pixel in art.data:
    let
      amount = mask.data[i].r.float32 / 255
      red = 1 + amount * (clamp(tint[0], 0, 1) - 1)
      green = 1 + amount * (clamp(tint[1], 0, 1) - 1)
      blue = 1 + amount * (clamp(tint[2], 0, 1) - 1)
    result.data[i] = rgbx(
      uint8(pixel.r.float32 * red + 0.5),
      uint8(pixel.g.float32 * green + 0.5),
      uint8(pixel.b.float32 * blue + 0.5),
      pixel.a
    )

proc readEyeTextures*(root: Node, directory: string): EyeTextures =
  ## Loads the approved atlas and finds its independently selectable decals.
  let path = directory / "eyes/generated_v2"
  try:
    result.art = loadStraightAlphaImage(path / "eyes_4x4_transparent.png")
    result.mask = loadStraightAlphaImage(path / "eyes_4x4_pupil_mask.png")
  except IOError, PixieError:
    raise newException(
      BlenderCharsError, "Cannot read eye atlas: " & getCurrentExceptionMsg()
    )
  for node in root.walkNodes:
    if node.mesh != nil and node.name.startsWith("Eyes_Atlas"):
      for primitive in node.mesh.primitives:
        result.primitives.add primitive
  if result.primitives.len != 16:
    raise newException(BlenderCharsError, "Expected 16 generated eye styles.")

proc applyPupilTint*(eyes: var EyeTextures, tint: array[3, float32]) =
  ## Refreshes the shared atlas only when the pupil color changes.
  if eyes.hasApplied and eyes.applied == tint:
    return
  let image = tintPupils(eyes.art, eyes.mask, tint)
  for primitive in eyes.primitives:
    primitive.clearFromGpu()
    primitive.material.baseColor = image
    primitive.material.baseColorKtx2 = ""
  eyes.applied = tint
  eyes.hasApplied = true
