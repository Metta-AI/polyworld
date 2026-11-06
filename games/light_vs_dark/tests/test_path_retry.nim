## Permanently blocked terrain destinations must not trigger A* every 7 ticks.
import trafficfixture
let f = trafficFixture(2, "opposing")
let w = f.world
# Mine footprint is permanently unwalkable, unlike moving occupancy.
let u = w.units[0]
doAssert w.applyMove(0, u.id, 58, 40)
pathSearches = 0
for tick in 0 ..< 900: w.tickWorld(nil)
doAssert pathSearches < 30, "Unchanged blocked terrain goal repeatedly searched: " & $pathSearches
# A later replacement must not inherit the retry delay.
doAssert w.applyMove(0, u.id, 48, 35)
for tick in 0 ..< 900: w.tickWorld(nil)
doAssert length(u.body.pos - fixedVec2(48.5'fx,35.5'fx)) <= 0.4'fx
echo "Bounded terrain retry and replacement passed"
