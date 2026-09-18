import
  std/tables,
  gltf, pixie,
  parts

type
  EyeTexture* = object
    art*, mask*: Image
    primitives*: seq[Primitive]

  EyeTextures* = object
    textures*: seq[EyeTexture]
    applied: array[3, float32]
    hasApplied: bool

proc tintPupils*(art, mask: Image, tint: array[3, float32]): Image =
  ## Multiplies masked iris shades while preserving highlights and alpha.
  if art.width != mask.width or art.height != mask.height:
    raise newException(ChargenError, "Eye art and mask sizes differ.")
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

proc readEyeTextures*(
  root: Node, directory: string, manifest: Manifest
): EyeTextures =
  ## Loads individual pupil masks and shares repeated packed texture pages.
  let nodes = partNodes(root)
  var pages: Table[string, int]
  for category in manifest.categories:
    for item in category.items:
      if item.pupilMask.len == 0:
        continue
      var primitives: seq[Primitive]
      for name in item.nodes:
        if name in nodes:
          primitives.add nodes[name].mesh.primitives
      if primitives.len == 0:
        continue
      let key = item.texture & "|" & item.pupilMask
      if key notin pages:
        var texture: EyeTexture
        try:
          texture.art = loadStraightAlphaImage(
            directory.assetPath(item.texture)
          )
          texture.mask = loadStraightAlphaImage(
            directory.assetPath(item.pupilMask)
          )
        except IOError, PixieError:
          raise newException(
            ChargenError, "Cannot read eye textures: " & getCurrentExceptionMsg()
          )
        if texture.art.width != texture.mask.width or
          texture.art.height != texture.mask.height:
            raise newException(ChargenError, "Eye art and mask sizes differ.")
        pages[key] = result.textures.len
        result.textures.add texture
      result.textures[pages[key]].primitives.add primitives

proc applyPupilTint*(eyes: var EyeTextures, tint: array[3, float32]) =
  ## Refreshes only the selected library's eye textures when its tint changes.
  if eyes.hasApplied and eyes.applied == tint:
    return
  for texture in eyes.textures:
    let image = tintPupils(texture.art, texture.mask, tint)
    for primitive in texture.primitives:
      primitive.clearFromGpu()
      primitive.material.baseColor = image
      primitive.material.baseColorKtx2 = ""
  eyes.applied = tint
  eyes.hasApplied = true
