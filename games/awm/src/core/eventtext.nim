## Logged events as one readable line each, for the app's terminal:
## "T3 P1 plays Oozification → P2's Bear#1".

import std/[sequtils, strutils]
import sim

proc seat(names: openArray[string], player: int): string =
  ## A seat's public name, or "P1" for the first one.
  if player in 0 ..< names.len and names[player].len > 0: names[player]
  elif player >= 0: "P" & $(player + 1)
  else: "nobody"

proc piece(card: string, id: int): string =
  ## A card with its id in play, "Bear#4", so copies stay apart.
  if id != 0: card & "#" & $id else: card

proc whose(names: openArray[string], player: int, thing: string): string =
  seat(names, player) & "'s " & thing

proc signed(number: int): string =
  (if number >= 0: "+" else: "") & $number

proc describe(names: openArray[string], target: EventTarget): string =
  if target.fromHand:
    return target.card
  case target.choice.kind
  of HeroChoice:
    names.whose(target.choice.owner, "hero")
  of CreatureChoice:
    names.whose(target.choice.owner,
      piece(target.card, target.choice.creatureId))
  of OptionChoice:
    "option " & $(target.choice.option + 1)
  of CanceledChoice, NoTargetChoice:
    "no target"

proc describe*(event: GameEvent, names: openArray[string] = []): string =
  ## One line saying what happened, its turn first.
  let
    who = seat(names, event.player)
    card = piece(event.card, event.cardId)
    held = names.whose(event.player, card)
    picks = event.targets.mapIt(names.describe(it)).join(", ")
    aimed = if picks.len > 0: " → " & picks else: ""
  result = "T" & $event.turn & " " &
    (case event.kind
    of TurnEvent:
      who & "'s turn"
    of DrawEvent:
      who & " draws a card"
    of PlayEvent:
      who & " plays " & card & aimed
    of AttackEvent:
      held & " attacks " & picks
    of TriggerEvent:
      let fired =
        if event.cause.len > 0 or event.causeId != 0:
          ", fired by " & names.whose(event.causeOwner,
            piece(event.cause, event.causeId))
        else: ""
      held & (if event.amount == 1: " resolves its rule" else: " triggers") &
        fired & aimed
    of ChoiceEvent:
      who & " picks " & (if picks.len > 0: picks else: "nothing") &
        " for " & names.whose(event.owner, card)
    of DiscardEvent:
      who & " discards " & picks & " for " & names.whose(event.owner, card)
    of DamageEvent:
      (if event.card.len > 0: held else: names.whose(event.player, "hero")) &
        " takes " & $event.amount & " damage"
    of DeathEvent:
      held & " dies" &
        (if event.owner >= 0 and event.owner != event.player:
          " to " & names.whose(event.owner, "discard pile")
        else: "")
    of SummonEvent:
      who & " summons " & card
    of BounceEvent:
      held & " returns to " & names.whose(event.owner, "hand")
    of GainControlEvent:
      who & " gains control of " & names.whose(event.owner, card)
    of StatsEvent:
      held & " gets " & signed(event.amount) & "/" & signed(event.amount2)
    of GainEvent:
      held & " gains " & event.text
    of LoseEvent:
      held & " loses " & event.text
    of DefeatEvent:
      who & " is out" & (if picks.len > 0: ", discarding " & picks else: ""))
