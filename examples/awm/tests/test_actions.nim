import
  std/[options, sequtils, strutils],
  ../src/core/[bots, eventtext, match, replays, ruletree, sim]

proc ready(owner, id: int, card: Card): MinionState =
  ## Creates an existing minion ready to attack in a regression fixture.
  MinionState(owner: owner, id: id, card: card,
    currentToughness: (if card.kind == Minion: card.toughness else: 0),
    canAttack: true)

proc basicText(text: string): string =
  ## A BASIC string expression for `text`, its quotes and line breaks too.
  "\"" & text.replace("\"", "\"\"").replace("\n", "\" + chr$(10) + \"") &
    "\""

proc scripted(source: string, seats = 2): BotMatch =
  ## Starts a match with the same script in every seat.
  initBotMatch(newSeqWith(seats, Mage), 7,
    loadBots(newSeqWith(seats, source)), 28_800)

echo "Ending a turn never selects attacks"
block:
  var played = scripted("endTurn()")
  let player = played.game.currentPlayer
  let enemy = played.game.nextPlayer(player)
  played.game.players[player].board = @[ready(player, 1,
    baseCardNamed("Primordial"))]
  played.game.nextMinionId = 2
  var human = played.game.copyGameState()
  human.finishTurn()
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.players[enemy].life == StartingLife

echo "An empty decision does not end the turn or choose a fallback"
block:
  var played = scripted("END")
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.outcome == MatchFailed
  doAssert played.tick == 0
  doAssert played.game.stateHash == before
  doAssert played.bots[played.game.currentPlayer].lastError.contains("no action")

echo "The designer's attack, bounce, replay order matches human actions"
block:
  var played = scripted("""
if phase = 0 then
  primordial = boardId(selfPlayer, 0)
  j = 0
  while j < attackChoiceCount(primordial)
    if attackChoiceKind(primordial, j) = 2 then
      if attackChoiceOwner(primordial, j) = enemyPlayer then
        if attack(primordial, j) then
          phase = 1
          end
        end if
      end if
    end if
    j = j + 1
  wend
end if
if phase = 1 then
  i = 0
  while i < handSize
    if handName$(i) = "Bouncer" then
      j = 0
      while j < choiceCount(i)
        if choiceId(i, j) = primordial then
          if playCardChoice(i, j) then
            phase = 2
            end
          end if
        end if
        j = j + 1
      wend
    end if
    i = i + 1
  wend
end if
if phase = 2 then
  i = 0
  while i < handSize
    if handName$(i) = "Primordial" then
      if playCard(i) then
        phase = 3
        end
      end if
    end if
    i = i + 1
  wend
end if
endTurn()
""")
  let player = played.game.currentPlayer
  let enemy = played.game.nextPlayer(player)
  played.game.turnNumber = 17
  played.game.players[player].energy = 11
  played.game.players[player].totalEnergy = 11
  played.game.players[player].hand = @[baseCardNamed("Bouncer")]
  played.game.players[player].board = @[ready(player, 1,
    baseCardNamed("Primordial"))]
  played.game.players[enemy].board = @[ready(enemy, 2,
    baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  var human = played.game.copyGameState()
  doAssert human.attack(1, heroChoice(enemy))
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.bots[player].action.kind == ActionAttack
  doAssert human.playCard(0, creatureChoice(player, 1))
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert human.playCard(0)
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.currentPlayer == player
  doAssert played.game.players[player].energy == 0
  doAssert played.game.players[enemy].life == StartingLife - 10
  # Primordial is a vanilla 10/10 now: the Bear and the Bouncer both stay.
  doAssert played.game.players[enemy].board.len == 1
  doAssert played.game.players[player].board.len == 2
  for minion in played.game.players[player].board:
    doAssert not minion.canAttack
  human.finishTurn()
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash

echo "Scripts can attack another opponent's hero or a chosen minion"
for target in [heroChoice(2), creatureChoice(2, 2)]:
  var played = scripted("""
id = boardId(selfPlayer, 0)
j = 0
while j < attackChoiceCount(id)
  if attackChoiceOwner(id, j) = 2 then
    if attackChoiceKind(id, j) = desired then
      attack(id, j)
      end
    end if
  end if
  j = j + 1
wend
""", 3)
  played.game.currentPlayer = 0
  played.game.players[0].board = @[ready(0, 1, baseCardNamed("Bear"))]
  played.game.players[2].board = @[ready(2, 2, baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  played.bots[0].runtime.setGlobal("desired", target.kind.ord.int32)
  var human = played.game.copyGameState()
  doAssert human.attack(1, target)
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.currentPlayer == 0

echo "Discard choices belong to their owner, including off-turn choices"
block:
  var played = scripted("""
dim picks(1)
picks(0) = 1
picks(1) = 2
observed = selfPlayer
discardCards("picks")
""")
  let owner = played.game.nextPlayer(played.game.currentPlayer)
  played.game.players[owner].hand = @[baseCardNamed("Primordial"),
    baseCardNamed("Bouncer"), baseCardNamed("Study")]
  played.game.pendingToss = PendingToss(player: owner, count: 2)
  var human = played.game.copyGameState()
  doAssert human.resolvePendingToss(@[1, 2])
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.bots[owner].action.playerId == owner.int32
  doAssert played.bots[owner].runtime.getGlobal("observed") == owner.int32
  doAssert played.game.players[owner].hand == @[baseCardNamed("Primordial")]

echo "Scripts choose trigger targets, including off-turn triggers"
block:
  var played = scripted("""
dim picks(0)
j = 0
while j < nextChoiceCount(-1, "picks", 0)
  if nextChoiceId(-1, "picks", 0, j) = 2 then
    picks(0) = j
    resolveTrigger("picks")
    end
  end if
  j = j + 1
wend
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  let snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
    rules: rules(on(nextTurn(You), damage(1, target({kind: {Minion}})))))
  played.game.players[owner].board = @[ready(owner, 1, snare)]
  played.game.players[player].board = @[ready(player, 2, baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  played.game.pendingTriggers = @[PendingTrigger(owner: owner,
    sourceId: 1, trigger: 0)]
  var human = played.game.copyGameState()
  doAssert human.resolvePendingTrigger(@[creatureChoice(player, 2)])
  doAssert played.step()
  discard human.takeVisualEvents()
  doAssert played.game.currentPlayer == human.currentPlayer
  doAssert played.game.turnNumber == human.turnNumber
  doAssert not played.game.waitingTrigger
  doAssert played.game.players[player].board[0].currentToughness ==
    human.players[player].board[0].currentToughness
  doAssert played.bots[owner].action.playerId == owner.int32

echo "Scripts see whose trigger or discard asks, from which card, and why"
block:
  # An attack fired it: the card, its words, whose it is and the attacker.
  let snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
    rules: rules(on(attacked(You), damage(1, target({kind: {Minion}})))))
  var played = scripted("""
dim picks(0)
if triggerCard$() <> "Snare" or cardName$(triggerCard$()) <> "Snare" then stop
if triggerRules$() <> """ & basicText(snare.triggers()[0].text(snare)) & """ then stop
if triggerOwner() <> selfPlayer or triggerOnPlay() <> 0 then stop
if triggerSourceId() <> boardId(selfPlayer, 0) then stop
if triggerAttackerOwner() <> currentPlayer then stop
if triggerAttackerId() <> boardId(currentPlayer, 0) then stop
if triggerPlayed$() <> "" or triggerPlayedId() <> 0 then stop
if tossCard$() <> "" or tossRules$() <> "" then stop
if tossOwner() >= 0 or tossSourceId() <> 0 then stop
resolveTrigger("picks")
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  played.game.players[owner].board = @[ready(owner, 1, snare)]
  played.game.players[player].board = @[ready(player, 2, baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  played.game.pendingTriggers = @[PendingTrigger(owner: owner,
    sourceId: 1, trigger: 0, attacker: creatureChoice(player, 2))]
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionResolveTrigger

block:
  # A play fired it: the played card, as it entered play.
  let watch = Card(name: "Watch", kind: Trinket, class: some(Mage),
    rules: rules(on(played(AnyOpponent, {kind: {Minion}}),
      damage(1, target({kind: {Minion}})))))
  var played = scripted("""
dim picks(0)
if triggerCard$() <> "Watch" or triggerOwner() <> selfPlayer then stop
if triggerPlayed$() <> "Bear" or cardName$(triggerPlayed$()) <> "Bear" then stop
if triggerPlayedId() <> boardId(currentPlayer, 0) then stop
if triggerAttackerOwner() >= 0 or triggerAttackerId() <> 0 then stop
resolveTrigger("picks")
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  played.game.players[owner].board = @[ready(owner, 1, watch)]
  played.game.nextMinionId = 2
  played.game.players[player].hand = @[baseCardNamed("Bear")]
  played.game.players[player].energy = 10
  doAssert played.game.playCard(0, @[])
  doAssert played.game.waitingTrigger
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionResolveTrigger

block:
  # A summoned card's on-play rules are its rules, not a trigger.
  let bouncer = baseCardNamed("Bouncer")
  var played = scripted("""
dim picks(0)
if triggerCard$() <> "Bouncer" or triggerOnPlay() <> 1 then stop
if triggerRules$() <> """ & basicText(bouncer.ruleText()) & """ then stop
if triggerSourceId() <> boardId(selfPlayer, 0) then stop
resolveTrigger("picks")
""")
  let owner = played.game.currentPlayer
  played.game.players[owner].board = @[ready(owner, 1, bouncer)]
  played.game.nextMinionId = 2
  played.game.pendingTriggers = @[PendingTrigger(owner: owner,
    sourceId: 1, attacker: Canceled, onPlay: true)]
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionResolveTrigger

block:
  # Another player's minion asks you to discard.
  let pickpocket = Card(name: "Pickpocket", energyCost: 1, kind: Minion,
    class: some(Mage), rules: rules(toss(1, AllOpponents)),
    power: 1, toughness: 1)
  var played = scripted("""
dim picks(0)
if tossCard$() <> "Pickpocket" or cardName$(tossCard$()) <> "Pickpocket" then stop
if tossRules$() <> """ & basicText(pickpocket.ruleText()) & """ then stop
if tossOwner() <> currentPlayer or tossOwner() = selfPlayer then stop
if tossSourceId() <> boardId(currentPlayer, 0) then stop
if triggerCard$() <> "" or triggerOwner() >= 0 then stop
discardCards("picks")
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  played.game.players[player].hand = @[pickpocket]
  played.game.players[player].energy = 10
  played.game.players[owner].hand = @[baseCardNamed("Bear")]
  doAssert played.game.playCard(0, @[])
  doAssert played.game.pendingToss.sourcePlayer == player
  doAssert played.game.pendingToss.sourceId ==
    played.game.players[player].board[0].id
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionToss

block:
  # Each offered option reads as its own card.
  let overcharge = baseCardNamed("Overcharge")
  var played = scripted("""
if optionRules$(0, "picks", 0, 0) <> """ &
    basicText(overcharge.optionCard(overcharge.options()[0]).ruleText()) & """ then stop
if optionRules$(0, "picks", 0, 1) <> """ &
    basicText(overcharge.optionCard(overcharge.options()[1]).ruleText()) & """ then stop
if optionRules$(0, "picks", 0, 2) <> "" then stop
endTurn()
""")
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[overcharge]
  doAssert played.step()
  doAssert played.bots[player].action.kind == ActionEndTurn

echo "A newly played Bouncer can target itself just as in the human UI"
block:
  var played = scripted("""
j = 0
while j < choiceCount(0)
  if choiceKind(0, j) = 3 and choiceOwner(0, j) = selfPlayer then
    playCardChoice(0, j)
    end
  end if
  j = j + 1
wend
""")
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Bouncer")]
  played.game.players[player].energy = 1
  var human = played.game.copyGameState()
  let id = human.playMinion(0)
  doAssert human.runMinionRules(baseCardNamed("Bouncer"),
    creatureChoice(player, id), id)
  doAssert played.step()
  doAssert played.game.stateHash == human.stateHash
  doAssert played.game.players[player].board.len == 0

echo "Only one selected action is committed and errors are atomic"
block:
  var played = scripted("first = playCard(0)\nsecond = endTurn()")
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Primordial")]
  played.game.players[player].energy = 10
  doAssert played.step()
  doAssert played.bots[player].runtime.getGlobal("first") == 1
  doAssert played.bots[player].runtime.getGlobal("second") == 0
  doAssert played.game.currentPlayer == player
block:
  var played = scripted("playCard(0)\nx = 1 \\ 0")
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Primordial")]
  played.game.players[player].energy = 10
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.game.stateHash == before
  doAssert played.tick == 0

echo "Invalid attacks and missing discard choices never produce fallbacks"
block:
  var played = scripted("attack(-1, 0)")
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.game.stateHash == before
block:
  var played = scripted("endTurn()")
  played.game.pendingToss = PendingToss(player: played.game.currentPlayer,
    count: 1)
  let before = played.game.stateHash
  doAssert not played.step()
  doAssert played.game.stateHash == before
  doAssert played.game.waitingToss

echo "Host queries reject excessive target steps without allocations"
block:
  var played = scripted("""
a = targetChoiceCount(0, 2147483647)
b = triggerChoiceCount(2147483647)
endTurn()
""")
  let player = played.game.currentPlayer
  doAssert played.step()
  doAssert played.bots[player].runtime.getGlobal("a") == 0
  doAssert played.bots[player].runtime.getGlobal("b") == 0

echo "Explicit action parity passed"

echo "Scripts choose classes and decks before dealing and can query every seat"
block:
  let sources = newSeqWith(4, """
if selectingClass then
  if selfClass <> -1 or enemyClass <> -1 then stop
  if handSize <> 0 or boardCount(selfPlayer) <> 0 then stop
  if pickClass(selfPlayer MOD 3) <> 1 then stop
  if pickClass(2) <> 0 or endTurn() <> 0 then stop
  if deckCard("Warrior", 40) <> 1 then stop
  end
end if
if selfClass <> playerClass(selfPlayer) then stop
if enemyClass <> playerClass(enemyPlayer) then stop
if playerClass(3) <> 0 then stop
endTurn()
""")
  let bots = loadBots(sources)
  let seats = bots.setupBotSeats()
  doAssert seats.mapIt(it.heroClass) == @[Archer, Warrior, Mage, Archer]
  doAssert seats.allIt(it.deck == @[("Warrior", 40)])
  let recorder = initReplayRecorder(matchSetup(seats, 19, 4),
    GameConfig(seed: 19, maxTicks: 4, players: unnamedPlayers(4)))
  var played = initBotMatch(seats, 19, bots, 4, recorder)
  played.run()
  doAssert played.outcome == MatchTimedOut
  var replayed = newGame(recorder.data.header.setup)
  for action in recorder.data.actions:
    doAssert replayed.applyAction(action)
    discard replayed.takeVisualEvents()
    doAssert replayed.stateHash == recorder.data.hashes[action.tick.int - 1]
  doAssert replayed.stateHash == played.game.stateHash
  let missing = loadBot("endTurn()", 0)
  var rejected = false
  try:
    discard missing.setupSeat(2)
  except BasicError:
    rejected = true
  doAssert rejected

echo "An illegal deck is out before the first turn"
block:
  const
    Legal = "if selectingClass then\npickClass(1)\n" &
      "deckCard(\"Bear\", 4)\ndeckCard(\"Warrior\", 36)\nend\nend if\nendTurn()"
    Short = "if selectingClass then\npickClass(0)\n" &
      "deckCard(\"Bolt\", 4)\ndeckCard(\"Bolt\", 1)\n" &
      "deckCard(\"Nothing\", 2)\nend\nend if\nendTurn()"
    Unlisted = "if selectingClass then\npickClass(2)\nend\nend if\nendTurn()"
  let bots = loadBots([Legal, Short, Unlisted])
  let seats = bots.setupBotSeats(5)
  doAssert seats[0].deck == @[("Bear", 4), ("Warrior", 36)]
  doAssert bots[0].deckProblems.len == 0
  # Seated with their class and no deck.
  doAssert seats[1].heroClass == Archer and seats[1].deck.len == 0
  doAssert bots[1].deckProblems == @["5 copies of Bolt; at most 4",
    "No card named 'Nothing'", "7 cards; a deck holds exactly 40"]
  doAssert seats[2].deck.len == 0
  doAssert bots[2].deckProblems == @["0 cards; a deck holds exactly 40"]
  var played = initBotMatch(seats, 5, bots, 100)
  doAssert played.game.gameOver
  doAssert played.game.winner == 0
  doAssert played.game.dead(1) and played.game.dead(2)
  doAssert played.game.players[1].hand.len == 0
  doAssert played.outcome == MatchWon
  doAssert not played.step()

echo "Printed identity and live stats cover hand and every player's board"
block:
  var sniper = ready(3, 1, baseCardNamed("Sniper"))
  sniper.bonusPower = 3
  sniper.lostRules = @[baseCardNamed("Sniper").rules[0]]
  sniper.gainedRules = @[baseCardNamed("Spirit").rules[0]]
  sniper.hasAttacked = true
  sniper.stolenFrom = some(1)
  let liveText = sniper.card.optionCard(sniper.liveRules).ruleText()
  doAssert liveText.len > 0 and liveText != sniper.card.ruleText()
  var played = scripted("""
if handId$(0) <> "Bouncer" then stop
if cardName$(handId$(0)) <> handName$(0) then stop
if cardClass(handId$(0)) <> 2 then stop
if cardCost(handId$(0)) <> 1 then stop
if cardRules$(handId$(0)) = "" then stop
if boardCard$(3, 0) <> "Sniper" then stop
if cardPower(boardCard$(3, 0)) <> 2 then stop
if boardPower(3, 0) <> 5 then stop
if cardToughness(boardCard$(3, 0)) <> 1 then stop
if boardHp(3, 0) <> 1 then stop
if cardHasKeyword(boardCard$(3, 0), 0) <> 1 then stop
if boardHasKeyword(3, 0, 0) <> 0 then stop
if boardReady(3, 0) <> 0 or boardAttacked(3, 0) <> 1 then stop
if boardKind(3, 1) <> 2 then stop
if cardRules$(boardCard$(3, 0)) <> """ & basicText(sniper.card.ruleText()) & """ then stop
if boardRules$(3, 0) <> """ & basicText(liveText) & """ then stop
if boardStolenFrom(3, 0) <> 1 or boardStolenFrom(3, 1) >= 0 then stop
if selfPlayer <> 3 and playerHandSize(3) <> 5 then stop
if playerLife(3) <> 20 then stop
endTurn()
""", 4)
  let player = played.game.currentPlayer
  played.game.players[player].hand = @[baseCardNamed("Bouncer")]
  played.game.players[3].board = @[
    sniper, ready(3, 2, baseCardNamed("Bubble"))]
  played.game.nextMinionId = 3
  doAssert played.step()
  doAssert played.bots[player].action.kind == ActionEndTurn

echo "Scripts read any card's rules as a tree of DSL nodes"
block:
  # Printed rules: Lasts, a played trigger and its filters, what it does.
  let postLasts = baseCardNamed("Post").lastsTurns()
  var played = scripted("""
n = rulesOfCard("Post")
if n = 0 or n <> nodeCount() then stop
l = nodeFind("lasts", -1)
if l < 0 or nodeParent(l) <> -1 or nodeRole$(l) <> "rules" then stop
if nodeValue(nodeChild(l, "turns")) <> """ & $postLasts & """ then stop
o = nodeFind("on", -1)
t = nodeChild(o, "trigger")
if nodeKind$(t) <> "played" or nodeText$(nodeChild(t, "player")) <> "You" then stop
if nodeText$(nodeChild(t, "kind")) <> "Minion" then stop
if nodeText$(nodeChild(t, "class")) <> "Archer" then stop
c = nodeChild(t, "energyCost")
if nodeKind$(c) <> "atMost" or nodeValue(nodeChild(c, "low")) <> 3 then stop
g = nodeChild(o, "rules")
if nodeKind$(g) <> "gain" or nodeKind$(nodeChild(g, "rule")) <> "ready" then stop
if nodeKind$(nodeChild(g, "what")) <> "getPlayed" then stop
s = nodeFind("summon", -1)
if nodeParent(s) <> o or nodeKind$(nodeChild(s, "card")) <> "getPlayed" then stop
if nodeText$(s) <> """ & basicText(baseCardNamed("Post").triggers()[0].rules[1].text(
    baseCardNamed("Post"))) & """ then stop
' Values that read the game, and a target's owner.
if rulesOfCard("Explode") = 0 then stop
a = nodeChild(nodeFind("damage", -1), "amount")
if nodeKind$(a) <> "power" or nodeKind$(nodeChild(a, "target")) <> "getTarget" then stop
w = nodeChild(nodeFind("destroy", -1), "what")
if nodeKind$(w) <> "target" or nodeText$(nodeChild(w, "owner")) <> "Friendly" then stop
' A choice's branches, in order.
if rulesOfCard("Overcharge") = 0 then stop
b = nodeChild(nodeFind("choose", -1), "options")
if nodeKind$(b) <> "rules" or nodeValue(b) <> 0 then stop
b = nodeFind("rules", b)
if nodeValue(b) <> 1 or nodeParent(b) <> nodeFind("choose", -1) then stop
' Nothing selected, nothing out of range.
if rulesOfCard("No Such Card") <> 0 or nodeCount() <> 0 then stop
if nodeKind$(0) <> "" or nodeParent(0) <> -1 or nodeChild(0, "rules") <> -1 then stop
endTurn()
""")
  let player = played.game.currentPlayer
  doAssert played.step()
  doAssert played.bots[player].action.kind == ActionEndTurn

block:
  # Live rules in play, and how long Hidden and Lasts still run.
  var played = scripted("""
if rulesOfBoard(selfPlayer, 0) = 0 then stop
if nodeFind("ranged", -1) >= 0 or nodeFind("hidden", -1) < 0 then stop
if nodeValue(nodeChild(nodeFind("hidden", -1), "turns")) <> -1 then stop
if rulesOfCard(boardCard$(selfPlayer, 0)) = 0 then stop
if nodeFind("ranged", -1) < 0 or nodeFind("hidden", -1) >= 0 then stop
if boardHiddenTurns(selfPlayer, 0) <> -1 or boardHiddenTurns(selfPlayer, 1) <> 0 then stop
if boardLastsTurns(selfPlayer, 1) <> 1 or boardLastsTurns(selfPlayer, 0) <> 0 then stop
if rulesOfTrigger() <> 0 then stop
endTurn()
""")
  let player = played.game.currentPlayer
  var sniper = ready(player, 1, baseCardNamed("Sniper"))
  sniper.lostRules = @[baseCardNamed("Sniper").rules[0]]
  sniper.gainedRules = @[baseCardNamed("Spirit").rules[0]]
  sniper.hiddenTurns = Always
  var post = ready(player, 2, baseCardNamed("Post"))
  post.lastsTurns = 1
  played.game.players[player].board = @[sniper, post]
  played.game.nextMinionId = 3
  doAssert played.step()
  doAssert played.bots[player].action.kind == ActionEndTurn

block:
  # The waiting trigger's own rule, its trigger first.
  let snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
    rules: rules(on(attacked(You), damage(1, target({kind: {Minion}})))))
  var played = scripted("""
dim picks(0)
if rulesOfTrigger() = 0 or nodeKind$(0) <> "on" then stop
t = nodeChild(0, "trigger")
if nodeKind$(t) <> "attacked" or nodeText$(nodeChild(t, "player")) <> "You" then stop
d = nodeChild(0, "rules")
if nodeKind$(d) <> "damage" or nodeValue(nodeChild(d, "amount")) <> 1 then stop
if nodeText$(nodeChild(nodeChild(d, "what"), "kind")) <> "Minion" then stop
if nodeText$(0) <> triggerRules$() then stop
resolveTrigger("picks")
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  played.game.players[owner].board = @[ready(owner, 1, snare)]
  played.game.players[player].board = @[ready(player, 2, baseCardNamed("Bear"))]
  played.game.nextMinionId = 3
  played.game.pendingTriggers = @[PendingTrigger(owner: owner,
    sourceId: 1, trigger: 0, attacker: creatureChoice(player, 2))]
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionResolveTrigger

echo "Every base card's rules read as a tree with nothing unknown"
for card in baseCards:
  let tree = card.rules.ruleNodes(card)
  doAssert tree.len > 0 or card.rules.len == 0
  for n, node in tree:
    doAssert node.kind != "unknown", card.name & ": " & node.text
    doAssert node.parent in -1 ..< n, card.name

echo "Scripts read what happened since their last decision"
block:
  # Seat O's script, three times: a discard the current player's minion
  # forces, an attack whose trigger O aims, then O's own turn.
  let
    snare = Card(name: "Snare", kind: Trinket, class: some(Mage),
      rules: rules(on(attacked(You), damage(1, target({kind: {Minion}})))))
    pickpocket = Card(name: "Pickpocket", energyCost: 1, kind: Minion,
      class: some(Mage), rules: rules(toss(1, AllOpponents)),
      power: 1, toughness: 1)
    bear = baseCardNamed("Bear")
  var played = scripted("""
dim picks(0)
if tossCount > 0 then
  if logCount() <> 2 then stop
  if logKind$(0) <> "turn" or logPlayer(0) <> currentPlayer or logTurn(0) <> 1 then stop
  if logKind$(1) <> "play" or logPlayer(1) <> currentPlayer then stop
  if logCard$(1) <> "Pickpocket" or logOwner(1) <> currentPlayer then stop
  if logCardId(1) <> boardId(currentPlayer, 1) or logTargetCount(1) <> 0 then stop
  picks(0) = 0
  discardCards("picks")
  end
end if
if triggerTargets > 0 then
  if logCount() <> 3 then stop
  if logKind$(0) <> "discard" or logPlayer(0) <> selfPlayer then stop
  if logCard$(0) <> "Pickpocket" or logOwner(0) <> currentPlayer then stop
  if logCardId(0) <> boardId(currentPlayer, 1) or logAmount(0) <> 1 then stop
  if logText$(0) <> """ & basicText(pickpocket.rules[0].text(pickpocket)) & """ then stop
  if logTargetKind(0, 0) <> 5 or logTargetCard$(0, 0) <> "Bear" then stop
  if logTargetOwner(0, 0) <> selfPlayer then stop
  if logKind$(1) <> "attack" or logPlayer(1) <> currentPlayer then stop
  if logCard$(1) <> "Bear" or logCardId(1) <> boardId(currentPlayer, 0) then stop
  if logAmount(1) <> """ & $bear.power & """ or logTargetKind(1, 0) <> 2 then stop
  if logTargetOwner(1, 0) <> selfPlayer then stop
  if logKind$(2) <> "damage" or logPlayer(2) <> selfPlayer or logCard$(2) <> "" then stop
  if logAmount(2) <> """ & $bear.power & """ then stop
  j = 0
  while j < nextChoiceCount(-1, "picks", 0)
    if nextChoiceId(-1, "picks", 0, j) = boardId(currentPlayer, 0) then
      picks(0) = j
      resolveTrigger("picks")
      end
    end if
    j = j + 1
  wend
  stop
end if
if logCount() <> 5 then stop
if logKind$(0) <> "choice" or logPlayer(0) <> selfPlayer or logCard$(0) <> "Snare" then stop
if logCardId(0) <> boardId(selfPlayer, 0) or logOwner(0) <> selfPlayer then stop
if logTargetKind(0, 0) <> 3 or logTargetCard$(0, 0) <> "Bear" then stop
if logTargetId(0, 0) <> boardId(enemyPlayer, 0) then stop
if logCause$(0) <> "Bear" or logCauseOwner(0) <> enemyPlayer then stop
if logKind$(1) <> "trigger" or logPlayer(1) <> selfPlayer or logAmount(1) <> 0 then stop
if logCause$(1) <> "Bear" or logCauseId(1) <> boardId(enemyPlayer, 0) then stop
if logText$(1) <> """ & basicText(snare.triggers()[0].text(snare)) & """ then stop
if logKind$(2) <> "damage" or logCard$(2) <> "Bear" or logPlayer(2) <> enemyPlayer then stop
if logAmount(2) <> 1 or logOwner(2) <> enemyPlayer then stop
if logKind$(3) <> "turn" or logPlayer(3) <> selfPlayer or logTurn(3) <> 2 then stop
if logKind$(4) <> "draw" or logPlayer(4) <> selfPlayer or logAmount(4) <> 1 then stop
if logKind$(5) <> "" or logPlayer(5) >= 0 or logTargetCard$(0, 9) <> "" then stop
endTurn()
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  played.game.players[owner].board = @[ready(owner, 1, snare)]
  played.game.players[owner].hand = @[bear]
  played.game.players[player].board = @[ready(player, 2, bear)]
  played.game.players[player].hand = @[pickpocket]
  played.game.players[player].energy = 10
  played.game.nextMinionId = 3
  doAssert played.game.playCard(0, @[])
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionToss
  doAssert played.game.attack(2, heroChoice(owner))
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionResolveTrigger
  played.game.finishTurn()
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionEndTurn

block:
  # A spell that destroys a minion and summons for its owner.
  let toughness = baseCardNamed("Bear").toughness
  var played = scripted("""
if logCount() <> """ & $(5 + toughness) & """ then stop
if logKind$(1) <> "play" or logCard$(1) <> "Oozification" or logCardId(1) <> 0 then stop
if logTargetCount(1) <> 1 or logTargetKind(1, 0) <> 3 then stop
if logTargetCard$(1, 0) <> "Bear" or logTargetOwner(1, 0) <> selfPlayer then stop
if logKind$(2) <> "death" or logCard$(2) <> "Bear" then stop
if logPlayer(2) <> selfPlayer or logOwner(2) <> selfPlayer then stop
n = """ & $toughness & """ ' Oozes, one per point of the Bear's toughness
for k = 0 to n - 1
  if logKind$(3 + k) <> "summon" or logCard$(3 + k) <> "Ooze" then stop
  if logPlayer(3 + k) <> selfPlayer or logCardId(3 + k) <> boardId(selfPlayer, k) then stop
next k
if logKind$(""" & $(3 + toughness) & """) <> "turn" then stop
endTurn()
""")
  let player = played.game.currentPlayer
  let owner = played.game.nextPlayer(player)
  played.game.players[owner].board = @[ready(owner, 1, baseCardNamed("Bear"))]
  played.game.players[player].hand = @[baseCardNamed("Oozification")]
  played.game.players[player].energy = 10
  played.game.nextMinionId = 2
  doAssert played.game.playCard(0, @[creatureChoice(owner, 1)])
  played.game.finishTurn()
  doAssert played.step()
  doAssert played.bots[owner].action.kind == ActionEndTurn

echo "Only games kept for bots record events, and events never change the state"
block:
  let seats = [precon(Mage), precon(Warrior)]
  var
    plain = newGame(seats, 31)
    logged = newGame(seats, 31, recordEvents = true)
  doAssert plain.events.len == 0 and logged.events.len == 1
  plain.finishTurn()
  logged.finishTurn()
  doAssert plain.events.len == 0
  doAssert logged.takeEvents().mapIt(it.kind) == @[TurnEvent, TurnEvent,
    DrawEvent]
  doAssert logged.events.len == 0
  doAssert plain.stateHash == logged.stateHash

echo "Each logged event reads as one line on the app's terminal"
block:
  var game = newGame([precon(Mage), precon(Mage)], 5, recordEvents = true)
  let
    player = game.currentPlayer
    owner = game.nextPlayer(player)
    p = "P" & $(player + 1)
    o = "P" & $(owner + 1)
  game.players[owner].board = @[ready(owner, 1, baseCardNamed("Bear"))]
  game.players[player].hand = @[baseCardNamed("Oozification")]
  game.players[player].energy = 10
  game.nextMinionId = 2
  discard game.takeEvents()
  doAssert game.playCard(0, @[creatureChoice(owner, 1)])
  doAssert game.takeEvents().mapIt(it.describe()) == @[
    "T1 " & p & " plays Oozification → " & o & "'s Bear#1",
    "T1 " & o & "'s Bear#1 dies",
    "T1 " & o & " summons Ooze#2",
    "T1 " & o & " summons Ooze#3"]
  game.finishTurn()
  doAssert game.takeEvents().mapIt(it.describe()) == @[
    "T2 " & o & "'s turn", "T2 " & o & " draws a card"]
  # A card that aims at nothing shows no stand-in pick.
  game.players[owner].hand = @[baseCardNamed("Bear")]
  game.players[owner].energy = 10
  doAssert game.playCard(0, @[NoTarget])
  doAssert game.takeEvents().mapIt(it.describe()) == @[
    "T2 " & o & " plays Bear#4"]
  # Heroes, hand cards, branches, causes and signs, with seat names.
  let names = ["Ana", "Bo"]
  doAssert GameEvent(kind: AttackEvent, turn: 4, player: 0, card: "Bear",
    cardId: 2, targets: @[EventTarget(choice: heroChoice(1))]).describe(
    names) == "T4 Ana's Bear#2 attacks Bo's hero"
  doAssert GameEvent(kind: DamageEvent, turn: 4, player: 1,
    amount: 3).describe(names) == "T4 Bo's hero takes 3 damage"
  doAssert GameEvent(kind: DiscardEvent, turn: 4, player: 1,
    card: "Pickpocket", cardId: 3, owner: 0, targets: @[EventTarget(
    choice: heroChoice(1), card: "Bear", fromHand: true)]).describe(names) ==
    "T4 Bo discards Bear for Ana's Pickpocket#3"
  doAssert GameEvent(kind: TriggerEvent, turn: 4, player: 1, card: "Snare",
    cardId: 1, cause: "Bear", causeId: 2, causeOwner: 0, targets: @[
    EventTarget(choice: creatureChoice(0, 2), card: "Bear")]).describe(
    names) == "T4 Bo's Snare#1 triggers, fired by Ana's Bear#2 → Ana's Bear#2"
  doAssert GameEvent(kind: PlayEvent, turn: 5, player: 0, card: "Overcharge",
    targets: @[EventTarget(choice: optionChoice(1)), EventTarget(
    choice: NoTarget)]).describe() ==
    "T5 P1 plays Overcharge → option 2, no target"
  doAssert GameEvent(kind: StatsEvent, turn: 5, player: 0, card: "Bear",
    cardId: 2, amount: 1, amount2: -1).describe() == "T5 P1's Bear#2 gets +1/-1"

echo "Large hands and boards have no automatic thirty-card turn cap"
block:
  var played = scripted("""
if handSize > 0 then
  if playCard(handSize - 1) then end
end if
id = boardId(selfPlayer, 0)
i = 0
while i < attackChoiceCount(id)
  if attackChoiceId(id, i) = 200 then
    if attack(id, i) then end
  end if
  i = i + 1
wend
endTurn()
""", 4)
  let player = played.game.currentPlayer
  played.game.players[player].hand = newSeqWith(64, baseCardNamed("Ooze"))
  played.game.players[player].board = @[
    ready(player, 1, baseCardNamed("Primordial"))]
  let enemy = (player + 2) mod 4
  for i in 100 .. 200:
    played.game.players[enemy].board.add ready(enemy, i, baseCardNamed("Bear"))
  played.game.nextMinionId = 201
  for i in 0 ..< 64:
    doAssert played.step()
    doAssert played.game.currentPlayer == player
    doAssert played.bots[player].action.kind == ActionPlayCard
  doAssert played.game.players[player].board.len == 65
  doAssert played.step()
  doAssert played.bots[player].action.kind == ActionAttack
  doAssert played.bots[player].action.choices[0].creatureId == 200
  doAssert played.game.currentPlayer == player

echo "Class, observation and large-board parity passed"
