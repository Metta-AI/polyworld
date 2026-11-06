## Execute the production input routines without loading all match art.
## AST extraction keeps this fixture tied to the real nested graphics handlers.
import std/[unittest, macros, importutils]
import windy/internal
include ../graphics
privateAccess(Window)

macro graphicsRoutine(name: static[string]): untyped =
  let source = parseStmt(staticRead("../graphics.nim"))
  for node in source:
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkAsgn and child[1].kind == nnkLambda and
            ((name == "buttonHandler" and child[0].repr == "window.onButtonPress") or
             (name == "releaseHandler" and child[0].repr == "window.onButtonRelease")):
          return child
        if child.kind == nnkProcDef and child[0].repr == name:
          return child
  error("Missing production routine: " & name)

suite "LvD match menu input isolation":
  setup:
    resetHumanCommunication()
  teardown:
    resetHumanCommunication()

  test "menu frames ignore held camera, selection, minimap and zoom input":
    window = newWindow("LvD input regression", ivec2(1600, 1000), visible = false)
    defer:
      window.close()
      window = nil
      run = nil
    # Focus is an independent production input gate. Keep it open so these
    # assertions exercise the menu gate, not hidden-window cancellation.
    # AppKit key-window activation is unavailable on unattended hosts.
    sk = Silky(uiScale: 1)
    options.playerSlot = 1
    run = Game(world: newWorld(generateMap(47, 3), 100))
    var
      matchMenu = HiddenMatchMenu
      actionCam = initActionCam(subjectMode = true)
    actionCam.takeManual()
    graphicsRoutine("playerMode")
    graphicsRoutine("selectionTarget")
    graphicsRoutine("selectedCount")
    graphicsRoutine("clearSelection")
    graphicsRoutine("selectAllUnits")
    graphicsRoutine("pruneSelection")
    graphicsRoutine("selectedCenter")
    graphicsRoutine("selectedRadius")
    graphicsRoutine("updateCamera")

    let mini = attackMinimapArea(currentLayout(window))
    for page in [PauseMenu, MatchSettings]:
      for onMinimap in [false, true]:
        matchMenu = page
        cameraTarget = vec3(2, 0, 3)
        cameraDistance = 40
        followSelection = false
        selectedIds = @[run.world.units[0].id]
        primaryId = selectedIds[0]
        let beforeSelection = @selectedIds
        selectionStarted = true
        selectionAdditive = true
        panning = true
        minimapPanning = true
        rightOrderStarted = true
        lineGesture = LineGesture(active: true, dragging: true)
        sk.mousePos = if onMinimap: mini.origin + mini.size * 0.75'f32
          else: vec2(800, 500)
        window.state.mousePos = ivec2(sk.mousePos.x.int32, sk.mousePos.y.int32)
        window.state.buttonDown = {MouseLeft, MouseMiddle, KeyLeftControl, KeyRight}
        window.state.perFrame = PerFrame(
          buttonPressed: {MouseLeft, MouseMiddle, KeyA},
          mouseDelta: ivec2(100, 80), scrollDelta: vec2(0, 3))
        updateCamera(0.1, focused = true)
        check cameraTarget == vec3(2, 0, 3)
        check cameraDistance == 40
        check selectedIds == beforeSelection
        check not selectionStarted
        check not selectionAdditive
        check not panning
        check not minimapPanning
        check not rightOrderStarted
        check not lineGesture.active
        # Releasing after the menu closes must not revive a stale gesture.
        matchMenu = HiddenMatchMenu
        window.state.buttonDown = {}
        window.state.perFrame = PerFrame(buttonReleased: {MouseLeft, MouseMiddle})
        updateCamera(0.1, focused = true)
        check not selectionStarted
        check not panning
        check not minimapPanning

    # A fresh minimap click still works in normal gameplay.
    window.state.buttonDown = {MouseLeft}
    window.state.perFrame = PerFrame(buttonPressed: {MouseLeft})
    sk.mousePos = mini.origin + mini.size * 0.75'f32
    updateCamera(0.1, focused = true)
    check minimapPanning
    check cameraTarget != vec3(2, 0, 3)
    # The explicit focus seam also verifies the production loss-of-focus gate.
    let focusedCamera = cameraTarget
    selectionStarted = true
    lineGesture = LineGesture(active: true, dragging: true)
    updateCamera(0.1, focused = false)
    check cameraTarget == focusedCamera
    check not selectionStarted
    check not minimapPanning
    check not lineGesture.active

  test "menu entry cancels immediately and menu/UI bindings remain usable":
    window = newWindow("LvD menu bindings", ivec2(1600, 1000), visible = false)
    defer:
      window.close()
      window = nil
      run = nil
      debugMenuOpen = false
    sk = Silky(uiScale: 1)
    run = Game()
    options.playerSlot = 1
    var
      matchMenu = HiddenMatchMenu
      preferences: Preferences
      network: NetworkMatch
      scene: CharacterScene
      actionCam = initActionCam(subjectMode = true)
    graphicsRoutine("playerMode")
    graphicsRoutine("buttonHandler")
    graphicsRoutine("releaseHandler")
    proc tap(button: Button) =
      window.state.buttonDown.incl button
      window.onButtonPress(button)
      window.state.buttonDown.excl button
      window.onButtonRelease(button)

    pendingBuild = -1
    attackMoveArmed = false
    selectionStarted = true
    selectionAdditive = true
    panning = true
    minimapPanning = true
    rightOrderStarted = true
    lineGesture.cancelLine()
    tap(KeyEscape)
    check matchMenu == PauseMenu
    check not selectionStarted
    check not selectionAdditive
    check not panning
    check not minimapPanning
    check not rightOrderStarted
    # No frame occurs between opening and closing the menu.
    tap(KeyEscape)
    check matchMenu == HiddenMatchMenu
    check not selectionStarted
    matchMenu = MatchSettings
    debugMenuOpen = false
    tap(KeyF1)
    check debugMenuOpen
    tap(KeyEscape)
    check matchMenu == PauseMenu
    tap(KeyEscape)
    check matchMenu == HiddenMatchMenu
    # Existing Esc-cancels-command behavior still precedes opening the menu.
    lineGesture = LineGesture(active: true, dragging: true)
    rightOrderStarted = true
    tap(KeyEscape)
    check matchMenu == HiddenMatchMenu
    check not lineGesture.active
    check not rightOrderStarted
