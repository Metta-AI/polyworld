## Requires desktop GL to check colored loot, font masks, and solid bars.

import
  chroma, opengl, vmath, windy,
  polyworld/worldbars

proc checkPixel(x, y: int32, expected: array[3, uint8]) =
  ## Checks the blended color of one framebuffer pixel.
  var actual: array[4, uint8]
  glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, actual.addr)
  for i in 0 ..< expected.len:
    doAssert abs(actual[i].int - expected[i].int) <= 2,
      "Expected " & $expected & " at " & $x & ", " & $y &
      ", got " & $actual

proc checkBillboards() =
  ## Verifies color and alpha handling for mixed billboard batches.
  let window = newWindow(
    "World billboard check",
    ivec2(360, 120),
    vsync = false,
    msaa = msaaDisabled
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  pollEvents()
  var
    renderer = initWorldBarRenderer()
    textureId: GLuint
    texels = [
      240'u8, 160, 40, 255, 16, 64, 128, 128,
      0, 0, 0, 0, 30, 210, 60, 255
    ]
  glGenTextures(1, textureId.addr)
  defer:
    glDeleteTextures(1, textureId.addr)
  glBindTexture(GL_TEXTURE_2D, textureId)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA.GLint, 2, 2, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, texels[0].addr
  )
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST.GLint)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST.GLint)
  glViewport(0, 0, window.size.x, window.size.y)
  glClearColor(20.0'f / 255, 40.0'f / 255, 60.0'f / 255, 1)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)

  const
    White = rgbx(255, 255, 255, 255)
    Tint = rgbx(180, 60, 90, 255)
    Cases = [
      (ColorTexture, vec2(0.25, 0.25), White, [240'u8, 160, 40]),
      (ColorTexture, vec2(0.75, 0.25), White, [26'u8, 84, 158]),
      (ColorTexture, vec2(0.25, 0.75), White, [20'u8, 40, 60]),
      (MaskTexture, vec2(0.25, 0.25), Tint, [180'u8, 60, 90]),
      (MaskTexture, vec2(0.75, 0.25), Tint, [100'u8, 50, 75]),
      (MaskTexture, vec2(-1), Tint, [180'u8, 60, 90])
    ]
  let width = 2.0'f / Cases.len.float32
  for i, (mode, uv, tint, expected) in Cases:
    renderer.addBillboardQuad(
      vec3(0),
      vec2(-1 + i.float32 * width, -1),
      vec2(width, 2),
      tint,
      uv,
      textureMode = mode
    )
  renderer.draw(mat4(), vec3(1, 0, 0), vec3(0, 1, 0), textureId)
  for i, (_, _, _, expected) in Cases:
    checkPixel(
      window.size.x * (i.int32 * 2 + 1) div (Cases.len.int32 * 2),
      window.size.y div 2,
      expected
    )
  doAssert glGetError() == GL_NO_ERROR
  echo "Billboard colors, transparency, font masks, and solid bars passed"

checkBillboards()
