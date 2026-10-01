## What every game mode shares: the window, the renderers, the heroes and
## the class choice. A mode is a client of the core that presents its match
## with these.
import std/[math, options, os]
import chroma, opengl, pixie, silky, vmath, windy
import core/sim, core/sessions, ui/cardfaces, scene/cardrenderer,
  vfx/vfxrenderer, scene/post, scene/table, scene/courtyard, scene/heroes,
  ui/hud, paths
import polyworld/[assets, characters, chargen, chrome, common, viewers]

const
  WindowTitle = "AWM — Archers Warriors Mages"
  CameraNear* = 0.1'f32
  CameraFar* = 100.0'f32
  ClassChoiceEye* = vec3(0, 6.2, 13.5)
  ClassChoiceTarget* = vec3(0, 1.0, 0)

when PostLayerControls:
  const PostLayerKeys*: array[PostLayer, Button] =
    [Key1, Key2, Key3, Key4, Key5, Key6, Key7, Key8, Key9, Key0]


type
  App* = ref object
    options*: SessionOptions
    appDir*: string  ## The project folder: players/, the atlas, screenshots.
    window*: Window
    sk*: Silky
    solid*: SolidRenderer
    cards*: CardRenderer
    vfx*: VfxRenderer
    post*: PostFx
    courtyard*: CourtyardRenderer
    scene*: CharacterScene
    models*: array[HeroSeats, array[HeroClass, CharacterModel]]
    idleClips*: array[HeroSeats, array[HeroClass, int]]
    deathClips*: array[HeroSeats, array[HeroClass, int]]

proc polyworldRoot(): string =
  var candidates: seq[string]
  let configured = getEnv("POLYWORLD_REPO")
  if configured.len > 0:
    candidates.add configured
  let appDir = getAppDir()
  for base in [appDir, getCurrentDir()]:
    candidates.add base / ".." / ".."
  candidates.add getCurrentDir()
  for candidate in candidates:
    let root = absolutePath(candidate)
    if fileExists(root / "src" / "polyworld" / "common.nim") and
        dirExists(root / ".." / "polyworld_art"):
      return root

proc lightLikeCourtyard*(scene: CharacterScene, cameraSide: float32) =
  ## Gives the heroes the courtyard's lighting: a cool hemisphere ambient,
  ## the same warm key from the same direction, and a moonlit rim that
  ## keeps a dark silhouette readable against dark stone. Call after
  ## beginCharacters, which sets the shared defaults.
  let
    context = scene.context
    # Heroes have no mapped relief, so they take less fill and a stronger
    # key than the stone: shape has to come from the light alone.
    ambient = (CourtyardAmbientGround + CourtyardAmbientSky) * 0.30'f32
    key = CourtyardKeyColor * 1.15'f32
    keyDirection = courtyardKeyDirection(cameraSide)
  context.ambientLightColor =
    color(ambient.x, ambient.y, ambient.z, 1.0)
  # The PBR shader negates the light vectors.
  context.sunLightDirection = -keyDirection
  context.sunLightColor = color(key.x, key.y, key.z, 1.0)
  context.rimLightDirection =
    normalize(vec3(-keyDirection.x, 0.35, -keyDirection.z))
  context.rimLightColor = color(0.55, 0.62, 0.78, 0.30)
  # A daylight probe would wash out a night courtyard, and a hot specular
  # on a hero's head would feed the bloom.
  context.environmentMapStrength = 0.25
  context.exposure = 0.9

proc initApp*(sessionOptions: SessionOptions): App =
  ## Opens the window and loads everything the modes draw with.
  when defined(emscripten):
    let appDir = "/"
    setCurrentDir("/")
  else:
    # The project folder (with players/), one up from src/.
    const sourceDir = currentSourcePath().parentDir.parentDir
    let
      appDir =
        if dirExists(getAppDir() / "players"): getAppDir()
        elif dirExists(sourceDir / "players"): sourceDir
        else: getAppDir()
      root = polyworldRoot()
    if root.len == 0:
      raise newException(IOError,
        "Could not find Polyworld. Set POLYWORLD_REPO to its repository root.")
    setCurrentDir(root)

  let
    cardAssets = artworkRoot() / "cards"
    atlasPath = appDir / "awm.atlas.png"
    atlasBuilder = newHudAtlas(4096)
  initCardAssets(cardAssets)
  atlasBuilder.addBaseCardImages()
  atlasBuilder.addAwmHudAssets(cardAssets)
  when PostPanelControls:
    # Silky's widget images, for the screen-effects tuning window.
    const EditorTheme = DataRoot & "/themes/editor/"
    atlasBuilder.addDir(EditorTheme, EditorTheme)
  atlasBuilder.addFont(cardAssets / "fonts/Grenze-SemiBold.ttf", "H1", 60.0)
  atlasBuilder.addFont(DefaultFontPath, "Default", 34.5)
  atlasBuilder.addFont(DefaultFontPath, "Hud", 28.5)
  atlasBuilder.addFont(DefaultFontPath, "Small", 22.5)
  atlasBuilder.write(atlasPath)

  var window: Window
  var sk: Silky
  (window, sk) = initGameWindow(
    WindowTitle,
    atlasPath,
    ivec2(3200, 2000),
    vsync = true
  )

  var
    solid = initSolidRenderer()
    cardSurfaces = initCardRenderer()
    vfx = initVfxRenderer(cardAssets.parentDir / "vfx" / "textures")
    post = initPostFx()
  var courtyard = initCourtyardRenderer(sessionOptions.playerCount)
  let scene = newCharacterScene(window)
  # AWM lights heroes with the courtyard's own night rig, not the shared
  # toon ramp: see lightLikeCourtyard.
  scene.shading = PbrCharacters
  var
    models: array[HeroSeats, array[HeroClass, CharacterModel]]
    idleClips: array[HeroSeats, array[HeroClass, int]]
    deathClips: array[HeroSeats, array[HeroClass, int]]
  let
    heroManifest = readManifest(ChargenLibrary)
    heroPresets = readHeroPresets()
  for seat in 0 ..< HeroSeats:
    for heroClass in HeroClass:
      models[seat][heroClass] = heroManifest.loadHeroModel(
        heroPresets[seat][heroClass], heroClass)
      idleClips[seat][heroClass] =
        models[seat][heroClass].clipIndex(HeroIdleClips[heroClass])
      deathClips[seat][heroClass] =
        models[seat][heroClass].clipIndex(HeroDeathClip)
  App(options: sessionOptions, appDir: appDir, window: window, sk: sk,
    solid: solid, cards: cardSurfaces, vfx: vfx, post: post,
    courtyard: courtyard, scene: scene, models: models,
    idleClips: idleClips, deathClips: deathClips)

proc heroClip*(app: App, model: int, heroClass: HeroClass,
    dying, idleTime: float32): tuple[clip: int, time: float32] =
  ## Idle while alive; once dying, the death clip, held on its last
  ## frame.
  if dying < 0:
    (app.idleClips[model][heroClass], idleTime)
  else:
    let clip = app.deathClips[model][heroClass]
    (clip, min(dying,
      app.models[model][heroClass].clipDuration(clip) - 0.001'f32))

# The class choice, shared by every mode.

proc addClassStage*(app: App) =
  app.solid.addBox(
    vec3(0, -0.3, 0),
    vec3(15, 0.55, 7),
    vec4(0.20, 0.24, 0.30, 1),
    sideFactor = 0.5
  )
  for heroClass in HeroClass:
    let x = (heroClass.ord.float32 - 1.0'f32) * 4.2'f32
    app.solid.addBox(
      vec3(x, 0.05, 0),
      vec3(3.0, 0.18, 3.0),
      heroClass.classColor().darker(0.72),
      sideFactor = 0.55
    )

proc drawClassHeroes*(app: App, selected: HeroClass, time: float32) =
  for heroClass in HeroClass:
    let
      x = (heroClass.ord.float32 - 1.0'f32) * 4.2'f32
      chosen = selected == heroClass
    drawCharacter(
      app.scene,
      app.models[0][heroClass],
      vec3(x, 0.15, 0),
      0,
      app.idleClips[0][heroClass],
      time,
      tint =
        if chosen:
          color(1.08, 1.08, 1.08, 1)
        else:
          color(1, 1, 1, 1),
      sizeFactor = if chosen: 1.06'f32 else: 1.0'f32
    )

proc drawClassHeader*(app: App, human: bool) =
  let (sk, window) = (app.sk, app.window)
  sk.drawRect(
    vec2(0),
    vec2(hudSize(window).x, 180),
    rgbx(14, 17, 24, 238)
  )
  sk.drawLabel(
    "ARCHERS | WARRIORS | MAGES",
    vec2(0, 15),
    vec2(hudSize(window).x, 78),
    rgbx(243, 218, 153, 255),
    "H1",
    CenterAlign
  )
  sk.drawLabel(
    (if human: "CHOOSE YOUR CLASS"
     else: "BOTS ARE CHOOSING CLASSES..."),
    vec2(0, 104),
    vec2(hudSize(window).x, 48),
    rgbx(221, 225, 233, 255),
    "Default",
    CenterAlign
  )

proc classButtons*(app: App): Option[HeroClass] =
  ## The human's class buttons; returns the class clicked this frame.
  let (sk, window) = (app.sk, app.window)
  for heroClass in HeroClass:
    let
      x = hudSize(window).x * 0.5'f32 +
        (heroClass.ord.float32 - 1.0'f32) * 400.0'f32
      rect = UiRect(
        origin: vec2(x - 140, hudSize(window).y - 180),
        size: vec2(280, 84)
      )
    if drawButton(
        sk,
        window,
        rect,
        heroClass.className()
    ):
      result = some(heroClass)

template bindApp*(app: App) {.dirty.} =
  ## Names a mode's loop uses for the shared app, so it reads like the rest
  ## of its code: `window`, `sk`, `solid`, `vfx`, `post`...
  let
    window = app.window
    sk = app.sk
    scene = app.scene
    sessionOptions = app.options
    appDir = app.appDir
  template solid: untyped = app.solid
  template cardSurfaces: untyped = app.cards
  template vfx: untyped = app.vfx
  template post: untyped = app.post
  template courtyard: untyped = app.courtyard
  template models: untyped = app.models
  const
    classChoiceEye = ClassChoiceEye
    classChoiceTarget = ClassChoiceTarget
  proc heroClip(model: int, heroClass: HeroClass,
      dying, idleTime: float32): tuple[clip: int, time: float32] =
    app.heroClip(model, heroClass, dying, idleTime)
  proc addClassStage() = app.addClassStage()
  proc drawClassHeroes(selected: HeroClass, time: float32) =
    app.drawClassHeroes(selected, time)
  proc drawClassHeader(human: bool) = app.drawClassHeader(human)
  proc classButtons(): Option[HeroClass] = app.classButtons()
