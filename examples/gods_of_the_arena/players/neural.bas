' Gods of the Arena 2026.9.21.3 compatibility layer.
' Draft a balanced roster, spend ability points, buy back, and keep the
' previously trained neural clock relative to the start of combat.
sub chooseHero()
  if draftTurnId <> selfId then
    exit sub
  end if
  bestClass = -1
  bestDraftScore = -2147483647
  candidateClass = 0
  while candidateClass < 10
    if heroAvailable(candidateClass) then
      candidateRole = heroRole(candidateClass)
      draftScore = 100
      draftPlayer = 0
      while draftPlayer < draftPlayerCount()
        if draftPlayerTeam(draftPlayer) = selfTeam then
          pickedClass = draftedClass(draftPlayerId(draftPlayer))
          if pickedClass >= 0 then
            if heroRole(pickedClass) = candidateRole then
              draftScore = draftScore - 100
            end if
          end if
        end if
        draftPlayer = draftPlayer + 1
      wend
      if candidateClass \ 5 = selfTeam then
        draftScore = draftScore + 1
      end if
      if draftScore > bestDraftScore then
        bestDraftScore = draftScore
        bestClass = candidateClass
      end if
    end if
    candidateClass = candidateClass + 1
  wend
  if bestClass >= 0 then
    draftHero(bestClass)
  end if
end sub

if drafting then
  chooseHero()
  end
end if

if battleStarted = 0 then
  battleStartTick = worldTick
  battleStarted = 1
end if
battleTick = worldTick - battleStartTick

if selfHp <= 0 then
  buybackCost = buybackPrice()
  if buybackCost > 0 and selfGold >= buybackCost then
    buyback()
  end if
  end
end if

' Spend every currently legal point. The trained actor favors W, then E/Q;
' take the ultimate whenever its level gate opens.
for upgrade = 1 to 4
  if canLevelAbility(3) then
    levelAbility(3)
  elseif canLevelAbility(1) then
    levelAbility(1)
  elseif canLevelAbility(2) then
    levelAbility(2)
  elseif canLevelAbility(0) then
    levelAbility(0)
  end if
next upgrade

dim f(27)
bestId = 0
bestDistance = 2147483647
objectiveId = 0
objectiveKind = 0
siegeThreatId = 0
siegeThreatHp = 2147483647
objectiveDistance = 2147483647
heroId = 0
heroDistance = 2147483647
enemyX = selfX
enemyY = selfY
enemyHp = 0
enemyKind = 0
enemyAttackTarget = 0
routeOpeningX = 71
routeOpeningY = 12
if selfTeam = 1 then
  routeOpeningX = 45
  routeOpeningY = 104
end if
routeGroupCount = 0
if selfTeam = 0 then
  gateHomeX = 105
  gateHomeY = 10
else
  gateHomeX = 10
  gateHomeY = 105
end if
gateThreatDistance = 2147483647
gateThreatSeen = 0
gateThreatX = gateHomeX
reserveHome = 0
allyCount = 0
allyX = 0
allyY = 0
maxAllyDistance = 0
index = 0
while index < objectCount()
  if objectAlive(index) then
    if objectTeam(index) = selfTeam and objectKind(index) = 1 then
      reserveHome = 1
      reserveHomeId = objectId(index)
      reserveX = objectX(index)
      reserveY = objectY(index)
    end if
    if objectTeam(index) = selfTeam and objectKind(index) = 2 then
      allyCount = allyCount + 1
      routeDx = objectX(index) - routeOpeningX
      routeDy = objectY(index) - routeOpeningY
      if routeDx * routeDx + routeDy * routeDy <= 16 then
        routeGroupCount = routeGroupCount + 1
      end if
      allyX = allyX + objectX(index)
      allyY = allyY + objectY(index)
      dx = objectX(index) - selfX
      dy = objectY(index) - selfY
      distance = dx * dx + dy * dy
      if distance > maxAllyDistance then
        maxAllyDistance = distance
      end if
    end if
    if objectTeam(index) <> selfTeam then
      if battleTick < 1000 and (objectKind(index) = 2 or objectKind(index) = 3) then
        gateDx = objectX(index) - gateHomeX
        gateDy = objectY(index) - gateHomeY
        gateDistance = gateDx * gateDx + gateDy * gateDy
        if gateDistance < gateThreatDistance then
          gateThreatDistance = gateDistance
          gateThreatSeen = 1
          gateThreatX = objectX(index)
        end if
      end if
      dx = objectX(index) - selfX
      dy = objectY(index) - selfY
      distance = dx * dx + dy * dy
      if distance < bestDistance then
        bestDistance = distance
        bestId = objectId(index)
        enemyX = objectX(index)
        enemyY = objectY(index)
        enemyHp = objectHp(index)
        enemyKind = objectKind(index)
        enemyAttackTarget = objectTarget(index)
      end if
      if objectKind(index) = 2 and objectTarget(index) = selfId then
        siegeRange = selfAttackRange \ 1000
        if distance * 3600 <= siegeRange * siegeRange and objectHp(index) < siegeThreatHp then
          siegeThreatId = objectId(index)
          siegeThreatHp = objectHp(index)
        end if
      end if
      if objectKind(index) = 1 or objectKind(index) = 4 then
        if distance < objectiveDistance then
          objectiveDistance = distance
          objectiveId = objectId(index)
          objectiveKind = objectKind(index)
        end if
      end if
      if objectKind(index) = 2 and distance < heroDistance then
        heroDistance = distance
        heroId = objectId(index)
        ringHeroX = objectX(index)
        ringHeroY = objectY(index)
        ringHeroTarget = objectTarget(index)
      end if
    end if
  end if
  index = index + 1
wend
if allyCount > 0 then
  allyX = allyX \ allyCount
  allyY = allyY \ allyCount
else
  allyX = selfX
  allyY = selfY
end if
f(0) = selfHp * 100 \ selfMaxHp
f(1) = 0
if selfMaxMana > 0 then
  f(1) = selfMana * 100 \ selfMaxMana
end if
f(2) = maxAllyDistance \ 100
f(3) = selfLevel * 5
f(4) = allyX - selfX
f(5) = allyY - selfY
f(6) = enemyX - selfX
f(7) = enemyY - selfY
f(8) = enemyHp \ 10
f(9) = enemyKind * 25
if selfTeam = 1 then
  f(4) = 0 - f(4)
  f(5) = 0 - f(5)
  f(6) = 0 - f(6)
  f(7) = 0 - f(7)
end if
f(10) = battleTick \ 288
f(11) = abilityCharges(0) * 25
f(12) = abilityCharges(1) * 25
f(13) = abilityCharges(2) * 25
f(14) = abilityCharges(3) * 25
f(15 + selfClass) = 100
f(25) = battleTick \ 16
if battleTick < 1000 and gateThreatSeen = 1 then
  gateEarlyThreatX = gateThreatX
  gateEarlyThreatSeen = 1
end if
f(26) = 0
if gateEarlyThreatSeen = 1 then
  f(26) = gateEarlyThreatX - gateHomeX
  if selfTeam = 1 then
    f(26) = 0 - f(26)
  end if
end if
index = 0
while index < 27
  if f(index) > 100 then
    f(index) = 100
  end if
  if f(index) < -100 then
    f(index) = -100
  end if
  index = index + 1
wend
dim h(18)
' METTA_DECISION
if decision = 18 then
  combatDecision = 8
else
combatDecision = decision
end if
objectiveBuild = 0
if decision >= 9 then
  combatDecision = decision - 9
  objectiveBuild = 1
end if

routeFallback = 0
if combatDecision = 2 or (combatDecision = 8 and bestId = 0) then
  if (objectiveId = 0 or objectiveDistance > 300) and (heroId = 0 or heroDistance > 700) then
    routeFallback = 1
  end if
end if
routeDx = selfX - routeOpeningX
routeDy = selfY - routeOpeningY
if battleTick < 3500 and routeFallback and routeGroupCount >= 3 then
  if routeDx * routeDx + routeDy * routeDy <= 16 then
    groupDeparture = 1
  end if
end if

if combatDecision = 8 then
  if objectiveId <> 0 and objectiveDistance <= 300 then
    attackTarget(objectiveId)
  else
    if heroId <> 0 and heroDistance <= 700 then
      attackTarget(heroId)
    else
      if bestId <> 0 then
        attackTarget(bestId)
      else
        if selfTeam = 0 then
          if battleTick < 3500 and groupDeparture = 0 then
            walkTo(71, 12)
          else
            if battleTick < 4500 then
              walkTo(9, 33)
            else
              walkTo(11, 106)
            end if
          end if
        else
          if battleTick < 3500 and groupDeparture = 0 then
            walkTo(45, 104)
          else
            if battleTick < 4500 then
              walkTo(107, 83)
            else
              walkTo(105, 10)
            end if
          end if
        end if
      end if
    end if
  end if
else
  if bestId <> 0 then
    attackTarget(bestId)
  else
    walkTo(64, 64)
  end if
end if
if selfClass = 7 and heroId <> 0 and ringHeroTarget = selfId then
  if heroDistance > 25 and heroDistance <= 49 then
    castPoint(3, (selfX + ringHeroX) \ 2, (selfY + ringHeroY) \ 2)
  end if
end if
hasHeal = 0
hasMana = 0
hasPoison = 0
hasGear = 0
hasDagger = 0
hasSword = 0
hasArmor = 0
hasAxe = 0
hasBook = 0
emptySlot = 0
slot = 0
while slot < 6
  id = itemId(slot)
  if id = 0 then
    emptySlot = 1
  end if
  if id = 1 or id = 2 then
    hasHeal = 1
    if selfHp * 5 < selfMaxHp * 3 and itemCooldown(slot) = 0 then
      useItem(slot)
    end if
  end if
  if id = 3 or id = 22 then
    hasMana = 1
    if objectiveBuild = 0 and selfMana * 5 < selfMaxMana * 2 and itemCooldown(slot) = 0 then
      useItem(slot)
    end if
  end if
  if id = 4 then
    hasPoison = 1
    if objectiveBuild = 0 and bestId <> 0 then
      useItem(slot)
    end if
  end if
  if id >= 5 and id <= 20 then
    hasGear = 1
  end if
  if id = 11 then
    hasDagger = 1
  end if
  if id = 13 then
    hasSword = 1
  end if
  if id = 16 then
    hasArmor = 1
  end if
  if id = 18 then
    hasAxe = 1
  end if
  if id = 20 then
    hasBook = 1
  end if
  slot = slot + 1
wend
if canShop() then
if selfHp * 2 < selfMaxHp and hasHeal = 0 then
  if selfGold >= 50 then
    buyItem(2)
  end if
  if selfGold >= 30 then
    buyItem(1)
  end if
end if
if objectiveBuild = 0 then
if selfMaxMana > 0 then
  if selfMana * 2 < selfMaxMana and hasMana = 0 then
    if selfGold >= 45 then
      buyItem(22)
    end if
  end if
end if
if bestId <> 0 and hasPoison = 0 then
  if selfGold >= 40 then
    buyItem(4)
  end if
end if
if emptySlot <> 0 then
  melee = 0
  ranged = 0
  magic = 0
  if selfClass = 0 or selfClass = 4 or selfClass = 5 or selfClass = 9 then
    melee = 1
  end if
  if selfClass = 1 or selfClass = 6 then
    ranged = 1
  end if
  if selfClass = 2 or selfClass = 3 or selfClass = 7 or selfClass = 8 then
    magic = 1
  end if
  if melee = 1 then
    if hasGear = 0 and selfGold >= 70 then
      buyItem(7)
    end if
    if selfGold >= 80 then
      buyItem(5)
    end if
    if selfGold >= 110 then
      buyItem(11)
    end if
    if selfGold >= 150 then
      buyItem(13)
    end if
    if selfGold >= 180 then
      buyItem(18)
    end if
  end if
  if ranged = 1 then
    if hasGear = 0 and selfGold >= 100 then
      buyItem(8)
    end if
    if selfGold >= 150 then
      buyItem(14)
    end if
    if selfGold >= 180 then
      buyItem(19)
    end if
  end if
  if magic = 1 then
    if hasGear = 0 and selfGold >= 140 then
      buyItem(12)
    end if
    if selfGold >= 120 then
      buyItem(10)
    end if
    if selfGold >= 170 then
      buyItem(17)
    end if
    if selfGold >= 190 then
      buyItem(20)
    end if
  end if
  if selfGold >= 90 then
    buyItem(6)
  end if
  if selfGold >= 120 then
    buyItem(9)
  end if
end if
else
  if emptySlot <> 0 then
    if hasDagger = 0 and selfGold >= 110 then
      buyItem(11)
    end if
    if hasSword = 0 and selfGold >= 150 then
      buyItem(13)
    end if
    if hasArmor = 0 and selfGold >= 160 then
      buyItem(16)
    end if
    if hasAxe = 0 and selfGold >= 180 then
      buyItem(18)
    end if
    if hasBook = 0 and selfGold >= 190 then
      buyItem(20)
    end if
  end if
end if
end if
if combatDecision = 1 then
  if selfTeam = 0 then
    walkTo(mapWidth - 10, 10)
  else
    walkTo(10, mapHeight - 10)
  end if
end if
if combatDecision = 2 then
  if objectiveId <> 0 and objectiveDistance <= 300 then
    attackTarget(objectiveId)
  else
    if heroId <> 0 and heroDistance <= 700 then
      attackTarget(heroId)
    else
      if selfTeam = 0 then
        if battleTick < 3500 and groupDeparture = 0 then
          walkTo(71, 12)
        else
          if battleTick < 4500 then
            walkTo(9, 33)
          else
            walkTo(11, 106)
          end if
        end if
      else
        if battleTick < 3500 and groupDeparture = 0 then
          walkTo(45, 104)
        else
          if battleTick < 4500 then
            walkTo(107, 83)
          else
            walkTo(105, 10)
          end if
        end if
      end if
    end if
  end if
end if
if combatDecision >= 3 and combatDecision <= 6 then
  if bestId <> 0 then
    castTarget(combatDecision - 3, bestId)
  else
    castTarget(combatDecision - 3, selfId)
  end if
end if
if combatDecision = 7 then
  walkTo(allyX, allyY)
end if

if decision = 18 and (bestId = 0 or bestDistance > 64) then
  specialistX = mapWidth - 1 - gateHomeX
  specialistY = gateHomeY
  specialistDx = selfX - specialistX
  specialistDy = selfY - specialistY
  if specialistDx * specialistDx + specialistDy * specialistDy <= 64 then
    perimeterStage = 1
  end if
  if perimeterStage <> 0 then
    specialistY = mapHeight - 1 - gateHomeY
  end if
  walkTo(specialistX, specialistY)
end if

if (combatDecision = 2 or combatDecision = 8) and objectiveKind = 4 and objectiveDistance <= 300 and siegeThreatId <> 0 then
  attackTarget(siegeThreatId)
end if

if reserveHome <> 0 then
  reserveGuards = 0
  reserveGuardCritical = 0
  reserveNearest = 1
  reserveDx = selfX - reserveX
  reserveDy = selfY - reserveY
  reserveDistance = reserveDx * reserveDx + reserveDy * reserveDy
  reserveTarget = 0
  reserveTargetDistance = 401
  reserveDirect = 0
  reserveDirectDistance = 401
  reserveHero = 0
  reserveHeroDistance = 401
  reserveFinish = 0
  reserveIndex = 0
  while reserveIndex < objectCount()
    reserveDx = objectX(reserveIndex) - reserveX
    reserveDy = objectY(reserveIndex) - reserveY
    reserveObjectHome = reserveDx * reserveDx + reserveDy * reserveDy
    if objectTeam(reserveIndex) = selfTeam then
      if objectKind(reserveIndex) = 4 and objectHp(reserveIndex) > 0 and reserveObjectHome <= 100 then
        reserveGuards = reserveGuards + 1
        if objectHp(reserveIndex) <= 780 then
          reserveGuardCritical = 1
        end if
      end if
      if objectKind(reserveIndex) = 2 and objectAlive(reserveIndex) and reserveObjectHome < reserveDistance then
        reserveNearest = 0
      end if
    else
      if objectAlive(reserveIndex) then
        if (objectKind(reserveIndex) = 2 or objectKind(reserveIndex) = 3) and reserveObjectHome < reserveDirectDistance then
          if objectTarget(reserveIndex) = reserveHomeId then
            reserveDirect = objectId(reserveIndex)
            reserveDirectDistance = reserveObjectHome
          end if
        end if
        if objectKind(reserveIndex) = 2 and reserveObjectHome < reserveHeroDistance then
          reserveHero = objectId(reserveIndex)
          reserveHeroDistance = reserveObjectHome
        end if
        if (objectKind(reserveIndex) = 2 or objectKind(reserveIndex) = 3) and reserveObjectHome < reserveTargetDistance then
          reserveTargetDistance = reserveObjectHome
          reserveTarget = objectId(reserveIndex)
        end if
        if objectKind(reserveIndex) = 1 and objectHp(reserveIndex) <= selfAttackDamage then
          reserveDx = objectX(reserveIndex) - selfX
          reserveDy = objectY(reserveIndex) - selfY
          reserveRange = selfAttackRange \ 1000
          if (reserveDx * reserveDx + reserveDy * reserveDy) * 3600 <= reserveRange * reserveRange then
            reserveFinish = 1
          end if
        end if
      end if
    end if
    reserveIndex = reserveIndex + 1
  wend
  if reserveHero <> 0 then
    reserveTarget = reserveHero
  end if
  if reserveDirect <> 0 then
    reserveTarget = reserveDirect
  end if
  if (reserveGuards <= 1 or (reserveGuardCritical <> 0 and reserveDistance <= 900)) and reserveNearest <> 0 and reserveFinish = 0 then
    if reserveDistance <= 400 and reserveTarget <> 0 then
      attackTarget(reserveTarget)
    else
      walkTo(reserveX, reserveY)
    end if
  end if
end if

if recoveryInitialized <> 0 and selfAttacksLanded > recoveryLastHit then
  walkTo(selfX, selfY)
end if
recoveryLastHit = selfAttacksLanded
recoveryInitialized = 1

