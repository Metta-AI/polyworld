## A runnable game UI built from the same Silky controls on desktop and WebGL.
import std/[json, unicode]
import bumpy, chroma, pixie, vmath, silky
import polyworld/gameuis

type GalleryState* = object
  tab*: int
  theme*: string
  playerName*: string
  showHints*: bool
  volume*: float32
  difficulty*: string
  claimed*: bool
  inspected*: bool
  crossingFound*: bool

proc newGalleryState*(): GalleryState =
  GalleryState(theme: "Midnight", playerName: "Mira", showHints: true,
    volume: 0.7, difficulty: "Normal")

proc galleryPanels*(size: Vec2): tuple[header, nav, content: GameUiPanel] =
  let layout = initGameUiLayout(size, margin = 16)
  let area = layout.gameArea
  result.header = area.fitPanel(vec2(24, 20), vec2(size.x - 48, 80))
  result.nav = area.fitPanel(vec2(24, 110), vec2(size.x - 48, 54))
  result.content = area.fitPanel(vec2(24, 176), vec2(size.x - 48, size.y - 200))

proc drawGallery*(sk: Silky, window: Window, state: var GalleryState) =
  let
    panels = galleryPanels(window.size.vec2 / sk.uiScale)
    paper = state.theme == "Parchment"
    background = if paper: rgbx(225, 216, 194, 255) else: rgbx(17, 26, 35, 255)
    foreground = if paper: rgbx(42, 46, 45, 255) else: rgbx(235, 239, 234, 255)
    muted = if paper: rgbx(78, 87, 80, 255) else: rgbx(164, 185, 188, 255)
  sk.theme.textColor = foreground
  sk.theme.textH1Color = foreground
  sk.theme.defaultTextColor = rgbx(235, 239, 234, 255)
  sk.clearScreen(background)
  ui:
    group "heading":
      box panels.header.origin.x, panels.header.origin.y, panels.header.size.x, panels.header.size.y
      text "title":
        characters "The Wayfarer's Journal"
        font (if panels.header.size.x < 400: "Default" else: "H1")
        tint foreground
      text "subtitle":
        characters "A place for your next adventure."
        tint muted
    group "navigation":
      box panels.nav.origin.x, panels.nav.origin.y, panels.nav.size.x, panels.nav.size.y
      layout LeftToRight
      itemSpacing 12
      button "Character": state.tab = 0
      button "Settings": state.tab = 1
      button "Quest": state.tab = 2
    frame "content":
      box panels.content.origin.x, panels.content.origin.y, panels.content.size.x, panels.content.size.y
      # Native scrollbars own overflow when the window is shorter than the content.
      horizontalPadding 18
      verticalPadding 18
      itemSpacing 12
      case state.tab
      of 0:
        h1text "Mira / Pathfinder"
        text "Explorer of the northern wilds."
        group "health":
          box 260, 30
          layout LeftToRight
          icon "heart"
          text "Health  /  84 of 100"
        progressBar 84, 0, 100
        text "Equipment"
        group "equipment":
          hugHeight()
          fillWidth()
          itemSpacing 8
          button "Inspect Wayfinder's Compass": state.inspected = not state.inspected
          button "Upgrade (requires 50 gold)", false: discard
        if state.inspected:
          text "compass detail":
            characters "A brass compass.\nIts needle always points home."
        text "Portrait alignment":
          fillWidth()
          characters "EXPLORER  /  LEVEL 12"
          textAlign RightAlign
      of 1:
        h1text "Your settings"
        text "Player name"
        textInput "player-name", state.playerName
        checkBox "Show interaction hints", state.showHints
        text "Volume"
        scrubber "volume", state.volume, 0'f32, 1'f32, "Volume"
        text "Difficulty"
        dropDown state.difficulty, ["Easy", "Normal", "Hard"]
        text "Appearance"
        dropDown state.theme, ["Midnight", "Parchment"]
      else:
        h1text "The old watchtower"
        text "quest description":
          characters "Follow the river.\nFind the old watchtower.\nSpeak to its keeper.\nReturn with news."
          fillWidth()
        text "Objectives"
        checkBox "Find the river crossing", state.crossingFound
        text "Reward / 25 gold + travel ration"
        button "Claim reward", not state.claimed:
          state.claimed = true
        if state.claimed:
          text "Reward claimed.\nReady for the next adventure."
        for name in ["River crossing", "The mossy stair", "Keeper's door", "North road", "Return to camp"]:
          text name

proc gallerySnapshot*(state: GalleryState, size: Vec2): JsonNode =
  let panels = galleryPanels(size)
  %* {"tab": state.tab, "theme": state.theme, "playerName": state.playerName,
    "hints": state.showHints, "volume": state.volume, "difficulty": state.difficulty,
    "claimed": state.claimed, "inspected": state.inspected,
    "width": size.x, "height": size.y,
    "content": {"x": panels.content.origin.x, "y": panels.content.origin.y,
      "width": panels.content.size.x, "height": panels.content.size.y}}

when isMainModule:
  let window = newWindow("Polyworld UI gallery", ivec2(960, 720), vsync = true)
  window.makeContextCurrent()
  loadExtensions()
  let sk = newSilky(window, "tmp/ui-gallery/atlas.png")
  var state = newGalleryState()
  window.runeInputEnabled = true
  window.onRune = proc(rune: Rune) = sk.inputRunes.add(rune)
  var frame = 0
  window.onFrame = proc() =
    inc frame
    if window.buttonPressed[MouseLeft] or window.buttonReleased[MouseLeft]:
      echo "Pointer ", window.mousePos, " pressed=", window.buttonPressed[MouseLeft], " released=", window.buttonReleased[MouseLeft]
    sk.beginUI(window, window.size)
    sk.drawGallery(window, state)
    sk.endUi()
    window.swapBuffers()
    when defined(emscripten):
      proc runScript(script: cstring) {.importc: "emscripten_run_script", header: "<emscripten.h>".}
      var snapshot = state.gallerySnapshot(window.size.vec2)
      snapshot["frame"] = %frame
      runScript(("window.__polyworldUiGalleryState = " & $snapshot &
        "; window.__polyworldUiGallery = {snapshot: () => window.__polyworldUiGalleryState};").cstring)
  while not window.closeRequested:
    pollEvents()
