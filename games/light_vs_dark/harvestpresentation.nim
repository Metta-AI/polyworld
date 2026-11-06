## Render-only harvesting activity. Never writes World or consumes its RNG.
## Fixed per-site slots bound emission independently of worker count.
import std/math
import vmath
import ./[content, maps, sim]

const
  MaxHarvestSites* = 64
  HarvestParticlesPerSite* = 6
  MaxHarvestParticles* = MaxHarvestSites * HarvestParticlesPerSite

type
  HarvestKind* = enum MineSparks, ChopLeaves
  HarvestSite* = object
    active*: bool
    kind*: HarvestKind
    id*: int32
    tilePoint*: Vec2
    cooldown: float32
    serial: uint32
  HarvestParticle* = object
    active*: bool
    offset*, velocity*: Vec3
    age*, lifetime*, size*: float32
    tint*: float32
  HarvestPresentation* = object
    sites*: array[MaxHarvestSites, HarvestSite]
    particles*: array[MaxHarvestParticles, HarvestParticle]
    world: World
    tick: int32

proc siteCount*(fx: HarvestPresentation): int =
  for site in fx.sites:
    if site.active: inc result

proc particleCount*(fx: HarvestPresentation): int =
  for particle in fx.particles:
    if particle.active: inc result

proc clearHarvest*(fx: var HarvestPresentation) =
  fx = HarvestPresentation()

proc pointVisible*(w: World, viewer: int32, point: Vec2): bool =
  ## Current vision only, never explored memory. -1 explicitly means spectator.
  w != nil and (viewer == -1 or w.visible(viewer,
    int32(floor(point.x)), int32(floor(point.y))))

proc visualNoise(seed: uint32): float32 =
  ## Local integer mixer, unrelated to the authoritative RNG/hash.
  var value = seed
  value = (value xor (value shr 16)) * 0x7feb352d'u32
  value = (value xor (value shr 15)) * 0x846ca68b'u32
  value = value xor (value shr 16)
  (value and 65535'u32).float32 / 65535'f32

proc observeSite(fx: var HarvestPresentation,
    seen: var array[MaxHarvestSites, bool], w: World, viewer: int32,
    kind: HarvestKind, id: int32, point: Vec2) =
  if not w.pointVisible(viewer, point): return
  var slot = -1
  for i, site in fx.sites:
    if site.active and site.kind == kind and site.id == id:
      slot = i
      break
  if slot < 0:
    for i, site in fx.sites:
      if not site.active and not seen[i]:
        slot = i
        fx.sites[i] = HarvestSite(active: true, kind: kind,
          id: id, tilePoint: point)
        break
  if slot >= 0: seen[slot] = true

proc updateHarvest*(fx: var HarvestPresentation, w: World, delta: float32,
    viewer = -1'i32, paused = false) =
  ## Call after simulation advancement. Rewinds/world replacement reset the pool.
  ## Pause freezes ages/cadence, but hidden/inactive sources retire immediately.
  if w == nil:
    fx.clearHarvest()
    return
  if fx.world != w or w.tick < fx.tick:
    fx.clearHarvest()
  fx.world = w
  fx.tick = w.tick
  var seen: array[MaxHarvestSites, bool]
  template observe(kindValue: HarvestKind, idValue: int32, pointValue: Vec2) =
    observeSite(fx, seen, w, viewer, kindValue, idValue, pointValue)
  if not w.over:
    for unit in w.units:
      if unit.hp <= 0 or unit.kind != PeonUnit or unit.stateTicks <= 0:
        continue
      if unit.state == UnitInMine:
        let index = w.buildingIndex(unit.sourceId)
        if index < 0: continue
        let mine = w.buildings[index]
        if mine.kind != GoldMineBuilding or mine.state != BuildingComplete or
            mine.hp <= 0 or mine.goldLeft <= 0 or mine.minersInside <= 0:
          continue
        observe(MineSparks, mine.id, vec2(
          mine.origin.x.float32 + mine.footprint.width.float32 * 0.5'f32,
          mine.origin.y.float32 + mine.footprint.depth.float32 * 0.75'f32))
      elif unit.state == UnitChopping and w.map.inGrid(unit.targetTile) and
          tileDistance(unit.tile, unit.targetTile) <= 1:
        let tree = w.map.tileIndex(unit.targetTile)
        if w.treeWood[tree] > 0:
          observe(ChopLeaves, tree, vec2(unit.targetTile.x.float32 + 0.5'f32,
            unit.targetTile.y.float32 + 0.5'f32))
  let dt = if paused: 0'f32 else: clamp(delta, 0'f32, 0.1'f32)
  for i in 0 ..< MaxHarvestSites:
    if not seen[i]: fx.sites[i] = HarvestSite()
    for j in 0 ..< HarvestParticlesPerSite:
      let index = i * HarvestParticlesPerSite + j
      var particle = addr fx.particles[index]
      if not seen[i]:
        particle[] = HarvestParticle()
      elif particle.active:
        particle.age += dt
        particle.offset += particle.velocity * dt
        particle.velocity.y -= 2.8'f32 * dt
        if particle.age >= particle.lifetime or not w.pointVisible(viewer,
            fx.sites[i].tilePoint + vec2(particle.offset.x, particle.offset.z)):
          particle.active = false
    if not seen[i] or paused: continue
    fx.sites[i].cooldown -= dt
    if fx.sites[i].cooldown > 0: continue
    inc fx.sites[i].serial
    let leaves = fx.sites[i].kind == ChopLeaves
    fx.sites[i].cooldown = if leaves: 0.72'f32 else: 0.48'f32
    for j in 0 ..< (if leaves: 5 else: 3):
      let seed = uint32(fx.sites[i].id) * 73'u32 +
        fx.sites[i].serial * 179'u32 + j.uint32 * 31'u32
      let angle = visualNoise(seed) * 2'f32 * PI.float32
      let speed = 0.35'f32 + visualNoise(seed + 1) * 0.6'f32
      fx.particles[i * HarvestParticlesPerSite + j] = HarvestParticle(
        active: true, velocity: vec3(cos(angle) * speed,
          0.6'f32 + visualNoise(seed + 2) * 0.5'f32, sin(angle) * speed),
        lifetime: (if leaves: 0.45'f32 else: 0.28'f32) +
          visualNoise(seed + 3) * 0.13'f32,
        size: (if leaves: 0.065'f32 else: 0.025'f32) +
          visualNoise(seed + 4) * 0.012'f32,
        tint: visualNoise(seed + 5))

when not defined(headless):
  import chroma
  import polyworld/worldbars

  proc addHarvestBillboards*(renderer: var WorldBarRenderer,
      fx: HarvestPresentation, w: World, viewer: int32,
      anchor: proc(site: HarvestSite): Vec3 {.closure.}) =
    ## Appends one small batch to the existing depth-tested billboard renderer.
    ## Callback returns art-aligned world position, tile origin = -map.side/2.
    ## Recheck actual anchor and full particle extent at draw time: a visibility
    ## change between update and draw cannot leak through explored-only fog.
    if w == nil or fx.world != w: return
    let half = w.map.side.float32 * 0.5'f32
    for i, site in fx.sites:
      if not site.active or not w.pointVisible(viewer, site.tilePoint): continue
      let origin = anchor(site)
      if not w.pointVisible(viewer, vec2(origin.x + half, origin.z + half)):
        continue
      for j in 0 ..< HarvestParticlesPerSite:
        let particle = fx.particles[i * HarvestParticlesPerSite + j]
        if not particle.active: continue
        let position = origin + particle.offset
        let point = vec2(position.x + half, position.z + half)
        # Conservative horizontal bound for any camera-facing quad orientation.
        let radius = particle.size * 2'f32
        var visible = true
        for dx in [-radius, 0'f32, radius]:
          for dz in [-radius, 0'f32, radius]:
            if not w.pointVisible(viewer, point + vec2(dx, dz)): visible = false
        if not visible: continue
        let fade = 1'f32 - particle.age / particle.lifetime
        let color =
          if site.kind == MineSparks:
            rgbx(255, uint8(145 + 65 * fade), 48, uint8(225 * fade))
          else:
            rgbx(uint8(60 + 30 * particle.tint),
              uint8(145 + 35 * particle.tint), 48, uint8(220 * fade))
        let size =
          if site.kind == MineSparks: vec2(particle.size * 0.65'f32, particle.size * 1.7'f32)
          else: vec2(particle.size * (0.6'f32 + 0.4'f32 * abs(cos(particle.age * 12))),
            particle.size * 0.48'f32)
        renderer.addBillboardQuad(position, -size * 0.5'f32, size, color)
