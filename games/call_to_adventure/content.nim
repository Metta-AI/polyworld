## Every simulation type for Call to Adventure, and the constants that tune
## them. The whole simulation is integer: tile coordinates, phase units, tick
## counts, hit points. Floating point appears only in the renderer.
##
## `World` holds value fields plus `seq[Actor]`. Actors are refs so a path
## seq is not copied by `let actor = world.actors[i]`. Clone and restore
## deep-copy each actor. The state hash walks actor contents, not addresses.
## Actors refer to each other by `int32` id, never by pointer.

import
  fixxy,
  polyworld/[bodies, cli, metrics, pathing, rngs]

## Shape of the world

const
  LevelCount* = 6      ## surface, pyramid, rooms, caves, lava hall, vault
  PartySize* = 4
  InventorySlots* = 2
  ChatLines* = 16      ## ring buffer of recent party chatter
  TilesPerLevel* = GridTiles * GridTiles
  WorldTiles* = LevelCount * TilesPerLevel

  SurfaceLevel* = 0'i8
  VaultLevel* = int8(LevelCount - 1)

## Tick budget

const
  TickRate* = SharedTickRate
  DecisionTicks* = 1'i32
    ## Ticks between hero VM decisions. One decision per simulation tick.
  HashIntervalTicks* = 24'i32     ## one replay checkpoint per second
  DefaultMaximumTicks* = 28_800'i32  ## 20 minutes at 24 ticks per second

## Movement

const
  PhaseUnits* = TickRate * 100
    ## Phase units in one flat tile step. An actor's `speed` is added to its
    ## phase each tick, so `tilesPerSecond = speed * TickRate / PhaseUnits`,
    ## so speed remains exactly centi-tiles per second at any tick rate.
  MinimumStepUnits* = PhaseUnits * 3 div 4
  MaximumStepUnits* = PhaseUnits * 2
  ClimbCostPerStep* = PhaseUnits div 8    ## per 1/8 tile of rise
  DescendCostPerStep* = PhaseUnits div 24 ## per 1/8 tile of drop
  MaximumPathTiles* = 256
  RepathAfterStuckTicks* = 12'i16
  SidestepAfterStuckTicks* = 36'i16

type
  TileRef* = object
    ## One tile anywhere in the world. Levels are separate `QuadLayer`s, so
    ## `level` doubles as the pathing layer index.
    level*: int8
    x*, z*: uint8

  Facing* = enum
    ## Numbered to match `edgeLink`'s direction argument exactly, so a facing
    ## can be passed straight through with no translation table.
    East, South, West, North

  PathStep* = object
    tile*: TileRef
    direction*: Facing
    offset*: FixedVec2

## Actors

type
  ActorKind* = enum
    HeroActor, MonsterActor

  HeroClass* = enum
    FighterClass, WizardClass, RogueClass, ClericClass

  Species* = enum
    DustlingSpecies, GraveStalkerSpecies, CryptAcolyteSpecies,
    BarrowWardenSpecies, BogRuntSpecies, TuskRaiderSpecies,
    MireShamanSpecies, IronhideChiefSpecies, DuskThrallSpecies,
    VelvetStalkerSpecies, BloodCantorSpecies, DreadCountSpecies,
    CinderImpSpecies, AshReaverSpecies, EmberHexerSpecies,
    InfernalDukeSpecies,
    BoneMiteSpecies, BogWhelpSpecies, BloodGnatSpecies, SparkFiendSpecies
      ## The swarm, one species per family, after the sixteen pack species
      ## so their numbers stay put.

  MonsterFamily* = enum
    UndeadFamily, OrcFamily, VampireFamily, DemonFamily

  MonsterRank* = enum
    RuntRank, RaiderRank, CasterRank, ChampionRank,
    SwarmRank
      ## Small, fast and weak, they come in numbers alongside every pack.

  MonsterState* = enum
    ## Native monster AI has no scripting; these are its whole vocabulary.
    GuardingState, PatrollingState, ChasingState, FightingState,
    KitingState, FleeingState

  Ability* = enum
    NoAbility,
    SwordAttack, Taunt, LionGuard,
    MeteorStrike, FrostLance, VoidPortal,
    PiercingArrow, BowAttack, ShadowCloak,
    Bloom, Entangle, SunOrb,
    HealingPotion, ChainAxe, CrystalCrown, ArcaneGateway, BattleHorn,
    HammerAttack,
      ## The Druid's plain swing.
    IronFlail, InfernoAegis, WingedBoot, BlazingBlade,
    IceWall, LightningStorm, ManaCrystal, ArcaneMeteor,
    VoidBlade, ShadowComet, GaleSlash, ThornRing,
    FirePhoenix, NatureTalisman, CosmicFlare,
    HexBolt,
      ## The monster casters' bolt. No hero has it, so it has no icon.
    RakingClaw, HeavyCleave, CrushingSlam, SwarmBite,
      ## The other monster ranks' melee attacks; see `RankAttacks`.
    HailOfArrows,
      ## The archer's ultimate.
    Heat
      ## The Fighter's burning aura.

const
  AbilityCount* = int(Ability.high) + 1
  AbilityIconFiles*: array[Ability, string] = [
    "",
    "sword_attack",
    "duelist_glove",
    "lion_guard",
    "meteor_strike",
    "frost_lance",
    "void_portal",
    "verdant_arrow",
    "ranger_bow",
    "shadow_cloak",
    "healing_bloom",
    "bridgevine",
    "sun_orb",
    "healing_potion",
    "chain_axe",
    "crystal_crown",
    "arcane_gateway",
    "battle_horn",
    "solar_hammer",
    "iron_flail",
    "inferno_aegis",
    "winged_boot",
    "blazing_blade",
    "ice_wall",
    "lightning_storm",
    "mana_crystal",
    "arcane_meteor",
    "void_blade",
    "shadow_comet",
    "gale_slash",
    "thorn_ring",
    "fire_phoenix",
    "nature_talisman",
    "cosmic_flare",
    "",
    "",
    "",
    "",
    "",
    "hail_of_arrows",
    "rage_crucible"
  ]

type
  AreaShape* = enum
    ## How an area spreads from the tile it is aimed at: a square of tiles
    ## round it, a disc round it, a straight line from the caster through
    ## it, as far as `radiusTiles` or the first wall, or a quarter-circle
    ## slice of the floor out from the caster toward it.
    SquareArea, RoundArea, LineArea, ConeArea

  AbilitySpec* = object
    ## Every ability plays out in three phases, counted in ticks so a
    ## spectator can read each one:
    ##
    ## - anticipation: the wind-up and its tell. Nothing has happened yet,
    ##   and the user turns to keep its target in front of it.
    ## - release: the strike, shot or spell going out. The effect lands on
    ##   the last release tick, never before.
    ## - recover: the follow-through. The user is still committed and can
    ##   neither act nor move until it ends.
    ##
    ## The client warps each animation clip to these phases; the simulation
    ## never reads a clip length. A cooldown starts once recovery ends.
    anticipationTicks*: int16
    releaseTicks*: int16
    recoverTicks*: int16
    cooldownTicks*: int16
    manaCost*: int16
    rangeTiles*: int16
    damage*: int16
    spread*: int16
    radiusTiles*: int16
      ## Zero hits the target alone. Otherwise the effect lands on every foe
      ## in an area of this reach, aimed at the tile the target stood on
      ## when the wind-up began.
    shape*: AreaShape
    tracksTarget*: bool
      ## The aim follows the target until release instead of pinning as the
      ## wind-up begins, for a skill too narrow or too slow to land otherwise.
    staggerTicks*: int16
      ## How long a hit stops its victim's feet.
    slowTicks*: int16
      ## How long a hit leaves its victim walking at `SlowPercent` speed.
    onSelf*: bool
      ## Cast round the user, whoever it is fighting. Range is then how close
      ## a foe must be before it is worth casting.
    leadsPack*: bool
      ## Aimed at the middle of the target's pack where the pack will be
      ## once the effect has landed and taken hold, not at the target, and
      ## kept on it until release.

  ActionPhase* = enum
    ## Where an actor's ability stands; see `AbilitySpec`.
    ReadyPhase, AnticipationPhase, ReleasePhase, RecoverPhase

  SkillTarget* = enum
    ## What a skill lands on, which is also how spectators see it marked:
    ## one actor, or every foe inside an area of the floor.
    SingleTarget, AreaTarget

const Abilities*: array[Ability, AbilitySpec] = [
  AbilitySpec(),
  # SwordAttack: the plain swing every class falls back on.
  AbilitySpec(anticipationTicks: 8, releaseTicks: 2, recoverTicks: 8,
    rangeTiles: 1, damage: 14, spread: 6),
  # Taunt: a roar that drags every foe in earshot onto the Fighter, held until
  # one is at his elbow so the rest of its pack has come inside the ring.
  AbilitySpec(anticipationTicks: 8, releaseTicks: 2, recoverTicks: 6,
    cooldownTicks: 240, rangeTiles: 1, radiusTiles: 3, shape: RoundArea,
    onSelf: true),
  # LionGuard: braces behind the shield.
  AbilitySpec(anticipationTicks: 6, releaseTicks: 1, recoverTicks: 6,
    cooldownTicks: 48),
  # MeteorStrike: a fireball lobbed onto a spot.
  AbilitySpec(anticipationTicks: 12, releaseTicks: 6, recoverTicks: 8,
    cooldownTicks: 36, manaCost: 12, rangeTiles: 7, damage: 22, spread: 8,
    radiusTiles: 1),
  # FrostLance: a quick shard thrown straight.
  AbilitySpec(anticipationTicks: 8, releaseTicks: 3, recoverTicks: 8,
    cooldownTicks: 96, manaCost: 16, rangeTiles: 5, damage: 10, spread: 4),
  # VoidPortal
  AbilitySpec(anticipationTicks: 14, releaseTicks: 2, recoverTicks: 8,
    cooldownTicks: 240, manaCost: 20, rangeTiles: 4),
  # PiercingArrow: a held draw, then one shot through a whole line of foes.
  AbilitySpec(anticipationTicks: 12, releaseTicks: 3, recoverTicks: 6,
    cooldownTicks: 96, rangeTiles: 6, damage: 18, spread: 6,
    radiusTiles: 9, shape: LineArea, tracksTarget: true, staggerTicks: 24),
  # BowAttack: draw, loose, a short flight, about one shot a second.
  AbilitySpec(anticipationTicks: 8, releaseTicks: 3, recoverTicks: 5,
    cooldownTicks: 8, rangeTiles: 6, damage: 9, spread: 5),
  # ShadowCloak: a quick fade, so it works as an escape. Range is how close
  # a foe must be before it is worth casting.
  AbilitySpec(anticipationTicks: 3, releaseTicks: 1, recoverTicks: 2,
    cooldownTicks: 600, rangeTiles: 6),
  # Bloom: a slow bloom that drifts over to an ally.
  AbilitySpec(anticipationTicks: 12, releaseTicks: 4, recoverTicks: 6,
    cooldownTicks: 480, manaCost: 18, rangeTiles: 4, damage: -70),
  # Entangle: vines spring up in a disc round the target and hold whoever
  # stands in them tighter every tick; see `VinePatch`.
  AbilitySpec(anticipationTicks: 14, releaseTicks: 4, recoverTicks: 8,
    cooldownTicks: 360, manaCost: 30, rangeTiles: 7, radiusTiles: 1,
    shape: RoundArea, tracksTarget: true, leadsPack: true),
  # SunOrb: an orb that consumes vines and raises flames on landing.
  # Flight is releaseTicks - 1: ten ticks, twice the original five.
  AbilitySpec(anticipationTicks: 12, releaseTicks: 11, recoverTicks: 8,
    cooldownTicks: 480, manaCost: 20, rangeTiles: 7, damage: 26, spread: 10,
    radiusTiles: 1),
  # HealingPotion
  AbilitySpec(anticipationTicks: 10, releaseTicks: 2, recoverTicks: 8,
    cooldownTicks: 12),
  # ChainAxe: picking up loot. It is instant, never played as an action, so
  # it has no phases; the cooldown is the wait before the next pickup.
  AbilitySpec(cooldownTicks: 12),
  # CrystalCrown
  AbilitySpec(anticipationTicks: 6, releaseTicks: 1, recoverTicks: 4),
  # ArcaneGateway
  AbilitySpec(anticipationTicks: 12, releaseTicks: 2, recoverTicks: 4,
    rangeTiles: 1),
  # BattleHorn: a long breath, one blast for the whole party.
  AbilitySpec(anticipationTicks: 10, releaseTicks: 2, recoverTicks: 8,
    cooldownTicks: 240),
  # HammerAttack: the Druid's plain overhead hammer blow.
  AbilitySpec(anticipationTicks: 10, releaseTicks: 2, recoverTicks: 8,
    rangeTiles: 1, damage: 14, spread: 6),
  # IronFlail: a wide sweep through everything near the target.
  AbilitySpec(anticipationTicks: 10, releaseTicks: 2, recoverTicks: 8,
    cooldownTicks: 72, rangeTiles: 2, damage: 18, spread: 8,
    radiusTiles: 1),
  # InfernoAegis
  AbilitySpec(anticipationTicks: 6, releaseTicks: 2, recoverTicks: 4,
    cooldownTicks: 64),
  # WingedBoot
  AbilitySpec(anticipationTicks: 4, releaseTicks: 1, recoverTicks: 2,
    cooldownTicks: 180, rangeTiles: 3),
  # BlazingBlade: a long draw, then one burning slash across a small cone
  # that leaves whatever it catches limping.
  AbilitySpec(anticipationTicks: 12, releaseTicks: 3, recoverTicks: 10,
    cooldownTicks: 96, rangeTiles: 2, damage: 46, spread: 10,
    radiusTiles: 2, shape: ConeArea, slowTicks: 36),
  # IceWall
  AbilitySpec(anticipationTicks: 8, releaseTicks: 2, recoverTicks: 6,
    cooldownTicks: 80),
  # LightningStorm: a long gather, then a bolt out of the sky.
  AbilitySpec(anticipationTicks: 16, releaseTicks: 2, recoverTicks: 10,
    cooldownTicks: 48, manaCost: 18, rangeTiles: 6, damage: 30, spread: 10,
    radiusTiles: 1),
  # ManaCrystal
  AbilitySpec(anticipationTicks: 8, releaseTicks: 2, recoverTicks: 6,
    cooldownTicks: 120, manaCost: 14, rangeTiles: 3),
  # ArcaneMeteor: the longest tell, the biggest crater.
  AbilitySpec(anticipationTicks: 18, releaseTicks: 6, recoverTicks: 10,
    cooldownTicks: 72, manaCost: 22, rangeTiles: 8, damage: 36, spread: 12,
    radiusTiles: 1),
  # VoidBlade
  AbilitySpec(anticipationTicks: 5, releaseTicks: 1, recoverTicks: 6,
    cooldownTicks: 80, rangeTiles: 1, damage: 16, spread: 5),
  # ShadowComet
  AbilitySpec(anticipationTicks: 10, releaseTicks: 4, recoverTicks: 6,
    cooldownTicks: 36, rangeTiles: 7, damage: 14, spread: 6),
  # GaleSlash: a spinning cut that clips everything round the target.
  AbilitySpec(anticipationTicks: 7, releaseTicks: 2, recoverTicks: 7,
    cooldownTicks: 48, rangeTiles: 1, damage: 20, spread: 6,
    radiusTiles: 1),
  # ThornRing
  AbilitySpec(anticipationTicks: 8, releaseTicks: 2, recoverTicks: 6,
    cooldownTicks: 90),
  # FirePhoenix
  AbilitySpec(anticipationTicks: 14, releaseTicks: 4, recoverTicks: 8,
    cooldownTicks: 300, manaCost: 22, rangeTiles: 4, damage: -90),
  # NatureTalisman
  AbilitySpec(anticipationTicks: 10, releaseTicks: 2, recoverTicks: 8,
    cooldownTicks: 240, manaCost: 16, rangeTiles: 4),
  # CosmicFlare
  AbilitySpec(anticipationTicks: 14, releaseTicks: 4, recoverTicks: 8,
    cooldownTicks: 180, manaCost: 20, rangeTiles: 6, damage: 24, spread: 8,
    radiusTiles: 1),
  # HexBolt: the casters' bolt, slow to gather and slow to fly.
  AbilitySpec(anticipationTicks: 12, releaseTicks: 6, recoverTicks: 6,
    cooldownTicks: 36, rangeTiles: 6, damage: 22, spread: 8),
  # RakingClaw: a runt's quick swipe.
  AbilitySpec(anticipationTicks: 6, releaseTicks: 1, recoverTicks: 6,
    rangeTiles: 1, damage: 10, spread: 4),
  # HeavyCleave: a raider's chop.
  AbilitySpec(anticipationTicks: 10, releaseTicks: 2, recoverTicks: 9,
    rangeTiles: 1, damage: 16, spread: 6),
  # CrushingSlam: a champion's slam, slow and wide.
  AbilitySpec(anticipationTicks: 18, releaseTicks: 2, recoverTicks: 14,
    rangeTiles: 1, damage: 26, spread: 8, radiusTiles: 1),
  # SwarmBite: a nip from something small and fast.
  AbilitySpec(anticipationTicks: 4, releaseTicks: 1, recoverTicks: 5,
    rangeTiles: 1, damage: 8, spread: 4),
  # HailOfArrows: a long draw at the sky, and the sky falls on the marked ring.
  AbilitySpec(anticipationTicks: 20, releaseTicks: 8, recoverTicks: 10,
    cooldownTicks: 480, rangeTiles: 7, damage: 40, spread: 10,
    radiusTiles: 2, shape: RoundArea, tracksTarget: true),
  # Heat: lights an aura that keeps burning what stands near the Fighter, a
  # small hit each `HeatPeriodTicks`; `damage` is one of those.
  AbilitySpec(anticipationTicks: 8, releaseTicks: 2, recoverTicks: 6,
    cooldownTicks: 240, rangeTiles: 2, damage: 2, spread: 1,
    radiusTiles: 2, shape: RoundArea, onSelf: true)
]

proc impactTicks*(spec: AbilitySpec): int16 =
  ## The action tick the effect lands on: the last tick of release.
  spec.anticipationTicks + spec.releaseTicks

proc totalTicks*(spec: AbilitySpec): int16 =
  ## The action tick the user is free again on.
  spec.impactTicks + spec.recoverTicks

proc targeting*(spec: AbilitySpec): SkillTarget =
  ## Whether a skill lands on its one target or on an area.
  if spec.radiusTiles > 0: AreaTarget else: SingleTarget

proc phaseAt*(spec: AbilitySpec, actionTicks: int16): ActionPhase =
  ## The phase an ability is in once `actionTicks` of it have run.
  if actionTicks <= spec.anticipationTicks:
    AnticipationPhase
  elif actionTicks <= spec.impactTicks:
    ReleasePhase
  else:
    RecoverPhase

type
  Actor* = ref object
    ## Heroes occupy slots 0 ..< PartySize; monsters follow. A slot with
    ## `id == 0` is a tombstone and is reused deterministically.
    id*: int32
    kind*: ActorKind
    class*: uint8              ## HeroClass for heroes, Species for monsters
    home*: TileRef             ## the tile this actor occupies and claims
    next*: TileRef             ## step destination; equals home when still
    phase*: int32              ## 0 ..< stepUnits
    stepUnits*: int32          ## cost of the step in progress
    speed*: int32              ## phase units per tick, after encumbrance
    baseSpeed*: int32
    facing*: Facing
    body*: Body
    hp*, maxHp*: int16
    mana*, maxMana*: int16
    action*: Ability
    actionTicks*: int16
    target*: int32             ## actor or item id, depending on the action
    aim*: TileRef              ## where the target stood as the wind-up began
                               ## or, if it `tracksTarget`, at release
    cooldowns*: array[AbilityCount, int16]
    inventory*: array[InventorySlots, int32]  ## item ids, 0 empty
    carriedWeight*: int32
    carriedValue*: int32
    sinceHitTicks*: int16      ## saturates; a hero regenerates only once
                               ## it reaches `RegenerationIdleTicks`
    slowTicks*: int16          ## ticks left walking at `SlowPercent` speed
    guardTicks*: int16
    guardPercent*: int16       ## the share of a blow that gets through a guard
    staggerTicks*: int16       ## ticks left with its feet stopped
    cloakTicks*: int16         ## ticks left that foes cannot pick it out
    heatTicks*: int16          ## ticks left of its Heat aura
    tauntTicks*: int16         ## ticks left that it must go for `tauntedBy`
    tauntedBy*: int32          ## the hero's actor id
    entangledTicks*: int16     ## ticks it has stood in vines, up to
                               ## `VineRootTicks`
    deathTicks*: int16
    state*: MonsterState
    stateTicks*: int16
    path*: seq[PathStep]
    pathIndex*: int32
    stuckTicks*: int16
    hasteTicks*: int16

## Items, doors, chat

type
  LootKind* = enum
    ## Floor drops. Treasure kinds only add gold. Gear kinds also fill Q or E.
    GoldPile,
    Gemstone,
    Chalice,
    Idol,
    Crown,
    HealingPotionLoot,
    ManaPotionLoot,
    BattleHornLoot,
    WingedBootLoot,
    IronFlailLoot,
    InfernoAegisLoot,
    BlazingBladeLoot,
    IceWallLoot,
    LightningStormLoot,
    ArcaneMeteorLoot,
    VoidBladeLoot,
    ShadowCometLoot,
    GaleSlashLoot,
    ThornRingLoot,
    FirePhoenixLoot,
    NatureTalismanLoot,
    CosmicFlareLoot

  Item* = object
    id*: int32
    kind*: LootKind
    tile*: TileRef
    carrier*: int32            ## actor id, 0 when lying on the floor
    value*: int32
    weight*: int32

  Door* = object
    id*: int32
    tile*: TileRef
    open*: bool

  ChatLine* = object
    ## Chat is simulation state: heroes read each other's lines, so it is
    ## recorded, checkpointed and hashed. Phrases are ids, never strings,
    ## because the script VM has no runtime strings.
    speaker*: int32
    phrase*: int32
    value*: int32
    tick*: int32

const
  LootValues*: array[LootKind, int32] = [
    12, 60, 140, 300, 900,
    40, 45, 80, 100,
    70, 75, 90,
    70, 110, 120,
    80, 85, 90, 70,
    100, 85, 95
  ]
  LootWeights*: array[LootKind, int32] = [
    0, 0, 0, 0, 0,
    1, 1, 2, 2,
    2, 2, 2,
    2, 2, 2,
    2, 2, 2, 1,
    2, 1, 2
  ]
  LootAbilities*: array[LootKind, Ability] = [
    NoAbility, NoAbility, NoAbility, NoAbility, NoAbility,
    HealingPotion, ManaCrystal, BattleHorn, WingedBoot,
    IronFlail, InfernoAegis, BlazingBlade,
    IceWall, LightningStorm, ArcaneMeteor,
    VoidBlade, ShadowComet, GaleSlash, ThornRing,
    FirePhoenix, NatureTalisman, CosmicFlare
  ]
  LootConsumable*: array[LootKind, bool] = [
    false, false, false, false, false,
    true, true, false, false,
    false, false, false,
    false, false, false,
    false, false, false, false,
    false, false, false
  ]
  HeroAbilities*: array[HeroClass, array[4, Ability]] = [
    [SwordAttack, Taunt, Heat, BlazingBlade],
    [MeteorStrike, FrostLance, VoidPortal, LightningStorm],
    [BowAttack, PiercingArrow, ShadowCloak, HailOfArrows],
    [HammerAttack, Bloom, Entangle, SunOrb]
  ]
  ClassAttacks*: array[HeroClass, seq[Ability]] = [
    @[SwordAttack],
    @[MeteorStrike, SwordAttack],
    @[BowAttack],
    @[HammerAttack]
  ]
    ## The attacks each class picks from, best first. The last is free, so a
    ## hero always has something to fall back on; only the bow cools down.
  ClassSkills*: array[HeroClass, seq[Ability]] = [
    @[Taunt, Heat, BlazingBlade],
    @[],
    @[HailOfArrows, PiercingArrow, ShadowCloak],
    @[Entangle, SunOrb]
  ]
    ## What a class fires the moment it is ready and a foe is in its range,
    ## ahead of any attack, in this order.
  RankAttacks*: array[MonsterRank, Ability] = [
    RakingClaw, HeavyCleave, HexBolt, CrushingSlam, SwarmBite
  ]
    ## The one attack each monster rank fights with, so a runt, a raider
    ## and a champion each read differently from across the room.
  UsableLoot*: array[17, LootKind] = [
    HealingPotionLoot, ManaPotionLoot, BattleHornLoot, WingedBootLoot,
    IronFlailLoot, InfernoAegisLoot, BlazingBladeLoot,
    IceWallLoot, LightningStormLoot, ArcaneMeteorLoot,
    VoidBladeLoot, ShadowCometLoot, GaleSlashLoot, ThornRingLoot,
    FirePhoenixLoot, NatureTalismanLoot, CosmicFlareLoot
  ]

## Class tuning

const
  HeroPresets*: array[HeroClass, string] = [
    "Vanguard Knight", "Arcanist", "Ranger", "Druid Warden"
  ]
  ClassSpeeds*: array[HeroClass, int32] = [250, 260, 340, 270]
  ClassHp*: array[HeroClass, int16] = [340, 200, 250, 270]
  ClassMana*: array[HeroClass, int16] = [0, 160, 40, 180]
  ClassDamage*: array[HeroClass, int32] = [150, 125, 135, 100]
    ## Percentage of base ability damage, so one table tunes how hard the
    ## party hits without touching the ability timings the client animates to.
  ClassCrowdLimit*: array[HeroClass, int32] = [0, 0, 0, 2]
    ## How many foes on its heels a class runs from rather than stand and
    ## trade blows with, and how many round its target it will not walk in
    ## among; 0 stands its ground. See `ChaseTiles` and `CrowdTiles`.
  ClassCarryWeight*: array[HeroClass, int32] = [120, 45, 70, 80]
  ClassLightRadius*: array[HeroClass, int32] = [6, 8, 5, 6]

  SpeciesNames*: array[Species, string] = [
    "Dustling", "Grave Stalker", "Crypt Acolyte", "Barrow Warden",
    "Bog Runt", "Tusk Raider", "Mire Shaman", "Ironhide Chief",
    "Dusk Thrall", "Velvet Stalker", "Blood Cantor", "Dread Count",
    "Cinder Imp", "Ash Reaver", "Ember Hexer", "Infernal Duke",
    "Bone Mite", "Bog Whelp", "Blood Gnat", "Spark Fiend"
  ]
  RankScales*: array[MonsterRank, float32] = [
    0.7'f, 0.9'f, 1.1'f, 1.4'f, 0.48'f
  ]
  FloorFamilies*: array[LevelCount, MonsterFamily] = [
    UndeadFamily, UndeadFamily, OrcFamily, VampireFamily,
    VampireFamily, DemonFamily
  ]
  SpeciesSpeeds*: array[Species, int32] = [
    240, 300, 200, 140, 240, 300, 200, 140,
    240, 300, 200, 140, 240, 300, 200, 140,
    380, 380, 380, 380
  ]
  SpeciesHp*: array[Species, int16] = [
    60, 90, 130, 260, 70, 100, 150, 280,
    80, 110, 170, 300, 90, 130, 190, 340,
    12, 13, 14, 15
  ]
    ## The swarm dies to one or two hits even on the deepest floor.
  SpeciesSight*: array[Species, int32] = [
    6, 9, 10, 5, 6, 9, 10, 5, 6, 9, 10, 5, 6, 9, 10, 5,
    8, 8, 8, 8
  ]
  SpeciesDamage*: array[Species, int32] = [
    55, 70, 80, 110, 60, 75, 85, 115,
    65, 80, 90, 120, 70, 85, 95, 125,
    14, 16, 18, 20
  ]
    ## Percentage of the base ability damage. Monsters hit for less than a
    ## hero would with the same swing: four heroes against a floor's worth of
    ## monsters lose a straight damage race, and the party is meant to be
    ## able to reach the vault and come back. A swarmling alone barely
    ## scratches; five round one hero are a pack member's worth.

  GuardPercent* = 40'i16
    ## The share of a blow that gets through a plain guard.
  TauntTicks* = 72'i16
    ## How long a taunt holds its victims and guards the Fighter.
  TauntGuardPercent* = 50'i16
    ## The share of a blow that gets through to a Fighter who is taunting.
  HeatTicks* = 120'i16               ## how long the aura burns
  HeatPeriodTicks* = 12'i16          ## how often it burns what stands in it
  SlowPercent* = 50'i32              ## of normal speed
  VineTicks* = 72'i16
    ## How long Entangle's vines hold what stands in them.
  VineRootTicks* = 36'i16
    ## How long a body stands in vines before they hold it fast. Its speed
    ## falls evenly to nothing over this stretch.
  VineLeadTicks* = VineRootTicks div 2
    ## How far past the vines' landing Entangle leads a walking pack: half
    ## the time they take to root it, which is how far it walks on at full
    ## speed while they slow it, so it ends up in the middle.
  VineWitherTicks* = 12'i16
    ## How long spent vines take to sink away, holding nothing.
  VineBurnTicks* = 18'i16
    ## How long vines Sun Orb sets alight take to burn away, holding nothing.

  RegenerationIdleTicks* = 72'i16    ## calm needed before wounds close
  RegenerationPeriodTicks* = 12'i32  ## how often a point of healing lands
  RegenerationPercent* = 4'i32       ## of maximum, per period

  EncumbranceScale*: array[4, int32] = [100, 85, 70, 50]
    ## Speed multiplier per encumbrance step, recomputed only when the
    ## inventory changes rather than divided out every tick.

## Run configuration and outcome

type
  Phase* = enum
    DescendingPhase, ReturningPhase, EscapedPhase, WipedPhase

  Outcome* = enum
    RunningOutcome, WipedOutcome, EscapedOutcome, TimedOutOutcome

  PartyMember* = object
    id*: int32
    class*: HeroClass

const
  ArenaMapVersion* = 2'u16
    ## Marks the debug arena, so its setup never matches a dungeon's.
  ArenaAftermathTicks* = TickRate * 3
    ## How long an arena fight keeps running after one side falls, long
    ## enough for the last death to play out.

type
  Setup* = object
    ## Immutable for the whole run, and byte-identical to the replay's setup
    ## record, so `newWorld(setup)` is total and needs nothing else.
    seed*: int32
    mapVersion*: uint16
    tickRate*: uint16
    gridTiles*: uint16
    levels*: uint8
    decisionTicks*: uint16
    hashIntervalTicks*: uint16
    maximumTicks*: uint32
    party*: array[PartySize, PartyMember]
    mapHash*: uint64

## The world

type VinePatch* = object
  ## Entangle's vines on one disc of floor. They hold everyone not on the
  ## side that grew them for `VineTicks`, unless a Sun Orb burns them
  ## first, and then stay, holding nothing, while they wither or burn away.
  side*: ActorKind     ## who grew them; they hold the other side
  center*: TileRef     ## the middle of the disc
  sprouted*: int32     ## the tick they sprang up on
  burned*: int32       ## the tick a Sun Orb set them alight, 0 if never
  burnedFrom*: TileRef ## where that orb landed, which the fire runs out from

type World* = ref object
  ## Everything the simulation may read or write. Adding a field here means
  ## `hashy(world[])` changes, and `games/call_to_adventure/tests/test_sim.nim` fails until the
  ## new field is intentional. Actors are refs; see the module header.
  setup*: Setup
  tick*: int32
  rng*: Rng
  turnStart*: int32                        ## rotating bot decision order
  actors*: seq[Actor]
  items*: seq[Item]
  doors*: seq[Door]
  vines*: seq[VinePatch]                   ## oldest first
  claims*: seq[uint16]                     ## tile -> actor slot + 1, 0 free
  explored*: seq[uint8]                    ## one bit per tile, party-shared
  visible*: array[PartySize, seq[uint8]]   ## one bit per tile, per hero
  chat*: array[ChatLines, ChatLine]
  chatHead*: int32
  banked*: int32
  bankedGold*: array[PartySize, int32]
  returned*: array[PartySize, bool]
  phase*: Phase
  deepest*: int32
  respawnTicks*: int32
  killed*: int32
  collected*: int32
  arenaDecided*: int32                     ## tick an arena fight was won, 0 before
  outcome*: Outcome
  nextActorId*: int32
  nextItemId*: int32
  stats*: CombatStats

## Small helpers on the types above

proc lootUsesSlot*(kind: LootKind): bool =
  ## True when this drop occupies a Q or E slot after pickup.
  LootAbilities[kind] != NoAbility

proc tileIndex*(tile: TileRef): int32 =
  ## Flat index into `claims`, `explored`, and the visibility bitmaps.
  int32(tile.level) * TilesPerLevel + int32(tile.z) * GridTiles + int32(tile.x)

proc `==`*(a, b: TileRef): bool =
  a.level == b.level and a.x == b.x and a.z == b.z

template isArena*(world: World): bool =
  ## True for the debug arena rather than a dungeon expedition.
  world.setup.mapVersion == ArenaMapVersion

template moving*(actor: Actor): bool =
  ## True while a string-pulled path still has a waypoint to walk.
  actor.path.len > 0 and actor.pathIndex < int32(actor.path.len)

template alive*(actor: Actor): bool =
  ## True while this slot holds a living actor.
  actor.id != 0 and actor.hp > 0

template busy*(actor: Actor): bool =
  ## True from an ability's first wind-up tick to its last recovery tick.
  actor.action != NoAbility

proc actionPhase*(actor: Actor): ActionPhase =
  ## Which phase of its ability the actor is in, or `ReadyPhase`.
  if actor.action == NoAbility:
    ReadyPhase
  else:
    Abilities[actor.action].phaseAt(actor.actionTicks)

template staggered*(actor: Actor): bool =
  ## True while a hit has stopped this actor's feet. It can still strike.
  actor.staggerTicks > 0

template cloaked*(actor: Actor): bool =
  ## True while foes cannot target this actor. An area still catches it.
  actor.cloakTicks > 0

template rooted*(actor: Actor): bool =
  ## True once vines hold this actor's feet fast. It can still strike.
  actor.entangledTicks >= VineRootTicks

proc holding*(patch: VinePatch, tick: int32): bool =
  ## True while vines still hold what stands in them: grown, not yet spent,
  ## and not burned.
  patch.burned == 0 and tick - patch.sprouted < int32(VineTicks)

proc gone*(patch: VinePatch, tick: int32): bool =
  ## True once vines have withered or burned all the way away.
  if patch.burned != 0:
    tick - patch.burned >= int32(VineBurnTicks)
  else:
    tick - patch.sprouted >= int32(VineTicks + VineWitherTicks)

template planted*(actor: Actor): bool =
  ## True for a hero with no route to walk, who stays put when bumped.
  actor.kind == HeroActor and not actor.moving

template heroClass*(actor: Actor): HeroClass =
  ## Reads a hero's class without copying the actor.
  HeroClass(actor.class)

template species*(actor: Actor): Species =
  ## Reads a monster's species without copying the actor.
  Species(actor.class)

proc monsterRank*(species: Species): MonsterRank =
  ## Returns the size and strength rank within one family.
  if species >= BoneMiteSpecies:
    SwarmRank
  else:
    MonsterRank(species.ord mod 4)

proc monsterFamily*(species: Species): MonsterFamily =
  ## Returns the faction that supplies the monster's skin color.
  if species >= BoneMiteSpecies:
    MonsterFamily(species.ord - BoneMiteSpecies.ord)
  else:
    MonsterFamily(species.ord div 4)

proc familySpecies*(family: MonsterFamily, rank: MonsterRank): Species =
  ## The one species of a family at a rank.
  if rank == SwarmRank:
    Species(BoneMiteSpecies.ord + family.ord)
  else:
    Species(family.ord * 4 + rank.ord)

proc encumbrance*(actor: Actor, capacity: int32): int32 =
  ## Zero to three, used to index `EncumbranceScale`.
  if capacity <= 0:
    return 0
  min(actor.carriedWeight * 4 div capacity, 3)

template carryCapacity*(actor: Actor): int32 =
  ## Hero carry limit after class lookup, or zero for monsters.
  if actor.kind == HeroActor:
    ClassCarryWeight[actor.heroClass]
  else:
    0

proc opposite*(facing: Facing): Facing =
  Facing((facing.ord + 2) mod 4)
