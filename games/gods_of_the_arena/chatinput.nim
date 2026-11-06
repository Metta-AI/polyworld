## Small callback owner: preserve Silky's rune handler outside human chat.
import std/unicode
import chats
when defined(silkyTesting):
  import silky/testwindow
else:
  import windy

type ChatInputHooks* = object
  rune: proc(rune: Rune)

proc syncChatInput*(window: Window, chat: ChatEditor) =
  ## Silky ends unfocused input each frame; chat independently requests runes.
  if chat.typing: window.runeInputEnabled = true

proc installChatInput*(window: Window, chat: ptr ChatEditor): ChatInputHooks =
  result.rune = window.onRune
  let previous = result.rune
  window.onRune = proc(rune: Rune) =
    if chat[].typing:
      discard chat[].addChatRune(rune)
    elif previous != nil:
      previous(rune)

proc restoreChatInput*(window: Window, hooks: ChatInputHooks) =
  window.onRune = hooks.rune
  window.runeInputEnabled = false

proc handleChatButton*(chat: var ChatEditor, button: Button, allowed: bool): bool =
  let key = case button
    of KeyEnter: ChatEnter
    of KeyEscape: ChatEscape
    of KeyBackspace: ChatBackspace
    else: ChatOther
  chat.handleChatKey(key, allowed)
