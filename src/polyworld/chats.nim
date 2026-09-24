import
  bassy,
  mailboxes

type
  ChatHost* = ref object
    runtime {.cursor.}: Runtime
    slot: int
    mailboxes*: Mailboxes
  ChatFunction = enum
    SendChat, PullMailbox, MailboxSender, MailboxChannel, MailboxTick,
    MailboxCount, MailboxSelf, MailboxPlayers, MailboxId

const
  FunctionNames: array[ChatFunction, string] = [
    "sendChat", "pullMailbox$", "mailboxSender", "mailboxChannel$",
    "mailboxTick", "mailboxCount", "mailboxSelf", "mailboxPlayers", "mailboxId"
  ]
  FunctionParameters: array[ChatFunction, int] = [2, 0, 0, 0, 0, 0, 0, 0, 0]

proc newChatHost*(slot: int, mailboxes: Mailboxes = nil): ChatHost =
  ## Binds a player's BASIC host to its own mailbox address.
  ChatHost(slot: slot, mailboxes: mailboxes)

proc bindRuntime*(host: ChatHost, runtime: Runtime) =
  ## Borrows the runtime owning these callbacks without a reference cycle.
  host.runtime = runtime

proc beginTick*(host: ChatHost, tick: int32) =
  ## Advances message timestamps without consuming unread mail.
  host.mailboxes.beginTick(tick)

proc decisionCallback*(host: ChatHost): proc(tick: int32) =
  ## Binds mailbox preparation to the game's decision boundary.
  result = proc(tick: int32) =
    ## Advances the shared router for this decision.
    host.beginTick(tick)

proc callback(host: ChatHost, kind: ChatFunction): NumericHostProc =
  ## Exposes only this player's queue to the BASIC runtime.
  result = proc(arguments: openArray[Value]): Value =
    ## Converts bounded BASIC strings and mailbox addresses.
    template output(value: string): Value =
      ## Stores returned message text in BASIC's bounded string pool.
      host.runtime.putString(value)
    case kind
    of SendChat:
      result = host.mailboxes.send(
        host.slot,
        int(arguments[0].asInt()),
        host.runtime.getString(arguments[1])
      )
    of PullMailbox:
      result = output(host.mailboxes.pull(host.slot).text)
    of MailboxSender:
      let last = host.mailboxes.last(host.slot)
      result = int32(if last.text.len == 0: -1 else: last.sender)
    of MailboxChannel:
      let last = host.mailboxes.last(host.slot)
      result = output(if last.text.len == 0: "" else: last.channel.channelName())
    of MailboxTick:
      result = host.mailboxes.last(host.slot).tick
    of MailboxCount:
      result = host.mailboxes.count(host.slot)
    of MailboxSelf:
      result = int32(host.slot)
    of MailboxPlayers:
      result = int32(host.mailboxes.players())
    of MailboxId:
      result = int32(host.mailboxes.last(host.slot).id())

proc addFunctions*(host: ChatHost, basic: var Host) =
  ## Registers player-to-player communication without external services.
  for kind in ChatFunction:
    discard basic.addFunction(
      FunctionNames[kind],
      FunctionParameters[kind],
      host.callback(kind),
      256
    )
