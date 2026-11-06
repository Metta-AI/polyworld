## Literal canvas text; no HTML, policy inbox consumption, or UI ownership.
import silky, vmath, chroma
import polyworld/chrome
import chats

proc humanChatVisible*(typing: bool, messageCount: int): bool =
  ## Keep an unused chat entirely off the battlefield.
  typing or messageCount > 0

proc drawHumanChat*(sk: Silky, viewport: Vec2, chat: ChatEditor,
    messages: openArray[HumanChatMessage], allowed: bool) =
  if not humanChatVisible(chat.typing and allowed, messages.len): return
  let
    width = max(100'f32, min(560'f32, viewport.x - 32))
    rows = min(messages.len, 6)
    height = (rows * 25 + (if chat.typing and allowed: 36 else: 0)).float32
    origin = vec2(16, max(64'f32, viewport.y - 290 - height))
  sk.drawRect(origin, vec2(width, height), rgbx(12, 16, 23, 205))
  for row in 0 ..< rows:
    let message = messages[messages.len - rows + row]
    let scope = if message.team: "[Team] " else: "[All] "
    sk.drawLabel(scope & message.sender & ": " & message.text,
      origin + vec2(8, row.float32 * 25), vec2(width - 16, 25),
      rgbx(228, 233, 242, 255))
  if chat.typing and allowed:
    let prompt = (if chat.team: "Team > " else: "All > ") & chat.text & "|"
    sk.drawLabel(prompt, origin + vec2(8, rows.float32 * 25),
      vec2(width - 16, 32), rgbx(255, 222, 140, 255))
