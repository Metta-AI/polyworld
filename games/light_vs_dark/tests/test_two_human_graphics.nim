## Exercise production selection + right-click input with both human owners.
## Uses the same real relay fixture; add -d:liveHumanMovement for sockets.
import std/[macros, importutils]
import windy/internal
include ../graphics
privateAccess(Window)

macro movementRoutine(name: static[string]): untyped =
  let source = parseStmt(staticRead("../graphics.nim"))
  for node in source:
    if node.kind == nnkProcDef and node[0].repr == "runGraphics*":
      for child in node[^1]:
        if child.kind == nnkProcDef and child[0].repr == name:
          return child
  error("Missing production routine: " & name)

proc frontendIssueMove(session: NetworkMatch, id: int32, target: Tile2) =
  run = session.game
  options.playerSlot = int32(session.client.snapshot.humanSeatFor(session.client.participant) + 1)
  viewMode = options.playerSlot
  var actionCam = initActionCam(subjectMode = true)
  var buildingArt: BuildingArt
  var grove: Grove
  var clickMarks, attackClickMarks: ClickMarkSystem
  let scenery = grovePlacements(run.world.treeWood, run.mapSeed, run.world.map.forestRocks)
  movementRoutine("selectionTarget")
  movementRoutine("playerMode")
  movementRoutine("selectEntity")
  movementRoutine("screenPosition")
  movementRoutine("pickEntity")
  movementRoutine("structureAtTile")
  movementRoutine("buildGhostOrigin")
  movementRoutine("queuePendingBuild")
  movementRoutine("clickTilePoint")
  movementRoutine("issueSelectedMove")
  movementRoutine("updatePlayerOrder")
  selectEntity(id)
  doAssert selectedIds == @[id], "Production selection failed"
  doAssert playerMode()
  let viewProjection = mat4()
  let area = attackMinimapArea(currentLayout(window))
  sk.mousePos = area.origin + area.size * vec2(
    (target.x.float32 + 0.5'f32) / run.world.map.side.float32,
    (target.y.float32 + 0.5'f32) / run.world.map.side.float32)
  sk.uiScale = gameUiScale(window)
  window.state.mousePos = ivec2((sk.mousePos.x * sk.uiScale).int32,
    (sk.mousePos.y * sk.uiScale).int32)
  window.state.buttonDown = {MouseRight}
  window.state.perFrame = PerFrame(buttonPressed: {MouseRight})
  echo "INPUT size=", window.size, " mouse=", window.mousePos,
    " pressed=", window.mousePressed(MouseRight), " slot=", options.playerSlot,
    " focused=", window.focused
  updatePlayerOrder(viewProjection)
  doAssert rightOrderStarted, "Right press rejected"
  window.state.buttonDown = {}
  window.state.perFrame = PerFrame(buttonReleased: {MouseRight})
  updatePlayerOrder(viewProjection)
  doAssert not rightOrderStarted, "Right release not consumed"

window = newWindow("LvD two human input regression", ivec2(1600, 1000), visible = false)
sk = Silky(uiScale: 1)
include test_two_human_movement
window.close()
window = nil
run = nil
