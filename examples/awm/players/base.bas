' AWM reference bot.
'
' Each decision selects one explicit action, then runs again for the next.
' The engine never attacks, chooses targets, discards, or ends turns for you.
' Globals and arrays survive between decisions.
' random(n) returns a seeded integer in 0 to n - 1.
' The script chooses its own class, card order, attacks, targets and discards.
'
' READ-ONLY VALUES
'   selfPlayer enemyPlayer turnNumber
'   selfLife enemyLife energy totalEnergy
'   handSize selfBoardSize enemyBoardSize selfDeckSize enemyDeckSize
'   playerCount currentPlayer tossCount triggerTargets
'   selectingClass selfClass enemyClass
'   Setup: call pickClass(0=Archer, 1=Warrior, 2=Mage), then END.
'   playerClass(p) returns any seat's class.
'
' HAND QUERIES (index 0 to handSize - 1)
'   handCost(i)       energy cost
'   handKind(i)       0 = minion, 1 = spell, 2 = trinket
'   handPower(i)      attack (minions only)
'   handToughness(i)  toughness (minions only)
'   canPlay(i)        1 if affordable
'   needsChoice(i)    1 if the card needs a target
'
' CHOICE QUERIES
'   A choice kind of 4 is an option: the card offers branches to choose
'   between, and the choice index is the branch. Its value is in
'   optionDamage/optionSelfDamage below. Later targets only appear once an
'   option is picked, so ask the next* queries with the picks so far.
'   nextTargetCount(handIndex, "picks", pickedCount)
'   nextHelpsTarget(handIndex, "picks", pickedCount)
'   nextIntent(handIndex, "picks", pickedCount)
'   nextAmount(handIndex, "picks", pickedCount)
'   optionDamage(handIndex, "picks", pickedCount, option)
'   optionSelfDamage(handIndex, "picks", pickedCount, option)
'   targetIntent(handIndex, step)  what the card does to that target:
'                                  0 = nothing to judge, 1 = damage,
'                                  2 = buff, 3 = weaken, 4 = bounce,
'                                  5 = destroy, 6 = loses a keyword
'   targetAmount(handIndex, step)  how much: damage dealt, stats changed
'   choiceCount(handIndex)              number of valid targets
'   choiceKind(handIndex, choiceIndex)  0=canceled 1=noTarget 2=hero 3=creature
'   choiceOwner(handIndex, choiceIndex) player who owns the target (-1 if n/a)
'   choiceId(handIndex, choiceIndex)    stable minion ID (0 for a hero)
'   (these cover a card's first target; for cards with several targets:)
'   targetCount(handIndex)                         targets the card asks for
'   helpsTarget(handIndex, step)                   1 if that target should be yours
'   targetChoiceCount(handIndex, step)             valid choices for that target
'   targetChoiceKind(handIndex, step, choiceIndex)
'   targetChoiceOwner(handIndex, step, choiceIndex)
'
' BOARD QUERIES (index 0 to selfBoardSize/enemyBoardSize - 1)
'   selfBoardPower(i)  selfBoardHp(i)
'   enemyBoardPower(i) enemyBoardHp(i)
'
' COMMANDS (at most one per decision)
'   playCard(handIndex)                    play without a target, returns 1 on success
'   playCardChoice(handIndex, choiceIndex) play with a specific target
'   playCardChoices(handIndex, first, second) play a two-target card

' EXPLICIT ACTIONS AND VISIBLE BOARD QUERIES
'   handName$(i), boardCount(player), boardId(player, index)
'   boardName$(player, index), boardCard$(player, index)
'   handId$(i) returns the unique printed card name.
'   cardName$(id$), cardRules$(id$), cardKind(id$), cardClass(id$)
'   cardCost(id$), cardPower(id$), cardToughness(id$)
'   cardHasKeyword(id$, k), boardHasKeyword(p, i, k): k=0 is Ranged.
'   boardPower(p, i), boardHp(p, i), boardKind(p, i)
'   boardReady(p, i), boardAttacked(p, i)
'   playerLife(p), playerEnergy(p), playerTotalEnergy(p)
'   playerHandSize(p), playerDeckSize(p), playerDead(p)
'   attackChoiceCount(id), attackChoiceKind(id, choice)
'   attackChoiceOwner(id, choice), attackChoiceId(id, choice)
'   attack(id, choice)                 attack one chosen hero or minion
'   endTurn()                         finish without any automatic attacks
'   discardCards("picks")              discard tossCount indexes in picks()
'   resolveTrigger("picks")            answer triggerTargets in picks()
'   triggerChoiceCount(step), triggerChoiceKind(step, choice)
'   triggerChoiceOwner(step, choice), triggerChoiceId(step, choice)
'   triggerHelpsTarget(step)
'   playCardTargets(handIndex, "picks") choose any number of card targets
'   nextChoiceCount(handIndex, "picks", pickedCount)
'   nextChoiceKind(handIndex, "picks", pickedCount, choice)
'   nextChoiceOwner(handIndex, "picks", pickedCount, choice)
'   nextChoiceId(handIndex, "picks", pickedCount, choice)
' Use handIndex = -1 for trigger queries. Prefix queries include earlier picks.
' Successful commands return 1; refused commands return 0 and do nothing.
' Exactly one successful command is allowed per decision. END alone is not
' an action. A decision with no action stops the match with a player error.

IF selectingClass THEN
  pickClass(random(3))
  END
END IF

DIM picks(1023)
DIM junk(1023)
IF tossCount > 0 THEN
  ' Rank the hand by what it is worth to you: a card you are still far from
  ' affording is dead weight, a minion is worth its body, and a spell about
  ' its price. Discard from the top of that ranking, ties at random.
  i = 0
  WHILE i < handSize
    picks(i) = i
    worth = 3 + handCost(i)
    IF handKind(i) = 0 THEN worth = handPower(i) + handToughness(i)
    over = handCost(i) - totalEnergy
    IF over < 0 THEN over = 0
    junk(i) = over * 4 - worth
    i = i + 1
  WEND
  i = 0
  WHILE i < tossCount
    best = i
    j = i + 1
    WHILE j < handSize
      take = 0
      IF junk(picks(j)) > junk(picks(best)) THEN take = 1
      IF junk(picks(j)) = junk(picks(best)) THEN take = random(2)
      IF take THEN best = j
      j = j + 1
    WEND
    swap = picks(i)
    picks(i) = picks(best)
    picks(best) = swap
    i = i + 1
  WEND
  discardCards("picks")
  END
END IF
IF triggerTargets > 0 THEN
  ' A trigger aims like a card: hand index -1 asks about the waiting one.
  ' With nothing worth aiming at, every legal choice stays eligible,
  ' including declining the target.
  s = 0
  WHILE s < triggerTargets
    n = nextChoiceCount(-1, "picks", s)
    IF n = 0 THEN STOP
    i = -1
    GOSUB aim
    s = s + 1
  WEND
  resolveTrigger("picks")
  END
END IF

' Try attacks before cards on some decisions and after cards on others.
' This allows attacking a Primordial before bouncing and replaying it.
IF random(2) THEN GOSUB attacks

' Visit every card from a random starting position, choosing its targets
' sequentially. This covers all cards, multiple targets and self-bounces.
IF handSize > 0 THEN
  start = random(handSize)
  offset = 0
  WHILE offset < handSize
    i = (start + offset) MOD handSize
    IF canPlay(i) THEN
      count = targetCount(i)
      IF count = 0 THEN
        IF playCard(i) THEN END
      ELSE
        valid = 1
        s = 0
        WHILE s < count AND valid
          n = nextChoiceCount(i, "picks", s)
          IF n = 0 THEN
            valid = 0
          ELSE
            GOSUB aim
            ' Picking an option reveals that branch's own targets.
            count = nextTargetCount(i, "picks", s + 1)
          END IF
          s = s + 1
        WEND
        IF valid THEN
          IF playCardTargets(i, "picks") THEN END
        END IF
      END IF
    END IF
    offset = offset + 1
  WEND
END IF

GOSUB attacks
endTurn()
END

aim:
' Choose the s'th target of hand card i (-1 for a waiting trigger) by what
' the card does to it. A target that helps goes on your best body; damage
' goes where it kills, otherwise at a hero; removal takes their biggest
' threat; a keyword only comes off a minion that has one. Ties break at
' random, and when nothing scores every choice stays eligible, so a lone
' minion still bounces itself and declining stays possible.
mine = nextHelpsTarget(i, "picks", s)
what = nextIntent(i, "picks", s)
size = nextAmount(i, "picks", s)
best = -1
bestScore = 0
c = 0
WHILE c < n
  k = nextChoiceKind(i, "picks", s, c)
  o = nextChoiceOwner(i, "picks", s, c)
  d = nextChoiceId(i, "picks", s, c)
  GOSUB score
  IF value > 0 THEN
    IF best < 0 THEN
      take = 1
    ELSE
      take = 0
      IF value > bestScore THEN take = 1
      IF value = bestScore THEN take = random(2)
    END IF
    IF take THEN
      best = c
      bestScore = value
    END IF
  END IF
  c = c + 1
WEND
IF best < 0 THEN
  picks(s) = random(n)
  RETURN
END IF
picks(s) = best
RETURN

score:
' What choice c is worth for this target: 0 means do not aim here. Scores
' stay small and positive so that equals can break at random.
value = 0
IF k = 4 THEN
  ' An option: worth what it deals, less twice what it costs your own hero,
  ' and never one that would finish you off.
  cost = optionSelfDamage(i, "picks", s, c)
  IF cost >= selfLife THEN RETURN
  value = 20 + optionDamage(i, "picks", s, c) - cost * 2
  IF value < 1 THEN value = 1
  RETURN
END IF
IF o < 0 THEN RETURN
IF mine THEN
  IF o <> selfPlayer THEN RETURN
ELSE
  IF o = selfPlayer THEN RETURN
END IF
IF k = 2 THEN
  ' A hero. Damage always lands, and a card that only offers heroes, like
  ' Summon Primordial, still has to pick one.
  value = 3
  IF mine THEN value = 0
ELSE
  GOSUB stats
  IF mine THEN
    value = 4 + power * 2 + hp
  ELSE
    IF what = 1 THEN
      ' Damage: a kill is worth their whole body, else soften the biggest.
      value = 1 + power
      IF hp <= size THEN value = 10 + power * 2 + hp
    ELSE
      IF what = 6 THEN
        ' Taking a keyword away only matters to a minion that has one.
        IF ranged THEN value = 10 + power * 2 + hp
      ELSE
        ' Bounce, destroy or weaken: take their biggest threat.
        value = 4 + power * 2 + hp
      END IF
    END IF
  END IF
END IF
IF value > 0 THEN
  IF o = enemyPlayer THEN value = value + 1
END IF
RETURN

stats:
' power, hp and ranged for the minion with id d on player o's board.
power = 0
hp = 0
ranged = 0
b = 0
WHILE b < boardCount(o)
  IF boardId(o, b) = d THEN
    power = boardPower(o, b)
    hp = boardHp(o, b)
    ranged = boardHasKeyword(o, b, 0)
    b = boardCount(o)
  END IF
  b = b + 1
WEND
RETURN

attacks:
' Visit every permanent. Each minion takes the swing worth the most: a kill
' is worth the body it removes, a hero swing is worth the damage it lands,
' and a trade only the difference, so a big minion goes face instead of
' eating a chump. A swing that dies for nothing is never taken. Ranged
' minions take no combat damage from non-ranged ones, attacking or
' defending. Trinkets and unready minions have no attack choices.
IF boardCount(selfPlayer) > 0 THEN
  start = random(boardCount(selfPlayer))
  offset = 0
  WHILE offset < boardCount(selfPlayer)
    i = (start + offset) MOD boardCount(selfPlayer)
    id = boardId(selfPlayer, i)
    n = attackChoiceCount(id)
    IF n > 0 THEN
      myPower = boardPower(selfPlayer, i)
      myHp = boardHp(selfPlayer, i)
      myRanged = boardHasKeyword(selfPlayer, i, 0)
      best = -1
      bestScore = 0
      c = 0
      WHILE c < n
        k = attackChoiceKind(id, c)
        o = attackChoiceOwner(id, c)
        d = attackChoiceId(id, c)
        GOSUB swing
        IF value > 0 THEN
          IF best < 0 THEN
            take = 1
          ELSE
            take = 0
            IF value > bestScore THEN take = 1
            IF value = bestScore THEN take = random(2)
          END IF
          IF take THEN
            best = c
            bestScore = value
          END IF
        END IF
        c = c + 1
      WEND
      IF best >= 0 THEN
        IF attack(id, best) THEN END
      END IF
    END IF
    offset = offset + 1
  WEND
END IF
RETURN

swing:
' What attacking choice c is worth to a minion of myPower and myHp.
value = 0
IF k = 2 THEN
  ' Their hero: every point of power lands on it.
  value = 4 + myPower * 2
ELSE
  GOSUB stats
  kills = 0
  dies = 0
  IF myPower >= hp THEN kills = 1
  IF power >= myHp THEN dies = 1
  IF ranged THEN
    IF myRanged = 0 THEN kills = 0
  END IF
  IF myRanged THEN
    IF ranged = 0 THEN dies = 0
  END IF
  IF kills THEN
    IF dies THEN
      ' A trade is worth what their body beats yours by.
      value = 6 + power * 2 + hp - myPower - myHp
      IF value < 1 THEN value = 1
    ELSE
      value = 6 + power * 2 + hp
    END IF
  ELSE
    ' No kill: chip in only when you walk away from it.
    IF dies = 0 THEN value = 6
  END IF
END IF
IF value > 0 THEN
  IF o = enemyPlayer THEN value = value + 1
END IF
RETURN
