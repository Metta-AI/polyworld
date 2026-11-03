## Lookups, wire IDs and decks over the base set. The cards and deck lists
## themselves are configured in ../baseset.nim.

import
  std/[options, strutils],
  core, ../baseset

export baseset

## The card lists are never mutated after module init, so the lookups below
## cast to gcsafe: async server handlers deal decks and encode snapshots.

proc classCardNamed(heroClass: HeroClass, name: string): Card =
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.class == some(heroClass) and card.name == name:
        return card
  raise newException(ValueError,
    "No base-set " & $heroClass & " card named '" & name & "'")

proc classCard*(heroClass: HeroClass): Card =
  ## Each class's signature card, found by name so list order doesn't matter.
  case heroClass
  of Archer: Archer.classCardNamed("Bolt")
  of Warrior: Warrior.classCardNamed("Bear")
  of Mage: Mage.classCardNamed("Bouncer")

proc cardId*(card: Card): string =
  ## Stable wire ID. Name plus cost keeps same-named printings apart.
  card.name.toLowerAscii().replace(" ", "-") & "-" & $card.energyCost

proc baseCard*(id: string): Card =
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.cardId() == id:
        return card
  raise newException(ValueError, "Unknown base-set card '" & id & "'")

proc baseCardNamed*(name: string): Card {.nimcall, gcsafe.} =
  ## The base-set card printed with this name, for `summon`.
  {.cast(gcsafe).}:
    for card in baseCards:
      if card.name == name:
        return card
  raise newException(ValueError, "Unknown base-set card named '" & name & "'")

proc ruleId*(rule: Rule): string =
  ## Stable wire ID for a rule written in the base set: its card's ID and
  ## its place in that card's rule tree ("explode-3#2"). Rules are shared
  ## by every copy, so the reference is what a snapshot keeps of a rule a
  ## card gained or lost.
  {.cast(gcsafe).}:
    for card in baseCards:
      for index, written in card.rules.ruleTree():
        if written == rule:
          return card.cardId() & "#" & $index
  raise newException(ValueError, "A rule outside the base set has no ID")

proc ruleById*(id: string): Rule =
  let separator = id.rfind('#')
  if separator < 0:
    raise newException(ValueError, "Invalid rule ID '" & id & "'")
  let
    tree = baseCard(id[0 ..< separator]).rules.ruleTree()
    index =
      try: parseInt(id[separator + 1 .. ^1])
      except ValueError: -1
  if index notin 0 ..< tree.len:
    raise newException(ValueError, "Invalid rule ID '" & id & "'")
  tree[index]

# A misspelled summon fails at startup rather than mid-game.
for card in baseCards:
  card.checkCardNames(baseCardNamed)

type
  DeckList* = seq[(string, int)]
    ## A deck as its builder writes it: card names and how many copies.

const MaxCopies* = 4  ## Of any one card but the class cards.

proc isClassCard*(card: Card): bool =
  ## A class card levels its hero up; a deck may hold any number of them.
  card.levelUpClass.isSome

proc deckProblems*(deck: openArray[(string, int)]): seq[string] =
  ## Why a deck can't be played, or nothing when it can: exactly DeckSize
  ## base-set cards, 1 to MaxCopies of each but the class cards. A card
  ## listed twice counts once, with its copies added up.
  var
    names: seq[string]
    counts: seq[int]
    total = 0
  for (name, copies) in deck:
    if copies < 1:
      result.add $copies & " copies of " & name & "; list at least 1"
      continue
    total += copies
    let index = names.find(name)
    if index < 0:
      names.add name
      counts.add copies
    else:
      counts[index] += copies
  for index, name in names:
    let card =
      try: baseCardNamed(name)
      except ValueError:
        result.add "No card named '" & name & "'"
        continue
    if counts[index] > MaxCopies and not card.isClassCard:
      result.add $counts[index] & " copies of " & name & "; at most " &
        $MaxCopies
  if total != DeckSize:
    result.add $total & " cards; a deck holds exactly " & $DeckSize

proc buildDeck*(deck: openArray[(string, int)]): seq[Card] =
  ## The cards a deck list deals, in list order.
  for (name, copies) in deck:
    let card = baseCardNamed(name)
    for _ in 0 ..< copies:
      result.add card

# Every precon is a legal deck, so the class screen never deals one that
# would put its player out.
for heroClass in HeroClass:
  doAssert baseDeckLists[heroClass].deckProblems().len == 0,
    $heroClass & " precon: " & $baseDeckLists[heroClass].deckProblems()

proc baseDeck*(heroClass: HeroClass): seq[Card] =
  ## The class's precon, dealt from its list in baseset.nim. A list may
  ## name cards of another class, or the class cards of no class: they cost
  ## more to play, which `playCost` works out at the table.
  result = buildDeck(baseDeckLists[heroClass])
  doAssert result.len == DeckSize
