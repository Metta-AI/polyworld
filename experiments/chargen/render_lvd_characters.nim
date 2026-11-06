import
  std/[os, strutils],
  opengl, pixie, vmath, windy,
  polyworld/[characters, chargen, shadows, toon],
  ../../games/light_vs_dark/[appearances, assets, content, factions]

proc run() =
  ## Reviews merged game outfits in the game's renderer across animated poses.
  let
    output = getEnv("REVIEW_OUTPUT", "tmp/chargen/lvd-characters")
    window = newWindow(
      "LvD character review",
      ivec2(768, 768),
      vsync = false,
      visible = false
    )
  createDir(output)
  makeContextCurrent(window)
  loadExtensions()
  initSunShadows(20, 40)
  sunShadowsEnabled = false
  var
    framebuffer, texture, depth: GLuint
    cache: UnitModelCache
    pose: CharacterPose
  glGenFramebuffers(1, framebuffer.addr)
  glGenTextures(1, texture.addr)
  glGenRenderbuffers(1, depth.addr)
  defer:
    glBindFramebuffer(GL_FRAMEBUFFER, 0)
    glDeleteFramebuffers(1, framebuffer.addr)
    glDeleteTextures(1, texture.addr)
    glDeleteRenderbuffers(1, depth.addr)
    window.close()
  glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
  glBindTexture(GL_TEXTURE_2D, texture)
  glTexImage2D(
    GL_TEXTURE_2D, 0, GL_RGBA8.GLint, 768, 768, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, nil
  )
  glFramebufferTexture2D(
    GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, texture, 0
  )
  glBindRenderbuffer(GL_RENDERBUFFER, depth)
  glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, 768, 768)
  glFramebufferRenderbuffer(
    GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, depth
  )
  doAssert glCheckFramebufferStatus(GL_FRAMEBUFFER) == GL_FRAMEBUFFER_COMPLETE
  let
    manifest = readManifest(ChargenLibrary)
    scene = CharacterScene(toon: newToonContext(), shading: ToonCharacters)
  scene.toon.cameraPosition = vec3(0, 1.9, 4)
  scene.toon.view = lookAt(
    scene.toon.cameraPosition, vec3(0, 0.83, 0), vec3(0, 1, 0)
  )
  scene.toon.proj = ortho(-1.05'f, 1.05'f, -1.05'f, 1.05'f, 0.02'f, 100'f)
  for faction in [Amethyst, Emerald]:
    let roster = readCharacterRoster([faction])
    for kind in [SummonUnit, KnightUnit]:
      let model = cache.loadUnitModel(manifest, roster.players[0][kind.ord], kind)
      doAssert model.mergedMeshes.len == 1
      let clipName = unitClip(kind, IdleAnimation)
      let clip = model.clipIndex(clipName)
      for sample in 0 ..< 2:
        for view, angle in [0'f, PI.float32 / 2, PI.float32, PI.float32 * 1.70]:
          scene.prepareCharacter(
            pose,
            model,
            vec3(0),
            angle,
            clip,
            model.clipDuration(clip) * sample.float32 / 4
          )
          glBindFramebuffer(GL_FRAMEBUFFER, framebuffer)
          glViewport(0, 0, 768, 768)
          glClearColor(0.79, 0.78, 0.76, 1)
          glClear(GL_COLOR_BUFFER_BIT or GL_DEPTH_BUFFER_BIT)
          scene.drawCharacter(pose)
          glFinish()
          doAssert glGetError() == GL_NO_ERROR
          let picture = newImage(768, 768)
          glReadPixels(
            0, 0, 768, 768, GL_RGBA, GL_UNSIGNED_BYTE, picture.data[0].addr
          )
          picture.flipVertical()
          picture.writeFile(output / (
            ($faction).toLowerAscii & "-" & $kind & "-" & clipName & "-" & $sample & "-" &
            $view & ".png"
          ))
  echo "Rendered Elemental and knight faction variants with shared game skinning"

run()
