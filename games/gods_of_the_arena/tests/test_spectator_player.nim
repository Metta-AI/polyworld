import std/times
import polyworld/player

var p = initPlayer(live = true, durationTicks = 240)
p.streamed = true
p.sync(0, 72, false)
doAssert p.playing and p.speed == 1
p.skipToEnd()
doAssert p.targetTick == 72, "Stream end must be received ticks, not configured duration"
p.seekTo(200)
doAssert p.targetTick == 72
p.pause()
p.sync(72, 72, false)
p.play()
p.startFrame(0.2, 24)
doAssert not p.shouldTick(epochTime()), "Never simulate without a received tick"
doAssert p.playing, "Starvation must wait, not pause or loop"
doAssert p.restoreTick == -1
p.sync(72, 96, false)
p.startFrame(1.0'f32 / 24, 24)
doAssert p.shouldTick(epochTime())
p.pause()
p.sync(50, 100, false)
p.setSpeed(1)
p.play()
p.startFrame(1.0'f32 / 24, 24)
var ticks = 0
while p.shouldTick(epochTime()):
  inc ticks
  p.sync(p.tick + 1, 100, false)
doAssert ticks == 2, "2x uses selected realtime rate, not catch-up pacing"
p.stepBack()
doAssert p.restoreTick == 51 and not p.playing
p.stepForward()
doAssert p.targetTick == 53 and not p.playing
p.sync(100, 100, true)
p.seekTo(20)
discard p.takeRestore()
p.sync(0, 100, false)
doAssert p.shouldTick(epochTime()), "Completed streams can replay history"
echo "Stream transport bounds and starvation passed"
