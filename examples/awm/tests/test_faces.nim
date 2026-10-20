## Live faces, composed from their layers on the CPU, against the reference
## renderer, which composes the whole face in one image. Every layer above
## the chrome is opaque wherever the chrome is, so the GPU draws exactly
## these pixels at 1:1; only the chrome blends, over the art.
import std/[sequtils, sets, strutils, unittest]
import pixie
import ../src/core/sim, ../src/ui/[cardfaces, facelayers]

const ChromeOverArt = 1
  ## The reference draws the frame and then the crystals over the art; a
  ## face draws them over the art already composed, which rounds a few of
  ## the crystal's edge pixels over the art differently.

proc compose(state: FaceState): Image =
  result = newImage(CardFaceWidth, CardFaceHeight)
  for layer in state.faceLayers():
    let part = layer.part.facePart
    result.draw(part.image, translate(part.at))

proc reference(state: FaceState): Image =
  state.card.renderCardFace(state.power, state.toughness,
    rules = state.rules, extraCost = state.extraCost)

proc worstDiff(a, b: Image): int =
  for i in 0 ..< a.data.len:
    let
      x = a.data[i]
      y = b.data[i]
    result = max(result, max(max(abs(x.r.int - y.r.int),
      abs(x.g.int - y.g.int)), max(abs(x.b.int - y.b.int),
      abs(x.a.int - y.a.int))))

proc inkPixels(image: Image, ink: string, box: Rect): int =
  ## Pixels in `box` close to `ink`: the body of its glyphs.
  let color = parseHtmlColor(ink).rgbx()
  for y in box.y.int ..< int(box.y + box.h):
    for x in box.x.int ..< int(box.x + box.w):
      let pixel = image[x, y]
      if abs(pixel.r.int - color.r.int) + abs(pixel.g.int - color.g.int) +
          abs(pixel.b.int - color.b.int) < 40:
        inc result

proc changed(card: Card, gained, lost: Rules): FaceState =
  ## A card in play whose rules changed.
  FaceState(card: card, power: -1, toughness: -1,
    rules: MinionState(card: card, gainedRules: gained,
      lostRules: lost).ruleLines)

suite "live card faces":
  test "every face the table can show composes to the reference":
    for state in everyFaceState(baseCards):
      let diff = worstDiff(state.compose(), state.reference())
      checkpoint state.card.name & " (" & $state.power & "/" &
        $state.toughness & ", +" & $state.extraCost & ") differs by " & $diff
      check diff <= ChromeOverArt

  test "an off-class minion in hand keeps its printed stats":
    # The old overlay patches drew a red 0 toughness here, from the hand's
    # -1.
    let
      bear = baseCardNamed("Bear")
      hand = FaceState(card: bear, power: -1, toughness: -1, extraCost: 3)
      printed = FaceState(card: bear, power: bear.power,
        toughness: bear.toughness, extraCost: 3)
    check worstDiff(hand.compose(), printed.compose()) == 0

  test "every branch of a choice gets a face of its own":
    for card in baseCards:
      var texts: HashSet[string]
      for option in card.everyOption():
        let layers = FaceState(card: card.optionCard(option), power: -1,
          toughness: -1).faceLayers()
        texts.incl layers[^1].part & layers[^2].part
      check texts.len == card.everyOption().len

  test "text a face first shows mid-game is laid out once":
    for state in everyFaceState(baseCards):
      discard state.faceLayers()
    discard takeNewParts()
    let state = FaceState(card: baseCardNamed("Bear"), power: 57,
      toughness: 2)
    discard state.faceLayers()
    check takeNewParts().len == 1  # "57"; the rest was laid out already.
    discard state.faceLayers()
    check takeNewParts().len == 0

  test "changed rules show in place, gained in green and lost struck in red":
    let
      sharpshooter = baseCardNamed("Sharpshooter")
      bear = baseCardNamed("Bear")
      commander = baseCardNamed("Commander")
      lost = sharpshooter.changed(@[], @[Rule(ranged())])
      gained = bear.changed(@[Rule(ranged()), hidden(1)], @[])
      both = commander.changed(@[on(eachTurn(You), draw(1))],
        commander.rules)
    for state in [lost, gained, both]:
      checkpoint state.card.name
      let face = state.compose()
      check worstDiff(face, state.reference()) <= ChromeOverArt
    let printed = FaceState(card: sharpshooter, power: -1, toughness: -1)
    check printed.compose().inkPixels(LostRuleInk, RulesBox) == 0
    check lost.compose().inkPixels(LostRuleInk, RulesBox) > 100
    check lost.compose().inkPixels(GainedRuleInk, RulesBox) == 0
    check gained.compose().inkPixels(GainedRuleInk, RulesBox) > 100
    check gained.compose().inkPixels(LostRuleInk, RulesBox) == 0
    check both.compose().inkPixels(LostRuleInk, RulesBox) > 100
    check both.compose().inkPixels(GainedRuleInk, RulesBox) > 100

  test "a card that costs its holder more shows the total in red":
    let
      bolt = baseCardNamed("Bolt")
      surcharged = FaceState(card: bolt, power: -1, toughness: -1,
        extraCost: OffClassCost)
      cost = "/" & DebuffedInk & "/1:" & $(bolt.energyCost + OffClassCost)
    check surcharged.faceLayers().anyIt(it.part.endsWith(cost))
    check FaceState(card: bolt, power: -1, toughness: -1).faceLayers().anyIt(
      it.part.endsWith("/" & CostInk & "/1:" & $bolt.energyCost))
