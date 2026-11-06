## Cache output must exactly match the original ray painter at every cell.
import trafficfixture, polyworld/visions
proc checkVision(w: World) =
  var blockers = newSeq[int16](w.blocker.len)
  for i,b in w.blocker:
    if b == TreeBlocker: blockers[i] = 24
    elif b != NoEntity: blockers[i] = 28
  for player in 0'i32 ..< w.players.len.int32:
    var expected = newSeq[bool](w.blocker.len)
    proc paint(x,y,r: int32, eye:int16) =
      for off in visionCircleTiles(r):
        let px = x+off.dx.int32
        let py = y+off.dz.int32
        if w.map.inGrid(px,py) and offsetVisible(w.map.side,w.map.heights,
            blockers,x,y,w.map.heights[w.map.tileIndex(x,y)].int64+eye.int64,off):
          expected[w.map.tileIndex(px,py)] = true
    for u in w.units:
      if (u.owner == player or w.diplomacy.sharesVision(player,u.owner)) and
          u.state notin {UnitDying,UnitInMine}:
        paint(u.tile.x,u.tile.y,unitOf(u.owner,u.kind).sightTiles,14)
    for b in w.buildings:
      if (b.owner == player or w.diplomacy.sharesVision(player,b.owner)) and
          b.state != BuildingDying:
        for y in b.origin.y.int32 ..< b.origin.y.int32+b.footprint.depth:
          for x in b.origin.x.int32 ..< b.origin.x.int32+b.footprint.width:
            paint(x,y,BuildingTable[b.kind].sightTiles,24)
    for i,v in expected:
      doAssert v == (w.visibleStamp[player][i] == w.visionGeneration[player])
let f = trafficFixture(20,"choke")
for tick in 0 ..< 150:
  f.world.tickWorld(nil)
  # Vision is computed before movement, so explicitly rebuild for this check.
  f.world.rebuildVision()
  checkVision(f.world)
# Force changed blockers and heights, sources, and a distinct alternating world.
let peer = f.world.clone()
for w in [f.world,peer]:
  w.blocker[w.map.tileIndex(39,40)] = TreeBlocker
  w.terrainEdits.add TileEdit(tick:w.tick,index:w.map.tileIndex(39,40))
  w.units[0].state = UnitDying
  w.rebuildVision()
  checkVision(w)
doAssert Game(world:f.world).stateHash() == Game(world:peer).stateHash()
echo "Cached vision matches original rays, terrain invalidation and peers"
