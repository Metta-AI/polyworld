## Human text is separate from consumable policy inboxes.
import std/[unicode, strutils]
import ../chats

block editing:
  var chat: ChatEditor
  doAssert chat.handleChatKey(ChatEnter, true)
  doAssert chat.typing and chat.blocksGameplay
  for rune in "mason :) 你好 <b>A</b>".runes:
    doAssert chat.addChatRune(rune)
  doAssert chat.text == "mason :) 你好 <b>A</b>"
  doAssert chat.handleChatKey(ChatEnter, true)
  doAssert not chat.typing and chat.blocksGameplay
  doAssert chat.takeChatText() == "mason :) 你好 <b>A</b>"
  chat.finishChatFrame()
  doAssert not chat.blocksGameplay
  discard chat.handleChatKey(ChatEnter, true)
  discard chat.addChatRune(Rune(0x1f642))
  discard chat.handleChatKey(ChatBackspace, true)
  doAssert chat.text == ""
  discard chat.handleChatKey(ChatEscape, true)
  doAssert not chat.typing and chat.takeChatText() == ""
  doAssert not chat.handleChatKey(ChatEnter, false)
block bounds:
  doAssert validHumanChat("你好 🙂 <script>")
  for invalid in ["", "  \t", "hello\nworld", "\x00", "\x7f", "\xC2\x80", "\xFF", repeat("🙂", 257)]:
    doAssert not validHumanChat(invalid), invalid
  doAssert validHumanChat(repeat("🙂", 256))
  var chat: ChatEditor
  discard chat.handleChatKey(ChatEnter, true)
  for i in 0 ..< 256: doAssert chat.addChatRune(Rune(0x1f642))
  doAssert not chat.addChatRune(Rune(0x1f642))
  doAssert not chat.addChatRune(Rune(10))
  discard chat.handleChatKey(ChatEscape, true)
  discard chat.handleChatKey(ChatEnter, true)
  for rune in "   ".runes: discard chat.addChatRune(rune)
  discard chat.handleChatKey(ChatEnter, true)
  doAssert chat.takeChatText() == ""
echo "Human chat editing and Unicode bounds passed"

block independentHistory:
  var history: seq[HumanChatMessage]
  for tick in 1 .. MaxHumanChatMessages + 5:
    history.appendHumanChat(HumanChatMessage(tick: uint32(tick), ordinal: 0,
      sender: "mason :)", text: "literal <b>你好</b>"))
  doAssert history.len == MaxHumanChatMessages
  let last = history[^1]
  history.appendHumanChat(last)
  doAssert history.len == MaxHumanChatMessages and history[^1] == last
  doAssert history[0].tick == 6
echo "Human chat bounded independent history and packet replay deduplication passed"
