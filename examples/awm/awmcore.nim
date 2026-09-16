## Core card, rule, target, choice, and effect types for AWM.
##
## Card definitions list their rules with `rules(...)`: immutable,
## polymorphic Rule objects shared by every copy of the card. Each Rule
## supplies both its displayed text and its executable program. Target objects do the same for target text and
## validated player choice.

import std/[macros, options, strutils]

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

  TargetKind* = enum
    ## Game objects a target may select. `Minion` overloads CardKind.Minion;
    ## the expected type picks the right one, so `target({Minion, Hero})`
    ## reads like rules text.
    Hero
    Minion

  VfxKind* = enum
    NoVfx
    LightningVfx
    BubbleVfx
    DamageFlashVfx
    ArrowVfx
    # Presentation cue, not a card VFX: a minion died. The UI holds its card
    # in place until the effects aimed at it finish, then sends it to discard.
    DeathVfx
    # A volley of arrows raining onto each minion a query hits.
    ManyArrowsVfx
    # Blades rise and spin away on a gust around each minion a buff reaches.
    SwordsIntoTheWindVfx
    # A glowing shield settles over each minion a toughness buff reaches.
    MightyShieldsVfx
    # A crossed sword and shield rise over one buffed minion.
    SwordAndShieldVfx
    # An arrow snaps in half: the minion loses Ranged.
    MeleeVfx
    # Two blades cross with a burst of sparks where minions fight.
    SwordClashVfx
    # A sword cracks and falls apart over a minion losing power.
    SwordBreakVfx
    # A glob of ooze drops onto a minion and bursts.
    OozeSplatVfx

  Keyword* = enum
    ## Printed minion keywords. Each prints as its own line of rules text.
    Ranged

  Owner* = enum
    ## Whose cards a query selects, relative to the player who plays the card.
    You
    Opponent

  Zone* = enum
    ## Game zones rules can query. Hand, deck and discard will join the board.
    BoardZone

  Target* = ref object of RootObj
    ## Base target. Concrete targets control text and legal choices.
    vfx*: VfxKind

  ObjectTarget* = ref object of Target
    ## Selects one hero and/or minion, restricted by its owner's relation.
    kinds*: set[TargetKind]
    relation*: TargetRelation

  Amount* = ref object of RootObj
    ## A number a rule works out when the card resolves. Plain ints convert
    ## to one, so `summon(2, ...)` and `summon(getTarget().toughness, ...)`
    ## both read naturally.

  FixedAmount* = ref object of Amount
    number*: int

  ToughnessAmount* = ref object of Amount
    ## `getTarget().toughness`: a minion's current toughness.
    target*: Target

  PickedTarget* = ref object of Target
    ## `getTarget(n)`: whatever the card's nth target (from 0) chose. It
    ## makes no new choice.
    index*: int

  Rule* = ref object of RootObj
    ## Base rule. Concrete rules control text and execution.

  Rules* = seq[Rule]

  Card* = object
    name*: string
    energyCost*: int
    class*: Option[HeroClass]
    rules*: Rules
    case kind*: CardKind
    of Minion:
      power*: int
      toughness*: int
    of Spell:
      discard

  CardLookup* = proc(name: string): Card {.nimcall, gcsafe.}
    ## Finds a card by printed name, for rules that create cards.

  ChoiceSelector* = proc(
    prompt: string,
    choices: seq[Choice]
  ): Choice {.closure.}

  EffectKind* = enum
    DamageHeroEffect
    DamageCreatureEffect
    BounceCreatureEffect
    ModifyStatsEffect
    LoseKeywordEffect
    FightEffect
    SummonEffect
    DestroyEffect
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
    of ModifyStatsEffect:
      ## A permanent power/toughness change. It lasts while the minion stays
      ## on the board; a minion that leaves returns to its printed stats.
      modifiedCreatureId*: int
      powerChange*: int
      toughnessChange*: int
    of LoseKeywordEffect:
      ## Permanent while the minion stays on the board, like stat changes.
      keywordLoserId*: int
      lostKeyword*: Keyword
    of FightEffect:
      ## Both minions deal their power to each other at once, as in combat.
      ## Resolved when applied, so earlier effects on the card count.
      fighterId*, opponentId*: int
    of SummonEffect:
      ## A new minion enters at the right of its owner's board. Its id was
      ## handed out while the rules ran, so later rules could reach it.
      summonedId*, summonedOwner*: int
      summonedCard*: Card
    of DestroyEffect:
      ## The minion goes to its owner's discard pile, whatever its toughness.
      destroyedId*: int
    of TargetVfxEffect:
      targetVfx*: VfxKind
      visualTarget*: Choice

  BoardCard* = object
    choice*: Choice
    card*: Card
    power*, toughness*: int  ## Live stats, counting damage and buffs.

  GameView* = object
    ## The live game as rules see it when they resolve.
    board*: seq[BoardCard]
    nextMinionId*: int  ## The id the next minion to enter play gets.

  RuleContext* = object
    ## The rule engine sees legal game objects and emits effects, but remains
    ## independent from the concrete GameState in awm.nim.
    sourcePlayer*: int
    allowNoTarget*: bool
    heroes*: seq[Choice]
    creatures*: seq[Choice]
    game*: GameView
    selector*: ChoiceSelector
    picks*: seq[Choice]
      ## Preselected answers, one per card target in order. When empty, the
      ## selector is asked instead.
    targets*: seq[Choice]
      ## What each target chose so far while resolving, for `getTarget`.
    cardNamed*: CardLookup
    effects*: seq[Effect]

  GameQuery* = object
    ## `game` inside `rules(...)`. Rules are built once, before any game
    ## exists, so `game.board.choose(...)` builds a query that reads the
    ## live `GameView` each time the card resolves.

  ZoneQuery* = object
    zone*: Zone

  CardQuery* = ref object
    ## Every card in `zone` matching the kinds and owners, found on resolve.
    zone*: Zone
    kinds*: set[CardKind]
    owners*: set[Owner]

  DamageRule* = ref object of Rule
    amount*: Amount
    target*: Target

  BounceRule* = ref object of Rule
    target*: Target

  KeywordRule* = ref object of Rule
    ## A static ability. It has no on-play program; the engine reads it
    ## through `keywords`.
    keyword*: Keyword

  DamageEachRule* = ref object of Rule
    ## Damages every card a query selects. Nothing to choose.
    amount*: Amount
    cards*: CardQuery
    vfx*: VfxKind

  StatsEachRule* = ref object of Rule
    ## Permanently changes the power and toughness of every card a query
    ## selects. Nothing to choose.
    power*, toughness*: Amount
    cards*: CardQuery
    vfx*: VfxKind

  StatsRule* = ref object of Rule
    ## Permanently changes one target's power and toughness.
    power*, toughness*: Amount
    target*: Target
    removes*: bool  ## Subtracts its amounts, printed "-1/-0".

  DestroyRule* = ref object of Rule
    target*: Target

  SummonRule* = ref object of Rule
    ## Creates new minions from a named card. Nothing to choose.
    count*: Amount
    cardName*: string
    owner*: Owner

  LoseKeywordRule* = ref object of Rule
    keyword*: Keyword
    target*: Target

  FightRule* = ref object of Rule
    ## Two minions fight each other, as in combat, without attacking.
    fighter*, opponent*: Target
    vfx*: VfxKind

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

method text*(target: ObjectTarget): string =
  if target.kinds == {Hero}:
    case target.relation
    of Friendly:
      "your hero"
    of Enemy:
      "the enemy hero"
    of Any:
      "a hero"
  elif target.kinds == {TargetKind.Minion}:
    case target.relation
    of Friendly:
      "a friendly minion"
    of Enemy:
      "an enemy minion"
    of Any:
      "a minion"
  else:
    case target.relation
    of Friendly:
      "a friendly target"
    of Enemy:
      "an enemy target"
    of Any:
      "any target"

method candidates*(
    target: ObjectTarget,
    context: RuleContext
): seq[Choice] =
  if Hero in target.kinds:
    for choice in context.heroes:
      if choice.kind == HeroChoice and
          target.relation.relationAllows(context.sourcePlayer, choice.owner):
        result.add choice
  if TargetKind.Minion in target.kinds:
    for choice in context.creatures:
      if choice.kind == CreatureChoice and
          target.relation.relationAllows(context.sourcePlayer, choice.owner):
        result.add choice

proc select(
    context: RuleContext,
    prompt: string,
    choices: seq[Choice]
): Choice =
  ## The preselected pick for the next target, else the selector's answer.
  if context.picks.len > 0:
    if context.targets.len < context.picks.len:
      context.picks[context.targets.len]
    else:
      Canceled
  elif context.selector.isNil:
    Canceled
  else:
    context.selector(prompt, choices)

method choose*(target: Target, context: var RuleContext): Choice {.base.} =
  ## Takes the next pick (or asks the selector), then validates that it is
  ## one of this target's legal candidates. Every target that resolves is
  ## recorded, so `getTarget(n)` lines up with the card's nth target.
  let choices = target.candidates(context)
  result = Canceled
  if choices.len == 0:
    if context.allowNoTarget:
      result = NoTarget
  else:
    let selected = context.select(target.text(), choices)
    if selected.kind == NoTargetChoice and context.allowNoTarget:
      result = NoTarget
    else:
      for choice in choices:
        if choice == selected:
          if target.vfx != NoVfx:
            context.effects.add Effect(kind: TargetVfxEffect,
              targetVfx: target.vfx, visualTarget: selected)
          result = selected
          break
  if not result.isCanceled:
    context.targets.add result

proc ordinal(index: int): string =
  case index
  of 0: "first"
  of 1: "second"
  of 2: "third"
  else: $(index + 1) & "th"

method text*(target: PickedTarget): string =
  "the " & target.index.ordinal() & " target"

method choose*(target: PickedTarget, context: var RuleContext): Choice =
  if target.index < context.targets.len:
    context.targets[target.index]
  else:
    Canceled

proc getTarget*(index = 0): Target =
  ## `fight(getTarget(0), getTarget(1))`: reuses earlier targets' choices.
  PickedTarget(index: index)

proc targetCount*(card: Card): int

proc targetText(target: Target, card: Card): string =
  ## A `getTarget` on a card with a single target is just "the target".
  if target of PickedTarget and card.targetCount() == 1:
    "the target"
  else:
    target.text()

converter toAmount*(number: int): Amount =
  FixedAmount(number: number)

proc toughness*(target: Target): Amount =
  ## `getTarget().toughness`.
  ToughnessAmount(target: target)

method value*(amount: Amount, context: var RuleContext): int {.base.} =
  discard (amount, context)
  0

method text*(amount: Amount, card: Card): string {.base.} =
  discard (amount, card)
  ""

method value*(amount: FixedAmount, context: var RuleContext): int =
  discard context
  amount.number

method text*(amount: FixedAmount, card: Card): string =
  discard card
  $amount.number

method value*(amount: ToughnessAmount, context: var RuleContext): int =
  ## Read from the rules' view of the board, so a minion an earlier rule on
  ## this card destroyed still counts with the toughness it had.
  let choice = amount.target.choose(context)
  if choice.kind == CreatureChoice:
    for entry in context.game.board:
      if entry.choice == choice:
        return max(0, entry.toughness)

method text*(amount: ToughnessAmount, card: Card): string =
  amount.target.targetText(card) & "'s toughness"

proc signed(amount: int): string =
  (if amount >= 0: "+" else: "") & $amount

proc estimate(amount: Amount): int =
  ## A fixed number, or 1 for one only known on resolve.
  if amount of FixedAmount: FixedAmount(amount).number else: 1

proc statsText(power, toughness: Amount, removes: bool, card: Card): string =
  ## "+1/+0", "-1/-0", or "+X/+0, where X is the target's toughness".
  const names = ["X", "Y"]
  var parts, clauses: seq[string]
  for amount in [power, toughness]:
    if amount of FixedAmount:
      let number = FixedAmount(amount).number
      parts.add(if removes: "-" & $number else: number.signed())
    else:
      let name = names[clauses.len]
      parts.add((if removes: "-" else: "+") & name)
      clauses.add name & " is " & amount.text(card)
  result = parts.join("/")
  if clauses.len > 0:
    result.add ", where " & clauses.join(" and ")

proc damageText(amount: Amount, victims: string, card: Card): string =
  ## "Deal 1 damage to a minion.", "Deal the first target's toughness
  ## damage to the second target."
  "Deal " & amount.text(card) & " damage to " & victims & "."

proc change(amount: Amount, removes: bool, context: var RuleContext): int =
  (if removes: -1 else: 1) * amount.value(context)

proc objectTarget*(
    kinds: set[TargetKind],
    relation = Any,
    vfx = NoVfx
): Target =
  ObjectTarget(kinds: kinds, relation: relation, vfx: vfx)

template target*(
    kinds: untyped,
    relation: TargetRelation = Any,
    vfx: VfxKind = NoVfx
): Target =
  ## `target({Hero})`, `target({Minion}, Enemy)`, `target({Minion, Hero})`.
  ## Set literals ignore their expected type, so `Minion` is locally bound to
  ## TargetKind.Minion instead of being ambiguous with CardKind.Minion.
  block:
    const Minion {.inject, used.} = TargetKind.Minion
    objectTarget(kinds, relation, vfx)

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

method targets*(rule: Rule): seq[Target] {.base.} =
  ## Targets this rule chooses, in order. `getTarget` references aren't
  ## listed: they choose nothing new.
  discard rule

method helpsTarget*(rule: Rule): bool {.base.} =
  ## True when the rule is good for what it targets, so players (and bots)
  ## aim it at their own minions.
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
  rule.amount.damageText(rule.target.targetText(card), card)

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

method targets*(rule: DamageRule): seq[Target] =
  @[rule.target]

method run*(
    rule: DamageRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let selected = rule.target.choose(context)
  let amount = rule.amount.value(context)
  case selected.kind
  of CanceledChoice:
    false
  of NoTargetChoice:
    true
  of HeroChoice:
    context.effects.add Effect(
      kind: DamageHeroEffect,
      heroPlayer: selected.owner,
      heroDamage: amount
    )
    true
  of CreatureChoice:
    context.effects.add Effect(
      kind: DamageCreatureEffect,
      damagedCreatureId: selected.creatureId,
      creatureDamage: amount
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

method targets*(rule: BounceRule): seq[Target] =
  @[rule.target]

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

method text*(rule: KeywordRule, card: Card): string =
  discard card
  $rule.keyword

proc text*(query: CardQuery): string =
  ## "all enemy minions", "all friendly minions", "all minions".
  result = "all "
  if query.owners == {Opponent}:
    result.add "enemy "
  elif query.owners == {You}:
    result.add "friendly "
  result.add(
    if query.kinds == {CardKind.Minion}: "minions"
    elif query.kinds == {Spell}: "spells"
    else: "cards")

proc matches*(query: CardQuery, context: RuleContext): seq[Choice] =
  ## The query's cards in the live game, in board order.
  case query.zone
  of BoardZone:
    for entry in context.game.board:
      let owner =
        if entry.choice.owner == context.sourcePlayer: You else: Opponent
      if entry.card.kind in query.kinds and owner in query.owners:
        result.add entry.choice

method text*(rule: DamageEachRule, card: Card): string =
  rule.amount.damageText(rule.cards.text(), card)

method run*(
    rule: DamageEachRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let
    hit = rule.cards.matches(context)
    amount = rule.amount.value(context)
  # Every visual lands before damage can remove a card from the board.
  if rule.vfx != NoVfx:
    for choice in hit:
      context.effects.add Effect(kind: TargetVfxEffect,
        targetVfx: rule.vfx, visualTarget: choice)
  for choice in hit:
    case choice.kind
    of HeroChoice:
      context.effects.add Effect(kind: DamageHeroEffect,
        heroPlayer: choice.owner, heroDamage: amount)
    of CreatureChoice:
      context.effects.add Effect(kind: DamageCreatureEffect,
        damagedCreatureId: choice.creatureId, creatureDamage: amount)
    of CanceledChoice, NoTargetChoice:
      discard
  true


method text*(rule: StatsEachRule, card: Card): string =
  ## "Give all friendly minions +1/+0." Give, not get: the change is permanent.
  "Give " & rule.cards.text() & " " &
    statsText(rule.power, rule.toughness, false, card) & "."

method run*(
    rule: StatsEachRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let hit = rule.cards.matches(context)
  if rule.vfx != NoVfx:
    for choice in hit:
      context.effects.add Effect(kind: TargetVfxEffect,
        targetVfx: rule.vfx, visualTarget: choice)
  for choice in hit:
    if choice.kind == CreatureChoice:
      context.effects.add Effect(kind: ModifyStatsEffect,
        modifiedCreatureId: choice.creatureId,
        powerChange: rule.power.change(false, context),
        toughnessChange: rule.toughness.change(false, context))
  true

method text*(rule: StatsRule, card: Card): string =
  "Give " & rule.target.text() & " " &
    statsText(rule.power, rule.toughness, rule.removes, card) & "."

method choices*(
    rule: StatsRule,
    card: Card,
    context: RuleContext
): seq[Choice] =
  discard card
  rule.target.candidates(context)

method needsChoice*(rule: StatsRule): bool =
  discard rule
  true

method targets*(rule: StatsRule): seq[Target] =
  @[rule.target]

method helpsTarget*(rule: StatsRule): bool =
  let total = rule.power.estimate() + rule.toughness.estimate()
  if rule.removes: total < 0 else: total > 0

method run*(
    rule: StatsRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let selected = rule.target.choose(context)
  if selected.isCanceled:
    return false
  if selected.kind == CreatureChoice:
    context.effects.add Effect(kind: ModifyStatsEffect,
      modifiedCreatureId: selected.creatureId,
      powerChange: rule.power.change(rule.removes, context),
      toughnessChange: rule.toughness.change(rule.removes, context))
  true

method text*(rule: LoseKeywordRule, card: Card): string =
  discard card
  rule.target.text().capitalizeAscii() & " loses " & $rule.keyword & "."

method choices*(
    rule: LoseKeywordRule,
    card: Card,
    context: RuleContext
): seq[Choice] =
  discard card
  rule.target.candidates(context)

method needsChoice*(rule: LoseKeywordRule): bool =
  discard rule
  true

method targets*(rule: LoseKeywordRule): seq[Target] =
  @[rule.target]

method run*(
    rule: LoseKeywordRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let selected = rule.target.choose(context)
  if selected.isCanceled:
    return false
  if selected.kind == CreatureChoice:
    context.effects.add Effect(kind: LoseKeywordEffect,
      keywordLoserId: selected.creatureId, lostKeyword: rule.keyword)
  true

method text*(rule: FightRule, card: Card): string =
  rule.fighter.targetText(card).capitalizeAscii() & " fights " &
    rule.opponent.targetText(card) & "."

method targets*(rule: FightRule): seq[Target] =
  for target in [rule.fighter, rule.opponent]:
    if not (target of PickedTarget):
      result.add target

method needsChoice*(rule: FightRule): bool =
  rule.targets().len > 0

method run*(
    rule: FightRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let
    fighter = rule.fighter.choose(context)
    opponent = rule.opponent.choose(context)
  if fighter.isCanceled or opponent.isCanceled:
    return false
  # Only minions fight; a minion's on-play rule may have chosen no target.
  if fighter.kind != CreatureChoice or opponent.kind != CreatureChoice:
    return true
  if rule.vfx != NoVfx:
    context.effects.add Effect(kind: TargetVfxEffect,
      targetVfx: rule.vfx, visualTarget: opponent)
  context.effects.add Effect(kind: FightEffect,
    fighterId: fighter.creatureId, opponentId: opponent.creatureId)
  true

proc addPowerToughness*(power, toughness: Amount, target: Target): Rule =
  ## `addPowerToughness(1, 1, target({Minion}))`.
  StatsRule(power: power, toughness: toughness, target: target)

proc removePowerToughness*(power, toughness: Amount, target: Target): Rule =
  ## `removePowerToughness(1, 0, target({Minion}))`: permanent, and power
  ## never drops below 0.
  StatsRule(power: power, toughness: toughness, target: target,
    removes: true)

method text*(rule: DestroyRule, card: Card): string =
  discard card
  "Destroy " & rule.target.text() & "."

method choices*(
    rule: DestroyRule,
    card: Card,
    context: RuleContext
): seq[Choice] =
  discard card
  rule.target.candidates(context)

method needsChoice*(rule: DestroyRule): bool =
  discard rule
  true

method targets*(rule: DestroyRule): seq[Target] =
  @[rule.target]

method run*(
    rule: DestroyRule,
    card: Card,
    context: var RuleContext
): bool =
  discard card
  let selected = rule.target.choose(context)
  if selected.isCanceled:
    return false
  if selected.kind == CreatureChoice:
    context.effects.add Effect(kind: DestroyEffect,
      destroyedId: selected.creatureId)
  true

proc destroy*(target: Target): Rule =
  ## `destroy(target({Minion}))`: straight to the discard pile.
  DestroyRule(target: target)

method text*(rule: SummonRule, card: Card): string =
  ## "Summon 2 Footsoldiers.", "Summon a Footsoldier for your opponent.",
  ## "Summon Oozes equal to the target's toughness."
  let name = rule.cardName
  result = "Summon "
  if not (rule.count of FixedAmount):
    result.add name & "s equal to " & rule.count.text(card)
  elif FixedAmount(rule.count).number == 1:
    result.add(
      if name.len > 0 and name[0].toLowerAscii() in {'a', 'e', 'i', 'o', 'u'}:
        "an "
      else:
        "a ")
    result.add name
  else:
    result.add rule.count.text(card) & " " & name & "s"
  if rule.owner == Opponent:
    result.add " for your opponent"
  result.add "."

method run*(
    rule: SummonRule,
    card: Card,
    context: var RuleContext
): bool =
  ## The new minions join the rules' view of the board at once, so later
  ## rules on the same card (Rally's buff) reach them.
  discard card
  let summoned = context.cardNamed(rule.cardName)
  var owner = context.sourcePlayer
  if rule.owner == Opponent:
    for hero in context.heroes:
      if hero.owner != context.sourcePlayer:
        owner = hero.owner
        break
  for _ in 0 ..< rule.count.value(context):
    let choice = creatureChoice(owner, context.game.nextMinionId)
    inc context.game.nextMinionId
    context.game.board.add BoardCard(choice: choice, card: summoned,
      power: summoned.power, toughness: summoned.toughness)
    context.creatures.add choice
    context.effects.add Effect(kind: SummonEffect,
      summonedId: choice.creatureId, summonedOwner: owner,
      summonedCard: summoned)
  true

proc summon*(count: Amount, cardName: string, owner = You): Rule =
  ## `summon(2, "Footsoldier")`: new base-set minions enter under `owner`'s
  ## control. Like played minions, they attack from their owner's next
  ## turn; their own on-play rules don't run.
  SummonRule(count: count, cardName: cardName, owner: owner)

proc summonedNames*(card: Card): seq[string] =
  ## Names of the cards this card's rules summon.
  for rule in card.rules:
    if rule of SummonRule:
      result.add SummonRule(rule).cardName

proc lose*(keyword: KeywordRule, target: Target): Rule =
  ## `lose(ranged(), target({Minion}))`: the target loses that keyword,
  ## permanently while it stays on the board.
  LoseKeywordRule(keyword: keyword.keyword, target: target)

proc fight*(fighter, opponent: Target, vfx = NoVfx): Rule =
  ## `fight(getTarget(0), getTarget(1))`: both deal their power at once.
  FightRule(fighter: fighter, opponent: opponent, vfx: vfx)

proc damage*(amount: Amount, target: Target): Rule =
  DamageRule(amount: amount, target: target)

proc damage*(amount: Amount, cards: CardQuery, vfx = NoVfx): Rule =
  ## `damage(1, game.board.choose(kind: Minion, owner: Opponent))`.
  DamageEachRule(amount: amount, cards: cards, vfx: vfx)

proc addPowerToughness*(
    power, toughness: Amount,
    cards: CardQuery,
    vfx = NoVfx
): Rule =
  ## `addPowerToughness(1, 0, game.board.choose(kind: Minion, owner: You))`.
  StatsEachRule(power: power, toughness: toughness, cards: cards, vfx: vfx)

proc board*(game: GameQuery): ZoneQuery =
  ZoneQuery(zone: BoardZone)

macro choose*(zone: ZoneQuery, filters: varargs[untyped]): CardQuery =
  ## Selects every card in `zone` matching `kind: CardKind` and
  ## `owner: Owner`. An omitted filter matches anything.
  let query = genSym(nskVar, "query")
  var body = newStmtList(quote do:
    var `query` = CardQuery(zone: `zone`.zone,
      kinds: {low(CardKind) .. high(CardKind)},
      owners: {low(Owner) .. high(Owner)}))
  for filter in filters:
    if filter.kind != nnkExprColonExpr:
      error("choose filters are written `name: value`", filter)
    let value = filter[1]
    if filter[0].eqIdent("kind"):
      body.add(quote do:
        block:
          let kind: CardKind = `value`
          `query`.kinds = {kind})
    elif filter[0].eqIdent("owner"):
      body.add(quote do:
        block:
          let owner: Owner = `value`
          `query`.owners = {owner})
    else:
      error("unknown choose filter; use `kind` or `owner`", filter[0])
  body.add query
  result = newBlockStmt(body)

proc chooseCalls(node: NimNode): NimNode =
  ## `zone.choose(kind: Minion)` parses as an object constructor, which Nim
  ## would reject before `choose` saw its filters. Rewrite it into a call.
  if node.kind == nnkObjConstr and node[0].kind == nnkDotExpr and
      node[0][1].eqIdent("choose"):
    result = newCall(ident"choose", chooseCalls(node[0][0]))
    for index in 1 ..< node.len:
      result.add node[index]
  else:
    result = node
    for index in 0 ..< node.len:
      result[index] = chooseCalls(node[index])

proc bounce*(target: Target): Rule =
  BounceRule(target: target)

proc ranged*(): KeywordRule =
  ## Ranged minions take no combat damage from non-ranged minions. Also
  ## names the keyword elsewhere: `lose(ranged(), target(...))`.
  KeywordRule(keyword: Ranged)

proc ruleList(items: varargs[Rule]): Rules =
  for item in items:
    result.add item

macro rules*(items: varargs[untyped]): Rules =
  ## A card's printed rules, in order: `rules: rules(ranged(), damage(...))`.
  ## Inside, `game` names the live game: `game.board.choose(...)`.
  var call = newCall(bindSym"ruleList")
  for item in items:
    call.add chooseCalls(item)
  let game = nnkPragmaExpr.newTree(ident"game",
    nnkPragma.newTree(ident"used"))
  result = newBlockStmt(newStmtList(
    newLetStmt(game, newCall(bindSym"GameQuery")), call))

proc `&`*(a, b: openArray[Card]): seq[Card] =
  ## Joins card lists, e.g. `archer & warrior & mage`.
  result = @a
  result.add b

proc ruleText*(card: Card): string =
  var lines: seq[string]
  for rule in card.rules:
    let line = rule.text(card)
    if line.len > 0:
      lines.add line
  lines.join("\n")

proc keywords*(card: Card): set[Keyword] =
  for rule in card.rules:
    if rule of KeywordRule:
      result.incl KeywordRule(rule).keyword

proc picks(rule: Rule): seq[Target] =
  ## The rule's targets that make a new choice: `getTarget` reuses one.
  for target in rule.targets():
    if not (target of PickedTarget):
      result.add target

proc targets*(card: Card): seq[Target] =
  ## Every choice the card asks for, in the order players make them.
  for rule in card.rules:
    result.add rule.picks()

proc needsChoice*(card: Card): bool =
  card.targets().len > 0

proc targetCount*(card: Card): int =
  card.targets().len

proc helpsTarget*(card: Card, step: int): bool =
  ## Whether the card's `step`th target (from 0) is one to aim at your own.
  var index = 0
  for rule in card.rules:
    for _ in rule.picks():
      if index == step:
        return rule.helpsTarget()
      inc index

proc choices*(card: Card, context: RuleContext, step = 0): seq[Choice] =
  ## Unique legal choices for the card's `step`th target (from 0).
  let targets = card.targets()
  if step >= targets.len:
    return
  for choice in targets[step].candidates(context):
    if choice notin result:
      result.add choice

proc runRules*(card: Card, context: var RuleContext): bool =
  ## Resolves every on-play rule. A canceled/invalid target cancels the play.
  let effectStart = context.effects.len
  for rule in card.rules:
    if not rule.run(card, context):
      # A later canceled rule must not leak damage or VFX from earlier rules.
      context.effects.setLen(effectStart)
      return false
  true

proc `==`*(a, b: Card): bool {.noSideEffect.} =
  ## Printed data plus the same rule objects. Copies of a card share its
  ## rules, so a look-alike built elsewhere never equals a base-set card.
  if a.name != b.name or
      a.energyCost != b.energyCost or
      a.class != b.class or
      a.kind != b.kind or
      a.rules.len != b.rules.len:
    return false
  for index in 0 ..< a.rules.len:
    if a.rules[index] != b.rules[index]:
      return false
  case a.kind
  of Minion:
    a.power == b.power and a.toughness == b.toughness
  of Spell:
    true
