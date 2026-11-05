## Native regression using the actual generated tree meshes and order queue.
## Needs an OpenGL context for generated prop textures (no WASM build).
import std/[algorithm, math, unittest]
import opengl, vmath, windy
import polyworld/[quadterrain, rtscameras]
import ../[content, controls, groves, maps, sim, treeorders]

proc project(point: Vec3, vp: Mat4, size: Vec2): Vec2 =
  let clip = vp * vec4(point, 1)
  vec2((clip.x / clip.w + 1) * size.x / 2,
    (1 - clip.y / clip.w) * size.y / 2)

let window = newWindow("LvD tree order regression", ivec2(64), visible = false)
window.makeContextCurrent()
loadExtensions()
let
  map = generateMap(DefaultSeed)
  grove = generateGrove(DefaultSeed, {LightTree, LightRock})
  placements = grovePlacements(map.treeWood, DefaultSeed, map.forestRocks)
  size = vec2(1600, 1000)
var candidates: seq[GrovePlacement]
for p in placements:
  if p.kind == LightTree:
    # Verify that rendering and simulation agree on the tree's base tile.
    let tile = groundTile(p.position, map.side.float32 / 2, map.side)
    doAssert map.tileIndex(tile[0], tile[1]) == p.tile.int32
    candidates.add p
candidates.sort(proc(a, b: GrovePlacement): int =
  cmp(tileDistance(map.hallOrigin[LightPlayer],
    tile2(a.tile.int32 mod map.side, a.tile.int32 div map.side)),
    tileDistance(map.hallOrigin[LightPlayer],
    tile2(b.tile.int32 mod map.side, b.tile.int32 div map.side))))

# Find a real visible canopy whose ground projection lands on empty terrain.
var
  clicked: GrovePlacement
  pointer: Vec2
  vp: Mat4
  planeY: float32
  found = false
for p in candidates:
  let
    target = p.position
    projection = perspective(RtsFieldOfView * PI.float32 / 180,
      size.x / size.y, 0.1'f32, 500'f32)
    viewProjection = projection * lookAt(rtsCameraEye(target, 17), target,
      vec3(0, 1, 0))
  for height in [1.8'f32, 2.2'f32, 2.6'f32]:
    let
      mouse = project(p.position + vec3(0, height * p.scale, 0),
        viewProjection, size)
      (origin, direction) = mouseRay(mouse, size, viewProjection)
      ground = pickGroundPoint(mouse, size, viewProjection, target.y)
      tile = groundTile(ground, map.side.float32 / 2, map.side)
      index = map.tileIndex(tile[0], tile[1])
    # Baked placement yaw is opposite to pickProp's standalone matrix yaw.
    let hit = grove.trees.pickProp(modelName(p.kind, p.variant),
      origin, direction, p.position, -p.rotation, p.scale)
    var foreground = false
    if hit > 0:
      for other in candidates:
        if other.tile == p.tile: continue
        let otherHit = grove.trees.pickProp(modelName(other.kind, other.variant),
          origin, direction, other.position, -other.rotation, other.scale)
        if otherHit > 0 and otherHit < hit:
          foreground = true
          break
    if map.treeWood[index] == 0 and map.passable[index] == 1 and
        hit > 0 and not foreground:
      clicked = p
      pointer = mouse
      vp = viewProjection
      planeY = target.y
      found = true
      echo "Canopy tree tile ", p.tile, " projects to empty ground tile ", index
      break
  if found: break
doAssert found, "fixture must hit actual generated foliage above empty ground"

suite "LvD contextual tree harvesting":
  test "a canopy order reaches the queue and deposits harvested wood":
    clearPlayerCommands()
    let game = newGame(map, DefaultSeconds * TickRate)
    let tree = grove.pickHarvestTree(placements, game.world.treeWood,
      pointer, size, vp, planeY)
    if tree >= 0:
      queueHarvest(LightPlayer, game.world.units[0].id, tree, 1)
    proc decide(w: World) = game.flushPlayerCommands()
    let before = game.world.players[LightPlayer].wood
    for tick in 0 ..< TickRate * 100:
      game.world.tickWorld(decide)
    check tree == clicked.tile.int32
    check game.world.treeWood[clicked.tile] == 0
    check game.world.players[LightPlayer].wood > before
    check (game.world.players[LightPlayer].wood - before) mod WoodPerTrip == 0
    echo "Wood deposited: ", game.world.players[LightPlayer].wood - before

  test "depleted rendered placements cannot be targeted":
    var wood = newSeq[int16](map.treeWood.len)
    check grove.pickHarvestTree(placements, wood, pointer, size, vp, planeY) == -1
    wood[clicked.tile] = WoodPerTree
    check grove.pickHarvestTree(placements, wood, pointer, size, vp, planeY) ==
      clicked.tile.int32
    wood[clicked.tile] = 0
    check grove.pickHarvestTree(placements, wood, pointer, size, vp, planeY) == -1

  test "a tree depleted before the decision tick rejects its queued order":
    clearPlayerCommands()
    let game = newGame(map, DefaultSeconds * TickRate)
    let tree = grove.pickHarvestTree(placements, game.world.treeWood,
      pointer, size, vp, planeY)
    queueHarvest(LightPlayer, game.world.units[0].id, tree, 1)
    game.world.treeWood[tree] = 0
    let before = game.world.units[0]
    game.flushPlayerCommands()
    check game.world.units[0] == before
    check game.world.players[LightPlayer].wood == StartingWood

  test "tree ground footprint remains targetable":
    var wood = newSeq[int16](map.treeWood.len)
    wood[clicked.tile] = WoodPerTree
    let basePointer = project(clicked.position, vp, size)
    check grove.pickHarvestTree(placements, wood, basePointer, size, vp,
      planeY) == clicked.tile.int32

closePropPack(grove.trees)
closePropPack(grove.rocks)
window.close()
