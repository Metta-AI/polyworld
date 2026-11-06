## Game-owned human chat state. Text is drawn literally, never as markup.
import std/unicode
import polyworld/mailboxes

const MaxHumanChatMessages* = 100

type
  ChatKey* = enum
    ChatOther, ChatEnter, ChatEscape, ChatBackspace
  ChatEditor* = object
    typing*: bool
    text*: string
    team*: bool
    captured: bool
    submitted: string
  HumanChatMessage* = object
    tick*: uint32
    ordinal*: int
    sender*: string
    text*: string
    team*: bool
    senderTeam*: int

proc printable(rune: Rune): bool =
  ## Exclude controls, surrogates, noncharacters and invisible bidi overrides.
  let value = rune.int
  value >= 32 and value <= 0x10ffff and value notin 0x7f .. 0x9f and
    value notin 0xd800 .. 0xdfff and value notin 0xfdd0 .. 0xfdef and
    (value and 0xffff) notin [0xfffe, 0xffff] and
    value notin 0x202a .. 0x202e and value notin 0x2066 .. 0x2069

proc validHumanChat*(text: string): bool =
  ## Bound UTF-8 bytes without cutting a codepoint; require visible content.
  if text.len == 0 or text.len > MaxChatBytes or text.validateUtf8() != -1:
    return false
  var visible = false
  for rune in text.runes:
    if not rune.printable: return false
    if not rune.isWhiteSpace: visible = true
  visible

proc blocksGameplay*(chat: ChatEditor): bool = chat.typing or chat.captured

proc handleChatKey*(chat: var ChatEditor, key: ChatKey, allowed: bool): bool =
  ## Own the whole typing interaction, including the closing event's frame.
  if not chat.typing:
    if key != ChatEnter or not allowed: return false
    chat.typing = true
    chat.text = ""
    chat.team = false
  else:
    case key
    of ChatEnter:
      if chat.text.validHumanChat: chat.submitted = chat.text
      chat.text = ""
      chat.typing = false
    of ChatEscape:
      chat.text = ""
      chat.typing = false
    of ChatBackspace:
      if chat.text.len > 0:
        var index = chat.text.len - 1
        while index > 0 and (ord(chat.text[index]) and 0xc0) == 0x80: dec index
        chat.text.setLen(index)
    of ChatOther: discard
  chat.captured = true
  true

proc addChatRune*(chat: var ChatEditor, rune: Rune): bool =
  if not chat.typing or not rune.printable: return false
  let bytes = rune.toUTF8()
  if chat.text.len + bytes.len > MaxChatBytes: return false
  chat.text.add bytes
  true

proc takeChatText*(chat: var ChatEditor): string =
  swap(result, chat.submitted)

proc finishChatFrame*(chat: var ChatEditor) = chat.captured = false

proc appendHumanChat*(history: var seq[HumanChatMessage], message: HumanChatMessage) =
  ## Packet replay/rewind must not duplicate the independent display history.
  for existing in history:
    if existing.tick == message.tick and existing.ordinal == message.ordinal: return
  if history.len == MaxHumanChatMessages: history.delete(0)
  history.add message
