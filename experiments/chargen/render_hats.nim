import
  std/[os, sets, strutils, tables],
  chroma, gltf, opengl, pixie, vmath, windy,
  polyworld/[animblend, chargen, toon], lineups

const Output = currentSourcePath().parentDir.parentDir.parentDir /
  "tmp/chargen/hats"

proc run() =
  ## Renders the actual swappable hats from front, side, and back for review.
  createDir(Output)
  let window = newWindow(
    "Gnome hat review", ivec2(1400, 1500), vsync = false, msaa = msaa4x
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
      if name in ["Body", "Hand.Left", "Hand.Right", "Foot.Left", "Foot.Right"] or
        name.startsWith("Clothing_") or name.startsWith("Gnome_"):
          node.visible = false
          node.baseVisible = false
      if name.startsWith("Eyes_") or name.startsWith("Mouth_") or
        name.startsWith("Brow_"):
          toon.unlitNodes.incl name
  toon.setPalette(ToonPalettes[0])
  toon.rimColor = color(1, 1, 1, 0.15)
  toon.cameraPosition = vec3(0, 5.23, 16)
  toon.view = lookAt(toon.cameraPosition, vec3(0, 5.23, 0), vec3(0, 1, 0))
  toon.proj = ortho(-3.715'f, 3.715'f, -3.98'f, 3.98'f, 0.02'f, 100'f)
  toon.lightDirection = -normalize(vec3(-0.6, 0.5, 0.7))
  var frame = 0
  window.onFrame = proc() =
    ## Captures consistent lit geometry views without changing library assets.
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.18, 0.20, 0.23, 1))
    glEnable(GL_MULTISAMPLE)
    let angle = [0'f, 1.30'f, PI.float32][frame]
    for i, actor in actors:
      toon.transform = translate(vec3(
        (i mod 3 - 1).float32 * 2.25,
        (2 - i div 3).float32 * 2.55,
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
    shot.writeFile(Output / ["front.png", "side.png", "back.png"][frame])
    window.swapBuffers()
    inc frame
    if frame == 3:
      quit(0)
  while not window.closeRequested:
    pollEvents()

run()
