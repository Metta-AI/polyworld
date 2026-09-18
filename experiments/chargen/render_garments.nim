import
  std/[os, sets, strutils, tables],
  chroma, gltf, opengl, pixie, vmath, windy,
  polyworld/[animblend, chargen, toon], lineups

const DefaultOutput = currentSourcePath().parentDir.parentDir.parentDir /
  "tmp/chargen/garments"

proc run() =
  ## Renders the actual swappable clothing from front, side, and back for review.
  let
    output = getEnv("REVIEW_OUTPUT", DefaultOutput)
    directory = getEnv("CHARGEN_LIBRARY", ChargenLibrary)
    details = getEnv("CLOTHING_DETAILS", "0") == "1"
    hands = getEnv("REVIEW_HANDS", "0") == "1"
    smoothLighting = getEnv("REVIEW_PBR", "0") == "1"
    window = newWindow(
      "Gnome clothing review",
      if hands: ivec2(1800, 1000)
      elif details: ivec2(1500, 900)
      else: ivec2(1500, 1800),
      vsync = false,
      msaa = msaa4x
    )
  createDir(output)
  makeContextCurrent(window)
  loadExtensions()
  let
    renderer = newRenderer(window)
    toon = newToonContext()
    pbr = newPbrContext(renderer)
    manifest = readManifest(directory)
    model = readCharacter(directory, manifest)
    player = newClipPlayer(model.root)
    actors = readLineup(directory, manifest, model.root, "Gnomes")
  player.play("A_TPose", 0)
  player.seek(0)
  actors.sync()
  for actor in actors:
    for name, node in partNodes(actor.root):
      if details and (name in ["Head", "Gnome_Vest", "Gnome_Jacket",
                               "Gnome_Coat"] or
        name.startsWith("Hat_") or name.startsWith("Eyes_") or
        name.startsWith("Mouth_") or name.startsWith("Brow_") or
        name.startsWith("Beard_") or name.startsWith("Ears_") or
        name.startsWith("Nose_")):
          node.visible = false
          node.baseVisible = false
      if name.startsWith("Eyes_") or name.startsWith("Mouth_") or
        name.startsWith("Brow_"):
          toon.unlitNodes.incl name
  toon.setPalette(ToonPalettes[0])
  toon.rimColor = color(1, 1, 1, 0.15)
  toon.cameraPosition = vec3(0, 5.94, 16)
  toon.view = lookAt(toon.cameraPosition, vec3(0, 5.94, 0), vec3(0, 1, 0))
  toon.proj = ortho(-5.125'f, 5.125'f, -6.15'f, 6.15'f, 0.02'f, 100'f)
  toon.lightDirection = -normalize(vec3(-0.6, 0.5, 0.7))
  if details:
    toon.cameraPosition = vec3(0, 1.0, 12)
    toon.view = lookAt(toon.cameraPosition, vec3(0, 1.0, 0), vec3(0, 1, 0))
    toon.proj = ortho(-2.5'f, 2.5'f, -1.5'f, 1.5'f, 0.02'f, 100'f)
  if hands:
    toon.cameraPosition = vec3(0, 1.30, 12)
    toon.view = lookAt(toon.cameraPosition, vec3(0, 1.30, 0), vec3(0, 1, 0))
    toon.proj = ortho(-1.5'f, 1.5'f, -0.8333'f, 0.8333'f, 0.02'f, 100'f)
  pbr.size = window.size
  pbr.view = toon.view
  pbr.proj = toon.proj
  pbr.cameraPosition = toon.cameraPosition
  pbr.tint = color(1, 1, 1, 1)
  pbr.useTrs = true
  pbr.ambientLightColor = color(0.32, 0.36, 0.46, 0.35)
  pbr.sunLightDirection = toon.lightDirection
  pbr.sunLightColor = color(0.95, 0.96, 1, 1)
  pbr.rimLightDirection = normalize(vec3(-1, 1, -1))
  pbr.rimLightColor = color(0.95, 0.72, 0.46, 0.25)
  pbr.debugView = dvLit
  pbr.useShadows = false
  pbr.drawSkybox = false
  var frame = 0
  window.onFrame = proc() =
    ## Captures consistent lit geometry views without changing library assets.
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.18, 0.20, 0.23, 1))
    glEnable(GL_MULTISAMPLE)
    let angle = [0'f, 1.1'f, PI.float32, 0.35'f, 0.35'f][frame]
    if frame >= 3:
      player.play(if frame == 3: "Walk_Loop" else: "Crouch_Fwd_Loop", 0)
      player.seek(0.35)
      actors.sync()
    for i, actor in actors:
      if details and i notin [2, 8]:
        continue
      if hands and i != 2:
        continue
      toon.transform = translate(vec3(
        if hands: 0'f
        elif details: (if i == 2: -1.15'f else: 1.15'f)
        else: (i mod 3 - 1).float32 * 3.45,
        if details or hands: 0'f else: (2 - i div 3).float32 * 4.05,
        0
      )) * rotateY(angle)
      actor.root.updateTransforms(toon.transform)
      if smoothLighting:
        pbr.transform = toon.transform
        pbr.draw(actor.root)
      else:
        toon.draw(actor.root)
    renderer.endFrame()
    let shot = newImage(window.size.x, window.size.y)
    glReadPixels(
      0, 0, window.size.x, window.size.y,
      GL_RGBA, GL_UNSIGNED_BYTE, shot.data[0].addr
    )
    shot.flipVertical()
    let filename = ["front.png", "side.png", "back.png", "walk.png",
                    "crouch.png"][frame]
    shot.writeFile(output / (if details: "details_" & filename else: filename))
    window.swapBuffers()
    inc frame
    if frame == 5:
      quit(0)
  while not window.closeRequested:
    pollEvents()

run()
