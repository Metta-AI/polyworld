import
  flatty/binny, gltf/ktx2, opengl,
  assets

when defined(emscripten):
  {.emit: "#include <emscripten.h>\n#include <emscripten/html5_webgl.h>".}
  ## Returns the browser's active graphics context.
  proc currentContext(): cint {.
    importc: "emscripten_webgl_get_current_context",
    header: "<emscripten/html5_webgl.h>"
  .}
  ## Requests a WebGL extension for the given context.
  proc enableExtension(context: cint, extension: cstring): bool {.
    importc: "emscripten_webgl_enable_extension",
    header: "<emscripten/html5_webgl.h>"
  .}

proc decode565(value: uint16): array[3, uint8] =
  ## Expands RGB565 endpoints into straight RGB bytes.
  [
    uint8((((value.int shr 11) and 31) * 255 + 15) div 31),
    uint8((((value.int shr 5) and 63) * 255 + 31) div 63),
    uint8(((value.int and 31) * 255 + 15) div 31)
  ]

proc decodeBc3*(data: string, info: Ktx2TextureInfo, level: int): string =
  ## Decodes a validated BC3 mip without multiplying RGB by its height channel.
  if info.vkFormat != VkFormatBc3UnormBlock or level < 0 or
    level >= info.levelCount:
      raise newException(AssetError, "Expected a valid linear BC3 mip level.")
  let
    width = max(1, info.width shr level)
    height = max(1, info.height shr level)
    blocksWide = (width + 3) div 4
    blocksHigh = (height + 3) div 4
    start = info.levels[level].byteOffset
    size = blocksWide * blocksHigh * 16
  if start < 0 or size > data.len - start or
    info.levels[level].byteLength != size:
      raise newException(AssetError, "Invalid BC3 level length.")
  result = newString(width * height * 4)
  for y in 0 ..< blocksHigh:
    for x in 0 ..< blocksWide:
      let
        offset = start + (y * blocksWide + x) * 16
        alphaBits = data.readUint64(offset) shr 16
        colorBits = data.readUint32(offset + 12)
      var
        alphas: array[8, uint8]
        colors: array[4, array[3, uint8]]
      alphas[0] = data[offset].ord.uint8
      alphas[1] = data[offset + 1].ord.uint8
      if alphas[0] > alphas[1]:
        for i in 1 .. 6:
          alphas[i + 1] = uint8(
            ((7 - i) * alphas[0].int + i * alphas[1].int) div 7
          )
      else:
        for i in 1 .. 4:
          alphas[i + 1] = uint8(
            ((5 - i) * alphas[0].int + i * alphas[1].int) div 5
          )
        alphas[6] = 0
        alphas[7] = 255
      colors[0] = decode565(data.readUint16(offset + 8))
      colors[1] = decode565(data.readUint16(offset + 10))
      for channel in 0 ..< 3:
        colors[2][channel] = uint8(
          (2 * colors[0][channel].int + colors[1][channel].int) div 3
        )
        colors[3][channel] = uint8(
          (colors[0][channel].int + 2 * colors[1][channel].int) div 3
        )
      for j in 0 ..< 4:
        for i in 0 ..< 4:
          let
            pixel = j * 4 + i
            px = x * 4 + i
            py = y * 4 + j
          if px >= width or py >= height:
            continue
          let
            destination = (py * width + px) * 4
            color = colors[int((colorBits shr (pixel * 2)) and 3)]
            alpha = alphas[int((alphaBits shr (pixel * 3)) and 7)]
          for channel in 0 ..< 3:
            result[destination + channel] = char(color[channel])
          result[destination + 3] = char(alpha)

proc supportsBc3(forceRgba: bool): bool =
  ## Enables browser compression only when available and requested.
  if forceRgba:
    return false
  when defined(webForceRgba):
    return false
  when defined(emscripten):
    var forced: cint
    {.emit: """
    `forced` = EM_ASM_INT({
      return new URLSearchParams(location.search).has('textureFallback');
    });
    """.}
    if forced != 0:
      return false
    result = enableExtension(currentContext(), "WEBGL_compressed_texture_s3tc")
  else:
    result = false

proc loadTerrainTextures*(
  paths: openArray[string], forceRgba = false
): tuple[texture: GLuint, compressed: bool] =
  ## Uploads prebuilt terrain mips, decoding only for the compatibility path.
  if paths.len == 0:
    raise newException(AssetError, "Terrain texture array cannot be empty.")
  var
    files: seq[string]
    infos: seq[Ktx2TextureInfo]
  for path in paths:
    try:
      let
        bytes = readFile(path)
        info = parseKtx2(bytes)
      if info.vkFormat != VkFormatBc3UnormBlock:
        raise newException(AssetError, "Terrain requires linear BC3: " & path)
      if infos.len > 0 and (info.width != infos[0].width or
        info.height != infos[0].height or info.levelCount != infos[0].levelCount):
          raise newException(AssetError, "Mismatched terrain KTX2 layers.")
      files.add bytes
      infos.add info
    except AssetError:
      raise
    except CatchableError as error:
      raise newException(AssetError, "Cannot load " & path & ": " & error.msg)
  result.compressed = supportsBc3(forceRgba)
  glGenTextures(1, result.texture.addr)
  glBindTexture(GL_TEXTURE_2D_ARRAY, result.texture)
  try:
    for level in 0 ..< infos[0].levelCount:
      let
        width = max(1, infos[0].width shr level)
        height = max(1, infos[0].height shr level)
      var bytes = ""
      for i, info in infos:
        if result.compressed:
          let mip = info.levels[level]
          bytes.add files[i][mip.byteOffset ..< mip.byteOffset + mip.byteLength]
        else:
          bytes.add decodeBc3(files[i], info, level)
      if result.compressed:
        glCompressedTexImage3D(
          GL_TEXTURE_2D_ARRAY, level.GLint, infos[0].glInternalFormat,
          width.GLsizei, height.GLsizei, files.len.GLsizei, 0,
          bytes.len.GLsizei, unsafeAddr bytes[0]
        )
      else:
        glTexImage3D(
          GL_TEXTURE_2D_ARRAY, level.GLint, GL_RGBA8.GLint,
          width.GLsizei, height.GLsizei, files.len.GLsizei, 0,
          GL_RGBA, GL_UNSIGNED_BYTE, unsafeAddr bytes[0]
        )
      let error = glGetError()
      if error != GL_NO_ERROR:
        raise newException(AssetError, "Terrain upload failed: " & $error.uint32)
    glTexParameteri(
      GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAX_LEVEL, (infos[0].levelCount - 1).GLint
    )
    glTexParameteri(
      GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR.GLint
    )
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_MAG_FILTER, GL_LINEAR.GLint)
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_S, GL_REPEAT.GLint)
    glTexParameteri(GL_TEXTURE_2D_ARRAY, GL_TEXTURE_WRAP_T, GL_REPEAT.GLint)
  except:
    glDeleteTextures(1, result.texture.addr)
    raise
  finally:
    glBindTexture(GL_TEXTURE_2D_ARRAY, 0)
