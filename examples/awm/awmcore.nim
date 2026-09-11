## Core card, rule, target, choice, and effect types for AWM.
##
## Card definitions provide rule factories. A factory returns immutable,
## polymorphic Rule objects; each Rule supplies both its displayed text and
## its executable program. Target objects do the same for target text and
## validated player choice.

import std/[options, strutils]

type
  HeroClass* = enum
    Archer
    Warrior
    Mage

  CardKind* = enum
    Minion
    Spell

  ChoiceKind* = enum
    CanceledChoice
    NoTargetChoice
    HeroChoice
    CreatureChoice

  Choice* = object
    ## A selected game object. `owner` is the player index for both heroes
    ## and creatures, which lets targets enforce friendly/enemy restrictions.
    owner*: int
    case kind*: ChoiceKind
    of CanceledChoice, NoTargetChoice, HeroChoice:
      discard
    of CreatureChoice:
      creatureId*: int

  TargetRelation* = enum
    Friendly
    Enemy
    Any

  VfxKind* = enum
    NoVfx
    LightningVfx
    BubbleVfx
    DamageFlashVfx

  Target* = ref object of RootObj
    ## Base target. Concrete targets control text and legal choices.
    vfx*: VfxKind

  HeroTarget* = ref object of Target
    relation*: TargetRelation

  CreatureTarget* = ref object of Target
    relation*: TargetRelation

  Rule* = ref object of RootObj
    ## Base rule. Concrete rules control text and execution.

  Rules* = seq[Rule]

  Card* = object
    name*: string
    energyCost*: int
    class*: Option[HeroClass]
    rules*: proc(card: Card): Rules {.nimcall.}
    case kind*: CardKind
    of Minion:
      power*: int
      toughness*: int
    of Spell:
      discard

  ChoiceSelector* = proc(
    prompt: string,
    choices: seq[Choice]
  ): Choice {.closure.}

  EffectKind* = enum
    DamageHeroEffect
    DamageCreatureEffect
    BounceCreatureEffect
    TargetVfxEffect

  Effect* = object
    ## Rules emit effects; the authoritative game applies them.
    case kind*: EffectKind
    of DamageHeroEffect:
      heroPlayer*: int
      heroDamage*: int
    of DamageCreatureEffect:
      damagedCreatureId*: int
      creatureDamage*: int
    of BounceCreatureEffect:
      bouncedCreatureId*: int
    of TargetVfxEffect:
      targetVfx*: VfxKind
      visualTarget*: Choice

  RuleContext* = object
    ## The rule engine sees legal game objects and emits effects, but remains
    ## independent from the concrete GameState in awm.nim.
    sourcePlayer*: int
    allowNoTarget*: bool
    heroes*: seq[Choice]
    creatures*: seq[Choice]
    selector*: ChoiceSelector
    effects*: seq[Effect]

  DamageRule* = ref object of Rule
    amount*: int
    target*: Target

  BounceRule* = ref object of Rule
    target*: Target

const
  Canceled* = Choice(kind: CanceledChoice, owner: -1)
  NoTarget* = Choice(kind: NoTargetChoice, owner: -1)

proc className*(heroClass: HeroClass): string =
  case heroClass
  of Archer:
    "Archer"
  of Warrior:
    "Warrior"
  of Mage:
    "Mage"

proc heroChoice*(player: int): Choice =
  Choice(kind: HeroChoice, owner: player)

proc creatureChoice*(owner, creatureId: int): Choice =
  Choice(
    kind: CreatureChoice,
    owner: owner,
    creatureId: creatureId
  )

proc isCanceled*(choice: Choice): bool =
  choice.kind == CanceledChoice

proc isNoTarget*(choice: Choice): bool =
  choice.kind == NoTargetChoice

proc `==`*(a, b: Choice): bool =
  if a.kind != b.kind or a.owner != b.owner:
    return false
  case a.kind
  of CanceledChoice, NoTargetChoice, HeroChoice:
    true
  of CreatureChoice:
    a.creatureId == b.creatureId

proc relationAllows(
    relation: TargetRelation,
    sourcePlayer,
    owner: int
): bool =
  case relation
  of Friendly:
    owner == sourcePlayer
  of Enemy:
    owner != sourcePlayer
  of Any:
    true

method text*(target: Target): string {.base.} =
  "a target"

method candidates*(
    target: Target,
    context: RuleContext
): seq[Choice] {.base.} =
  discard (target, context)

method text*(target: HeroTarget): string =
  case target.relation
  of Friendly:
    "your hero"
  of Enemy:
    "the enemy hero"
  of Any:
    "a hero"

method candidates*(
    target: HeroTarget,
    context: RuleContext
): seq[Choice] =
  for choice in context.heroes:
    if choice.kind == HeroChoice and
        target.relation.relationAllows(context.sourcePlayer, choice.owner):
      result.add choice

method text*(target: CreatureTarget): string =
  case target.relation
  of Friendly:
    "a friendly minion"
  of Enemy:
    "an enemy minion"
  of Any:
    "a minion"

method candidates*(
    target: CreatureTarget,
    context: RuleContext
): seq[Choice] =
  for choice in context.creatures:
    if choice.kind == CreatureChoice and
        target.relation.relationAllows(context.sourcePlayer, choice.owner):
      result.add choice

method choose*(target: Target, context: var RuleContext): Choice {.base.} =
  ## Delegates presentation to the supplied selector, then validates that its
  ## answer is one of this target's legal candidates.
  let choices = target.candidates(context)
  if choices.len == 0:
    return if context.allowNoTarget: NoTarget else: Canceled
  if context.selector.isNil:
    return Canceled
  let selected = context.selector(target.text(), choices)
  if selected.kind == NoTargetChoice and context.allowNoTarget:
    return NoTarget
  for choice in choices:
    if choice == selected:
      if target.vfx != NoVfx:
        context.effects.add Effect(kind: TargetVfxEffect,
          targetVfx: target.vfx, visualTarget: selected)
      return selected
  Canceled

proc targetHero*(relation = Any, vfx = NoVfx): Target =
  HeroTarget(relation: relation, vfx: vfx)

proc targetCreature*(relation = Any, vfx = NoVfx): Target =
  CreatureTarget(relation: relation, vfx: vfx)

method text*(rule: Rule, card: Card): string {.base.} =
  discard card
  ""

method choices*(
    rule: Rule,
    card: Card,
    context: RuleContext
): seq[Choice] {.base.} =
  discard (rule, card, context)

method needsChoice*(rule: Rule): bool {.base.} =
  discard rule
  false

method run*(
    rule: Rule,
    card: Card,
    context: var RuleContext
): bool {.base.} =
  discard (rule, card, context)
  true

method text*(rule: DamageRule, card: Card): string =
  discard card
  "Deal " & $rule.amount & " damage to " & rule.target.text() & "."

method choices*(
    rule: DamageRule,
    card: Card,
    context: RuleContext
): seq[Choice] =
  discard card
  rule.target.candidates(context)

method needsChoice*(rule: DamageRule): bool =
  discard rule
  true

method run*(
    rule: DamageRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let selected = rule.target.choose(context)
  case selected.kind
  of CanceledChoice:
    false
  of NoTargetChoice:
    true
  of HeroChoice:
    context.effects.add Effect(
      kind: DamageHeroEffect,
      heroPlayer: selected.owner,
      heroDamage: rule.amount
    )
    true
  of CreatureChoice:
    context.effects.add Effect(
      kind: DamageCreatureEffect,
      damagedCreatureId: selected.creatureId,
      creatureDamage: rule.amount
    )
    true

method text*(rule: BounceRule, card: Card): string =
  discard card
  "Return " & rule.target.text() & " to its owner's hand."

method choices*(
    rule: BounceRule,
    card: Card,
    context: RuleContext
): seq[Choice] =
  discard card
  rule.target.candidates(context)

method needsChoice*(rule: BounceRule): bool =
  discard rule
  true

method run*(
    rule: BounceRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let selected = rule.target.choose(context)
  if selected.kind == NoTargetChoice:
    return true
  if selected.kind != CreatureChoice:
    return false
  context.effects.add Effect(
    kind: BounceCreatureEffect,
    bouncedCreatureId: selected.creatureId
  )
  true

proc damage*(amount: int, target: Target): Rule =
  DamageRule(amount: amount, target: target)

proc bounce*(target: Target): Rule =
  BounceRule(target: target)

converter singleRule*(rule: Rule): Rules =
  @[rule]

proc rules*(items: varargs[Rule]): Rules =
  for item in items:
    result.add item

proc cardRules*(card: Card): Rules =
  if not card.rules.isNil:
    result = card.rules(card)

proc ruleText*(card: Card): string =
  var lines: seq[string]
  for rule in card.cardRules():
    let line = rule.text(card)
    if line.len > 0:
      lines.add line
  lines.join("\n")

proc needsChoice*(card: Card): bool =
  for rule in card.cardRules():
    if rule.needsChoice():
      return true

proc choices*(card: Card, context: RuleContext): seq[Choice] =
  ## Returns unique legal choices requested by this card's rules.
  for rule in card.cardRules():
    for choice in rule.choices(card, context):
      var duplicate = false
      for existing in result:
        if existing == choice:
          duplicate = true
          break
      if not duplicate:
        result.add choice

proc runRules*(card: Card, context: var RuleContext): bool =
  ## Resolves every on-play rule. A canceled/invalid target cancels the play.
  let effectStart = context.effects.len
  for rule in card.cardRules():
    if not rule.run(card, context):
      # A later canceled rule must not leak damage or VFX from earlier rules.
      context.effects.setLen(effectStart)
      return false
  true

proc `==`*(a, b: Card): bool {.noSideEffect.} =
  ## Rule factories are programs and cannot be compared directly. Card
  ## identity for decks/tests is its printed data and whether it has a rule
  ## program; rule text and behavior are tested through their own APIs.
  if a.name != b.name or
      a.energyCost != b.energyCost or
      a.class != b.class or
      a.kind != b.kind or
      a.rules.isNil != b.rules.isNil:
    return false
  case a.kind
  of Minion:
    a.power == b.power and a.toughness == b.toughness
  of Spell:
    true
