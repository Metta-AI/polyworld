## Windy-compatible callback exercise; Silky owns text outside the chat focus.
import std/unicode
import vmath
import silky/testwindow
import silky/internal/inputs
import ../[chats, chatinput]
let window = newWindow("chat", ivec2(640, 480))
var forwarded = ""
window.onRune = proc(rune: Rune) = forwarded.add rune.toUTF8()
var chat: ChatEditor
let hooks = window.installChatInput(addr chat)
window.onRune(Rune('z'))
doAssert forwarded == "z"
doAssert chat.handleChatButton(KeyEnter, true)
window.onRune(Rune('A'))
window.onRune(Rune(0x1f642))
doAssert chat.text == "A🙂" and forwarded == "z"
doAssert chat.handleChatButton(KeyA, true), "Attack binding must be consumed"
doAssert chat.handleChatButton(MouseRight, true), "Orders must be consumed"
doAssert chat.handleChatButton(KeyEscape, true)
doAssert chat.takeChatText() == ""
window.onRune(Rune('q'))
doAssert forwarded == "zq"
window.restoreChatInput(hooks)
window.onRune(Rune('x'))
doAssert forwarded == "zqx"
echo "Human chat rune ownership and callback restoration passed"

block silkyOwnership:
  let window = newWindow()
  let inputs = newTextInputs(window)
  var chat: ChatEditor
  let hooks = window.installChatInput(addr chat)
  inputs.beginInputFrame(window)
  inputs.submitInput(window, "settings", true, true)
  window.onRune(Rune('s'))
  doAssert chat.text == ""
  doAssert inputs.takeInput()[0].rune == Rune('s')
  inputs.endInputFrame(window)
  inputs.beginInputFrame(window)
  inputs.endInputFrame(window)
  discard chat.handleChatButton(KeyEnter, true)
  window.syncChatInput(chat)
  doAssert window.runeInputEnabled, "Native/WASM must enable rune events while typing"
  window.onRune(Rune('A'))
  doAssert chat.text == "A", "Silky must forward runes to chat when no field owns focus"
  window.restoreChatInput(hooks)
echo "Human chat coexists with Silky field focus passed"
