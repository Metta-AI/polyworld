## Flat, typed replay diagnostics. Formatting belongs to the consumer.

type
  ActionError* {.size: sizeof(int32).} = enum
    NoActionError, ActionNotAlive, ActionInvalidSlot, ActionUnknownItem,
    ActionInsufficientGold, ActionAlreadyEquipped, ActionStackFull,
    ActionInventoryFull, ActionEmptySlot, ActionNotConsumable,
    ActionFullHealth, ActionFullMana, ActionTargetUnavailable,
    ActionOutOfRange, ActionNoRoute, ActionInvalidPoint, ActionCooldown,
    ActionNoCharges, ActionInsufficientMana, ActionSpellLimit,
    ActionChanneling, ActionStunned, ActionRooted, ActionOutsideKeep,
    ActionAbilityLocked, ActionNoAbilityPoints, ActionAbilityMaxLevel,
    ActionHeroLevelRequired,
    ActionNotDead, ActionMatchEnded,
    ActionDrafting, ActionNotDrafting, ActionNotDraftTurn,
    ActionUnknownHero, ActionHeroTaken

  EventKind* {.size: sizeof(int32).} = enum
    EntitySpawned, EntityRespawned, EntityRemoved, Damage, Healing, Death,
    Assist, XpGained, GoldGained, GoldSpent, LevelChanged, HealthAdjusted,
    ManaChanged, SpellReleased, ItemPurchased, ItemConsumed, ActionRejected,
    MatchEnded, PortalStarted, PortalCompleted, PortalInterrupted,
    Stunned, Rooted, RecoveryStarted, RecoveryInterrupted, RecoveryCompleted,
    AbilityLeveled,
    HeroDrafted

  EventCause* {.size: sizeof(int32).} = enum
    Initialization, Wave, BasicAttack, AbilityEffect, ItemEffect, KillReward,
    EquipmentChange, LevelUp, Regeneration, Respawn, Command, GodDestroyed,
    TimeLimit, CorpseExpired, Buyback

  EventEntity* = object
    id*, kind*, team*, class*, player*: int32
    x*, y*, z*: int32

  GameEvent* = object
    kind*: EventKind
    tick*: int32
    actor*, target*: EventEntity
    cause*: EventCause
    detail*: int32
      ## Ability or item ID, according to cause or kind.
    amount*, requested*, before*, after*: int64
    related*: int32
      ## Index of the causal event in this tick, or -1 when absent.
    action*: uint8
    slot*, first*, second*: int32
    offsetX*, offsetY*: int32
      ## Original command arguments, including invalid signed slots.
    error*: ActionError

proc actionErrorMessage*(error: ActionError): string =
  ## Formats a rejection at the UI boundary, never in the event buffer.
  case error
  of NoActionError: ""
  of ActionNotAlive: "Available when alive"
  of ActionInvalidSlot: "Invalid slot"
  of ActionUnknownItem: "Unknown item"
  of ActionInsufficientGold: "Not enough gold"
  of ActionAlreadyEquipped: "Already equipped"
  of ActionStackFull: "Stack full"
  of ActionInventoryFull: "Inventory full"
  of ActionEmptySlot: "Empty slot"
  of ActionNotConsumable: "Not consumable"
  of ActionFullHealth: "Health is full"
  of ActionFullMana: "Mana is full"
  of ActionTargetUnavailable: "Target unavailable"
  of ActionOutOfRange: "Out of range"
  of ActionNoRoute: "No route"
  of ActionInvalidPoint: "Invalid map point"
  of ActionCooldown: "On cooldown"
  of ActionNoCharges: "No charges"
  of ActionInsufficientMana: "Not enough mana"
  of ActionSpellLimit: "Too many active spells"
  of ActionChanneling: "Teleport channel in progress"
  of ActionStunned: "Stunned"
  of ActionRooted: "Rooted"
  of ActionOutsideKeep: "Return to your keep"
  of ActionAbilityLocked: "Ability is locked"
  of ActionNoAbilityPoints: "No ability points"
  of ActionAbilityMaxLevel: "Ability is at maximum level"
  of ActionHeroLevelRequired: "Higher hero level required"
  of ActionNotDead: "Available when dead"
  of ActionMatchEnded: "Match has ended"
  of ActionDrafting: "Waiting for all players to draft"
  of ActionNotDrafting: "Draft is complete"
  of ActionNotDraftTurn: "Wait for your draft turn"
  of ActionUnknownHero: "Unknown hero"
  of ActionHeroTaken: "Hero already drafted"
