import
  std/[os, sets],
  chroma, gltf, jsony, opengl, pixie, vmath, windy,
  polyworld/[animblend, chargen, toon]

const
  RenderSize = 1024
  Clips = ["A_TPose", "Walk_Loop"]

type
  Preview = object
    slug, family, weapons: string
    rank: int
    scale: float32
    skinRgb: seq[float32]
    preset: Preset
    missing: seq[string]
  Roster = object
    entries, heroes: seq[Preview]
  Measurement = object
    name: string
    triangles, meshes: int
    scale: float32
  Review = object
    mobs, heroes: seq[Measurement]

proc readRoster(path: string): Roster =
  ## Reads draft selections without changing the shared library manifest.
  try:
    result = readFile(path).fromJson(Roster)
  except IOError, JsonError:
    raise newException(
      ChargenError, "Cannot read CTA selections: " & getCurrentExceptionMsg()
    )

proc measure(root: Node, preview: Preview): Measurement =
  ## Counts the visible existing geometry selected for one equipped character.
  result.name = preview.preset.name
  result.scale = preview.scale
  for node in root.walkNodes:
    if node.mesh == nil or not node.visible:
      continue
    inc result.meshes
    for primitive in node.mesh.primitives:
      result.triangles +=
        (primitive.indices16.len + primitive.indices32.len) div 3

proc capture(
  window: Window,
  renderer: Renderer,
  toon: ToonContext,
  root: Node,
  path: string
) =
  ## Captures the game renderer directly without synthetic image generation.
  for i in 0 ..< 2:
    renderer.beginFrame(window, window.size)
    renderer.clearScreen(color(0.91, 0.91, 0.89, 1))
    glEnable(GL_MULTISAMPLE)
    root.updateTransforms(toon.transform)
    toon.draw(root)
    renderer.endFrame()
    glFinish()
    if i == 1:
      let shot = newImage(window.size.x, window.size.y)
      glReadBuffer(GL_BACK)
      glReadPixels(
        0,
        0,
        window.size.x,
        window.size.y,
        GL_RGBA,
        GL_UNSIGNED_BYTE,
        shot.data[0].addr
      )
      shot.flipVertical()
      shot.writeFile(path)
    window.swapBuffers()
    pollEvents()

proc render(
  directory, output: string,
  manifest: Manifest,
  previews: seq[Preview],
  window: Window,
  renderer: Renderer,
  toon: ToonContext
): seq[Measurement] =
  ## Assembles existing parts with supported tints and captures three views.
  for preview in previews:
    if preview.scale <= 0 or preview.skinRgb.len notin [0, 3]:
      raise newException(ChargenError, "Invalid preview: " & preview.slug)
    let
      inventory = manifest.presetManifest(preview.preset)
      model = readPresetCharacter(directory, manifest, preview.preset, Clips)
      nodes = partNodes(model.root)
      player = newClipPlayer(model.root)
    if preview.skinRgb.len == 3:
      nodes.applySkin(inventory, color(
        preview.skinRgb[0],
        preview.skinRgb[1],
        preview.skinRgb[2],
        1
      ))
    toon.unlitNodes.clear()
    for category in inventory.categories:
      if category.key in ["Eyes", "Mouth", "Brow"]:
        for item in category.items:
          for name in item.nodes:
            toon.unlitNodes.incl name
    for view in ["front", "back", "walk"]:
      player.play(if view == "walk": "Walk_Loop" else: "A_TPose", 0)
      player.seek(if view == "walk": 0.35'f else: 0'f)
      let angle = if view == "back": PI.float32 + 0.18'f else: 0.18'f
      toon.transform = rotateY(angle) * scale(vec3(preview.scale))
      capture(
        window,
        renderer,
        toon,
        model.root,
        output / (preview.slug & "_" & view & ".png")
      )
    result.add measure(model.root, preview)
    echo preview.preset.name, ": ", result[^1].triangles, " triangles"
    renderer.release(model.root)

proc main() =
  ## Renders a reproducible CTA roster from draft recipes and existing assets.
  if paramCount() != 2:
    raise newException(
      ChargenError, "Usage: render_cta <existing_presets.json> <output>"
    )
  let
    roster = readRoster(paramStr(1))
    directory = getEnv("CHARGEN_LIBRARY", ChargenLibrary)
    output = paramStr(2)
    manifest = readManifest(directory)
    window = newWindow(
      "CTA existing asset review",
      ivec2(RenderSize, RenderSize),
      visible = false,
      vsync = false,
      msaa = msaa4x
    )
  createDir(output)
  makeContextCurrent(window)
  loadExtensions()
  let
    renderer = newRenderer(window)
    toon = newToonContext()
  toon.setPalette(ToonPalettes[0])
  toon.rimColor = color(1, 1, 1, 0)
  toon.lightDirection = -normalize(vec3(-0.6, 0.5, 0.7))
  toon.cameraPosition = vec3(0, 0, 16)
  toon.view = lookAt(toon.cameraPosition, vec3(0), vec3(0, 1, 0))
  toon.proj = ortho(-3.5'f, 3.5'f, -0.4'f, 6.6'f, 0.02'f, 100'f)
  let review = Review(
    mobs: render(
      directory, output, manifest, roster.entries, window, renderer, toon
    ),
    heroes: render(
      directory, output, manifest, roster.heroes, window, renderer, toon
    )
  )
  writeFile(output / "geometry.json", review.toJson())
  renderer.shutdown()
  window.close()

main()
