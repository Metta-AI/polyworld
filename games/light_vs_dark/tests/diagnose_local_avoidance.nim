## Separate diagnostic run; ordinary benchmark timing scope stays unchanged.
import trafficfixture, polyworld/profiles, std/[os, strutils, json]
let f = trafficFixture(parseInt(paramStr(3)), paramStr(2))
var rows = newJArray()
for tick in 0 ..< 900:
  if tick mod 50 == 0:
    startRuntimeProfileTrace(paramStr(1) & "-trace-" & $(tick div 50) & ".json")
  var positions: seq[FixedVec2]
  var active = 0
  for u in f.world.units:
    positions.add u.body.pos
    if u.hasGoal: inc active
  let searches = pathSearches
  let expansions = pathExpansions
  f.world.tickWorld(nil)
  var moved = 0
  for i,u in f.world.units:
    if u.body.pos != positions[i]: inc moved
  rows.add %*{"tick":tick+1, "active":active, "moved":moved,
    "searches":pathSearches-searches, "expansions":pathExpansions-expansions}
  if tick mod 50 == 49: discard finishProfileTrace()
writeFile(paramStr(1) & "-work.json", $rows)
