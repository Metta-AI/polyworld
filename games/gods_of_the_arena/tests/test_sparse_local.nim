import ../[game, sim, replays]
let config = parseConfig("{\"maxTicks\":24,\"draftMode\":\"open\"}")
var sources: array[10, string]
initializeLocalMatch(config, sources, 8)
doAssert run.world.heroes.len == 1, "Local empty slots must not spawn"
doAssert run.world.heroes[0].id == FirstHeroId + 8
doAssert options.playerSlot == 1
for vm in run.heroVms:
  doAssert vm == nil
echo "Local sparse human preserved without ghost policies"
