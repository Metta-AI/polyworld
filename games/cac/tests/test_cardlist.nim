## The card reference on the command line: --cards, --cards:CLASS and
## --card:NAME. Needs no window.
import std/[options, sequtils, strutils, unittest]
import ../src/core/[core, cardset, cardlist]

suite "CaC card reference":
  test "a card prints one field per line, in order":
    check baseCardNamed("Sniper").cardSheet == """
Card:   Sniper
Cost:   2
Class:  Archer
Type:   Minion
Effect: Ranged
P/T:    2/1"""

  test "rules of several lines stay indented under the effect":
    check baseCardNamed("Overcharge").cardSheet == """
Card:   Overcharge
Cost:   3
Class:  Archer
Type:   Spell
Effect: Choose:
        - Deal 1 damage to a minion. Deal 1 damage to the target's owner.
        - Deal 3 damage to a minion. Deal 3 damage to the target's owner. Deal 3 damage to yourself.
P/T:    —"""

  test "no rules, no class and no stats print a dash":
    check baseCardNamed("Bear").cardSheet.contains("Effect: —\n")
    let archer = baseCardNamed("Archer").cardSheet
    check archer.contains("Class:  —\n")
    check archer.endsWith("P/T:    —")

  test "every card is listed once, and each class lists its own":
    check cardsOf().len == baseCards.len
    var total = 0
    for heroClass in HeroClass:
      let cards = cardsOf(some(heroClass))
      total += cards.len
      check cards.len > 0
      # Its level-up card is among them.
      check cards.anyIt(it.levelUpClass == some(heroClass))
      for card in cards:
        check card.class == some(heroClass) or
          card.levelUpClass == some(heroClass)
    check total == baseCards.len

  test "a name is read without case, spaces or hyphens":
    for name in ["Hail of Arrows", "hail of arrows", "hail-of-arrows",
        "HAILOFARROWS"]:
      check findCard(name).get.name == "Hail of Arrows"
    check findCard("Bubble").get.name == "Bubble"
    check findCard("Bub").isNone

  test "the command line asks for a listing, a class or a card":
    check cardReference(["--seed", "4"]).isNone
    check cardReference(["--cards"]).get.count("Card:   ") == baseCards.len
    check cardReference(["--cards:warrior"]).get ==
      cardReference(["--cards=Warrior"]).get
    check cardReference(["--card:post"]).get.startsWith("Card:   Post\n")
    check cardReference(["--card", "Summon Primordial"]).get.startsWith(
      "Card:   Summon Primordial\n")
    expect ValueError:
      discard cardReference(["--cards:ranger"])
    expect ValueError:
      discard cardReference(["--card"])
    try:
      discard cardReference(["--card:bub"])
      check false
    except ValueError as error:
      check "Bubble, Bubble Shield" in error.msg
