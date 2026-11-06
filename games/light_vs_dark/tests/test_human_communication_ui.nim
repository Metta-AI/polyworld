import std/unicode
import windy
import ../[ui, game, multiplayer, presets]

var config = defaultConfig(2)
config.maxTicks = 100
config.mapSettings = MapSettings(layout: RandomLayout, size: 90, expansions: 0)
run = newLocalMatch(config, ["", ""])
options.playerSlot = 1
resetHumanCommunication()
doAssert not humanCommunicationBlocksGameplay()
doAssert humanCommunicationKey(KeyEnter)
humanCommunicationRelease(KeyEnter)
doAssert humanCommunicationRune(Rune(0x96ea))
doAssert humanCommunicationKey(KeyS), "Stop cannot fire while typing"
doAssert humanCommunicationKey(KeyB), "Build cannot fire while typing"
doAssert humanCommunicationKey(KeyTab), "Stats cannot open while typing"
doAssert humanCommunicationKey(KeyEscape), "Escape cancels chat, not pause"
humanCommunicationRelease(KeyEscape)
finishHumanCommunicationFrame()
doAssert humanCommunicationBlocksGameplay(), "Held typed keys must stay quarantined"
humanCommunicationRelease(KeyS)
humanCommunicationRelease(KeyB)
humanCommunicationRelease(KeyTab)
doAssert not humanCommunicationBlocksGameplay()
doAssert not humanCommunicationKey(KeyS)
resetHumanCommunication()
doAssert not humanCommunicationRune(Rune(65))
doAssert humanCommunicationKey(KeyEnter)
humanCommunicationRelease(KeyEnter)
discard humanCommunicationRune(Rune(0x1f642))
doAssert humanCommunicationKey(KeyBackspace)
humanCommunicationRelease(KeyBackspace)
doAssert humanCommunicationKey(KeyEnter)
humanCommunicationRelease(KeyEnter)
finishHumanCommunicationFrame()
doAssert not humanCommunicationBlocksGameplay()
resetHumanCommunication()
options.playerSlot = 0
doAssert not humanCommunicationKey(KeyEnter), "Spectators cannot submit human chat"
echo "PASS native UI chat key/rune/edit, hotkey quarantine and lifecycle hooks"
