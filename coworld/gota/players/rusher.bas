' Rusher: send the whole team down mid together.
' Regroup above a 10-tile team diameter, closing to 8 tiles before resuming.
' Attack visible, vulnerable enemies within 20 tiles; otherwise attack-move.
' Use this policy for all five heroes on a team. It uses basic attacks only.


' Draft roles: 0 frontline, 1 carry, 2 mage, 3 support, 4 fighter.
' Prefer roles missing from our team, independent of faction.
sub chooseHero()
  if draftTurnId <> selfId then
    exit sub
  end if
  bestClass = -1
  bestScore = -2147483647
  candidate = 0
  while candidate < 10
    if heroAvailable(candidate) then
      role = heroRole(candidate)
      score = 100
      player = 0
      while player < draftPlayerCount()
        if draftPlayerTeam(player) = selfTeam then
          picked = draftedClass(draftPlayerId(player))
          if picked >= 0 then
            if heroRole(picked) = role then
              score = score - 100
            end if
          end if
        end if
        player = player + 1
      wend
      if score > bestScore then
        bestScore = score
        bestClass = candidate
      end if
    end if
    candidate = candidate + 1
  wend
  if bestClass >= 0 then
    draftHero(bestClass)
  end if
end sub

if drafting then
  chooseHero()
  end
end if

' Use the same team-relative coordinates for every spatial decision.
side = 1 - selfTeam * 2
originX = selfTeam * (mapWidth - 1)
originY = selfTeam * (mapHeight - 1)
myX = originX + side * selfX
myY = originY + side * selfY

' Spend points explicitly, prioritizing the ultimate and primary spell.
for upgrade = 1 to 4
  if canLevelAbility(3) then
    levelAbility(3)
  elseif canLevelAbility(0) then
    levelAbility(0)
  elseif canLevelAbility(1) then
    levelAbility(1)
  elseif canLevelAbility(2) then
    levelAbility(2)
  end if
next upgrade

' Keep marching orders until their destination changes or the route ends.
sub moveTo(goalX, goalY, marching)
  if orderActive and selfInfo(5) then
    if goalX = orderX and goalY = orderY and marching = orderMarch then
      exit sub
    end if
  end if
  if marching then
    accepted = attackMove(originX + side * goalX, originY + side * goalY)
  else
    accepted = walkTo(originX + side * goalX, originY + side * goalY)
  end if
  if accepted then
    orderActive = 1
    orderX = goalX
    orderY = goalY
    orderMarch = marching
  end if
end sub

if selfHp <= 0 then
  orderActive = 0
  crossedMiddle = 0
  end
end if

dim allyX(9)
dim allyY(9)

sub rush()
  count = 0
  sumX = 0
  sumY = 0
  index = 0
  objects = objectCount()
  while index < objects
    if objectTeam(index) = selfTeam then
      if objectKind(index) = 1 then
        homeX = originX + side * objectX(index)
        homeY = originY + side * objectY(index)
      end if
      if objectKind(index) = 2 and objectAlive(index) then
        allyX(count) = originX + side * objectX(index)
        allyY(count) = originY + side * objectY(index)
        sumX = sumX + allyX(count)
        sumY = sumY + allyY(count)
        count = count + 1
      end if
    end if
    index = index + 1
  wend

  if count = 0 then
    exit sub
  end if
  centerX = sumX \ count
  centerY = sumY \ count
  diameter = 0
  first = 0
  while first < count
    second = first + 1
    while second < count
      dx = allyX(first) - allyX(second)
      dy = allyY(first) - allyY(second)
      distance = dx * dx + dy * dy
      if distance > diameter then
        diameter = distance
      end if
      second = second + 1
    wend
    first = first + 1
  wend
  if diameter > 100 then
    regroup = 1
  end if
  if diameter <= 64 then
    regroup = 0
  end if
  if regroup then
    moveTo(centerX, centerY, 0)
    exit sub
  end if

  bestId = 0
  bestDistance = 2147483647
  index = 0
  while index < objects
    if objectTeam(index) <> selfTeam and objectAlive(index) then
      x = originX + side * objectX(index)
      y = originY + side * objectY(index)
      dx = x - myX
      dy = y - myY
      if dx * dx + dy * dy <= 400 then
        dx = x - centerX
        dy = y - centerY
        distance = dx * dx + dy * dy
        if distance < bestDistance then
          bestDistance = distance
          bestId = objectId(index)
        end if
      end if
    end if
    index = index + 1
  wend
  if bestId <> 0 then
    if selfTarget <> bestId then
      accepted = attackTarget(bestId)
      if accepted then
        orderActive = 0
      end if
    end if
    exit sub
  end if

  ' Pass through the middle before pushing onward to the enemy god.
  middleX = mapWidth \ 2
  middleY = mapHeight \ 2
  dx = myX - homeX
  dy = myY - homeY
  if dx * dx + dy * dy <= 100 then
    crossedMiddle = 0
  end if
  dx = myX - middleX
  dy = myY - middleY
  if dx * dx + dy * dy <= 36 then
    crossedMiddle = 1
  end if
  if crossedMiddle then
    moveTo(mapWidth - 1 - homeX, mapHeight - 1 - homeY, 1)
  else
    moveTo(middleX, middleY, 1)
  end if
end sub

rush()
