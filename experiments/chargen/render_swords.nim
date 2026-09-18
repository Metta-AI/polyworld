import
  std/[os, sets, strformat, strutils, tables],
  chroma, gltf, opengl, pixie, vmath, windy,
  polyworld/[animblend, chargen, toon], lineups

proc run() =
  ## Captures both creeps at identical attack times from three fixed views.
  let
    directory = getEnv("CHARGEN_LIBRARY", ChargenLibrary)
    output = getEnv("REVIEW_OUTPUT", "tmp/chargen/swords")
    manifest = readManifest(directory)
    gripOnly = getEnv("REVIEW_GRIP", "0") == "1"
    window = newWindow(
      "Creep sword review", ivec2(1800, 1200),
      vsync = false, msaa = msaa4x
    )
  createDir(output)
  makeContextCurrent(window)
  loadExtensions()
  let
    renderer = newRenderer(window)
    toon = newToonContext()
  var
    models: seq[GltfFile]
    players: seq[ClipPlayer]
    times: seq[float32]
  for value in getEnv("REVIEW_TIMES", "0.2,0.4,0.6,0.8,1.0").split(','):
    times.add parseFloat(value).float32
  for name in ["Blue Creep", "Purple Creep"]:
    for preset in manifest.presets:
      if preset.name != name:
        continue
      var inventory = manifest.presetManifest(preset)
      if getEnv("REVIEW_ORIGINAL", "0") == "1":
        for category in inventory.categories.mitems:
          for item in category.items.mitems:
            item.attachmentRotation = [0'f, 0'f, 0'f]
      if existsEnv("REVIEW_ROTATION"):
        let angles = getEnv("REVIEW_ROTATION").split(',')
        if angles.len != 3:
          raise newException(ChargenError, "REVIEW_ROTATION needs XYZ degrees.")
        for category in inventory.categories.mitems:
          if category.key == "Right hand":
            for item in category.items.mitems:
              for i in 0 ..< 3:
                item.attachmentRotation[i] = parseFloat(angles[i]).float32
      for clip in manifest.clips:
        if clip.name == "Sword_Attack":
          inventory.clips.add clip
      let
        model = readCharacter(directory, inventory)
        nodes = partNodes(model.root)
        player = newClipPlayer(model.root)
      nodes.applySelection(inventory, inventory.defaultSelection())
      nodes.applySkin(inventory, preset.skin)
      var eyes = readEyeTextures(model.root, directory, inventory)
      eyes.applyPupilTint(manifest.pupilColors[
        manifest.pupilColors.colorIndex(preset.pupilColor)
      ].rgb)
      for category in inventory.categories:
        if category.key in ["Eyes", "Mouth", "Brow"]:
          for item in category.items:
            for node in item.nodes:
              toon.unlitNodes.incl node
      player.play("Sword_Attack", 0)
      models.add model
      players.add player
  toon.setPalette(ToonPalettes[0])
  toon.rimColor = color(1, 1, 1, 0)
  toon.lightDirection = -normalize(vec3(-0.6, 0.5, 0.7))
  toon.transform = mat4()
  var frame = 0
  window.onFrame = proc() =
    ## Draws front, right side, and top without changing the evaluated pose.
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.72, 0.71, 0.69, 1))
    glEnable(GL_MULTISAMPLE)
    for row, model in models:
      players[row].seek(times[frame])
      model.root.updateTransforms()
      var center = vec3(0, 1.7, 0)
      if gripOnly:
        let
          slug = if row == 0: "vanguard_knight" else: "death_knight"
          sword = partNodes(model.root)["GotaWeapon_" & slug & "_right_hand"]
        for i, joint in sword.skin.joints:
          if joint.name == "RightHand":
            center = joint.mat * sword.skin.inverseBindMatrices[i] *
              vec3(-1.13, 1.73, 0.025)
      for column in 0 ..< 3:
        glViewport((column * 600).GLint, ((1 - row) * 600).GLint, 600, 600)
        let
          direction = [vec3(0, 0, 1), vec3(1, 0, 0), vec3(0, 1, 0)][column]
          up = if column == 2: vec3(0, 0, -1) else: vec3(0, 1, 0)
        toon.cameraPosition = center + direction * 16
        toon.view = lookAt(toon.cameraPosition, center, up)
        let extent = if gripOnly: 0.5'f else: 2.3'f
        toon.proj = ortho(-extent, extent, -extent, extent, 0.02'f, 100'f)
        toon.draw(model.root)
    glViewport(0, 0, window.size.x.GLsizei, window.size.y.GLsizei)
    renderer.endFrame()
    let shot = newImage(window.size.x, window.size.y)
    glReadPixels(
      0, 0, window.size.x, window.size.y,
      GL_RGBA, GL_UNSIGNED_BYTE, shot.data[0].addr
    )
    shot.flipVertical()
    shot.writeFile(output / &"attack_{times[frame]:.3f}.png")
    window.swapBuffers()
    inc frame
    if frame == times.len:
      quit(0)
  while not window.closeRequested:
    pollEvents()

run()
