' Rusher: send the whole team down mid together.
' Regroup above a 10-tile team diameter, closing to 8 tiles before resuming.
' Attack visible, vulnerable enemies within 20 tiles; otherwise attack-move.
' Use this policy for all five heroes on a team. Automatic spells stay enabled.


' Spend points explicitly, prioritizing the ultimate and primary spell.
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
        homeX = objectX(index)
        homeY = objectY(index)
      end if
      if objectKind(index) = 2 and objectAlive(index) then
        allyX(count) = objectX(index)
        allyY(count) = objectY(index)
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
    walkTo(centerX, centerY)
    exit sub
  end if

  bestId = 0
  bestDistance = 2147483647
  index = 0
  while index < objects
    if objectTeam(index) <> selfTeam and objectAlive(index) then
      x = objectX(index)
      y = objectY(index)
      dx = x - selfX
      dy = y - selfY
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
    attackTarget(bestId)
    exit sub
  end if

  ' Pass through the middle before pushing onward to the enemy god.
  middleX = mapWidth \ 2
  middleY = mapHeight \ 2
  dx = selfX - homeX
  dy = selfY - homeY
  if dx * dx + dy * dy <= 100 then
    crossedMiddle = 0
  end if
  dx = selfX - middleX
  dy = selfY - middleY
  if dx * dx + dy * dy <= 36 then
    crossedMiddle = 1
  end if
  if crossedMiddle then
    attackMove(mapWidth - 1 - homeX, mapHeight - 1 - homeY)
  else
    attackMove(middleX, middleY)
  end if
end sub

rush()
