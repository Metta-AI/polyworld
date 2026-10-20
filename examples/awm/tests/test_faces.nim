## Card faces as silky lays them out (silkyfaces.nim), from the fonts baked
## into the UI atlas: every face the table can show fits its text in its
## boxes, and a face shows the state of its card.
import std/[sequtils, sets, strutils, tables, unittest]
import pixie, silky
import ../src/core/[sim, cardset], ../src/baseset,
  ../src/ui/[cardfaces, silkyfaces]

let builder = newAtlasBuilder(5632, 4)
builder.addFaceAssets()
let fonts = builder.atlas.fonts

proc changed(card: Card, gained, lost: Rules): FaceState =
  ## A card in play whose rules changed.
  FaceState(card: card, power: -1, toughness: -1,
    rules: MinionState(card: card, gainedRules: gained,
      lostRules: lost).ruleLines)

proc printed(card: Card): FaceState =
  FaceState(card: card, power: -1, toughness: -1)

proc textIn(state: FaceState, box: Rect): TextBlock =
  for text in state.faceText():
    if text.box == box:
      return text

proc laidRules(state: FaceState): LaidText =
  fonts.layout(state.textIn(RulesBox))

suite "card faces":
  test "every face the table can show fits its text in its boxes":
    # Silky places glyphs on whole pixels down and quarter pixels across.
    # A few rules (Morphosis Chamber's, Overcharge's) overflow their box
    # even at the smallest size; there the text may spill as far as
    # `renderCardFace`'s does, and no further.
    const Slack = 1'f32
    for state in everyFaceState(baseCards):
      for text in state.faceText():
        let
          laid = fonts.layout(text)
          bounds = text.box or fitFaceText(text.runs, text.box, text.style).ink
        checkpoint state.card.name & ": " & text.runs.mapIt(it.text).join()
        check laid.font.len > 0
        check laid.ink.x >= bounds.x - Slack
        check laid.ink.y >= bounds.y - Slack
        check laid.ink.x + laid.ink.w <= bounds.x + bounds.w + Slack
        check laid.ink.y + laid.ink.h <= bounds.y + bounds.h + Slack

  test "an off-class minion in hand keeps its printed stats":
    let
      bear = baseCardNamed("Bear")
      hand = FaceState(card: bear, power: -1, toughness: -1, extraCost: 3)
    check hand.textIn(PowerBox).runs == @[TextRun(text: $bear.power,
      ink: StatInk)]
    check hand.textIn(ToughnessBox).runs == @[TextRun(text: $bear.toughness,
      ink: StatInk)]

  test "a card that costs its holder more shows the total in red":
    let bolt = baseCardNamed("Bolt")
    check bolt.printed.faceText()[0].runs == @[TextRun(
      text: $bolt.energyCost, ink: CostInk)]
    check FaceState(card: bolt, power: -1, toughness: -1,
      extraCost: OffClassCost).faceText()[0].runs == @[TextRun(
      text: $(bolt.energyCost + OffClassCost), ink: DebuffedInk)]

  test "changed rules show in place, gained in green and lost struck in red":
    let
      sharpshooter = baseCardNamed("Sharpshooter")
      commander = baseCardNamed("Commander")
      lost = sharpshooter.changed(@[], @[Rule(ranged())]).laidRules
      gained = baseCardNamed("Bear").changed(@[Rule(ranged()), hidden(1)],
        @[]).laidRules
      both = commander.changed(@[on(eachTurn(You), draw(1))],
        commander.rules).laidRules
    check lost.lines.mapIt((it.text, it.ink, it.struck)) == @[
      ("Ranged", LostRuleInk, true),
      ("Deal 1 damage to any target.", RulesInk, false)]
    check gained.lines.mapIt((it.text, it.ink, it.struck)) == @[
      ("Ranged", GainedRuleInk, false), ("Hidden 1.", GainedRuleInk, false)]
    check both.lines[0].text == "Summon 2 Footsoldiers."
    check both.lines[0].struck and both.lines[0].ink == LostRuleInk
    check both.lines[1 .. ^1].allIt(it.ink == GainedRuleInk and not it.struck)
    check both.lines[1 .. ^1].mapIt(it.text).join(" ") ==
      "At the start of each of your turns, draw 1 card."
    # The printed face has a single ink, nothing struck.
    check sharpshooter.printed.laidRules.lines.allIt(it.ink == RulesInk and
      not it.struck)

  test "every branch of a choice gets a face of its own":
    for card in baseCards:
      var texts: HashSet[string]
      for option in card.everyOption():
        texts.incl card.optionCard(option).printed.textIn(RulesBox).runs.mapIt(
          it.text).join()
      check texts.len == card.everyOption().len
