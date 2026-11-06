## Guard actual event and polling routes, not only the editor model.
import std/[os, strutils]
let graphics = readFile(currentSourcePath().parentDir / "../graphics.nim")
doAssert "installChatInput" in graphics, "Match must install chained rune/key input"
doAssert "restoreChatInput" in graphics, "Match exit must restore text callbacks"
doAssert "if chat.blocksGameplay:" in graphics, "Poll routes must suppress gameplay"
doAssert "bindingCapture = bindingCapture or chat.blocksGameplay" in graphics,
  "HUD aliases and held action keys must also be masked"
doAssert "drawHumanChat" in graphics, "Match must render literal independent history"
echo "Human chat graphics input ownership routes passed"
