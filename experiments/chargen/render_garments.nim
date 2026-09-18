import
  std/[os, sets, strutils, tables],
  chroma, gltf, opengl, pixie, vmath, windy,
  polyworld/[animblend, chargen, toon], lineups

const Output = currentSourcePath().parentDir.parentDir.parentDir /
  "tmp/chargen/garments"

proc run() =
  ## Renders the actual swappable clothing from front, side, and back for review.
  createDir(Output)
  let
    details = getEnv("CLOTHING_DETAILS", "0") == "1"
    window = newWindow(
      "Gnome clothing review",
      if details: ivec2(1500, 900) else: ivec2(1500, 1800),
      vsync = false,
      msaa = msaa4x
    )
  makeContextCurrent(window)
  loadExtensions()
  let
    renderer = newRenderer(window)
    toon = newToonContext()
    manifest = readManifest(ChargenLibrary)
    model = readCharacter(ChargenLibrary, manifest)
    player = newClipPlayer(model.root)
    actors = readLineup(ChargenLibrary, manifest, model.root, "Gnomes")
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
      toon.transform = translate(vec3(
        if details: (if i == 2: -1.15'f else: 1.15'f)
        else: (i mod 3 - 1).float32 * 3.45,
        if details: 0'f else: (2 - i div 3).float32 * 4.05,
        0
      )) * rotateY(angle)
      actor.root.updateTransforms(toon.transform)
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
    shot.writeFile(Output / (if details: "details_" & filename else: filename))
    window.swapBuffers()
    inc frame
    if frame == 5:
      quit(0)
  while not window.closeRequested:
    pollEvents()

run()
