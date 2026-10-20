## Card faces from independently editable illustration, frame, icon and font
## assets. The game draws a face live from parts made here (see
## facelayers.nim): the art crop, the chrome (frame and icons) and its text,
## laid out by the same fit as below. `renderCardFace` composes a whole face
## on the CPU: it is the reference the live faces are tested against, and
## what tools draw previews with.

import std/[os, options, strutils, tables]
import pixie
import pixie/fileformats/svg
import ../core/core, ../paths

const
  CardFaceWidth* = 600
  CardFaceHeight* = 850
  ArtX = 27
  ArtY = 113
  ArtWidth = 546
  ArtHeight = 417
  ArtRect* = Rect(x: ArtX, y: ArtY, w: ArtWidth, h: ArtHeight)
  # Minion stat number boxes in face pixels: a minion in play shows its
  # live stats here, in place of the printed ones.
  PowerBox* = Rect(x: 85, y: 757, w: 54, h: 61)
  ToughnessBox* = Rect(x: 503, y: 757, w: 54, h: 61)
  # The type line ("MINION").
  TypeLine* = Rect(x: 109, y: 532, w: 382, h: 32)
  # The cost crystal, top right, with what the card costs right now.
  CrystalSize* = 120'f32
  CostBox* = Rect(x: CardFaceWidth.float32 - 26 - CrystalSize, y: 15,
    w: CrystalSize, h: CrystalSize)
  # The gem inside the crystal, where its number is centred.
  CrystalGem* = Rect(x: 14, y: 13, w: CrystalSize - 28, h: 94)
  # Text boxes, in face pixels. The name stops well short of the crystal.
  NameBox* = Rect(x: 42, y: 21, w: CostBox.x - CrystalSize - 56, h: 90)
  RulesBox* = Rect(x: 65, y: 605, w: 470, h: 113)
  ClassBox* = Rect(x: 171, y: 762, w: 258, h: 24)
  PowerIconAt* = vec2(29, 745)
  ToughnessIconAt* = vec2(447, 745)
  # Where the spell mark at the foot of a spell or trinket is drawn (the
  # 30 px icon at (285, 791), with a pixel round it for its filtered edge),
  # and the ornament an empty rules box shows instead of text.
  ArcaneMarkBox* = Rect(x: 284, y: 790, w: 32, h: 32)
  FlourishBox* = Rect(x: 248, y: 646, w: 104, h: 24)

type
  TextStyle* = object
    ## How a block of face text is set: its starting size, the size it may
    ## shrink to so it fits its box, ink, weight, alignment and wrapping.
    size*, minimumSize*: float32
    ink*: string
    semibold*: bool
    alignment*: HorizontalAlignment
    wrap*: bool

  Buff* = enum
    ## A live value against the printed one, for whoever holds the card.
    Unbuffed
    Buffed  ## Better: more power or toughness, a lower cost.
    Debuffed  ## Worse: less power or toughness, a higher cost.

  TextRun* = object
    ## A stretch of face text in an ink of its own, struck through or not.
    text*: string
    ink*: string
    struck*: bool

var
  assetsRoot: string
  assetImages: Table[string, Image]
  titleTypeface, rulesTypeface: Typeface

proc assetImage(relativePath: string, width = 0, height = 0): Image =
  let key = relativePath & ":" & $width & ":" & $height
  if key notin assetImages:
    assetImages[key] = if width > 0 and relativePath.endsWith(".svg"):
      newImage(parseSvg(readFile(assetsRoot / relativePath), width, height))
    else:
      readImage(assetsRoot / relativePath)
  assetImages[key]

proc initCardAssets*(root = artworkRoot() / "cards") =
  ## Load card components from the AWM data folder or an explicit directory.
  if root == assetsRoot and not titleTypeface.isNil:
    return
  assetsRoot = root
  assetImages.clear()
  titleTypeface = readFont(assetsRoot / "fonts/Grenze-SemiBold.ttf").typeface
  rulesTypeface = readFont(assetsRoot / "fonts/Grenze-Regular.ttf").typeface

proc ensureAssets() =
  if assetsRoot.len == 0:
    initCardAssets()

proc cardFont(size: float32, ink: string, semibold = false): Font =
  result = newFont(if semibold: titleTypeface else: rulesTypeface)
  result.size = size
  result.lineHeight = size * 1.08
  result.paint.color = parseHtmlColor(ink)

proc textStyle*(size: float32, ink: string, semibold = false,
    alignment = CenterAlign, minimumSize = 28'f32, wrap = false): TextStyle =
  TextStyle(size: size, minimumSize: minimumSize, ink: ink,
    semibold: semibold, alignment: alignment, wrap: wrap)

proc fitText(runs: openArray[TextRun], width, height: float32,
    style: TextStyle): tuple[arrangement: Arrangement, shift: Vec2] =
  ## Fit long names and multi-line rule text to a fixed safe area, every run
  ## shrinking together. Actual ink bounds provide optical vertical
  ## centering independent of font ascenders. `shift` places the
  ## arrangement from the box's top left.
  var
    size = style.size
    arrangement: Arrangement
  while true:
    var spans: seq[Span]
    for run in runs:
      let font = cardFont(size, run.ink, style.semibold)
      font.strikethrough = run.struck
      spans.add newSpan(run.text, font)
    arrangement = typeset(spans, vec2(width, 0), style.alignment,
      wrap = style.wrap)
    let bounds = arrangement.computeBounds()
    if (bounds.w <= width and bounds.h <= height) or
        size <= style.minimumSize:
      break
    size -= 1
  let bounds = arrangement.computeBounds()
  (arrangement, vec2(0, (height - bounds.h) / 2 - bounds.y))

proc drawText(image: Image, runs: openArray[TextRun], box: Rect,
    style: TextStyle) =
  if runs.len == 0:
    return
  let fitted = fitText(runs, box.w, box.h, style)
  image.fillText(fitted.arrangement,
    translate(vec2(box.x, box.y) + fitted.shift))

proc drawText(image: Image, value: string, box: Rect, style: TextStyle) =
  if value.len == 0:
    return
  image.drawText([TextRun(text: value, ink: style.ink)], box, style)

proc drawText(
    image: Image, value: string, x, y, width, height, size: float32,
    ink: string, semibold = false, alignment = CenterAlign,
    minimumSize = 28'f32, wrap = false
) =
  image.drawText(value, Rect(x: x, y: y, w: width, h: height),
    textStyle(size, ink, semibold, alignment, minimumSize, wrap))

proc fitFaceText*(runs: openArray[TextRun], box: Rect,
    style: TextStyle): tuple[arrangement: Arrangement, at: Vec2, ink: Rect] =
  ## Text laid out in its box as `drawText` lays it out: the arrangement,
  ## where it is filled on the face, and the whole-pixel area its ink can
  ## touch (anti-aliasing stays within a pixel of the ink; two leave room).
  ensureAssets()
  let fitted = fitText(runs, box.w, box.h, style)
  result.arrangement = fitted.arrangement
  result.at = vec2(box.x, box.y) + fitted.shift
  let
    ink = fitted.arrangement.computeBounds(translate(result.at))
    left = max(0'f32, floor(ink.x) - 2)
    top = max(0'f32, floor(ink.y) - 2)
    right = min(CardFaceWidth.float32, ceil(ink.x + ink.w) + 2)
    bottom = min(CardFaceHeight.float32, ceil(ink.y + ink.h) + 2)
  result.ink = Rect(x: left, y: top, w: right - left, h: bottom - top)

proc cardArt(relativePath: string): Image =
  ## A card's illustration, scaled once to the window it is drawn into and
  ## kept at that size. The source art is several times larger than the
  ## window, and no view ever shows it bigger, so holding the original
  ## would cost memory for the whole session and buy nothing.
  let key = "art:" & relativePath
  if key notin assetImages:
    let source =
      if fileExists(assetsRoot / relativePath):
        readImage(assetsRoot / relativePath)
      else:
        readImage(assetsRoot / "art/unknown.svg")
    let
      scaleFactor = max(ArtWidth.float32 / source.width.float32,
        ArtHeight.float32 / source.height.float32)
      crop = newImage(ArtWidth, ArtHeight)
      x = (ArtWidth.float32 - source.width.float32 * scaleFactor) / 2
      y = (ArtHeight.float32 - source.height.float32 * scaleFactor) / 2
    crop.draw(source, translate(vec2(x, y)) * scale(vec2(scaleFactor)))
    assetImages[key] = crop
  assetImages[key]

proc cardArtImage*(card: Card): Image =
  ## The card's illustration, cropped to the face's art window.
  ensureAssets()
  cardArt("art/" & card.name.toLowerAscii().replace(" ", "-") & ".png")

proc drawArt(image: Image, card: Card) =
  image.draw(card.cardArtImage(), translate(vec2(ArtX, ArtY)))

proc frameImage*(kind: CardKind): Image =
  ## The face frame: the minion frame, or the spell frame spells and
  ## trinkets share.
  ensureAssets()
  assetImage(if kind == Minion: "frames/creature.svg" else: "frames/spell.svg")

proc energyIcon*(): Image =
  ensureAssets()
  assetImage("icons/energy.svg")

proc powerIcon*(): Image =
  ensureAssets()
  assetImage("icons/power.svg")

proc toughnessIcon*(): Image =
  ensureAssets()
  assetImage("icons/toughness.svg")

proc drawArcaneMark*(image: Image, at = vec2(0, 0)) =
  ## The spell mark at the foot of a spell or trinket, onto an image whose
  ## top left is `at` on the face: the 80 px arcane icon scaled by 0.375 at
  ## (285, 791), exactly as the face draws it.
  ensureAssets()
  image.draw(assetImage("icons/arcane.svg"),
    translate(vec2(285, 791) - at) * scale(vec2(0.375)))

proc drawFlourish*(image: Image, at = vec2(0, 0)) =
  ## The ornament of an empty rules box, two rules and a diamond, onto an
  ## image whose top left is `at` on the face.
  let
    color = parseHtmlColor("#a39169")
    lines = newPath()
    diamond = newPath()
  lines.moveTo(252, 659)
  lines.lineTo(284, 659)
  lines.moveTo(316, 659)
  lines.lineTo(348, 659)
  image.strokePath(lines, color, translate(-at), strokeWidth = 1.5)
  diamond.moveTo(300, 650)
  diamond.lineTo(305, 659)
  diamond.lineTo(300, 668)
  diamond.lineTo(295, 659)
  diamond.closePath()
  image.fillPath(diamond, color, translate(-at))

const
  CostInk* = "#fff4d5"
  StatInk* = "#fff0c9"
  BuffedInk* = "#a8f08c"
  DebuffedInk* = "#ff9d87"
  RulesInk* = "#26251e"
  GainedRuleInk* = "#18772f"
    ## A rule a card in play gained, on the parchment of its rules box.
  LostRuleInk* = "#ad2a1f"
    ## A rule it lost, struck through.

proc statBuff*(value, printed: int): Buff =
  ## A live power or toughness: more is better.
  if value > printed: Buffed
  elif value < printed: Debuffed
  else: Unbuffed

proc costBuff*(value, printed: int): Buff =
  ## A live cost: less is better.
  statBuff(printed, value)

proc ink*(buff: Buff, unbuffed: string): string =
  ## A live value's colour: `unbuffed` while it is the printed one.
  case buff
  of Unbuffed: unbuffed
  of Buffed: BuffedInk
  of Debuffed: DebuffedInk

proc ruleRuns*(card: Card, lines: openArray[RuleLine]): seq[TextRun] =
  ## The rules box of a card in play whose rules changed, a line per rule:
  ## kept ones as printed, gained ones in green, lost ones in red and
  ## struck through.
  for line in lines:
    let text = line.rule.text(card)
    if text.len == 0:
      continue
    if result.len > 0:
      result.add TextRun(text: "\n", ink: RulesInk)
    result.add case line.change
      of KeptRule: TextRun(text: text, ink: RulesInk)
      of GainedRule: TextRun(text: text, ink: GainedRuleInk)
      of LostRule: TextRun(text: text, ink: LostRuleInk, struck: true)

proc drawStat(image: Image, value: int, buff: Buff, box: Rect) =
  image.drawText($value, box.x, box.y, box.w, box.h, 68, buff.ink(StatInk),
    true)

proc renderChrome*(kind: CardKind): Image =
  ## Everything on a face that isn't art or text, for one kind of card: the
  ## frame and its icons, drawn exactly as `renderCardFace` draws them.
  result = frameImage(kind).copy()
  result.draw(energyIcon(), translate(vec2(CostBox.x, CostBox.y)))
  if kind == Minion:
    result.draw(powerIcon(), translate(PowerIconAt))
    result.draw(toughnessIcon(), translate(ToughnessIconAt))
  else:
    result.drawArcaneMark()

proc renderCardFace*(card: Card, currentPower = -1, currentToughness = -1,
    showStats = true, rules: openArray[RuleLine] = [], extraCost = 0): Image =
  ## The face composed on the CPU, in one image: the reference live faces
  ## are tested against. A card in play shows its live stats, and `rules`
  ## when they changed (`ruleLines`); `extraCost` is what its holder pays on
  ## top of the printed cost, which the crystal shows added in.
  ensureAssets()
  result = newImage(CardFaceWidth, CardFaceHeight)
  result.drawArt(card)
  result.draw(assetImage(if card.kind == Minion:
    "frames/creature.svg" else: "frames/spell.svg"))
  result.draw(assetImage("icons/energy.svg"),
    translate(vec2(CostBox.x, CostBox.y)))
  let cost = card.energyCost + extraCost
  result.drawText($cost, CostBox.x + CrystalGem.x,
    CostBox.y + CrystalGem.y, CrystalGem.w, CrystalGem.h, 75,
    costBuff(cost, card.energyCost).ink(CostInk), true)
  result.drawText(card.name, NameBox.x, NameBox.y, NameBox.w, NameBox.h, 60,
    "#f7e6be", true, LeftAlign, minimumSize = 30)
  result.drawText(($card.kind).toUpperAscii(),
    109, 532, 382, 32, 31, "#e1c792", true)

  let
    printed = card.ruleText()
    runs =
      if rules.len > 0: card.ruleRuns(rules)
      elif printed.len > 0: @[TextRun(text: printed, ink: RulesInk)]
      else: @[]
  if runs.len > 0:
    result.drawText(runs, RulesBox, textStyle(43, RulesInk, minimumSize = 28,
      wrap = true))
  else:
    # Empty rules have no invented gameplay text.
    let flourish = newPath()
    flourish.moveTo(252, 659)
    flourish.lineTo(284, 659)
    flourish.moveTo(316, 659)
    flourish.lineTo(348, 659)
    result.strokePath(flourish, parseHtmlColor("#a39169"), strokeWidth = 1.5)
    let diamond = newPath()
    diamond.moveTo(300, 650)
    diamond.lineTo(305, 659)
    diamond.lineTo(300, 668)
    diamond.lineTo(295, 659)
    diamond.closePath()
    result.fillPath(diamond, parseHtmlColor("#a39169"))

  if card.kind == Minion:
    result.draw(assetImage("icons/power.svg"), translate(vec2(29, 745)))
    result.draw(assetImage("icons/toughness.svg"), translate(vec2(447, 745)))
    if showStats:
      let
        power = if currentPower >= 0: currentPower else: card.power
        toughness =
          if currentToughness >= 0: currentToughness else: card.toughness
      result.drawStat(power, statBuff(power, card.power), PowerBox)
      result.drawStat(toughness, statBuff(toughness, card.toughness),
        ToughnessBox)
    if card.class.isSome:
      result.drawText(card.class.get.className.toUpperAscii(),
        171, 762, 258, 24, 26, "#c1ab7e", true)
  else:
    result.draw(assetImage("icons/arcane.svg"),
      translate(vec2(285, 791)) * scale(vec2(0.375)))
    if card.class.isSome:
      result.drawText(card.class.get.className.toUpperAscii(),
        171, 762, 258, 24, 26, "#c1ab7e", true)

proc renderCardBack*(): Image =
  ensureAssets()
  result = newImage(CardFaceWidth, CardFaceHeight)
  result.draw(assetImage("frames/back.svg"))
  result.draw(assetImage("icons/arcane.svg", 282, 282),
    translate(vec2(159, 284)))
