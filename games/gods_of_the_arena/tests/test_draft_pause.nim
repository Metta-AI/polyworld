## Actual transport/layout policy plus guards for every rendered input route.
import std/[strutils, times]
import polyworld/player
import ../[game, sim, ui]

run = Game(world: World(phase: Drafting))
for online in [false, true]:
  for watching in [false, true]:
    run.networked = online
    networkSpectator = watching
    doAssert not transportAvailable(), "Draft must not expose playback controls"

for live in [false, true]:
  for streamed in [false, true]:
    var transport = initPlayer(live = live, durationTicks = 2000, playing = false)
    transport.streamed = streamed
    transport.sync(0, 500, false)
    run.world.keepDraftPlaying(transport)
    doAssert transport.playing, "Draft must ignore paused startup"
    transport.startFrame(1.0'f32 / 24, 24)
    doAssert transport.shouldTick(epochTime()), "Draft deadline must actually advance"
    transport.pause()
    run.world.keepDraftPlaying(transport)
    doAssert transport.playing, "Restoring into draft must not strand a paused viewer"
    run.world.phase = Playing
    transport.pause()
    run.world.keepDraftPlaying(transport)
    doAssert not transport.playing, "Battle retains normal playback pause"
    run.world.phase = Drafting

run.world.phase = Playing
run.networked = false
doAssert transportAvailable(), "Local battle transport remains available"
run.networked = true
networkSpectator = true
doAssert transportAvailable(), "Spectator battle transport remains available"
networkSpectator = false
doAssert not transportAvailable(), "Controllers must not get local playback controls"

let graphics = readFile("games/gods_of_the_arena/graphics.nim")
let drafts = readFile("games/gods_of_the_arena/drafts.nim")
doAssert "run.world.phase != Drafting and" in graphics.split("if PauseInput.matches(button)", 1)[1].split("elif CameraInput", 1)[0],
  "Space must not pause the draft"
doAssert "enabled = run.world.phase != Drafting and" in graphics.split("\"Resume match\" else: \"Pause match\"", 1)[1].split("if sk.lobbyButton(\"Settings\"", 1)[0],
  "Esc pause must not pause local, controller, or spectator drafts"
doAssert "run.world.keepDraftPlaying(transport)" in graphics,
  "Paused startup or seeking back to draft must resume automatically"
doAssert "Paused. Press Space" notin drafts

echo "Draft transport visibility and pause input routes passed"
