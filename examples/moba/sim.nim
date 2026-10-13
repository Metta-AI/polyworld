## Native port of PufferLib 5's moba (ocean/moba/moba.h, pin 6ffa5b1).
##
## Same map, units, skills, scripted heroes, observation bytes and rewards,
## in the same order, including moba's quirks: rewards are cleared at the
## start of the players' phase (so deaths to towers and creeps cost
## nothing), scan lists are reused between scans, the pull skills move the
## caster, and episodes never send a terminal. Deviations: rand() is a
## per-match xorshift, path tables are built per destination when first
## needed instead of one 256 MB table, and moves off the map fail instead
## of reading out of bounds.
##
## Cut-ladder traits (Moba.traits, bit n for trait n) put Gods of the
## Arena rules back into the engine for ladder rungs 11 to 18; 0 is exact
## moba. Rung r keeps traits r - 10 to 8:
## - 8 GotA's 20-minute clock (2,880 steps at 10 ticks per step); a match
##   that reaches it is a draw.
## - 7 Gates: a lane's towers fall in tier order (1 outer to 3), the two
##   tier-4 guards only after one whole lane fell, the ancient only after
##   both guards, as GotA's lanes, god guards and god.
## - 6 Respawn timers: 9 s plus 5 s per earlier death, at most 60 s (22,
##   +12, 144 steps); a dead hero is off the map.
## - 5 Spawn-only healing: no passive regeneration; within 10 cells of its
##   spawn a hero heals 5% of its health and mana per step.
## - 4 GotA towers: tiers 1 to 3 (and the guards, as tier 3) with GotA's
##   health and damage, a 752-health god, and 9 to 10 cell reach.
## - 3 GotA waves: every 48 steps (20 s) 6 melee and 2 ranged creeps per
##   lane with GotA's health and damage; ranged creeps hit at 4 cells.
## - 2 GotA heroes and XP: the roles get Druid Warden, Demon Hunter,
##   Arcanist, Vanguard Knight and Ranger's stats, attack reach and rate;
##   GotA's XP curve (100, then 75 more per level, to level 20) and kill XP
##   (creep 15, hero 150, tower 200, the god 1,000 to each winner).
## GotA's numbers enter moba's units with health x 1.40 and damage x 1.88,
## the ratios of the five roles' average health and damage.

import std/math

const
  MapSize* = 128
  NumPlayers* = 10
  NumCreeps = 300
    ## Creep slots stored; moba cycles through the first 100.
  MobaCreepSlots = 100
  NumNeutrals = 72
  NumTowers = 24
  NumEntities* = NumPlayers + NumCreeps + NumNeutrals + NumTowers
  CreepOffset = NumPlayers
  NeutralOffset = NumPlayers + NumCreeps
  TowerOffset* = NumPlayers + NumCreeps + NumNeutrals
  RadiantAncient* = TowerOffset + 23
  DireAncient* = TowerOffset + 22
  Window = 11
  ExtraStart = Window * Window * 4
  ObservationSize* = 510
  ActionSizes* = [7'i32, 7, 3, 2, 2, 2]
  ActionCount* = ActionSizes.len
  EmptyTile = 0'u8
  WallTile = 1'u8
  TowerTile = 2'u8
  RadiantCreepTile = 3'u8
  DireCreepTile = 4'u8
  NeutralTile = 5'u8
  RadiantSupportTile = 6'u8
  TowerVision = 5
  CreepVision = 7
  NeutralVision = 3
  XpRange = 7'f32
  ClockSteps = 2880
  RespawnBase = 22
  RespawnGrowth = 12
  RespawnMax = 144
  SpawnHealRange = 10'f32
  GotaWaveSteps = 48
  GotaMeleePerLane = 6
  GotaRangedPerLane = 2
  GotaCreepHealth = 113'f32
  GotaCreepDamage = 39'f32
  GotaCreepRange = 4'f32
  GotaCreepXp = 15
  GotaTowerHealth = [3572'f32, 4888, 7332, 7332, 752]
    ## By tier 1 to 5 (4 the god guards, 5 the god).
  GotaTowerDamage = [50'f32, 67, 84, 84, 0]
  GotaTowerReach = [9, 10, 10, 10, 0]
  GotaHeroKillXp = 150
  GotaTowerXp = 200
  GotaGodXp = 1000
  GotaMaxLevel = 20
  GotaHeroes = [
    # health, health/level, mana, mana/level, damage, damage/level,
    # reach in tenths of a cell, attack steps: Druid Warden, Demon Hunter,
    # Arcanist, Vanguard Knight, Ranger (moba's support, assassin, burst,
    # tank and carry).
    [490, 28, 359, 29, 45, 4, 40, 3],
    [469, 94, 200, 15, 55, 9, 15, 2],
    [403, 27, 398, 33, 49, 9, 50, 3],
    [631, 158, 230, 17, 62, 11, 15, 3],
    [305, 126, 112, 34, 39, 23, 60, 3]
  ]
  ScanSlots = 121
    ## moba reads at most 121 scanned targets per entity.
  ScanCapacity = 226
  PathRngCount = 10000
  MapData = staticRead("map.bin")
  XpForLevel = [0'f32, 240, 640, 1160, 1760, 2440, 3200, 4000, 4900,
    4900, 7000, 8200, 9500, 10900, 12400, 14000, 15700, 17500, 19400,
    21400, 23600, 26000, 28600, 31400, 34400, 38400, 43400, 49400, 56400,
    63900]
  AtnY = [1'f32, -1, 0, 0, 1, -1, -1, 1]
  AtnX = [0'f32, 0, 1, -1, -1, -1, 1, 1]
  NeutralCampX = [44.753846153846155'f32, 74.41538461538462,
    101.67692307692307, 89.92307692307692, 73.95384615384616,
    64.38461538461539, 31.657692307692308, 95.67692307692307,
    81.1076923076923, 34.99230769230769, 50.784615384615385,
    63.646153846153844, 59.49230769230769, 44.69230769230769,
    98.67307692307692, 28.642307692307693, 64.87692307692308,
    51.46153846153846]
  NeutralCampY = [71.99230769230769'f32, 108.15384615384616,
    102.16923076923078, 102.78461538461539, 40.753846153846155,
    39.92307692307692, 39.96923076923077, 70.78461538461538,
    69.18461538461538, 59.52307692307692, 99.95384615384614,
    93.97692307692307, 49.86153846153846, 31.353846153846156,
    61.06153846153846, 69.92307692307692, 83.83076923076923,
    33.98461538461538]
  TowerDamage = [175'f32, 175, 175, 175, 110, 175, 175, 110, 175, 175,
    175, 110, 175, 110, 175, 175, 175, 175, 175, 175, 110, 110, 0, 0]
  TowerHealth = [2000'f32, 2000, 2000, 2000, 1800, 2000, 2000, 1800, 2100,
    2100, 2000, 1800, 2000, 1800, 2000, 2000, 2000, 2000, 2100, 2100, 1800,
    1800, 4500, 4500]
  TowerTeam = [0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0,
    0, 1, 1, 0]
  TowerTier = [3, 3, 3, 2, 1, 2, 2, 1, 4, 4, 2, 1, 2, 1, 2, 3, 3, 3, 4, 4,
    1, 1, 5, 5]
  TowerX = [34.6'f32, 29.307692307692307, 14.292307692307695, 64.2,
    102.87692307692308, 38.29230769230769, 17.615384615384613,
    16.876923076923077, 21.06153846153846, 103.03076923076924, 65.0,
    29.06153846153846, 84.2, 69.03076923076924, 112.75384615384615,
    113.73846153846154, 92.32307692307693, 97.86153846153846,
    105.61538461538461, 23.52307692307692, 53.12307692307692,
    113.22307692307692, 107.52307692307693, 19.46153846153846]
  TowerY = [112.01538461538462'f32, 96.87692307692308, 91.21538461538461,
    113.61538461538461, 112.13846153846154, 85.43076923076923,
    71.70769230769231, 51.03076923076923, 102.41538461538462,
    28.261538461538464, 18.723076923076924, 18.723076923076924,
    48.753846153846155, 59.98461538461538, 62.04615384615384,
    41.676923076923075, 20.56923076923077, 36.08461538461539,
    30.907692307692308, 104.93846153846154, 75.83076923076923, 78.3,
    26.53846153846154, 106.16923076923078]
  WaypointCounts = [14, 10, 13, 9, 9, 12]
  Waypoints: array[6, array[14, array[2, float32]]] = [
    [[96.26153846153846'f32, 14.04615384615385],
      [93.61538461538461'f32, 14.292307692307695],
      [58.23076923076923'f32, 16.07692307692308],
      [43.4'f32, 16.01538461538462],
      [32.10769230769231'f32, 17.584615384615383],
      [24.93846153846154'f32, 19.123076923076923],
      [22.96923076923077'f32, 20.446153846153848],
      [21.06153846153846'f32, 25.307692307692307],
      [20.200000000000003'f32, 30.47692307692308],
      [19.4'f32, 35.892307692307696],
      [18.47692307692308'f32, 43.52307692307693],
      [18.04615384615385'f32, 50.723076923076924],
      [20.50769230769231'f32, 94.66153846153847],
      [27.676923076923075'f32, 105.94615384615385]],
    [[99.52307692307693'f32, 26.47692307692308],
      [98.66153846153847'f32, 27.646153846153844],
      [86.04615384615384'f32, 41.12307692307692],
      [71.33846153846154'f32, 57.49230769230769],
      [66.96923076923076'f32, 62.23076923076923],
      [64.07692307692308'f32, 66.35384615384615],
      [60.2'f32, 72.01538461538462],
      [51.892307692307696'f32, 84.87692307692308],
      [34.66153846153846'f32, 99.4],
      [28.169230769230772'f32, 105.94615384615385],
      [0'f32, 0], [0'f32, 0], [0'f32, 0], [0'f32, 0]],
    [[112.01538461538462'f32, 36.93846153846154],
      [112.01538461538462'f32, 32.50769230769231],
      [116.2'f32, 68.6923076923077],
      [113.73846153846154'f32, 80.75384615384615],
      [113.55384615384615'f32, 90.53846153846155],
      [113.21538461538461'f32, 95.98461538461538],
      [111.49230769230769'f32, 100.93846153846154],
      [109.06153846153846'f32, 108.07692307692308],
      [107.18461538461538'f32, 111.36923076923077],
      [101.73846153846154'f32, 114.66153846153847],
      [90.53846153846155'f32, 111.76923076923077],
      [39.4'f32, 113.73846153846154],
      [28.169230769230772'f32, 106.43846153846154],
      [0'f32, 0]],
    [[20.446153846153848'f32, 89.36923076923077],
      [20.630769230769232'f32, 94.66153846153847],
      [18.784615384615385'f32, 50.6],
      [22.292307692307695'f32, 24.50769230769231],
      [22.815384615384616'f32, 18.815384615384616],
      [27.52307692307692'f32, 17.03076923076923],
      [35.03076923076923'f32, 15.95384615384615],
      [93.61538461538461'f32, 14.415384615384617],
      [103.64615384615385'f32, 21.99230769230769],
      [0'f32, 0], [0'f32, 0], [0'f32, 0], [0'f32, 0], [0'f32, 0]],
    [[37.43076923076923'f32, 96.50769230769231],
      [34.53846153846154'f32, 99.27692307692308],
      [51.707692307692305'f32, 84.38461538461539],
      [59.83076923076923'f32, 71.64615384615385],
      [63.83076923076923'f32, 66.1076923076923],
      [66.72307692307692'f32, 61.98461538461538],
      [70.84615384615384'f32, 57.246153846153845],
      [98.53846153846155'f32, 27.52307692307692],
      [103.64615384615385'f32, 22.48461538461538],
      [0'f32, 0], [0'f32, 0], [0'f32, 0], [0'f32, 0], [0'f32, 0]],
    [[36.93846153846154'f32, 113.24615384615385],
      [39.4'f32, 113.61538461538461],
      [62.292307692307695'f32, 114.6],
      [83.64615384615385'f32, 114.6],
      [90.66153846153847'f32, 109.8],
      [94.87692307692308'f32, 112.01538461538462],
      [104.26153846153846'f32, 112.2923076923077],
      [109.3076923076923'f32, 107.83076923076922],
      [112.23076923076923'f32, 105.86153846153846],
      [114.44615384615385'f32, 72.96923076923076],
      [111.8923076923077'f32, 32.50769230769231],
      [104.13846153846154'f32, 22.48461538461538],
      [0'f32, 0], [0'f32, 0]]
  ]

type
  EntityKind* = enum
    PlayerEntity, CreepEntity, NeutralEntity, TowerEntity

  Skill = enum
    SupportHook, SupportAoeHeal, SupportStun,
    AssassinAoeMinions, AssassinTpDamage, AssassinMoveBuff,
    BurstNuke, BurstAoe, BurstAoeStun,
    TankAoeDot, TankSelfHeal, TankEngageAoe,
    CarryRetreatSlow, CarrySlowDamage, CarryAoe

  Entity* = object
    pid*, heroType*, team*, lane*, waypoint*: int
    ranged*: bool
      ## Trait 3 ranged creeps.
    reach*: float32
      ## Trait 2: basic-attack reach in cells (0 is moba's).
    kind*: EntityKind
    gridId*: uint8
    health*, maxHealth*, mana*, maxMana*: float32
    y*, x*, spawnY*, spawnX*: float32
    damage*, moveSpeed*, moveModifier*: float32
    stunTimer*, moveTimer*, qTimer*, wTimer*, eTimer*: int
    basicAttackTimer*, basicAttackCd*, isHit*: int
    level*, xp*, xpOnKill*, tier*: int
    baseHealth*, baseMana*, baseDamage*: float32
    hpGainPerLevel*, manaGainPerLevel*, damageGainPerLevel*: int
    lastX*, lastY*: float32
    targetPid*, attackAoe*: int

  Reward* = object
    death*, xp*, distance*, tower*: float32

  Moba* = ref object
    grid*: array[MapSize * MapSize, uint8]
    pids*: array[MapSize * MapSize, int32]
    origGrid: array[MapSize * MapSize, uint8]
    entities*: array[NumEntities, Entity]
    rewards*: array[NumPlayers, Reward]
    scanned: array[NumEntities, array[ScanCapacity, int16]]
    skills: array[NumPlayers, array[3, Skill]]
    actions*: array[NumPlayers, array[ActionCount, int32]]
    tick*, creepIdx: int
    shouldReset: bool
    visionRange*: int
    agentSpeed*: float32
    rewardDeath*, rewardXp*, rewardDistance*, rewardTower*: float32
    scriptOpponents*: bool
    rngState: uint32
    pathRng: seq[float32]
    pathRngIndex: int
    finished*: bool
      ## Set by `step` when an ancient fell this tick (before the reset).
    radiantVictory*, direVictory*: bool
    finishedTick*: int
    traits*: uint16
      ## GotA traits for the cut ladder, bit n for trait n (0 = moba).
    dead: array[NumPlayers, bool]
    respawnTimers: array[NumPlayers, int]
    deaths: array[NumPlayers, int]
    towerLanes: array[NumTowers, int]
      ## Each tower's lane (0 to 2 on its team's side), for the gates.
    creepSlots: int
      ## Creep slots in use: moba's 100, or all for trait 3.

var pathCache: seq[seq[uint8]]
  ## Per destination cell, the BFS action toward it from every cell (255
  ## unreached, 8 at a wall or the destination), built on first use. The
  ## walls are static, so every match shares it.

proc trait*(game: Moba, n: int): bool {.inline.} =
  ## Whether GotA trait n is on.
  (game.traits and (1'u16 shl n)) != 0

proc mapOffset(y, x: int): int {.inline.} =
  ## Grid index of a cell.
  y * MapSize + x

proc l1(y1, x1, y2, x2: float32): float32 {.inline.} =
  ## moba's l1_distance.
  abs(x1 - x2) + abs(y1 - y2)

proc rand(game: Moba): int =
  ## A xorshift stand-in for C's rand(): 0 to 2^31 - 1.
  var s = game.rngState
  s = s xor (s shl 13)
  s = s xor (s shr 17)
  s = s xor (s shl 5)
  game.rngState = s
  int(s shr 1)

proc fastRng(game: Moba): float32 =
  ## moba's fast_rng over a cached table of uniform -1 to 1 values.
  result = game.pathRng[game.pathRngIndex]
  inc game.pathRngIndex
  if game.pathRngIndex >= PathRngCount - 1:
    game.pathRngIndex = 0

proc bfs(dest: int): seq[uint8] =
  ## moba's bfs from one destination over the static walls.
  result = newSeq[uint8](MapSize * MapSize)
  for cell in result.mitems:
    cell = 255
  let
    destY = dest div MapSize
    destX = dest mod MapSize
  if uint8(MapData[dest]) == WallTile:
    return
  var queue = newSeqOfCap[array[3, int]](8 * MapSize * MapSize)
  queue.add [0, destY, destX]
  var start = 0
  while start < queue.len:
    let
      atn = queue[start][0]
      y = queue[start][1]
      x = queue[start][2]
    inc start
    if y < 0 or y >= MapSize or x < 0 or x >= MapSize:
      continue
    let cell = mapOffset(y, x)
    if result[cell] != 255:
      continue
    if uint8(MapData[cell]) == WallTile:
      result[cell] = 8
      continue
    result[cell] = uint8(atn)
    queue.add [0, y - 1, x]
    queue.add [1, y + 1, x]
    queue.add [2, y, x - 1]
    queue.add [3, y, x + 1]
    queue.add [4, y - 1, x + 1]
    queue.add [5, y + 1, x + 1]
    queue.add [6, y + 1, x - 1]
    queue.add [7, y - 1, x - 1]
  result[dest] = 8

proc pathAction(destY, destX, srcY, srcX: int): int =
  ## The BFS action from (srcY, srcX) toward (destY, destX), or 8 or more
  ## when there is none.
  if destY < 0 or destY >= MapSize or destX < 0 or destX >= MapSize or
    srcY < 0 or srcY >= MapSize or srcX < 0 or srcX >= MapSize:
      return 8
  if pathCache.len == 0:
    pathCache.setLen(MapSize * MapSize)
  let dest = mapOffset(destY, destX)
  if pathCache[dest].len == 0:
    pathCache[dest] = bfs(dest)
  int(pathCache[dest][mapOffset(srcY, srcX)])

proc moveTo(game: Moba, entity: var Entity, destY, destX: float32): int =
  ## moba's move_to: 0 when the entity moved, 1 when the cell is taken.
  let
    srcY = int(entity.y)
    srcX = int(entity.x)
    dstY = int(destY)
    dstX = int(destX)
  if dstY < 0 or dstY >= MapSize or dstX < 0 or dstX >= MapSize:
    return 1
  let
    src = mapOffset(srcY, srcX)
    dst = mapOffset(dstY, dstX)
  if game.grid[dst] != EmptyTile and game.pids[dst] != int32(entity.pid):
    return 1
  game.grid[src] = EmptyTile
  game.grid[dst] = entity.gridId
  game.pids[src] = -1
  game.pids[dst] = int32(entity.pid)
  entity.y = destY
  entity.x = destX
  0

proc moveNear(game: Moba, entity: var Entity, target: Entity): int =
  ## moba's move_near: the first free cell around the target.
  for dy in -1 .. 1:
    for dx in -1 .. 1:
      if game.moveTo(entity, target.y + float32(dy),
        target.x + float32(dx)) == 0:
          return 0
  1

proc moveTowards(
  game: Moba,
  entity: var Entity,
  destY, destX: int,
  speed: float32
): int =
  ## moba's move_towards: one BFS step, else a random jitter.
  let
    srcY = int(entity.y)
    srcX = int(entity.x)
    atn = pathAction(destY, destX, srcY, srcX)
  if atn >= 8:
    return 0
  let
    modifier = speed * entity.moveModifier
    stepY = int(float32(srcY) + modifier * AtnY[atn])
    stepX = int(float32(srcX) + modifier * AtnX[atn])
  if game.moveTo(entity, float32(stepY), float32(stepX)) == 0:
    return 0
  let
    jitterX = game.fastRng()
    jitterY = game.fastRng()
  game.moveTo(entity, entity.y + jitterY, entity.x + jitterX)

proc killEntity(game: Moba, entity: var Entity) =
  ## moba's kill_entity.
  if entity.pid == -1:
    return
  let cell = mapOffset(int(entity.y), int(entity.x))
  game.grid[cell] = EmptyTile
  game.pids[cell] = -1
  entity.pid = -1
  entity.targetPid = -1
  entity.health = 0
  entity.lastX = 0
  entity.lastY = 0
  entity.x = 0
  entity.y = 0

proc spawnPlayer(game: Moba, index: int) =
  ## moba's spawn_player: full health and mana within 7 cells of spawn.
  var entity = game.entities[index]
  let pid = entity.pid
  game.killEntity(entity)
  entity.pid = pid
  entity.maxHealth = entity.baseHealth +
    float32(entity.level * entity.hpGainPerLevel)
  entity.maxMana = entity.baseMana +
    float32(entity.level * entity.manaGainPerLevel)
  entity.damage = entity.baseDamage +
    float32(entity.level * entity.damageGainPerLevel)
  entity.health = entity.maxHealth
  entity.mana = entity.maxMana
  entity.basicAttackTimer = 0
  entity.moveModifier = 0
  entity.moveTimer = 0
  entity.stunTimer = 0
  entity.qTimer = 0
  entity.wTimer = 0
  entity.eTimer = 0
  entity.targetPid = -1
  entity.waypoint = 1
  var y, x: int
  while true:
    y = int(entity.spawnY) + game.rand() mod 15 - 7
    x = int(entity.spawnX) + game.rand() mod 15 - 7
    if game.grid[mapOffset(y, x)] == EmptyTile:
      break
  entity.lastX = float32(x)
  entity.lastY = float32(y)
  doAssert game.moveTo(entity, float32(y), float32(x)) == 0
  game.entities[index] = entity

proc calcLevel(xp: int): int =
  ## moba's calc_level.
  for i in 0 ..< 30:
    if float32(xp) < XpForLevel[i]:
      return i + 1
  30

proc gotaLevel(xp: int): int =
  ## Trait 2: GotA's level for total XP (100 to level 2, then 75 more per
  ## level), at most 20.
  result = 1
  var need = 100
  var total = 0
  while result < GotaMaxLevel and xp >= total + need:
    total += need
    need += 75
    inc result

proc levelFor(game: Moba, xp: int): int =
  ## The level for total XP under the current traits.
  if game.trait(2): gotaLevel(xp) else: calcLevel(xp)

proc gainXp(game: Moba, index, xp: int) =
  ## Adds XP to a hero, pays its XP reward and refreshes its stats.
  game.entities[index].xp += xp
  game.rewards[index].xp += float32(xp) * game.rewardXp
  game.entities[index].level = game.levelFor(game.entities[index].xp)
  let level = game.entities[index].level
  game.entities[index].maxHealth = game.entities[index].baseHealth +
    float32(level * game.entities[index].hpGainPerLevel)
  game.entities[index].maxMana = game.entities[index].baseMana +
    float32(level * game.entities[index].manaGainPerLevel)
  game.entities[index].damage = game.entities[index].baseDamage +
    float32(level * game.entities[index].damageGainPerLevel)

proc towerAlive(game: Moba, slot: int): bool =
  ## Whether a tower stands.
  let tower = game.entities[TowerOffset + slot]
  tower.pid != -1 and tower.health > 0

proc exposed(game: Moba, slot: int): bool =
  ## Trait 7: whether a tower can be damaged under GotA's gates.
  let
    team = TowerTeam[slot]
    tier = TowerTier[slot]
  case tier
  of 1 .. 3:
    for other in 0 ..< NumTowers:
      if TowerTeam[other] == team and TowerTier[other] < tier and
        TowerTier[other] >= 1 and game.towerLanes[other] ==
          game.towerLanes[slot] and game.towerAlive(other):
            return false
    true
  of 4:
    for lane in 0 .. 2:
      var standing = false
      for other in 0 ..< NumTowers:
        if TowerTeam[other] == team and TowerTier[other] in 1 .. 3 and
          game.towerLanes[other] == lane and game.towerAlive(other):
            standing = true
      if not standing:
        return true
    false
  else:
    for other in 0 ..< NumTowers:
      if TowerTeam[other] == team and TowerTier[other] == 4 and
        game.towerAlive(other):
          return false
    true

proc killPlayer(game: Moba, pid: int) =
  ## Trait 6: takes a dead hero off the map until its respawn timer ends.
  let cell = mapOffset(int(game.entities[pid].y), int(game.entities[pid].x))
  if game.pids[cell] == int32(pid):
    game.grid[cell] = EmptyTile
    game.pids[cell] = -1
  inc game.deaths[pid]
  game.dead[pid] = true
  game.respawnTimers[pid] = min(RespawnMax,
    RespawnBase + (game.deaths[pid] - 1) * RespawnGrowth)
  game.entities[pid].health = 0
  game.entities[pid].y = game.entities[pid].spawnY
  game.entities[pid].x = game.entities[pid].spawnX

proc attack(game: Moba, attacker, target: int, damage: float32): int =
  ## moba's attack: damages a hostile target in L1 range 12 and pays kill
  ## XP, death and tower rewards. 0 on a hit, 1 otherwise.
  if game.entities[target].pid == -1 or
    game.entities[target].team == game.entities[attacker].team:
      return 1
  if target < NumPlayers and game.dead[target]:
    return 1
  if game.trait(7) and game.entities[target].kind == TowerEntity and
    not game.exposed(target - TowerOffset):
      return 1
  if l1(game.entities[attacker].y, game.entities[attacker].x,
    game.entities[target].y, game.entities[target].x) > 12:
      return 1
  if damage < game.entities[target].health:
    game.entities[target].health -= damage
    game.entities[attacker].targetPid = game.entities[target].pid
    game.entities[target].isHit = 1
    return 0
  game.entities[target].health = 0
  if game.entities[target].pid == RadiantAncient:
    game.shouldReset = true
  let
    kind = game.entities[target].kind
    targetY = game.entities[target].y
    targetX = game.entities[target].x
  case kind
  of PlayerEntity:
    game.rewards[game.entities[target].pid].death = game.rewardDeath
    if game.trait(6):
      game.killPlayer(target)
    else:
      game.spawnPlayer(target)
  else:
    game.killEntity(game.entities[target])
  if game.entities[attacker].kind != PlayerEntity:
    return 0
  var xp =
    if kind == PlayerEntity:
      if game.trait(2): GotaHeroKillXp
      else: 100 + int(float32(game.entities[target].xp) / 7.69'f32)
    else:
      game.entities[target].xpOnKill
  let first = if game.entities[attacker].team == 0: 0 else: 5
  var
    inRange: array[5, bool]
    count = 0
  for i in 0 ..< 5:
    let ally = game.entities[first + i]
    if ally.pid == game.entities[attacker].pid:
      inRange[i] = true
      inc count
      continue
    if l1(ally.y, ally.x, targetY, targetX) <= XpRange:
      inRange[i] = true
      inc count
  xp = xp div count
  for i in 0 ..< 5:
    if not inRange[i]:
      continue
    let index = first + i
    if game.entities[index].xp > 10_000_000:
      continue
    if game.trait(2):
      game.gainXp(index, xp)
    else:
      game.entities[index].xp += xp
      game.rewards[index].xp = float32(xp) * game.rewardXp
      game.entities[index].level = calcLevel(game.entities[index].xp)
      let level = game.entities[index].level
      game.entities[index].maxHealth = game.entities[index].baseHealth +
        float32(level * game.entities[index].hpGainPerLevel)
      game.entities[index].maxMana = game.entities[index].baseMana +
        float32(level * game.entities[index].manaGainPerLevel)
      game.entities[index].damage = game.entities[index].baseDamage +
        float32(level * game.entities[index].damageGainPerLevel)
  if game.trait(2) and kind == TowerEntity and
    (target == RadiantAncient or target == DireAncient):
      # GotA pays every hero of the winning team for the god.
      for i in 0 ..< 5:
        game.gainXp(first + i, GotaGodXp)
  if kind == TowerEntity:
    game.rewards[game.entities[attacker].pid].tower = game.rewardTower
  0

proc basicAttack(game: Moba, attacker, target: int): int =
  ## moba's basic_attack: starts the cooldown even when the hit fails.
  if game.entities[attacker].basicAttackTimer > 0:
    return 1
  let reach = game.entities[attacker].reach
  if reach > 0:
    # Traits 2 and 3: basic attacks only within the attacker's reach.
    let
      dy = game.entities[attacker].y - game.entities[target].y
      dx = game.entities[attacker].x - game.entities[target].x
    if dy * dy + dx * dx > reach * reach:
      return 1
  game.entities[attacker].basicAttackTimer =
    game.entities[attacker].basicAttackCd
  game.attack(attacker, target, game.entities[attacker].damage)

proc heal(game: Moba, healer, target: int, amount: float32): int =
  ## moba's heal: allied players only.
  if target < NumPlayers and game.dead[target]:
    return 1
  if game.entities[target].pid == -1 or
    game.entities[target].team != game.entities[healer].team:
      return 1
  if game.entities[target].kind != PlayerEntity:
    return 1
  let missing = int(game.entities[target].maxHealth -
    game.entities[target].health)
  if amount <= float32(missing):
    game.entities[target].health += amount
    return 0
  game.entities[target].health = game.entities[target].maxHealth
  0

proc spawnCreep(game: Moba, slot, lane: int) =
  ## moba's spawn_creep at the lane's first waypoint.
  let pid = CreepOffset + slot
  var creep = game.entities[pid]
  if lane < 3:
    creep.team = 0
    creep.gridId = RadiantCreepTile
  else:
    creep.team = 1
    creep.gridId = DireCreepTile
  creep.pid = pid
  creep.kind = CreepEntity
  creep.maxHealth = 450
  creep.lane = lane
  creep.xpOnKill = 60
  creep.damage = 22
  creep.basicAttackCd = 5
  creep.ranged = false
  creep.reach = 0
  if game.trait(3):
    creep.maxHealth = GotaCreepHealth
    creep.damage = GotaCreepDamage
  if game.trait(2):
    creep.xpOnKill = GotaCreepXp
  let
    spawnY = int(Waypoints[lane][0][0])
    spawnX = int(Waypoints[lane][0][1])
  var y, x: int
  for i in 0 ..< 10:
    y = spawnY + game.rand() mod 7 - 3
    x = spawnX + game.rand() mod 7 - 3
    if game.grid[mapOffset(y, x)] == EmptyTile:
      break
  creep.health = creep.maxHealth
  creep.targetPid = -1
  creep.waypoint = 1
  creep.lastX = float32(x)
  creep.lastY = float32(y)
  discard game.moveTo(creep, float32(y), float32(x))
  game.entities[pid] = creep

proc spawnNeutral(game: Moba, slot: int) =
  ## moba's spawn_neutral within 3 cells of its camp.
  let pid = NeutralOffset + slot
  var neutral = game.entities[pid]
  neutral.pid = pid
  neutral.health = neutral.maxHealth
  neutral.basicAttackTimer = 0
  neutral.targetPid = -1
  let
    spawnY = int(neutral.spawnY)
    spawnX = int(neutral.spawnX)
  var y, x: int
  for i in 0 ..< 100:
    y = spawnY + game.rand() mod 7 - 3
    x = spawnX + game.rand() mod 7 - 3
    if game.grid[mapOffset(y, x)] == EmptyTile:
      break
  neutral.lastX = float32(x)
  neutral.lastY = float32(y)
  discard game.moveTo(neutral, float32(y), float32(x))
  game.entities[pid] = neutral

proc scanAoe(
  game: Moba,
  scanner, radius: int,
  excludeFriendly, excludeHostile, excludeCreeps, excludeNeutrals,
    excludeTowers: bool
): int =
  ## moba's scan_aoe: lists entities in a square around the scanner in
  ## row order, ending with -1; 0 when it found any.
  let
    centerY = int(game.entities[scanner].y)
    centerX = int(game.entities[scanner].x)
    team = game.entities[scanner].team
    pid = game.entities[scanner].pid
  var count = 0
  for y in centerY - radius .. centerY + radius:
    for x in centerX - radius .. centerX + radius:
      if y < 0 or y >= MapSize or x < 0 or x >= MapSize:
        continue
      let targetPid = game.pids[mapOffset(y, x)]
      if targetPid == -1:
        continue
      let target = game.entities[targetPid]
      if excludeFriendly and target.team == team:
        continue
      if excludeHostile and target.team != team:
        continue
      if excludeNeutrals and target.kind == NeutralEntity:
        continue
      if excludeCreeps and target.kind == CreepEntity:
        continue
      if excludeTowers and target.kind == TowerEntity:
        continue
      if count < ScanCapacity - 1:
        game.scanned[pid][count] = int16(targetPid)
        inc count
  game.scanned[pid][count] = -1
  if count == 0: 1 else: 0

proc nearestScanned(game: Moba, scanner: int): int =
  ## moba's nearest_scanned_target from the last scan, or -1.
  result = -1
  var nearest = 9999999'f32
  let
    y = game.entities[scanner].y
    x = game.entities[scanner].x
    pid = game.entities[scanner].pid
  for i in 0 ..< ScanSlots:
    let target = int(game.scanned[pid][i])
    if target == -1:
      break
    let distance = l1(y, x, game.entities[target].y, game.entities[target].x)
    if distance < nearest:
      result = target
      nearest = distance

proc aoeScanned(game: Moba, caster: int, damage: float32, stun: int) =
  ## moba's aoe_scanned: damages (or heals, when negative) every scanned
  ## entity and stuns it.
  let pid = game.entities[caster].pid
  for i in 0 ..< ScanSlots:
    let target = int(game.scanned[pid][i])
    if target == -1:
      break
    if damage < 0:
      discard game.heal(caster, target, -damage)
      continue
    discard game.attack(caster, target, damage)
    if stun > 0:
      game.entities[target].stunTimer = stun

proc playerAoeAttack(
  game: Moba,
  caster, target, radius: int,
  damage: float32,
  stun: int
): int =
  ## moba's player_aoe_attack, centred on the caster.
  let
    excludeHostile = damage < 0
    excludeFriendly = not excludeHostile
  if game.scanAoe(caster, radius, excludeFriendly, excludeHostile, false,
    false, false) != 0:
      return 1
  game.aoeScanned(caster, damage, stun)
  game.entities[caster].targetPid = game.entities[target].pid
  game.entities[caster].attackAoe = radius
  0

proc push(game: Moba, source, target: int, amount: float32): int =
  ## moba's push: moves `target` along the source-to-target direction.
  var
    dx = game.entities[target].x - game.entities[source].x
    dy = game.entities[target].y - game.entities[source].y
  let distance = abs(dx) + abs(dy)
  if distance == 0:
    return 1
  dx = amount * dx / distance
  dy = amount * dy / distance
  game.moveTo(game.entities[target], game.entities[target].y + dy,
    game.entities[target].x + dx)

proc pull(game: Moba, source, target: int, amount: float32): int =
  ## moba's pull.
  game.push(source, target, -amount)

proc aoePull(game: Moba, caster, radius: int, amount: float32): int =
  ## moba's aoe_pull, which moves the caster toward each scanned enemy.
  discard game.scanAoe(caster, radius, true, false, false, false, true)
  result = 1
  let pid = game.entities[caster].pid
  for i in 0 ..< ScanSlots:
    let target = int(game.scanned[pid][i])
    if target == -1:
      break
    discard game.pull(target, caster, amount)
    result = 0

proc creepAi(game: Moba, index: int) =
  ## moba's creep_ai: fights the nearest scanned enemy, else walks the
  ## lane's waypoints. Scripted heroes run it too.
  if game.tick mod 5 == 0:
    discard game.scanAoe(index, CreepVision, true, false, false, true, false)
  let pid = game.entities[index].pid
  if game.scanned[pid][0] != -1:
    let target = game.nearestScanned(index)
    let
      destY = game.entities[target].y
      destX = game.entities[target].x
    let reach = if game.entities[index].ranged: GotaCreepRange else: 2
    if l1(game.entities[index].y, game.entities[index].x, destY, destX) <
      reach:
        discard game.basicAttack(index, target)
    discard game.moveTowards(game.entities[index], int(destY), int(destX),
      game.agentSpeed)
  else:
    let
      lane = game.entities[index].lane
      waypoint = game.entities[index].waypoint
      destY = Waypoints[lane][waypoint][0]
      destX = Waypoints[lane][waypoint][1]
    discard game.moveTowards(game.entities[index], int(destY), int(destX),
      game.agentSpeed)
    if l1(game.entities[index].y, game.entities[index].x, destY, destX) < 2 and
      waypoint < WaypointCounts[lane] - 1:
        inc game.entities[index].waypoint

proc neutralAi(game: Moba, index: int) =
  ## moba's neutral_ai: fights heroes within 3 cells, else goes home.
  if game.tick mod 5 == 0:
    discard game.scanAoe(index, NeutralVision, true, false, true, true, true)
  let pid = game.entities[index].pid
  if game.scanned[pid][0] != -1:
    let target = game.nearestScanned(index)
    if l1(game.entities[index].y, game.entities[index].x,
      game.entities[target].y, game.entities[target].x) < 2:
        discard game.basicAttack(index, target)
    else:
      discard game.moveTowards(game.entities[index],
        int(game.entities[target].y), int(game.entities[target].x),
        game.agentSpeed)
  elif l1(game.entities[index].y, game.entities[index].x,
    game.entities[index].spawnY, game.entities[index].spawnX) > 2:
      discard game.moveTowards(game.entities[index],
        int(game.entities[index].spawnY), int(game.entities[index].spawnX),
        game.agentSpeed)

proc updateStatus(entity: var Entity) =
  ## moba's update_status.
  if entity.stunTimer > 0:
    dec entity.stunTimer
  if entity.moveTimer > 0:
    dec entity.moveTimer
  if entity.moveTimer == 0:
    entity.moveModifier = 1

proc updateCooldowns(entity: var Entity) =
  ## moba's update_cooldowns.
  if entity.qTimer > 0:
    dec entity.qTimer
  if entity.wTimer > 0:
    dec entity.wTimer
  if entity.eTimer > 0:
    dec entity.eTimer
  if entity.basicAttackTimer > 0:
    dec entity.basicAttackTimer

proc useSkill(game: Moba, skill: Skill, caster, target: int): int =
  ## moba's fifteen skill functions; `target` is -1 for none. 0 on use.
  let level = float32(game.entities[caster].level)
  template mana(): float32 = game.entities[caster].mana
  case skill
  of SupportHook:
    if target == -1 or mana < 100:
      return 1
    discard game.pull(target, caster, 1.5 + 0.1 * level)
    game.entities[caster].mana -= 100
    game.entities[caster].qTimer = 15
    result = 0
  of SupportAoeHeal:
    if mana < 100:
      return 1
    if game.playerAoeAttack(caster, caster, 5, -350 - 50 * level, 0) == 0:
      game.entities[caster].mana -= 100
      game.entities[caster].wTimer = 50
      return 0
    result = 1
  of SupportStun:
    if target == -1 or mana < 75:
      return 1
    if game.attack(caster, target, 50 + 20 * level) == 0:
      game.entities[target].stunTimer = int(15 + 0.5 * level)
      game.entities[caster].mana -= 75
      game.entities[caster].eTimer = 60
      return 0
    result = 1
  of AssassinAoeMinions:
    if target == -1 or mana < 100:
      return 1
    if game.entities[target].kind notin {CreepEntity, NeutralEntity}:
      return 1
    if game.playerAoeAttack(caster, target, 3, 100 + 20 * level, 0) == 0:
      game.entities[caster].mana -= 100
      game.entities[caster].qTimer = 40
      return 0
    result = 1
  of AssassinTpDamage:
    if target == -1 or mana < 150:
      return 1
    if game.moveNear(game.entities[caster], game.entities[target]) != 0:
      return 1
    game.entities[caster].mana -= 150
    if game.attack(caster, target, 250 + 50 * level) == 0:
      game.entities[caster].wTimer = 60
      return 0
    result = 1
  of AssassinMoveBuff:
    if mana < 100:
      return 1
    game.entities[caster].moveModifier = 2
    game.entities[caster].moveTimer = 25
    game.entities[caster].mana -= 100
    game.entities[caster].eTimer = 100
    result = 0
  of BurstNuke:
    if target == -1 or mana < 200:
      return 1
    if game.attack(caster, target, 250 + 40 * level) == 0:
      game.entities[caster].mana -= 200
      game.entities[caster].qTimer = 70
      return 0
    result = 1
  of BurstAoe:
    if target == -1 or mana < 100:
      return 1
    if game.playerAoeAttack(caster, target, 2, 100 + 40 * level, 0) == 0:
      game.entities[caster].mana -= 100
      game.entities[caster].wTimer = 40
      return 0
    result = 1
  of BurstAoeStun:
    if target == -1 or mana < 75:
      return 1
    if game.playerAoeAttack(caster, target, 2, 0,
      int(10 + 0.5 * level)) == 0:
        game.entities[caster].mana -= 75
        game.entities[caster].eTimer = 50
        return 0
    result = 1
  of TankAoeDot:
    if mana < 5:
      return 1
    if game.playerAoeAttack(caster, caster, 2, 25 + 2 * level, 0) == 0:
      game.entities[caster].mana -= 5
      return 0
    result = 1
  of TankSelfHeal:
    if mana < 100:
      return 1
    if game.heal(caster, caster, 400 + 125 * level) == 0:
      game.entities[caster].mana -= 100
      game.entities[caster].wTimer = 70
      return 0
    result = 1
  of TankEngageAoe:
    if target == -1 or mana < 50:
      return 1
    if game.moveNear(game.entities[caster], game.entities[target]) == 0:
      game.entities[caster].mana -= 50
      game.entities[caster].eTimer = 40
      discard game.aoePull(caster, 4, 2 + 0.1 * level)
      return 0
    result = 1
  of CarryRetreatSlow:
    if target == -1 or mana < 25:
      return 1
    result = 1
    for i in 0 ..< 3:
      if game.entities[caster].mana < 25:
        return
      if game.push(target, caster, 3 + 0.1 * level) == 0:
        game.entities[target].moveTimer = 15
        game.entities[target].moveModifier = 0.5
        game.entities[caster].mana -= 25
        game.entities[caster].qTimer = 40
        result = 0
  of CarrySlowDamage:
    if target == -1 or mana < 150:
      return 1
    if game.attack(caster, target, 50 + 20 * level) == 0:
      game.entities[target].moveTimer = 20 + int(level)
      game.entities[target].moveModifier = 0.5
      game.entities[caster].mana -= 150
      game.entities[caster].wTimer = 40
      return 0
    result = 1
  of CarryAoe:
    if target == -1 or mana < 100:
      return 1
    if game.playerAoeAttack(caster, target, 2, 100 + 20 * level, 0) == 0:
      game.entities[caster].mana -= 100
      game.entities[caster].eTimer = 40
      return 0
    result = 1

proc stepCreeps(game: Moba) =
  ## moba's step_creeps: a wave of 5 per lane every 150 ticks.
  let
    period = if game.trait(3): GotaWaveSteps else: 150
    perLane = if game.trait(3): GotaMeleePerLane + GotaRangedPerLane else: 5
  if game.tick mod period == 0:
    for lane in 0 ..< 6:
      for i in 0 ..< perLane:
        let pid = CreepOffset + game.creepIdx
        game.killEntity(game.entities[pid])
        game.spawnCreep(game.creepIdx, lane)
        game.entities[pid].ranged = game.trait(3) and i >= GotaMeleePerLane
        game.creepIdx = (game.creepIdx + 1) mod game.creepSlots
  for slot in 0 ..< game.creepSlots:
    let index = CreepOffset + slot
    if game.entities[index].pid == -1:
      continue
    updateStatus(game.entities[index])
    updateCooldowns(game.entities[index])
    if game.entities[index].stunTimer > 0:
      continue
    game.creepAi(index)

proc stepNeutrals(game: Moba) =
  ## moba's step_neutrals: every camp respawns every 600 ticks.
  if game.tick mod 600 == 0:
    for camp in 0 ..< 18:
      for i in 0 ..< 4:
        game.spawnNeutral(4 * camp + i)
  for slot in 0 ..< NumNeutrals:
    let index = NeutralOffset + slot
    if game.entities[index].pid == -1:
      continue
    updateStatus(game.entities[index])
    updateCooldowns(game.entities[index])
    if game.entities[index].stunTimer > 0:
      continue
    game.neutralAi(index)

proc stepTowers(game: Moba) =
  ## moba's step_towers: shoot the nearest of the last scan.
  for slot in 0 ..< NumTowers:
    let index = TowerOffset + slot
    if game.entities[index].pid == -1:
      continue
    updateCooldowns(game.entities[index])
    if game.entities[index].basicAttackTimer > 0:
      continue
    if game.tick mod 3 == 0:
      let vision =
        if game.trait(4): GotaTowerReach[TowerTier[slot] - 1]
        else: TowerVision
      discard game.scanAoe(index, vision, true, false, false, true, true)
    let target = game.nearestScanned(index)
    if target != -1:
      discard game.basicAttack(index, target)

proc stepPlayers(game: Moba): array[NumPlayers, float32] =
  ## moba's step_players; returns each player's reward this tick (0 for a
  ## stunned player, which moba skips).
  for pid in 0 ..< NumPlayers:
    game.rewards[pid] = Reward()
  for pid in 0 ..< NumPlayers:
    if game.dead[pid]:
      dec game.respawnTimers[pid]
      if game.respawnTimers[pid] > 0:
        continue
      game.dead[pid] = false
      game.spawnPlayer(pid)
    var
      manaGain = 2'f32
      healthGain = 2'f32
    if game.trait(5):
      manaGain = 0
      healthGain = 0
      if l1(game.entities[pid].y, game.entities[pid].x,
        game.entities[pid].spawnY, game.entities[pid].spawnX) <=
          SpawnHealRange:
            manaGain = 0.05 * game.entities[pid].maxMana
            healthGain = 0.05 * game.entities[pid].maxHealth
    if game.entities[pid].mana < game.entities[pid].maxMana:
      game.entities[pid].mana += manaGain
    if game.entities[pid].mana > game.entities[pid].maxMana:
      game.entities[pid].mana = game.entities[pid].maxMana
    if game.entities[pid].health < game.entities[pid].maxHealth:
      game.entities[pid].health += healthGain
    if game.entities[pid].health > game.entities[pid].maxHealth:
      game.entities[pid].health = game.entities[pid].maxHealth
    updateStatus(game.entities[pid])
    updateCooldowns(game.entities[pid])
    if game.entities[pid].stunTimer > 0:
      continue
    if game.scriptOpponents and pid >= 5:
      game.creepAi(pid)
    else:
      let action = game.actions[pid]
      var
        velY = (float32(action[0]) - 3) / 3
        velX = (float32(action[1]) - 3) / 3
      let magnitude = sqrt(velY * velY + velX * velX)
      if magnitude > 1:
        velY /= magnitude
        velX /= magnitude
      if action[2] == 1 or action[2] == 0:
        discard game.scanAoe(pid, game.visionRange, true, false, false, false,
          false)
      elif action[2] == 2:
        discard game.scanAoe(pid, game.visionRange, true, false, true, true,
          false)
      var target = -1
      if game.scanned[pid][0] != -1:
        target = game.nearestScanned(pid)
      if action[3] != 0 and game.entities[pid].qTimer <= 0 and
        game.useSkill(game.skills[pid][0], pid, target) == 0:
          discard
      elif action[4] != 0 and game.entities[pid].wTimer <= 0 and
        game.useSkill(game.skills[pid][1], pid, target) == 0:
          discard
      elif action[5] != 0 and game.entities[pid].eTimer <= 0 and
        game.useSkill(game.skills[pid][2], pid, target) == 0:
          discard
      elif target != -1 and game.basicAttack(pid, target) == 0:
        discard
      let
        modifier = game.entities[pid].moveModifier * game.agentSpeed
        destY = game.entities[pid].y + modifier * velY
        destX = game.entities[pid].x + modifier * velX
      discard game.moveTo(game.entities[pid], destY, destX)
    let reward = game.rewards[pid]
    result[pid] = reward.death + reward.xp + reward.distance + reward.tower

proc toByte(value: float32): int32 {.inline.} =
  ## C's float to unsigned char for in-range values.
  int32(clamp(int(value), 0, 255))

proc observe*(game: Moba, pid: int, observation: var openArray[int32]) =
  ## moba's compute_observations for one player, byte for byte: the
  ## 11 x 11 map window with entity health, mana and level written at the
  ## following offsets (overlapping as in moba), then 26 extras at 484.
  for i in 0 ..< ObservationSize:
    observation[i] = 0
  let
    player = game.entities[pid]
    reward = game.rewards[pid]
    vision = game.visionRange
    y = int(player.y)
    x = int(player.x)
  observation[ExtraStart + 0] = int32(x)
  observation[ExtraStart + 1] = int32(y)
  observation[ExtraStart + 2] = int32(player.level)
  observation[ExtraStart + 3] = toByte(10 * player.health / player.maxHealth)
  observation[ExtraStart + 4] = toByte(10 * player.mana / player.maxMana)
  observation[ExtraStart + 5] = toByte(player.damage / 50)
  observation[ExtraStart + 6] = toByte(player.moveSpeed)
  observation[ExtraStart + 7] = toByte(player.moveModifier)
  observation[ExtraStart + 8] = int32(player.stunTimer and 255)
  observation[ExtraStart + 9] = int32(player.moveTimer and 255)
  observation[ExtraStart + 10] = int32(player.qTimer and 255)
  observation[ExtraStart + 11] = int32(player.wTimer and 255)
  observation[ExtraStart + 12] = int32(player.eTimer and 255)
  observation[ExtraStart + 13] = int32(player.basicAttackTimer and 255)
  observation[ExtraStart + 14] = int32(player.basicAttackCd and 255)
  observation[ExtraStart + 15] = int32(player.isHit)
  observation[ExtraStart + 16] = int32(player.team)
  observation[ExtraStart + 17 + player.heroType] = 1
  observation[ExtraStart + 22] = int32(reward.death != 0)
  observation[ExtraStart + 23] = int32(reward.xp != 0)
  observation[ExtraStart + 24] = int32(reward.distance != 0)
  observation[ExtraStart + 25] = int32(reward.tower != 0)
  for dy in -vision .. vision:
    for dx in -vision .. vision:
      let
        yy = y + dy
        xx = x + dx
        index = (dy + vision) * Window + (dx + vision)
      if yy < 0 or yy >= MapSize or xx < 0 or xx >= MapSize:
        observation[index] = int32(WallTile)
        continue
      let cell = mapOffset(yy, xx)
      observation[index] = int32(game.grid[cell])
      let targetPid = game.pids[cell]
      if targetPid == -1:
        continue
      let target = game.entities[targetPid]
      observation[index + 1] = toByte(10 * target.health / target.maxHealth)
      if target.maxMana > 0:
        observation[index + 2] = toByte(10 * target.mana / target.maxMana)
      observation[index + 3] = int32(target.level)

proc reset*(game: Moba) =
  ## moba's puf_reset: towers rebuilt, heroes at level 1 near spawn.
  game.tick = 0
  for i in 0 ..< NumEntities:
    game.entities[i].targetPid = -1
    game.scanned[i][0] = -1
    game.killEntity(game.entities[i])
  game.grid = game.origGrid
  for cell in game.pids.mitems:
    cell = -1
  for slot in 0 ..< NumTowers:
    let pid = TowerOffset + slot
    game.entities[pid].targetPid = -1
    game.entities[pid].pid = pid
    game.entities[pid].health = game.entities[pid].maxHealth
    game.entities[pid].basicAttackTimer = 0
    game.entities[pid].x = 0
    game.entities[pid].y = 0
    let cell = mapOffset(int(game.entities[pid].spawnY),
      int(game.entities[pid].spawnX))
    game.grid[cell] = EmptyTile
    doAssert game.moveTo(game.entities[pid], game.entities[pid].spawnY,
      game.entities[pid].spawnX) == 0
    game.entities[pid].lastX = game.entities[pid].x
    game.entities[pid].lastY = game.entities[pid].y
  for pid in 0 ..< NumPlayers:
    game.entities[pid].pid = pid
    game.entities[pid].targetPid = -1
    game.entities[pid].xp = 0
    game.entities[pid].level = 1
    game.dead[pid] = false
    game.respawnTimers[pid] = 0
    game.deaths[pid] = 0
    game.spawnPlayer(pid)

proc step*(game: Moba): array[NumPlayers, float32] =
  ## moba's puf_step: one tick, then a reset when an ancient fell. Returns
  ## each player's reward; `finished` and the victory flags report a match
  ## that ended this tick.
  game.finished = false
  for pid in 0 ..< NumEntities:
    game.entities[pid].targetPid = -1
    game.entities[pid].attackAoe = 0
    game.entities[pid].lastX = game.entities[pid].x
    game.entities[pid].lastY = game.entities[pid].y
    game.entities[pid].isHit = 0
  game.stepNeutrals()
  game.stepCreeps()
  game.stepTowers()
  result = game.stepPlayers()
  inc game.tick
  let
    dire = game.entities[DireAncient]
    radiant = game.entities[RadiantAncient]
    radiantWins = dire.health <= 0 or dire.pid == -1
    direWins = radiant.health <= 0 or radiant.pid == -1
  game.shouldReset = false
  let clockOut = game.trait(8) and game.tick >= ClockSteps
  if radiantWins or direWins or clockOut:
    game.finished = true
    game.radiantVictory = radiantWins
    game.direVictory = direWins
    game.finishedTick = game.tick
    game.reset()

proc assignTowerLanes(game: Moba) =
  ## Each tower's lane: the team's lane whose waypoints come nearest.
  for slot in 0 ..< NumTowers:
    let first = TowerTeam[slot] * 3
    var best = Inf.float32
    for lane in first .. first + 2:
      for i in 0 ..< WaypointCounts[lane]:
        let distance = l1(TowerY[slot], TowerX[slot], Waypoints[lane][i][0],
          Waypoints[lane][i][1])
        if distance < best:
          best = distance
          game.towerLanes[slot] = lane - first

proc newMoba*(seed: uint32, traits = 0'u16): Moba =
  ## moba's init_moba with moba.ini's [env]: vision 5, speed 1, scripted
  ## opponents and its reward weights, plus the cut-ladder GotA traits.
  result = Moba(
    traits: traits,
    creepSlots: if (traits and (1'u16 shl 3)) != 0: NumCreeps
      else: MobaCreepSlots,
    visionRange: 5,
    agentSpeed: 1,
    rewardDeath: -0.163764,
    rewardXp: 0.00665677,
    rewardDistance: 0,
    rewardTower: 0.642119,
    scriptOpponents: true,
    rngState: seed or 1
  )
  for i in 0 ..< MapSize * MapSize:
    result.origGrid[i] = uint8(MapData[i])
  result.grid = result.origGrid
  for cell in result.pids.mitems:
    cell = -1
  result.pathRng = newSeq[float32](PathRngCount)
  for value in result.pathRng.mitems:
    value = -1 + 2 * float32(result.rand()) / float32(0x7fffffff)
  for i in 0 ..< NumEntities:
    result.scanned[i][0] = -1
  const
    Stats = [
      # heroType, gridId offset, health, mana, hp/level, mana/level,
      # damage/level, lane on team 0 (team 1 adds 3)
      [0, 0, 500, 250, 100, 50, 10, 2],
      [1, 1, 400, 300, 100, 65, 10, 1],
      [2, 2, 400, 300, 75, 90, 10, 1],
      [3, 3, 700, 200, 150, 50, 15, 0],
      [4, 4, 300, 250, 50, 50, 25, 2]
    ]
    Kits = [
      [SupportHook, SupportAoeHeal, SupportStun],
      [AssassinAoeMinions, AssassinTpDamage, AssassinMoveBuff],
      [BurstNuke, BurstAoe, BurstAoeStun],
      [TankAoeDot, TankSelfHeal, TankEngageAoe],
      [CarryRetreatSlow, CarrySlowDamage, CarryAoe]
    ]
  for team in 0 .. 1:
    let
      spawnY = if team == 0: float32(MapSize - 15) else: 15'f32
      spawnX = if team == 0: 12'f32 else: float32(MapSize - 12)
    for role in 0 ..< 5:
      let pid = team * 5 + role
      var player = Entity(
        pid: pid,
        kind: PlayerEntity,
        team: team,
        spawnY: spawnY,
        spawnX: spawnX,
        moveSpeed: result.agentSpeed,
        basicAttackCd: 8,
        baseDamage: 50,
        heroType: Stats[role][0],
        gridId: RadiantSupportTile + uint8(Stats[role][1] + team * 5),
        baseHealth: float32(Stats[role][2]),
        baseMana: float32(Stats[role][3]),
        hpGainPerLevel: Stats[role][4],
        manaGainPerLevel: Stats[role][5],
        damageGainPerLevel: Stats[role][6],
        lane: Stats[role][7] + 3 * team,
        targetPid: -1
      )
      if result.trait(2):
        # GotA's level-1 values; moba's formula adds one level's gain.
        let hero = GotaHeroes[role]
        player.hpGainPerLevel = hero[1]
        player.baseHealth = float32(hero[0] - hero[1])
        player.manaGainPerLevel = hero[3]
        player.baseMana = float32(hero[2] - hero[3])
        player.damageGainPerLevel = hero[5]
        player.baseDamage = float32(hero[4] - hero[5])
        player.reach = float32(hero[6]) / 10
        player.basicAttackCd = hero[7]
      result.entities[pid] = player
      result.skills[pid] = Kits[role]
  for slot in 0 ..< NumTowers:
    let pid = TowerOffset + slot
    result.entities[pid] = Entity(
      pid: pid,
      kind: TowerEntity,
      gridId: TowerTile,
      basicAttackCd: 5,
      team: TowerTeam[slot],
      spawnY: TowerY[slot],
      spawnX: TowerX[slot],
      maxHealth:
        if result.trait(4): GotaTowerHealth[TowerTier[slot] - 1]
        else: TowerHealth[slot],
      damage:
        if result.trait(4): GotaTowerDamage[TowerTier[slot] - 1]
        else: TowerDamage[slot],
      xpOnKill: if result.trait(2): GotaTowerXp else: 0,
      tier: TowerTier[slot],
      targetPid: -1
    )
  var index = 0
  for camp in 0 ..< 18:
    for i in 0 ..< 4:
      let pid = NeutralOffset + index
      result.entities[pid] = Entity(
        pid: pid,
        kind: NeutralEntity,
        gridId: NeutralTile,
        maxHealth: 500,
        team: 2,
        spawnY: NeutralCampY[camp],
        spawnX: NeutralCampX[camp],
        xpOnKill: 35,
        basicAttackCd: 5,
        damage: 22,
        targetPid: -1
      )
      inc index
  for slot in 0 ..< NumCreeps:
    result.entities[CreepOffset + slot] = Entity(pid: -1, targetPid: -1)
  result.assignTowerLanes()
  result.reset()
