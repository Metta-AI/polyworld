## The card reference on the command line: `--cards` lists every base-set
## card, `--cards:CLASS` one class's, and `--card:NAME` shows one card.
## Needs no window, so every build answers before anything else starts.

import
  std/[options, sequtils, strutils],
  core, cardset

const NoValue = "—"

proc cardSheet*(card: Card): string =
  ## A card as the reference prints it, one field per line. Rules that
  ## take several lines keep them, indented under the first.
  let
    effect = card.ruleText()
    lines = if effect.len == 0: @[NoValue] else: effect.splitLines()
  result = "Card:   " & card.name & "\n" &
    "Cost:   " & $card.energyCost & "\n" &
    "Class:  " & (if card.class.isSome: $card.class.get else: NoValue) & "\n" &
    "Type:   " & $card.kind & "\n" &
    "Effect: " & lines[0]
  for line in lines[1 .. ^1]:
    result.add "\n        " & line
  result.add "\nP/T:    " &
    (if card.kind == Minion: $card.power & "/" & $card.toughness
    else: NoValue)

proc inClass(card: Card, heroClass: HeroClass): bool =
  ## A class's cards, its level-up card among them.
  card.class == some(heroClass) or card.levelUpClass == some(heroClass)

proc cardsOf*(heroClass: Option[HeroClass] = none(HeroClass)): seq[Card] =
  ## Every base-set card, or one class's, in base-set order.
  for card in baseCards:
    if heroClass.isNone or card.inClass(heroClass.get):
      result.add card

proc simplified(name: string): string =
  ## A card name without case, spaces or hyphens: "hail-of-arrows" finds
  ## Hail of Arrows.
  for character in name.toLowerAscii():
    if character in {'a' .. 'z', '0' .. '9'}:
      result.add character

proc findCard*(name: string): Option[Card] =
  ## The base-set card with this name, read loosely.
  let wanted = name.simplified
  for card in baseCards:
    if card.name.simplified == wanted:
      return some(card)

proc parseClass(value: string): HeroClass =
  case value.toLowerAscii()
  of "archer": Archer
  of "warrior": Warrior
  of "mage": Mage
  else:
    raise newException(ValueError, "Unknown class '" & value &
      "'; expected archer, warrior or mage")

proc flagValue(argument, flag: string): Option[string] =
  ## The value of `--flag:VALUE` or `--flag=VALUE`.
  for separator in [":", "="]:
    if argument.startsWith(flag & separator):
      return some(argument[flag.len + 1 .. ^1])

proc cardReference*(arguments: openArray[string]): Option[string] =
  ## What `--cards`, `--cards:CLASS` or `--card:NAME` prints, or none
  ## when the command line asks for none of them. Raises ValueError for an
  ## unknown class or card.
  for index, argument in arguments:
    if argument == "--cards":
      return some(cardsOf().mapIt(it.cardSheet).join("\n\n"))
    let classValue = argument.flagValue("--cards")
    if classValue.isSome:
      let cards = cardsOf(some(parseClass(classValue.get)))
      return some(cards.mapIt(it.cardSheet).join("\n\n"))
    var name = argument.flagValue("--card")
    if name.isNone and argument == "--card":
      if index + 1 >= arguments.len:
        raise newException(ValueError, "--card needs a card name")
      name = some(arguments[index + 1])
    if name.isSome:
      let card = findCard(name.get)
      if card.isNone:
        var close: seq[string]
        let wanted = name.get.simplified
        for known in baseCards:
          if wanted.len > 0 and wanted in known.name.simplified:
            close.add known.name
        raise newException(ValueError, "No card named '" & name.get & "'" &
          (if close.len > 0: "; did you mean " & close.join(", ") & "?"
          else: "; --cards lists them all"))
      return some(card.get.cardSheet)

proc printCardReference*(arguments: openArray[string]): bool =
  ## Prints the card reference the command line asks for and returns true,
  ## or returns false when it asks for none. A bad name or class quits
  ## with an error.
  try:
    let text = cardReference(arguments)
    if text.isNone:
      return false
    echo text.get
    true
  except ValueError as error:
    quit error.msg, QuitFailure
