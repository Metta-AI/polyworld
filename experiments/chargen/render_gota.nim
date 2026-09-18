import
  std/[os, sets, strutils, tables],
  chroma, gltf, opengl, pixie, vmath, windy,
  polyworld/[animblend, chargen, toon], lineups

proc run() =
  ## Renders a preset with isolated clothing, equipment, or head details.
  let
    directory = getEnv("CHARGEN_LIBRARY", ChargenLibrary)
    output = getEnv("REVIEW_OUTPUT", "tmp/chargen/gota/review")
    manifest = readManifest(directory)
    presetName = getEnv("REVIEW_PRESET", manifest.presets[0].name)
    equipment = getEnv("REVIEW_EQUIPMENT", "0") == "1"
    headOnly = getEnv("REVIEW_HEAD", "0") == "1"
    smoothLighting = getEnv("REVIEW_PBR", "0") == "1"
    angle = parseFloat(getEnv("REVIEW_ANGLE", "0")).float32
  var
    preset: Preset
    found = false
  for candidate in manifest.presets:
    if candidate.name == presetName:
      preset = candidate
      found = true
  if not found:
    raise newException(ChargenError, "Unknown review preset: " & presetName)
  var inventory = manifest.presetManifest(preset)
  for clip in manifest.clips:
    if clip.name in ["A_TPose", "Walk_Loop", "Crouch_Fwd_Loop"]:
      inventory.clips.add clip
  let
    window = newWindow(
      "Gota clothing review", ivec2(1600, 1100),
      vsync = false, msaa = msaa4x
    )
  createDir(output)
  makeContextCurrent(window)
  loadExtensions()
  let
    renderer = newRenderer(window)
    toon = newToonContext()
    pbr = newPbrContext(renderer)
    model = readCharacter(directory, inventory)
    nodes = partNodes(model.root)
    player = newClipPlayer(model.root)
  nodes.applySelection(inventory, inventory.defaultSelection())
  nodes.applySkin(inventory, preset.skin)
  var clothes = initClothMaterials(nodes, inventory)
  clothes.applyClothPreset(preset)
  let hair = manifest.hairColors.colorIndex(preset.hairColor)
  initHairMaterials(nodes, inventory).applyHairTint(
    manifest.hairColors[hair].rgb
  )
  initBrowMaterials(model.root, inventory).applyBrowTint(
    manifest.hairColors[hair].rgb
  )
  var eyes = readEyeTextures(model.root, directory, inventory)
  eyes.applyPupilTint(
    manifest.pupilColors[manifest.pupilColors.colorIndex(preset.pupilColor)].rgb
  )
  var
    original: Table[string, bool]
    categories: seq[string]
  for key in (if headOnly: @["Headgear"]
              elif equipment: @["Left hand", "Right hand", "Back"]
              else: @["Foot", "Leg", "Belt", "Chest", "Headgear"]):
    for category in inventory.categories:
      if category.key == key and category.items.len > 0:
        categories.add key
  var headNodes: HashSet[string]
  if headOnly:
    for category in inventory.categories:
      if category.key in ["Headgear", "Face", "Hair", "Beard", "Eyes",
                          "Mouth", "Nose", "Ears", "Brow"]:
        for item in category.items:
          for name in item.nodes:
            headNodes.incl name
  for name, node in nodes:
    original[name] = node.visible and (not headOnly or name in headNodes)
  for category in inventory.categories:
    if category.key in ["Eyes", "Mouth", "Brow"]:
      for item in category.items:
        for name in item.nodes:
          toon.unlitNodes.incl name
  toon.setPalette(ToonPalettes[0])
  toon.rimColor = color(1, 1, 1, 0)
  toon.lightDirection = -normalize(vec3(-0.6, 0.5, 0.7))
  pbr.size = window.size
  pbr.tint = color(1, 1, 1, 1)
  pbr.useTrs = true
  pbr.ambientLightColor = color(0.65, 0.67, 0.72, 0.65)
  pbr.sunLightDirection = toon.lightDirection
  pbr.sunLightColor = color(0.95, 0.96, 1, 1)
  pbr.rimLightDirection = normalize(vec3(-1, 1, -1))
  pbr.rimLightColor = color(0.95, 0.82, 0.66, 0.25)
  pbr.debugView = dvLit
  pbr.useShadows = false
  pbr.drawSkybox = false
  player.play("A_TPose", 0)
  player.seek(0)
  var frame = 0
  window.onFrame = proc() =
    ## Captures actual runtime meshes with the shared skin and animation code.
    let slot = frame - 3
    for name, node in nodes:
      node.visible = original[name]
      node.baseVisible = original[name]
    if frame >= 3:
      var kept: HashSet[string]
      for category in inventory.categories:
        if category.key == categories[slot]:
          for item in category.items:
            for name in item.nodes:
              kept.incl name
      for name, node in nodes:
        node.visible = name in kept
        node.baseVisible = node.visible
    player.play(
      if frame == 1: "Walk_Loop"
      elif frame == 2: "Crouch_Fwd_Loop"
      else: "A_TPose", 0
    )
    player.seek(if frame in [1, 2]: 0.35'f else: 0'f)
    var
      center = vec3(0, 1.7, 0)
      height = 3.8'f
      width = if equipment: 3.7'f else: 3.1'f
    if headOnly:
      center = vec3(0, 2.63, 0)
      height = 1.9
      width = 2.0
    if frame >= 3:
      var
        low = vec3(100, 100, 100)
        high = vec3(-100, -100, -100)
      for name, node in nodes:
        if node.visible:
          let bounds = node.getAABoundsNode()
          low = min(low, bounds.min)
          high = max(high, bounds.max)
      center = (low + high) / 2
      height = max(0.5'f, high.y - low.y) * 1.25
      width = max(0.6'f, high.x - low.x) * 1.20
    let
      halfWidth = max(width * 1.2'f, height * 1600 / 2200)
      halfHeight = halfWidth * 1100 / 1600
      separation = halfWidth * 0.51'f
    toon.cameraPosition = vec3(0, 0, 16)
    toon.view = lookAt(toon.cameraPosition, vec3(0, 0, 0), vec3(0, 1, 0))
    toon.proj = ortho(
      -halfWidth, halfWidth, -halfHeight, halfHeight, 0.02'f, 100'f
    )
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.72, 0.71, 0.69, 1))
    glEnable(GL_MULTISAMPLE)
    for i in 0 ..< 2:
      toon.transform = translate(vec3(
        if i == 0: -separation else: separation, 0, 0
      )) * rotateY(angle + (if i == 0: 0'f else: PI.float32)) *
        translate(-center)
      model.root.updateTransforms(toon.transform)
      if smoothLighting:
        pbr.view = toon.view
        pbr.proj = toon.proj
        pbr.cameraPosition = toon.cameraPosition
        pbr.transform = toon.transform
        pbr.draw(model.root)
      else:
        toon.draw(model.root)
    renderer.endFrame()
    let shot = newImage(window.size.x, window.size.y)
    glReadPixels(
      0, 0, window.size.x, window.size.y,
      GL_RGBA, GL_UNSIGNED_BYTE, shot.data[0].addr
    )
    shot.flipVertical()
    let name =
      if frame == 0: "model"
      elif frame == 1: "walk"
      elif frame == 2: "crouch"
      else: categories[slot].replace(' ', '_')
    shot.writeFile(output / (name & ".png"))
    window.swapBuffers()
    inc frame
    if frame == 3 + categories.len:
      quit(0)
  while not window.closeRequested:
    pollEvents()

run()
