## Requires desktop GL to verify occluded edges against real scene depth.

import
  opengl, vmath, windy,
  polyworld/selectionoutlines

proc integer(parameter: GLenum): GLint =
  ## Reads one integer from the active GL context.
  glGetIntegerv(parameter, result.addr)

proc pixel(x, y: int32): array[4, uint8] =
  ## Reads one resolved window pixel without changing framebuffer state.
  glReadPixels(x, y, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, result.addr)

proc clearRectangle(x, y, width, height: int32, depth: float64) =
  ## Writes an opaque rectangular silhouette at a controlled depth.
  glEnable(GL_SCISSOR_TEST)
  glScissor(x, y, width, height)
  glClearDepth(depth)
  glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
  glDisable(GL_SCISSOR_TEST)
  glClearDepth(1)

proc checkOutlines(msaa: MSAA) =
  ## Checks full, partial, absent, and empty occlusion with and without MSAA.
  let window = newWindow(
    "Character occlusion check",
    ivec2(320, 240),
    vsync = false,
    msaa = msaa
  )
  defer:
    window.close()
  window.makeContextCurrent()
  loadExtensions()
  pollEvents()
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  var
    outline = initSelectionOutline(OccludedOutline)
    selection = initSelectionOutline()
  defer:
    outline.closeSelectionOutline()
    selection.closeSelectionOutline()
  glEnable(GL_MULTISAMPLE)

  for size in [window.size, window.size div 2, window.size]:
    let
      left = size.x div 4
      bottom = size.y div 4
      width = size.x div 2
      height = size.y div 2
      lower = bottom + height div 4
      upper = bottom + height * 3 div 4
    for coverage in 0 .. 2:
      glBindFramebuffer(GL_FRAMEBUFFER, 0)
      glDepthMask(GL_TRUE)
      glClearColor(0, 0, 0, 1)
      glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
      if coverage > 0:
        clearRectangle(0, 0, size.x, size.y * coverage.int32 div 2, 0.4)

      outline.beginMask(size)
      glClearColor(1, 1, 1, 1)
      clearRectangle(left, bottom, width, height, 0.6)
      outline.drawOutline(vec3(0, 1, 0))

      doAssert (pixel(left - 1, lower)[1] > 200) == (coverage > 0)
      doAssert (pixel(left - 1, upper)[1] > 200) == (coverage == 2)
      doAssert pixel(left + width div 2, lower)[1] == 0,
        "Occlusion must outline the silhouette without filling its interior."
      # A nearer silhouette still behind the wall must pass the same test.
      outline.beginMask(size)
      glClearColor(1, 1, 1, 1)
      clearRectangle(left, bottom, width, height, 0.5)
      outline.drawOutline(vec3(0, 0, 1))
      doAssert (pixel(left - 1, lower)[2] > 200) == (coverage > 0),
        "Outlines must preserve scenery depth."
      doAssert integer(GL_DEPTH_FUNC) == GL_LEQUAL.GLint
      doAssert integer(GL_DEPTH_WRITEMASK) == GL_TRUE.GLint
      doAssert integer(GL_FRAMEBUFFER_BINDING) == 0

      # Existing selection outlines remain visible regardless of scene depth.
      selection.beginMask(size)
      glClearColor(1, 1, 1, 1)
      clearRectangle(left, bottom, width, height, 0.6)
      selection.drawOutline(vec3(1, 0, 0))
      let selectedPixel = pixel(left - 1, upper)
      doAssert selectedPixel[0] > 200,
        $msaa & " " & $size & " " & $coverage & " " &
        $selectedPixel & " GL error " & $glGetError().uint32

    # An empty mask must not reveal anything through a fully occluding wall.
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    glClearColor(0, 0, 0, 1)
    clearRectangle(0, 0, size.x, size.y, 0.4)
    outline.beginMask(size)
    outline.drawOutline(vec3(0, 1, 0))
    doAssert pixel(left - 1, lower)[1] == 0
    doAssert glGetError() == GL_NO_ERROR

  echo "Character occlusion passed with ", msaa

checkOutlines(msaaDisabled)
checkOutlines(msaa4x)
