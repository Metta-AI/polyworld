## Regenerate standalone card previews without opening the game.
## Run from the project root:
## nim c -r --out:/tmp/awm-render-cards tools/render_cards.nim
import std/[os, strutils]
import pixie
import ../[awmcore, baseset, cardfaces]

let
  root = currentSourcePath().parentDir.parentDir
  outputDir = root / "artwork/cards/previews"
initCardAssets(root)
createDir(outputDir)

let sheet = newImage(2040, 1110)
sheet.fill(parseHtmlColor("#111a20"))
let
  title = readFont(root / "artwork/cards/fonts/Grenze-SemiBold.ttf")
  subtitle = readFont(root / "artwork/cards/fonts/Grenze-Regular.ttf")
title.size = 50
title.paint.color = parseHtmlColor("#ebd9b4")
subtitle.size = 26
subtitle.paint.color = parseHtmlColor("#b7b9b1")
sheet.fillText(title, "The first three cards", translate(vec2(60, 26)))
sheet.fillText(subtitle, "Illustration · Frame · Symbols · Living type",
  translate(vec2(61, 89)))

for i, heroClass in [Warrior, Mage, Archer]:
  let
    card = heroClass.classCard()
    face = renderCardFace(card)
  face.writeFile(outputDir / card.name.toLowerAscii() & ".png")
  sheet.draw(face, translate(vec2((60 + i * 660).float32, 163)))

renderCardBack().writeFile(outputDir / "back.png")
renderCardFace(Warrior.classCard(), currentToughness = 1).writeFile(outputDir / "bear-damaged.png")
sheet.writeFile(outputDir / "cards.png")
echo "Card previews: ", outputDir
