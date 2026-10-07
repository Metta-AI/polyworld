import polyworld/pathing

proc plane(x,width:int):QuadLayer =
  result=QuadLayer(originX:x,width:width,depth:1,tiles:newSeq[Tile](width))
  for tile in result.tiles.mitems:
    tile=Tile(flags:TileExists or TileConnectedEast or TileConnectedSouth)

let first=plane(0,1)
let second=plane(1,1)
layers = @[first,second]
computeWalkable()
doAssert findTilePath(0,0,0,1,0,0).len==2
# The previously cached edge starts in the unchanged first layer.
second.tiles[0].impassable=true
refreshWalkableLayers([1])
doAssert findTilePath(0,0,0,1,0,0).len==0
second.tiles[0].impassable=false
refreshWalkableLayers([1])
doAssert findTilePath(0,0,0,1,0,0).len==2
# Equal node count, different placement: old incoming geometry must disappear.
second.originX=3
refreshWalkableLayers([1])
doAssert findTilePath(0,0,0,1,0,0).len==0
second.originX=1
refreshWalkableLayers([1])
doAssert findTilePath(0,0,0,1,0,0).len==2
layers[1]=plane(1,3)
refreshWalkableLayers([1])
doAssert findTilePath(0,0,0,1,2,0).len==4
var rejected=false
try:refreshWalkableLayers([2])
except ValueError:rejected=true
doAssert rejected
let edited=layers
let elsewhere = @[plane(10,2)]
installImmutableLayers(elsewhere)
doAssert findTilePath(0,0,0,0,1,0).len==2
installImmutableLayers(edited)
doAssert findTilePath(0,0,0,1,2,0).len==4
layers[1].tiles[1].impassable=true
refreshWalkableLayers([1])
doAssert findTilePath(0,0,0,1,2,0).len==0
installImmutableLayers(elsewhere)
doAssert findTilePath(0,0,0,0,1,0).len==2
installImmutableLayers(edited)
doAssert findTilePath(0,0,0,1,2,0).len==0
echo "Incremental pathing checks passed"
