## Native production graphics callbacks, not source-string route assertions.
## Separate from the art-free suite: creates a real Windy GL window.
import std/[macros, importutils]
import windy/internal
import polyworld/mailboxes
import ../presets
include ../graphics
privateAccess(Window)

proc renameDirector(node: NimNode): NimNode {.compileTime.} =
  if node.kind == nnkIdent and node.strVal == "actionCam": return ident("director")
  result = copyNimNode(node)
  for item in node: result.add renameDirector(item)

macro productionCallback(name: static[string]): untyped =
  for node in parseStmt(staticRead("../graphics.nim")):
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkAsgn and child[0].repr == "window." & name and
            child[1].kind == nnkLambda:
          return renameDirector(child)
  # Missing rune callback is deliberately a runtime assertion in RED.
  result = newStmtList()

macro productionRoutine(name: static[string]): untyped =
  for node in parseStmt(staticRead("../graphics.nim")):
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkProcDef and child[0].repr == name: return renameDirector(child)
  error("Missing production routine: " & name)

macro finishProductionUi(): untyped =
  proc search(node: NimNode): NimNode =
    if node.kind == nnkIfStmt and node.repr.contains(
        "window.runeInputEnabled = humanCommunicationTyping() and window.focused") and
        node[0][0].repr == "matchMenu == HiddenMatchMenu": return node
    for child in node:
      let found = search(child)
      if found != nil: return found
  result = search(parseStmt(staticRead("../graphics.nim")))
  if result == nil: error("Missing production post-Silky rune restoration")

window = newWindow("LvD communication callback regression", ivec2(1200, 800), visible = false)
window.makeContextCurrent()
loadExtensions()
glClearColor(0, 0, 0, 1)
let atlas = buildUiAtlas(factionOrder(DefaultSeed.int64))
sk = newSilky(window, atlas.atlasImage, atlas.atlas)
window.visible = true
pollEvents()
doAssert window.focused, "Camera polling regression needs a focused native window"
var config = defaultConfig(2)
config.maxTicks = 100
config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
run = newLocalMatch(config, ["", ""])
options.playerSlot = 1
for unit in run.world.units:
  if unit.owner == 0:
    selectedIds = @[unit.id]
    primaryId = unit.id
    break
var matchMenu = HiddenMatchMenu
var preferences = readLvdPreferences()
var director = initActionCam(subjectMode = true)
let network: NetworkMatch = nil
var scene: CharacterScene
productionRoutine("playerMode")
productionRoutine("selectionTarget")
productionRoutine("selectedCount")
productionRoutine("clearSelection")
productionRoutine("selectAllUnits")
productionRoutine("pruneSelection")
productionRoutine("selectedCenter")
productionRoutine("selectedRadius")
productionRoutine("updateCamera")
productionCallback("onButtonPress")
productionCallback("onButtonRelease")
productionCallback("onRune")
productionCallback("onFocusChange")
resetHumanCommunication()

proc press(button: Button) =
  window.state.buttonDown.incl button
  window.onButtonPress(button)
proc release(button: Button) =
  window.state.buttonDown.excl button
  window.onButtonRelease(button)

press(KeyEnter)
doAssert humanCommunicationBlocksGameplay(), "Enter must open chat through graphics callback"
doAssert window.onRune != nil, "Graphics must register rune callback"
doAssert window.runeInputEnabled, "Enter must request native rune input immediately"
release(KeyEnter)
sk.beginUi(window, window.size)
sk.endUi()
doAssert not window.runeInputEnabled, "Fixture must exercise Silky ending unused text capture"
finishProductionUi()
doAssert window.runeInputEnabled, "Graphics must restore capture after Silky"
for rune in "Hi 雪🙂".runes: window.onRune(rune)
let selectedBefore = selectedIds
let cameraBefore = cameraTarget
window.state.buttonDown = {KeyLeftControl, KeyA, KeyRight, MouseMiddle}
window.state.perFrame = PerFrame(buttonPressed: {KeyA, MouseMiddle})
updateCamera(1)
doAssert selectedIds == selectedBefore, "Polled Ctrl+A must not select while typing"
doAssert cameraTarget == cameraBefore and not panning, "Polled camera must not move while typing"
window.state.buttonDown = {}
window.state.perFrame = PerFrame()
let tilesBefore = showTiles
let playingBefore = transport.playing
for key in [KeyS, KeyB, KeyE, KeySpace, KeyA]:
  press(key)
  release(key)
doAssert showTiles == tilesBefore, "Typed E toggled terrain"
doAssert transport.playing == playingBefore, "Typed Space paused transport"
doAssert pendingBuild == -1 and not attackMoveArmed
run.networked = true
run.flushPlayerCommands()
doAssert run.submissions.len == 0, "Typed Stop/build must not queue gameplay commands"
run.networked = false
press(KeyEnter)
doAssert run.inboxes[1].count == 1, "Enter must send exactly one authoritative local chat"
press(KeyEnter) # OS auto-repeat cannot reopen chat or double-send.
doAssert run.inboxes[1].count == 1
release(KeyEnter)
doAssert run.inboxes[1].messages[run.inboxes[1].first] == "Hi 雪🙂"
doAssert run.inboxes[1].pop() == -2
doAssert humanCommunicationBlocksGameplay(), "Closing event must block this frame"
window.state.buttonDown = {KeyRight}
updateCamera(1)
doAssert cameraTarget == cameraBefore, "Sending must not release polling in the closing frame"
window.state.buttonDown = {}
finishHumanCommunicationFrame()
doAssert not humanCommunicationBlocksGameplay()
press(KeyEnter)
release(KeyEnter)
window.onRune(Rune('x'))
press(KeyEscape)
doAssert matchMenu == HiddenMatchMenu, "Escape cancels chat rather than opening pause"
release(KeyEscape)
finishHumanCommunicationFrame()
doAssert run.inboxes[1].count == 0
block diplomacyPanel:
  var colors = @[rgbx(230, 100, 100, 255), rgbx(100, 100, 230, 255)]
  proc drawHud(at: Vec2, pressed: set[Button] = {}) =
    sk.uiScale = gameUiScale(window)
    window.state.mousePos = ivec2((at.x * sk.uiScale).int32, (at.y * sk.uiScale).int32)
    window.state.perFrame = PerFrame(buttonPressed: pressed)
    sk.beginUi(window, window.size)
    drawUi(sk, window, transport, cameraTarget, cameraDistance, viewMode,
      primaryId, selectedIds, followSelection, director, colors)
    sk.endUi()
    finishProductionUi()
    finishHumanCommunicationFrame()
    window.state.perFrame = PerFrame()
  # Typing the default keyboard-select alias while hovering Diplomacy cannot
  # turn a text character into a panel toggle.
  customBindingsEnabled = true
  inputBindings[SelectInput] = [MouseLeft, KeyZ]
  press(KeyEnter)
  release(KeyEnter)
  press(KeyZ)
  press(KeyTab)
  drawHud(vec2(60, 216), {KeyZ})
  doAssert humanCommunicationTyping(), "Typed select alias clicked Diplomacy"
  doAssert not director.manualPanel, "Typed Tab must not engage the stats director"
  release(KeyTab)
  release(KeyZ)
  press(KeyEscape)
  release(KeyEscape)
  finishHumanCommunicationFrame()
  drawHud(vec2(60, 216), {MouseLeft})
  doAssert humanCommunicationBlocksGameplay(), "Diplomacy button must open panel"
  let layout = currentLayout(window)
  let width = min(660'f32, layout.size.x - 24)
  let rows = max(1, min(6, int((layout.size.y - 148) / 92)))
  let height = 100'f32 + float32(rows * 92)
  let origin = vec2((layout.size.x-width)/2, max(12'f32, (layout.size.y-height)/2))
  let firstAction = origin + vec2(40, 104)
  let secondAction = firstAction + vec2(164, 0)
  drawHud(firstAction, {MouseLeft})
  doAssert run.world.diplomacy.relation(0, 1).offer == PeaceOffer
  options.playerSlot = 2
  drawHud(secondAction, {MouseLeft})
  doAssert run.world.diplomacy.relation(0, 1).offer == NoOffer, "Recipient Decline button"
  # Opposite side can immediately offer; original sender retains cooldown.
  drawHud(firstAction, {MouseLeft})
  doAssert run.world.diplomacy.relation(0, 1).offer == PeaceOffer
  options.playerSlot = 1
  drawHud(firstAction, {MouseLeft})
  doAssert run.world.diplomacy.relation(0, 1).state == Neutral, "Recipient Accept button"
  press(KeyEscape)
  release(KeyEscape)
  finishHumanCommunicationFrame()
press(KeyEnter)
release(KeyEnter)
press(KeyS) # Deliberately lose its release while unfocused.
window.visible = false
pollEvents()
window.onFocusChange()
doAssert not humanCommunicationTyping()
doAssert not window.runeInputEnabled
finishHumanCommunicationFrame()
doAssert not humanCommunicationBlocksGameplay(), "Focus loss clears held-key quarantine"
press(KeyEscape)
doAssert matchMenu == PauseMenu, "Escape outside communication still opens pause"
release(KeyEscape)
window.close()
window = nil
run = nil
echo "PASS production graphics Enter/rune/send/repeat/Escape, Silky capture restoration, focus loss, hotkeys and camera/Ctrl+A polling suppression; HUD alias/Tab isolation and both-player diplomacy Offer/Decline/Accept"
