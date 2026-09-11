## Composes card faces from independently editable illustration, frame, icon,
## and font assets. The rendered image is only a presentation cache: game data
## and the source artwork stay separate.

import std/[os, options, strutils, tables]
import pixie
import pixie/fileformats/svg
import awmcore

const
  CardFaceWidth* = 600
  CardFaceHeight* = 850
  ArtX = 27
  ArtY = 113
  ArtWidth = 546
  ArtHeight = 417

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

proc initCardAssets*(root: string) =
  ## Accept either the project root or the artwork/cards directory.
  let resolved = if dirExists(root / "frames"): root else: root / "artwork/cards"
  if resolved == assetsRoot and not titleTypeface.isNil:
    return
  assetsRoot = resolved
  assetImages.clear()
  titleTypeface = readFont(assetsRoot / "fonts/Grenze-SemiBold.ttf").typeface
  rulesTypeface = readFont(assetsRoot / "fonts/Grenze-Regular.ttf").typeface

proc ensureAssets() =
  if assetsRoot.len == 0:
    initCardAssets(currentSourcePath().parentDir)

proc cardFont(size: float32, ink: string, semibold = false): Font =
  result = newFont(if semibold: titleTypeface else: rulesTypeface)
  result.size = size
  result.lineHeight = size * 1.08
  result.paint.color = parseHtmlColor(ink)

proc drawText(
    image: Image, value: string, x, y, width, height, size: float32,
    ink: string, semibold = false, alignment = CenterAlign,
    minimumSize = 28'f32, wrap = false
) =
  ## Fit long names and multi-line rule text to a fixed safe area. Actual ink
  ## bounds provide optical vertical centering independent of font ascenders.
  if value.len == 0:
    return
  var font = cardFont(size, ink, semibold)
  var arrangement: Arrangement
  while true:
    arrangement = font.typeset(value, vec2(width, 0), alignment, wrap = wrap)
    let bounds = arrangement.computeBounds()
    if (bounds.w <= width and bounds.h <= height) or font.size <= minimumSize:
      break
    font.size -= 1
    font.lineHeight = font.size * 1.08
  let bounds = arrangement.computeBounds()
  image.fillText(arrangement, translate(vec2(x, y + (height - bounds.h) / 2 - bounds.y)))

proc drawArt(image: Image, card: Card) =
  let
    relativePath = "art/" & card.name.toLowerAscii().replace(" ", "-") & ".png"
    source = if fileExists(assetsRoot / relativePath):
      assetImage(relativePath)
    else:
      assetImage("art/unknown.svg")
    scaleFactor = max(ArtWidth.float32 / source.width.float32,
      ArtHeight.float32 / source.height.float32)
    crop = newImage(ArtWidth, ArtHeight)
    x = (ArtWidth.float32 - source.width.float32 * scaleFactor) / 2
    y = (ArtHeight.float32 - source.height.float32 * scaleFactor) / 2
  crop.draw(source, translate(vec2(x, y)) * scale(vec2(scaleFactor)))
  image.draw(crop, translate(vec2(ArtX, ArtY)))

proc renderCardFace*(card: Card, currentToughness = -1): Image =
  ensureAssets()
  result = newImage(CardFaceWidth, CardFaceHeight)
  result.drawArt(card)
  result.draw(assetImage(if card.kind == Minion:
    "frames/creature.svg" else: "frames/spell.svg"))
  result.draw(assetImage("icons/energy.svg"), translate(vec2(26, 15)))
  result.drawText($card.energyCost, 40, 33, 92, 73, 75, "#fff4d5", true)
  result.drawText(card.name, 154, 40, 390, 58, 60, "#f7e6be", true,
    minimumSize = 35)
  result.drawText(if card.kind == Minion: "CREATURE" else: "SPELL",
    109, 532, 382, 32, 31, "#e1c792", true)

  let rules = card.ruleText().replace("minion", "creature").replace("Minion", "Creature")
  if rules.len > 0:
    result.drawText(rules, 65, 605, 470, 113, 43, "#26251e",
      minimumSize = 28, wrap = true)
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
    result.drawText($card.power, 85, 757, 54, 61, 68, "#fff0c9", true)
    let toughness = if currentToughness >= 0: currentToughness else: card.toughness
    let ink = if toughness < card.toughness: "#ff9d87" else: "#fff0c9"
    result.drawText($toughness, 503, 757, 54, 61, 68, ink, true)
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
