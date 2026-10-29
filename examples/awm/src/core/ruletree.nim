## A card's rules tree as plain nodes, for bots: every rule, trigger,
## target, filter and value its rules are built from, in the order they are
## written, each right after the node it belongs to. A node's kind is the
## card DSL call that builds it, so bots read the same names baseset.nim
## writes.

import std/strutils
import core

type
  RuleNode* = object
    kind*: string
      ## The DSL call that builds it: "damage", "on", "lasts", "target",
      ## "fixed". A set of kinds or classes is "set"; anything this file
      ## doesn't know yet is "unknown".
    role*: string
      ## Which part of its parent it is: "amount", "what", "rules",
      ## "trigger", "turns", or a filter's stat, "energyCost".
    parent*: int  ## Its parent's index; -1 for one of the card's own rules.
    value*: int
      ## A fixed number, or an enum's ordinal; -1 for a count that never
      ## runs down (`hidden()`); a `choose` branch's index.
    text*: string
      ## A rule's printed words, a fixed value or card name as written, a
      ## set's members ("Minion,Trinket"), a target's description.

  RuleTree* = seq[RuleNode]

const
  TriggerNames: array[TriggerKind, string] = [
    "nextTurn", "eachTurn", "eachEndOfTurn", "attacked", "attacked", "played",
    "destroyed"]
  StatNames: array[CardStat, string] = ["energyCost", "power", "toughness"]
  ComparisonNames: array[Comparison, string] = [
    "eq", "notEq", "atMost", "atLeast", "between"]

proc add(tree: var RuleTree, kind, role: string, parent: int, value = 0,
    text = ""): int {.discardable.} =
  tree.add RuleNode(kind: kind, role: role, parent: parent, value: value,
    text: text)
  tree.high

proc names[T](members: set[T]): string =
  var parts: seq[string]
  for member in members:
    parts.add $member
  parts.join(",")

proc addRules(tree: var RuleTree, rules: Rules, role: string, parent: int,
    card: Card)
proc addTarget(tree: var RuleTree, target: Target, role: string,
    parent: int, card: Card)
proc addQuery(tree: var RuleTree, query: CardQuery, role: string,
    parent: int, card: Card)

proc addValue[T](tree: var RuleTree, value: RuleValue[T], role: string,
    parent: int, card: Card) =
  let text = value.text(card)
  case value.kind
  of FixedValue:
    when T is int:
      tree.add("fixed", role, parent, value.fixed, text)
    elif T is enum:
      tree.add("fixed", role, parent, value.fixed.ord, $value.fixed)
    elif T is Card:
      tree.add("fixed", role, parent, text = value.fixed.name)
    else:
      let node = tree.add("fixed", role, parent, text = text)
      tree.addRules(value.fixed, "rules", node, card)
  of CardNamed:
    tree.add("cardNamed", role, parent, text = value.name)
  of SelfCard:
    tree.add("self", role, parent, text = text)
  of PlayedCard:
    tree.add("getPlayed", role, parent, text = text)
  of PowerOf, ToughnessOf, OwnerOf, RulesOf:
    let kind =
      case value.kind
      of PowerOf: "power"
      of ToughnessOf: "toughness"
      of OwnerOf: "owner"
      else: "printedRules"
    let node = tree.add(kind, role, parent, text = text)
    tree.addTarget(value.target, "target", node, card)
  of CountOf:
    let node = tree.add("count", role, parent, text = text)
    tree.addQuery(value.query, "query", node, card)
  of Sum, Difference:
    let node = tree.add(if value.kind == Sum: "sum" else: "difference",
      role, parent, text = text)
    for operand in value.operands:
      tree.addValue(operand, "operands", node, card)

proc addFilters(tree: var RuleTree, stats: seq[StatFilter], parent: int,
    card: Card) =
  ## `energyCost: atMost(3)`: the comparison, in the stat's role.
  for filter in stats:
    let node = tree.add(ComparisonNames[filter.bound.comparison],
      StatNames[filter.stat], parent)
    tree.addValue(filter.bound.low, "low", node, card)
    if filter.bound.comparison == Between:
      tree.addValue(filter.bound.high, "high", node, card)

proc addTarget(tree: var RuleTree, target: Target, role: string,
    parent: int, card: Card) =
  let text = target.text()
  if target of ObjectTarget:
    let aimed = ObjectTarget(target)
    let node = tree.add("target", role, parent, text = text)
    tree.add("set", "kind", node, text = aimed.kinds.names)
    if aimed.relation != Any:
      tree.add("fixed", "owner", node, aimed.relation.ord, $aimed.relation)
    tree.addFilters(aimed.stats, node, card)
    if aimed.classes.card > 0:
      tree.add("set", "class", node, text = aimed.classes.names)
  elif target of PickedTarget:
    let node = tree.add("getTarget", role, parent, text = text)
    let index = PickedTarget(target).index
    tree.add("fixed", "index", node, index, $index)
  elif target of AttackerTarget:
    tree.add("getAttacker", role, parent, text = text)
  elif target of PlayedTarget:
    tree.add("getPlayed", role, parent, text = text)
  elif target of OptionTarget:
    tree.add("option", role, parent, text = text)
  else:
    tree.add("unknown", role, parent, text = text)

proc addQuery(tree: var RuleTree, query: CardQuery, role: string,
    parent: int, card: Card) =
  let node = tree.add("getCards", role, parent, text = query.text(card))
  if query.kinds.card > 0:
    tree.add("set", "kind", node, text = query.kinds.names)
  if not query.anyOwner:
    tree.addValue(query.owner, "owner", node, card)
  tree.add("fixed", "self", node, query.includeSelf.int, $query.includeSelf)
  tree.addFilters(query.stats, node, card)
  if query.classes.card > 0:
    tree.add("set", "class", node, text = query.classes.names)

proc addSelection(tree: var RuleTree, what: Selection, role: string,
    parent: int, card: Card) =
  case what.kind
  of SelectTarget: tree.addTarget(what.target, role, parent, card)
  of SelectQuery: tree.addQuery(what.query, role, parent, card)

proc addTrigger(tree: var RuleTree, trigger: Trigger, parent: int,
    card: Card) =
  let node = tree.add(TriggerNames[trigger.kind], "trigger", parent,
    text = trigger.text(card))
  case trigger.kind
  of NextTurnStart, EachTurnStart, EachTurnEnd, HeroAttacked:
    tree.addValue(trigger.player, "player", node, card)
  of CardAttacked, CardDestroyed:
    tree.addValue(trigger.card, "card", node, card)
  of CardPlayed:
    tree.addValue(trigger.playedBy, "player", node, card)
    if trigger.playedKinds.card > 0:
      tree.add("set", "kind", node, text = trigger.playedKinds.names)
    tree.addFilters(trigger.playedStats, node, card)
    if trigger.playedClasses.card > 0:
      tree.add("set", "class", node, text = trigger.playedClasses.names)

proc addTurns(tree: var RuleTree, turns, parent: int) =
  tree.add("fixed", "turns", parent, turns,
    if turns == Always: "always" else: $turns)

proc addRule(tree: var RuleTree, rule: Rule, role: string, parent: int,
    card: Card) =
  let text = rule.text(card)
  template node(kind: string): int =
    tree.add(kind, role, parent, text = text)
  if rule of DamageRule:
    let damage = DamageRule(rule)
    let at = node("damage")
    tree.addValue(damage.amount, "amount", at, card)
    tree.addSelection(damage.what, "what", at, card)
  elif rule of DamagePlayerRule:
    let damage = DamagePlayerRule(rule)
    let at = node("damage")
    tree.addValue(damage.amount, "amount", at, card)
    tree.addValue(damage.players, "players", at, card)
  elif rule of BounceRule:
    let at = node("bounce")
    tree.addSelection(BounceRule(rule).what, "what", at, card)
  elif rule of KeywordRule:
    discard node(($KeywordRule(rule).keyword).toLowerAscii)
  elif rule of StatsRule:
    let stats = StatsRule(rule)
    let at = node(
      if stats.removes: "removePowerToughness" else: "addPowerToughness")
    tree.addValue(stats.power, "power", at, card)
    tree.addValue(stats.toughness, "toughness", at, card)
    tree.addSelection(stats.what, "what", at, card)
  elif rule of DestroyRule:
    let at = node("destroy")
    tree.addSelection(DestroyRule(rule).what, "what", at, card)
  elif rule of DestroyCardRule:
    let at = node("destroy")
    tree.addValue(DestroyCardRule(rule).card, "card", at, card)
  elif rule of DrawRule:
    let draw = DrawRule(rule)
    let at = node("draw")
    tree.addValue(draw.count, "count", at, card)
    tree.addValue(draw.player, "player", at, card)
  elif rule of ExtraEnergyRule:
    let energy = ExtraEnergyRule(rule)
    let at = node("extraEnergy")
    tree.addValue(energy.amount, "amount", at, card)
    tree.addValue(energy.player, "player", at, card)
  elif rule of TossRule:
    let toss = TossRule(rule)
    let at = node("toss")
    tree.addValue(toss.count, "count", at, card)
    tree.addValue(toss.player, "player", at, card)
  elif rule of OnRule:
    let on = OnRule(rule)
    let at = node("on")
    tree.addTrigger(on.trigger, at, card)
    tree.addRules(on.rules, "rules", at, card)
  elif rule of SummonRule:
    let summon = SummonRule(rule)
    let at = node("summon")
    tree.addValue(summon.count, "count", at, card)
    tree.addValue(summon.card, "card", at, card)
    tree.addValue(summon.owner, "owner", at, card)
  elif rule of GainRule:
    let gain = GainRule(rule)
    let at = node("gain")
    tree.addRule(gain.rule, "rule", at, card)
    tree.addSelection(gain.what, "what", at, card)
  elif rule of LoseRule:
    let lose = LoseRule(rule)
    let at = node("lose")
    tree.addRule(lose.rule, "rule", at, card)
    tree.addSelection(lose.what, "what", at, card)
  elif rule of GainControlRule:
    let control = GainControlRule(rule)
    let at = node("gainControl")
    tree.addValue(control.player, "player", at, card)
    tree.addSelection(control.what, "what", at, card)
  elif rule of FightRule:
    let fight = FightRule(rule)
    let at = node("fight")
    tree.addTarget(fight.fighter, "fighter", at, card)
    tree.addTarget(fight.opponent, "opponent", at, card)
  elif rule of LevelUpRule:
    let levelUp = LevelUpRule(rule)
    let at = node("levelUp")
    tree.add("fixed", "levels", at, levelUp.levels, $levelUp.levels)
    tree.add("fixed", "heroClass", at, levelUp.heroClass.ord,
      $levelUp.heroClass)
  elif rule of HiddenRule:
    let at = node("hidden")
    tree.addTurns(HiddenRule(rule).turns, at)
  elif rule of LastsRule:
    let at = node("lasts")
    tree.addTurns(LastsRule(rule).turns, at)
  elif rule of RepeatRule:
    let at = node("repeat")
    tree.addValue(RepeatRule(rule).what, "what", at, card)
  elif rule of ChooseRule:
    let at = node("choose")
    for index, option in ChooseRule(rule).options:
      let branch = tree.add("rules", "options", at, index,
        card.optionCard(option).ruleText())
      tree.addRules(option, "rules", branch, card)
  else:
    discard node("unknown")

proc addRules(tree: var RuleTree, rules: Rules, role: string, parent: int,
    card: Card) =
  for rule in rules:
    tree.addRule(rule, role, parent, card)

proc ruleNodes*(rules: Rules, card: Card): RuleTree =
  ## Every node of these rules, written for `card` ("this card", its name).
  result.addRules(rules, "rules", -1, card)
