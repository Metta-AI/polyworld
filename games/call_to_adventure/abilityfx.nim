## How every ability reads on screen.
##
## The simulation steps each ability through anticipation, release and
## recovery (see `AbilitySpec`). This module turns those phases into what a
## spectator sees, from nothing but the actor's action and its tick count,
## so it keeps no memory between frames and a seek or a rewound replay shows
## exactly the same picture.
##
## The spectator's language has two words. A skill's target is a single
## actor or an area of the floor (`SkillTarget`), and its caster is friendly
## (the party) or an enemy (`SkillSide`). While a skill winds up, and only
## then, one gizmo marks it: a circle round its single target, or the true
## shape of its area, with a thin solid border and a fill that turns from
## clear to solid as the wind-up runs out, plus a dotted arrow from the
## caster, which a line or a cone leaving the caster's own feet has no need
## of.
## Friendly gizmos are light green, enemy ones red. Nothing else is drawn on
## the floor.
##
## Release and recovery read from the body alone: the clip snaps through
## the blow and holds it for a beat of hit-stop, and missiles fly from the
## user to its target. Whoever is struck shows it only in its health bar
## and the burst where the hit lands.
##
## Nothing here is authoritative and nothing is written back.

import
  std/math,
  chroma, vmath,
  polyworld/[particleshaders, pathing, shapes],
  assets, attackclips, content, sim

type
  Delivery* = enum
    ## How an ability's release travels, which picks its clip, its body
    ## motion and its particles.
    SwingDelivery,   ## a cutting arc in front of the user
    ThrustDelivery,  ## a straight jab, stab or bite
    SlamDelivery,    ## an overhead blow
    ShotDelivery,    ## a fast straight missile
    LobDelivery,     ## a slow missile that bursts where it lands
    SkyDelivery,     ## falls out of the sky onto a marked spot
    VolleyDelivery,  ## shot up into the sky, and rains down on a marked spot
    MendDelivery,    ## healing carried over to an ally
    WardDelivery,    ## a shell or blessing on the user
    RallyDelivery,   ## one blast that reaches the whole party
    QuaffDelivery,   ## something drunk or crushed in the hand
    GrabDelivery,    ## picking up loot, which is instant and never played
    RiteDelivery,    ## a working with no foe at the end of it
    GrowDelivery     ## something springing up out of the floor on a spot

  AbilityLook* = object
    delivery*: Delivery
    heavy*: bool                  ## a big blow: a bigger lunge or kick
    burst*: ParticleEffectKind    ## the particles where a hit lands
    missile*: ParticleEffectKind  ## what flies, for a shot or a lob
    plain*: bool                  ## lands on the body alone, with no burst

  SkillSide* = enum
    ## Whose skill it is, from the spectator's seat.
    FriendlySide, EnemySide

  Telegraph* = object
    ## One winding-up skill's gizmo this frame.
    side*: SkillSide
    targeting*: SkillTarget
    shape*: AreaShape   ## for an area
    progress*: float32  ## 0 as the wind-up starts, 1 as it releases
    caster*: Vec3       ## the caster's feet
    center*: Vec3       ## the target's feet, the middle of the area, or the
                        ## last tile of a line
    reach*: float32     ## the circle's radius, or the area's half-width

  ClipBeats* = object
    ## Fractions of an attack clip: the end of the wind-up, the blow, and
    ## where the follow-through comes to rest.
    cock*, impact*, settle*: float32

  BodyMotion* = object
    ## How far the whole body shifts on top of its clip: `pull` along its
    ## facing, `lift` up, `twist` turned away from the target.
    pull*, lift*, twist*: float32

const
  HitStopTicks* = 2.0'f32
    ## How long the user holds the blow before following through.
  GroundLift = 0.06'f32
    ## Keeps gizmos just above the floor so it never swallows them.
  BorderWidth = 0.05'f32
  DotRadius = 0.04'f32
  DotSpacing = 0.22'f32
  ArrowHead = 0.22'f32
  LineHalfWidth = 0.35'f32
  ConeHalfAngle = PI.float32 / 4
    ## How far a cone opens to each side, as `inCone` judges it.
  SideColors: array[SkillSide, ColorRGBX] = [
    rgbx(150, 255, 150, 255), rgbx(255, 55, 55, 255)
  ]
  Projectiles* = {ShotDelivery, LobDelivery, VolleyDelivery}
  Spells* = {MendDelivery, WardDelivery, RallyDelivery, QuaffDelivery,
    RiteDelivery, GrowDelivery}
    ## Abilities played with the raised-hand spell clip, whatever the
    ## user's weapon, so a blessing never looks like a sword swing.
  SpellClip* = "Spell_Simple_Shoot"
    ## Every character model carries it, whatever its weapon.
  CloakTint* = color(0.24, 0.26, 0.4, 1)
    ## A cloaked body drawn in shadow, which is its whole tell.
  VolleyArrows* = 12
  VolleyHeight* = 9.0'f32
    ## How high a volley climbs before it turns and falls, in tiles.
  BladeBurnTicks = 6.0'f32
    ## How long a blade keeps burning after the blow lands.
  BladeFlameSteps* = 6
    ## Bursts of flame down a blade per tick as it sweeps. It crosses the
    ## whole cone in three ticks, so one a tick would leave gaps in the arc
    ## behind it. A blade held still only needs a couple, or it burns white.
  HeatEmberTicks* = 5'i16
    ## How often a burning hero throws off another drift of embers.

proc look(
    delivery: Delivery, heavy = false,
    burst = CombatSparks, missile = MagicBolt, plain = false
): AbilityLook =
  AbilityLook(delivery: delivery, heavy: heavy, burst: burst,
    missile: missile, plain: plain)

const AbilityLooks*: array[Ability, AbilityLook] = [
  look(RiteDelivery),                                    # NoAbility
  look(SwingDelivery, plain = true),                     # SwordAttack
  look(RallyDelivery, burst = MagicBurst),               # Taunt
  look(WardDelivery),                                    # LionGuard
  look(LobDelivery, heavy = true, burst = FireBurst,     # MeteorStrike
    missile = Fireball),
  look(ShotDelivery, burst = MagicBurst),                # FrostLance
  look(RiteDelivery),                                    # VoidPortal
  look(ShotDelivery, heavy = true, missile = ArrowWake), # PiercingArrow
  look(ShotDelivery, missile = ArrowWake),               # BowAttack
  look(WardDelivery),                                    # ShadowCloak
  look(MendDelivery),                                    # Bloom
  look(GrowDelivery),                                    # Entangle
  look(LobDelivery, burst = SolarFlames, missile = SolarOrb), # SunOrb
  look(QuaffDelivery),                                   # HealingPotion
  look(GrabDelivery),                                    # ChainAxe
  look(RiteDelivery),                                    # CrystalCrown
  look(RiteDelivery),                                    # ArcaneGateway
  look(RallyDelivery),                                   # BattleHorn
  look(SlamDelivery, plain = true),                      # HammerAttack
  look(SwingDelivery, heavy = true),                     # IronFlail
  look(WardDelivery),                                    # InfernoAegis
  look(WardDelivery),                                    # WingedBoot
  look(SwingDelivery, heavy = true),                     # BlazingBlade
  look(WardDelivery),                                    # IceWall
  look(SkyDelivery, heavy = true, burst = MagicBurst),   # LightningStorm
  look(QuaffDelivery),                                   # ManaCrystal
  look(SkyDelivery, heavy = true, burst = FireBurst),    # ArcaneMeteor
  look(ThrustDelivery, burst = MagicBurst),              # VoidBlade
  look(ShotDelivery, burst = MagicBurst),                # ShadowComet
  look(SwingDelivery),                                   # GaleSlash
  look(WardDelivery),                                    # ThornRing
  look(MendDelivery),                                    # FirePhoenix
  look(QuaffDelivery),                                   # NatureTalisman
  look(LobDelivery, burst = MagicBurst),                 # CosmicFlare
  look(ShotDelivery, burst = MagicBurst),                # HexBolt
  look(SwingDelivery),                                   # RakingClaw
  look(SwingDelivery, heavy = true),                     # HeavyCleave
  look(SlamDelivery, heavy = true),                      # CrushingSlam
  look(ThrustDelivery),                                  # SwarmBite
  look(VolleyDelivery, heavy = true, missile = ArrowWake), # HailOfArrows
  look(WardDelivery)                                     # Heat
]

## Timing

proc clipBeats*(clip: string): ClipBeats =
  ## Where the wind-up ends, the blow lands and the swing comes to rest in
  ## each attack clip, measured from the clips themselves. The library's
  ## pistol and spell clips barely wind up, so their anticipation leans on
  ## the body motion and the gizmo instead.
  case clip
  of "Sword_Attack": ClipBeats(cock: 0.21, impact: 0.31, settle: 0.85)
  of "Pistol_Shoot": ClipBeats(cock: 0.0, impact: 0.06, settle: 0.9)
  of "Spell_Simple_Shoot": ClipBeats(cock: 0.06, impact: 0.24, settle: 0.95)
  of BowShotClip, StaffCastClip, BlazingSlashClip, TauntRoarClip,
      HammerSlamClip:
    ClipBeats(cock: 0.5, impact: AttackImpactTime, settle: 1.0)
  else: ClipBeats()

proc actionTime*(actor: Actor, renderAlpha: float32): float32 =
  ## Ticks into the actor's ability, between simulation steps.
  max(float32(actor.actionTicks - 1) + renderAlpha, 0)

proc snapTicks(ability: Ability): float32 =
  ## How long the blow itself takes: the whole release for a strike, one
  ## tick for a missile, which then flies out the rest of the release.
  let release = Abilities[ability].releaseTicks.float32
  if AbilityLooks[ability].delivery in Projectiles: min(release, 1)
  else: release

proc easeOut(u: float32): float32 =
  let v = clamp(u, 0, 1)
  1 - (1 - v) * (1 - v)

proc attackClipTime*(
    ability: Ability, beats: ClipBeats, duration, time: float32
): float32 =
  ## Warps an attack clip onto an ability's phases: it eases into the
  ## cocked pose and holds it through the anticipation, snaps through the
  ## blow so the impact frame lands on the release's last tick, freezes on
  ## it for the hit-stop, then follows through.
  let
    spec = Abilities[ability]
    anticipation = spec.anticipationTicks.float32
    release = spec.releaseTicks.float32
    recover = spec.recoverTicks.float32
    snap = ability.snapTicks
    hold = min(HitStopTicks, recover * 0.5)
  var beat: float32
  if time < anticipation:
    beat = beats.cock * smoothstep(0'f32, 0.7'f32, time / anticipation)
  elif time < anticipation + snap:
    beat = mix(beats.cock, beats.impact, (time - anticipation) / snap)
  elif time < anticipation + release + hold:
    beat = beats.impact
  else:
    beat = mix(beats.impact, beats.settle, easeOut(
      (time - anticipation - release - hold) / max(recover - hold, 1)))
  beat * duration

proc bodyMotion*(ability: Ability, time: float32): BodyMotion =
  ## Shifts the whole body on top of its clip, which is what reads from
  ## the camera's height: strikers coil back and lunge, shooters brace and
  ## kick back, casters rise, and everyone sags a little while recovering.
  let
    spec = Abilities[ability]
    look = AbilityLooks[ability]
    anticipation = spec.anticipationTicks.float32
    impact = spec.impactTicks.float32
    total = spec.totalTicks.float32
    scale = if look.heavy: 1.4'f32 else: 1.0'f32
  # Wound up, struck, and drawn back over the follow-through.
  let
    coil = smoothstep(0'f32, 0.8'f32, time / anticipation)
    snap =
      if time < anticipation: 0'f32
      else: clamp((time - anticipation) / ability.snapTicks, 0, 1)
    rest =
      if time < impact: 0'f32
      else: easeOut((time - impact) / max(total - impact, 1))
    # A charged wind-up trembles in its last stretch.
    tremble =
      if time < anticipation and coil > 0.9:
        sin(time * 9.0'f32) * 0.012'f32 * scale
      else: 0'f32
  case look.delivery
  of SwingDelivery, ThrustDelivery:
    let twist = if look.delivery == SwingDelivery: 0.5'f32 else: 0.1'f32
    if time < anticipation:
      result = BodyMotion(pull: -0.16 * coil * scale + tremble,
        lift: -0.05 * coil, twist: twist * coil)
    elif time < impact:
      result = BodyMotion(pull: mix(-0.16 * scale, 0.32 * scale, snap),
        lift: -0.05, twist: mix(twist, -0.35 * twist, snap))
    else:
      result = BodyMotion(pull: 0.32 * scale * (1 - rest),
        lift: -0.07 * sin(rest * PI), twist: -0.35 * twist * (1 - rest))
  of SlamDelivery:
    if time < anticipation:
      result = BodyMotion(pull: -0.1 * coil, lift: 0.14 * coil * scale +
        tremble, twist: 0)
    elif time < impact:
      result = BodyMotion(pull: mix(-0.1, 0.25, snap),
        lift: mix(0.14 * scale, -0.12 * scale, snap))
    else:
      result = BodyMotion(pull: 0.25 * (1 - rest),
        lift: -0.12 * scale * (1 - rest))
  of ShotDelivery, LobDelivery, SkyDelivery, VolleyDelivery:
    if time < anticipation:
      result = BodyMotion(pull: -0.06 * coil + tremble, lift: -0.03 * coil)
    else:
      let kick = if time < impact: snap else: 1 - rest
      result = BodyMotion(pull: -0.06 - 0.12 * scale * kick,
        lift: -0.03 * (1 - rest))
  of MendDelivery, WardDelivery, RallyDelivery, QuaffDelivery, RiteDelivery,
      GrowDelivery:
    if time < anticipation:
      result = BodyMotion(lift: 0.08 * coil + tremble)
    elif time < impact:
      result = BodyMotion(lift: mix(0.08, 0.16, snap))
    else:
      result = BodyMotion(lift: 0.16 * (1 - rest) - 0.04 * sin(rest * PI))
  of GrabDelivery:
    # Never played: a pickup is instant, and only the loot moves.
    discard

proc loosed*(ability: Ability, time: float32): bool =
  ## True once a shot's missile has left, through to the end of its
  ## recovery: the bow hand is empty until the archer nocks again.
  AbilityLooks[ability].delivery in Projectiles and
    time >= Abilities[ability].anticipationTicks.float32

proc volleySpot*(index: int): Vec2 =
  ## Where one arrow of a volley falls, within a unit disc: a sunflower
  ## spiral, so the arrows spread evenly with no dice to roll.
  let
    radius = sqrt((index.float32 + 0.5'f32) / VolleyArrows.float32)
    turn = index.float32 * 2.39996'f32
  vec2(cos(turn), sin(turn)) * radius

proc bladeFlames*(ability: Ability, time: float32): int =
  ## How many bursts of flame a blade throws off over this tick.
  if time < Abilities[ability].anticipationTicks.float32 or
      time >= Abilities[ability].impactTicks.float32: 2
  else: BladeFlameSteps

proc burning*(ability: Ability, time: float32): bool =
  ## True while a blade is alight: from the moment the draw begins until
  ## the slash has played out.
  ability == BlazingBlade and
    time < Abilities[ability].impactTicks.float32 + BladeBurnTicks

proc scorched*(world: World, slot: int32): seq[int32] =
  ## Whoever a hero's Heat burns on the coming tick, as the simulation will
  ## judge it.
  let actor = world.actors[slot]
  if actor.heatTicks == 0 or actor.heatTicks mod HeatPeriodTicks != 0:
    return
  for other in 0 ..< world.actors.len:
    let victim = world.actors[other]
    if victim.alive and victim.kind != actor.kind and
        world.inArea(Abilities[Heat], actor.home, actor.home, victim):
      result.add int32(other)

proc spellClip*(ability: Ability): bool =
  ## True for abilities played with the raised-hand spell clip.
  AbilityLooks[ability].delivery in Spells

proc victims*(world: World, slot: int32): seq[int32] =
  ## Whoever an actor's ability lands on, as the simulation will judge it
  ## on the release's last tick: every foe inside an area, or the one
  ## target while it is still in reach.
  let
    actor = world.actors[slot]
    spec = Abilities[actor.action]
  if actor.action == ChainAxe:
    return
  if spec.radiusTiles > 0:
    for other in 0 ..< world.actors.len:
      let victim = world.actors[other]
      if not victim.alive or victim.kind == actor.kind:
        continue
      if world.inArea(spec, actor.home, actor.aim, victim):
        result.add int32(other)
    return
  let target = world.actorSlot(actor.target)
  if target >= 0 and target != slot and world.actors[target].alive and
      not (world.actors[target].cloaked and
        world.actors[target].kind != actor.kind):
    let distance = tileDistance(actor.home, world.actors[target].home)
    if distance >= 0 and distance <= int32(spec.rangeTiles):
      result.add target


## Picking up loot

const
  PickupLiftTicks* = 12.0'f32
    ## How long a picked-up item takes to rise out of sight.
  PickupLiftHeight* = 1.0'f32
    ## How far it rises, in tiles.

type
  LiftedLoot* = object
    ## An item picked up off the floor, kept on screen while it rises away.
    kind*: LootKind
    tile*: TileRef
    tick*: int32  ## the tick it was picked up on

proc easeOutCubic*(u: float32): float32 =
  let v = 1 - clamp(u, 0, 1)
  1 - v * v * v

proc rise*(time: float32): float32 =
  ## How far a picked-up item has risen `time` ticks after the pickup: fast
  ## off the floor, slowing to a stop.
  PickupLiftHeight * easeOutCubic(time / PickupLiftTicks)

proc fade*(time: float32): float32 =
  ## A picked-up item's alpha `time` ticks after the pickup: most of it
  ## goes at once, and the last of it lingers.
  1 - easeOutCubic(time / PickupLiftTicks)

proc pickedUp*(world: World, before: seq[Item]): seq[LiftedLoot] =
  ## Every item that lay on the floor before this tick and has left it. A
  ## pickup is the only way off the floor, so these are this tick's.
  var still: seq[int32]
  for item in world.items:
    if item.carrier == 0:
      still.add item.id
  for item in before:
    if item.carrier == 0 and item.id notin still:
      result.add LiftedLoot(kind: item.kind, tile: item.tile, tick: world.tick)


## The anticipation gizmo

proc heading*(angle: float32): Vec3 =
  ## The unit XZ direction of a renderer yaw.
  vec3(sin(angle), 0, cos(angle))

proc paint(color: ColorRGBX, alpha: float32): ColorRGBX =
  ## The color at an alpha; the shape batch halves fully opaque ones.
  rgbx(color.r, color.g, color.b, uint8(clamp(alpha, 0, 0.99) * 255))

proc telegraphed*(ability: Ability, time: float32): bool =
  ## True while a skill is winding up and so shows its gizmo. Picking up
  ## loot is not a skill and is never marked.
  ability != ChainAxe and time < Abilities[ability].anticipationTicks.float32

proc sideOf*(actor: Actor): SkillSide =
  ## The party's skills are friendly; the monsters' are the enemy's.
  if actor.kind == HeroActor: FriendlySide else: EnemySide

proc markerRadius*(actor: Actor): float32 =
  ## The circle round one actor, sized to its body.
  let scale =
    if actor.kind == HeroActor: 1.0'f32
    else: RankScales[actor.species.monsterRank]
  0.45'f32 * scale + 0.1'f32

proc tileFeet*(tile: TileRef): Vec3 =
  ## The middle of a tile at floor height.
  tileCenter(int(tile.level), int(tile.x), int(tile.z))

proc addSquareFrame(
    shapes: var ShapeRenderer,
    center: Vec3,
    outer, width: float32,
    color: ColorRGBX
) =
  ## A square outline in the floor's grid, `outer` from its middle to an
  ## outside edge.
  let inner = outer - width
  for (a, b) in [(vec2(-1, -1), vec2(1, -1)), (vec2(1, -1), vec2(1, 1)),
      (vec2(1, 1), vec2(-1, 1)), (vec2(-1, 1), vec2(-1, -1))]:
    shapes.addQuad(
      center + vec3(a.x * outer, 0, a.y * outer),
      center + vec3(b.x * outer, 0, b.y * outer),
      center + vec3(b.x * inner, 0, b.y * inner),
      center + vec3(a.x * inner, 0, a.y * inner),
      color
    )

proc addRing(
    shapes: var ShapeRenderer,
    center: Vec3,
    outer, width: float32,
    color: ColorRGBX
) =
  ## A circle outline, `outer` from its middle to its outside edge.
  const Sides = 40
  let inner = outer - width
  for i in 0 ..< Sides:
    let
      a0 = TAU * i.float32 / Sides
      a1 = TAU * (i + 1).float32 / Sides
    shapes.addQuad(
      center + heading(a0) * inner, center + heading(a0) * outer,
      center + heading(a1) * outer, center + heading(a1) * inner,
      color
    )

proc addDottedArrow(
    shapes: var ShapeRenderer,
    start, tip: Vec3,
    color: ColorRGBX
) =
  ## Dots from `start` to just short of `tip`, then an arrowhead on it.
  let span = length(tip - start)
  if span < ArrowHead + DotSpacing:
    return
  let
    direction = (tip - start) / span
    side = vec3(direction.z, 0, -direction.x) * (ArrowHead * 0.5)
    base = tip - direction * ArrowHead
  var at = DotSpacing * 0.5
  while at < span - ArrowHead - DotSpacing * 0.5:
    shapes.addCircle(start + direction * at, DotRadius, color, 8)
    at += DotSpacing
  shapes.addTriangle(tip, base + side, base - side, color)

proc addStrip(
    shapes: var ShapeRenderer,
    start, stop: Vec3,
    fill, border: ColorRGBX
) =
  ## A thin line along the floor from `start`, past the middle of the tile
  ## at `stop` to that tile's edge, filled and outlined.
  let span = length(stop - start)
  if span < 0.01'f32:
    return
  let
    along = (stop - start) / span
    tip = stop + along * 0.5'f32
    outer = vec3(along.z, 0, -along.x) * LineHalfWidth
    inner = vec3(along.z, 0, -along.x) * (LineHalfWidth - BorderWidth)
    cap = along * BorderWidth
  shapes.addQuad(start + inner + cap, tip + inner - cap,
    tip - inner - cap, start - inner + cap, fill)
  shapes.addQuad(start + outer, tip + outer, tip + inner, start + inner,
    border)
  shapes.addQuad(start - inner, tip - inner, tip - outer, start - outer,
    border)
  shapes.addQuad(start + inner, start + inner + cap, start - inner + cap,
    start - inner, border)
  shapes.addQuad(tip + inner - cap, tip + inner, tip - inner,
    tip - inner - cap, border)

proc addCone(
    shapes: var ShapeRenderer,
    apex, aim: Vec3,
    reach: float32,
    fill, border: ColorRGBX
) =
  ## A slice of the floor from `apex` toward `aim`, `reach` long, filled
  ## and outlined.
  const Sides = 16
  var toward = aim - apex
  toward.y = 0
  if length(toward) < 0.01'f32:
    return
  let
    middle = arctan2(toward.x, toward.z)
    inner = reach - BorderWidth
  proc rim(step: int, distance: float32): Vec3 =
    let turn = (2 * step.float32 / Sides.float32 - 1) * ConeHalfAngle
    apex + heading(middle + turn) * distance
  for step in 0 ..< Sides:
    shapes.addTriangle(apex, rim(step, inner), rim(step + 1, inner), fill)
    shapes.addQuad(rim(step, inner), rim(step, reach), rim(step + 1, reach),
      rim(step + 1, inner), border)
  for (step, side) in [(0, 1'f32), (Sides, -1'f32)]:
    let
      tip = rim(step, reach)
      across = normalize(vec3(tip.z - apex.z, 0, apex.x - tip.x)) *
        BorderWidth * side
    shapes.addQuad(apex, tip, tip + across, apex + across, border)

proc addTelegraph*(shapes: var ShapeRenderer, tell: Telegraph) =
  ## Marks a winding-up skill: its target or area with a solid border and
  ## a fill that turns solid as the release nears, and a dotted arrow from
  ## the caster toward it.
  let
    color = SideColors[tell.side]
    center = tell.center + vec3(0, GroundLift, 0)
    fill = paint(color, clamp(tell.progress, 0, 1))
    border = paint(color, 0.95)
    caster = tell.caster + vec3(0, GroundLift, 0)
    round = tell.targeting == SingleTarget or tell.shape == RoundArea
  if tell.targeting == AreaTarget and tell.shape == LineArea:
    shapes.addStrip(caster, center, fill, border)
    return
  if tell.targeting == AreaTarget and tell.shape == ConeArea:
    shapes.addCone(caster, center, tell.reach, fill, border)
    return
  if round:
    shapes.addCircle(center, tell.reach - BorderWidth, fill, 40)
    shapes.addRing(center, tell.reach, BorderWidth, border)
  else:
    shapes.addSquare(center, (tell.reach - BorderWidth) * 2, fill)
    shapes.addSquareFrame(center, tell.reach, BorderWidth, border)
  # The arrow stops where it meets the marker; a skill the caster aims at
  # itself has none.
  var toward = center - caster
  toward.y = 0
  let
    span = length(toward)
    across = max(abs(toward.x), abs(toward.z))
    inside =
      if round: span <= tell.reach
      else: across <= tell.reach
  if inside:
    return
  let edge =
    if round: tell.reach
    else: tell.reach * span / across
  shapes.addDottedArrow(caster, caster + toward / span * (span - edge),
    border)


## Entangle's vines

const
  SunOrbGroundFlameRadius* = 0.7'f32
    ## A bare-ground landing burns a small spot; vines burn their whole patch.
  VineStems* = 18
    ## Stems in one patch of vines.
  VineGrowTicks = 8.0'f32
    ## How long vines take to spring up to their full height.
  VineHeight = 0.85'f32
    ## How tall the tallest stems stand, in tiles.
  VineCatchShare = 0.35'f32
    ## The share of a burn the fire takes to run from where the orb landed
    ## to the far edge of the vines.
  VineFlameShare = 0.3'f32
    ## The share of a stem's own burn spent alight before it chars.
  StemDark = color(0.11, 0.3, 0.1, 1)
  StemLight = color(0.47, 0.74, 0.24, 1)
  LeafColor = color(0.3, 0.64, 0.2, 1)
  MatColor = color(0.1, 0.3, 0.06, 1)
  WitherColor = color(0.42, 0.33, 0.15, 1)
  FlameColor = color(1.0, 0.6, 0.1, 1)
  FlameTip = color(1.0, 0.92, 0.5, 1)
  CharColor = color(0.1, 0.07, 0.05, 1)

proc blend(a, b: Color, t: float32): Color =
  let u = clamp(t, 0, 1)
  color(a.r + (b.r - a.r) * u, a.g + (b.g - a.g) * u, a.b + (b.b - a.b) * u,
    1)

proc ink(tone: Color, alpha: float32): ColorRGBX =
  rgbx(uint8(tone.r * 255), uint8(tone.g * 255), uint8(tone.b * 255),
    uint8(clamp(alpha, 0, 0.99) * 255))

proc vineNoise(patch: VinePatch, index, salt: int): float32 =
  ## A steady value in 0 ..< 1 for one stem of one patch, so a patch keeps
  ## its shape from frame to frame and across a seek.
  var hash = uint32(patch.sprouted) * 747796405'u32 +
    uint32(index) * 2891336453'u32 + uint32(salt) * 277803737'u32 +
    uint32(patch.center.x) * 1103515245'u32 + uint32(patch.center.z) * 12345'u32
  hash = (hash xor (hash shr 16)) * 2246822519'u32
  hash = hash xor (hash shr 13)
  float32(hash and 0xFFFF'u32) / 65536'f32

proc vineReach*(): float32 =
  ## The vines' radius on the floor, as `inArea` judges a disc.
  Abilities[Entangle].radiusTiles.float32 + 0.5'f32

proc vineBase*(patch: VinePatch, index: int): Vec3 =
  ## Where one stem leaves the floor: spread evenly over the disc in a
  ## sunflower spiral, each nudged a little off it.
  let
    radius = sqrt((index.float32 + 0.5'f32) / VineStems.float32) *
      vineReach() * 0.82'f32
    turn = index.float32 * 2.39996'f32 + patch.vineNoise(index, 0) * 0.6'f32
  tileFeet(patch.center) + heading(turn) * radius

proc vineCatch*(patch: VinePatch, index: int): float32 =
  ## The share of a burn that passes before the fire reaches one stem,
  ## running out from where the orb landed.
  var
    toStem = patch.vineBase(index) - tileFeet(patch.burnedFrom)
    toMiddle = tileFeet(patch.center) - tileFeet(patch.burnedFrom)
  toStem.y = 0
  toMiddle.y = 0
  length(toStem) / (length(toMiddle) + vineReach()) * VineCatchShare

proc addStem(
    shapes: var ShapeRenderer,
    patch: VinePatch,
    index: int,
    grown, flame, charred, wither, clock: float32
) =
  ## One stem as a ribbon rising off the floor and curling over, `grown`
  ## of the way to its tip, with a leaf or two on it and, while it burns,
  ## a tongue of flame where it ends.
  const Steps = 8
  let
    base = patch.vineBase(index) + vec3(0, GroundLift, 0)
    facing = patch.vineNoise(index, 1) * TAU.float32
    curl = (patch.vineNoise(index, 2) - 0.5'f32) * 3.0'f32
    span = 0.3'f32 + patch.vineNoise(index, 3) * 0.35'f32
    tall = VineHeight * (0.55'f32 + 0.45'f32 * patch.vineNoise(index, 4))
    sway = sin(clock * 2.2'f32 + index.float32 * 1.7'f32) * 0.2'f32
  proc tone(along: float32): Color =
    var shade = blend(StemDark, StemLight, along)
    shade = blend(shade, WitherColor, wither)
    shade = blend(shade, FlameColor, flame)
    blend(shade, CharColor, charred)
  var points, sides: array[Steps + 1, Vec3]
  for step in 0 .. Steps:
    let
      along = step.float32 / Steps.float32 * grown
      turn = facing + (curl + sway) * along
    points[step] = base + heading(facing + curl * along * 0.5'f32) *
      (span * along) + vec3(0, tall * sin(along * PI.float32 * 0.8'f32), 0)
    sides[step] = heading(turn + PI.float32 / 2) *
      (0.075'f32 * (1 - 0.7'f32 * along))
  let alpha = 0.95'f32 * (1 - 0.6'f32 * wither)
  for step in 0 ..< Steps:
    let along = (step.float32 + 0.5'f32) / Steps.float32 * grown
    shapes.addQuad(points[step] - sides[step], points[step] + sides[step],
      points[step + 1] + sides[step + 1], points[step + 1] - sides[step + 1],
      ink(tone(along), alpha))
  for (step, side) in [(3, 1'f32), (6, -1'f32)]:
    if step.float32 / Steps.float32 > grown * 0.98'f32:
      continue
    let
      stalk = points[step]
      outward = normalize(sides[step]) * side
      tip = stalk + outward * 0.25'f32 + vec3(0, 0.05'f32, 0)
      across = normalize(points[step + 1] - points[step]) * 0.08'f32
      middle = mix(stalk, tip, 0.45'f32)
    shapes.addQuad(stalk, middle + across, tip, middle - across,
      ink(blend(blend(blend(LeafColor, WitherColor, wither), FlameColor,
        flame), CharColor, charred), alpha))
  if flame > 0 and charred < 1:
    let
      top = points[Steps]
      lick = (0.18'f32 + 0.1'f32 * sin(clock * 23 + index.float32 * 2.3'f32)) *
        (1 - charred)
    for turn in [facing, facing + PI.float32 / 2]:
      let across = heading(turn) * 0.07'f32
      shapes.addTriangle(top - across, top + across, top + vec3(0, lick, 0),
        ink(blend(FlameColor, FlameTip, 0.5'f32), 0.9'f32 * (1 - charred)))

proc addVinePatch*(
    shapes: var ShapeRenderer,
    patch: VinePatch,
    now, clock: float32
) =
  ## Draws one patch of Entangle's vines `now`, in ticks between steps: a
  ## dark mat over its disc and stems that spring up, sway and then sink
  ## away, or, once a Sun Orb has set them alight, catch one after another
  ## from where it landed, flare and char away.
  let age = now - patch.sprouted.float32
  if age <= 0:
    return
  let
    grow = easeOut(age / VineGrowTicks)
    wither =
      if patch.burned != 0: 0'f32
      else: clamp((age - VineTicks.float32) / VineWitherTicks.float32, 0, 1)
    burn =
      if patch.burned == 0: -1'f32
      else: max(now - patch.burned.float32, 0) / VineBurnTicks.float32
    scorch = clamp(burn * 2, 0, 1)
    matTone =
      if burn >= 0: blend(MatColor, CharColor, scorch)
      else: blend(MatColor, WitherColor, wither)
    matAlpha = 0.24'f32 * grow * (1 - wither) *
      (if burn >= 0: 1 - clamp(burn, 0, 1) else: 1)
  shapes.addCircle(tileFeet(patch.center) + vec3(0, GroundLift * 0.5'f32, 0),
    vineReach() * grow, ink(matTone, matAlpha), 40)
  # Branching roots stitch the whole patch together as it grows.
  for root in 0 ..< 10:
    var previous = tileFeet(patch.center) + vec3(0, GroundLift, 0)
    for step in 1 .. 14:
      let
        t = step.float32 / 14 * grow
        angle = root.float32 * TAU.float32 / 10 + sin(t * 5 + root.float32) * 0.24'f32
        point = tileFeet(patch.center) + heading(angle) * (vineReach() * t) +
          vec3(0, GroundLift, 0)
        tone = if burn >= 0: blend(StemLight, CharColor, scorch)
          else: blend(StemLight, WitherColor, wither)
      shapes.addPolyline([previous, point], ink(tone,
        0.65'f32 * grow * (1 - wither) * (if burn >= 0: 1 - clamp(burn, 0, 1) else: 1)),
        0.025'f32 * (1 - t * 0.65'f32))
      previous = point
  for index in 0 ..< VineStems:
    var
      grown = grow * (1 - wither)
      flame, charred = 0'f32
    if burn >= 0:
      let alight = (burn - patch.vineCatch(index)) / (1 - VineCatchShare)
      if alight > 0:
        flame = clamp(alight / VineFlameShare, 0, 1)
        charred = clamp((alight - VineFlameShare) / (1 - VineFlameShare), 0, 1)
        grown *= 1 - charred
    if grown > 0.02'f32:
      shapes.addStem(patch, index, grown, flame, charred, wither, clock)

proc addVineWrap*(
    shapes: var ShapeRenderer,
    feet: Vec3,
    scale, hold: float32
) =
  ## Vines twining up a body that stands in them, higher the tighter they
  ## hold it: round its ankles as it steps in, up to its waist once it is
  ## rooted.
  const
    Strands = 3
    Steps = 10
  let
    top = HeroTargetHeight * scale * 0.42'f32 * clamp(hold, 0, 1)
    radius = 0.3'f32 * scale
    band = vec3(0, 0.045'f32 * scale, 0)
  for strand in 0 ..< Strands:
    for step in 0 ..< Steps:
      proc twist(along: float32): Vec3 =
        let turn = strand.float32 * TAU.float32 / Strands.float32 +
          along * 2.4'f32 * PI.float32
        feet + heading(turn) * (radius * (1 - 0.2'f32 * along)) +
          vec3(0, 0.04'f32 + top * along, 0)
      let
        a = twist(step.float32 / Steps.float32)
        b = twist((step + 1).float32 / Steps.float32)
      shapes.addQuad(a - band, a + band, b + band, b - band,
        ink(blend(StemDark, StemLight, step.float32 / Steps.float32), 0.95))
