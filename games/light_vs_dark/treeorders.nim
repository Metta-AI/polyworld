## Tree targeting for contextual orders, independent of window input state.
import vmath
import polyworld/[rtscameras, pathing, quadterrain]
import groves

proc pickHarvestTree*(
    grove: Grove, placements: openArray[GrovePlacement],
    wood: openArray[int16], mouse, windowSize: Vec2,
    viewProjection: Mat4, planeY: float32
): int32 =
  ## Picks the rendered tree before considering its ground footprint.
  ## Leaves and trunks project away from their tile in the angled RTS view.
  result = -1
  let (origin, direction) = mouseRay(mouse, windowSize, viewProjection)
  var nearest = float32.high
  for placement in placements:
    if placement.kind != LightTree or not placement.visible(wood):
      continue
    let distance = grove.trees.pickProp(
      modelName(placement.kind, placement.variant), origin, direction,
      placement.position, -placement.rotation, placement.scale
    )
    # Baked prop yaw is the opposite of pickProp's standalone matrix yaw.
    if distance > 0 and distance < nearest:
      nearest = distance
      result = placement.tile.int32
  if result >= 0:
    return
  let
    ground = pickGroundPoint(mouse, windowSize, viewProjection, planeY)
    side = layers[0].width.int32
    tile = groundTile(ground, side.float32 / 2, side)
    index = tile[1] * side + tile[0]
  if wood[index] > 0:
    result = index
