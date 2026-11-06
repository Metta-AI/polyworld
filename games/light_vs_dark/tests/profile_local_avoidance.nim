import trafficfixture, polyworld/profiles, std/[os, strutils]
let count = if paramCount() >= 3: parseInt(paramStr(3)) else: 300
let ticks = if paramCount() >= 4: parseInt(paramStr(4)) else: 300
let f = trafficFixture(count, paramStr(2))
startRuntimeProfileTrace(paramStr(1))
for tick in 0 ..< ticks: f.world.tickWorld(nil)
discard finishProfileTrace()
