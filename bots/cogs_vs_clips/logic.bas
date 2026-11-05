' Three aligners claim junctions sector by sector, four miners feed the bank
' one element each, and one scrambler frees enemy junctions. Each seat
' remembers what it has seen and routes over the known map with an A* search
' that resumes across ticks. Coordinates are padded: (y + 1) * 122 + x + 1.

data stepOffset = 0, -122, 1, 122, -1
data teamBit = 1, 2, 4, 8
data seatRole = 2, 2, 2, 1, 1, 1, 1, 3
data seatAligner = 0, 1, 2, 0, 0, 0, 0, 0
data gearOffset = 0, 1, -3, -1, 3
data gearCost = 0, 0, 0, 0, 1, 1, 3, 1, 3, 1, 1, 1, 1, 3, 1, 1, 1, 1, 1, 3

dim junctionOwner(175)
dim junctionSeen(175)
dim junctionSkip(175)
dim junctionLinked(175)
dim junctionGround(175)
dim extractorStock(511)
dim extractorSkip(511)
dim extractorGround(511)
dim extractorSeen(511)
dim searchMark(14883)
dim searchStep(14883)
dim searchCost(14883)
dim searchQueue(29767)
dim others(31)

sub observe()
  ' Refreshes remembered junction owners and extractor stock in view.
  firstX = (selfX - 6) \ 10
  if firstX < 0 then firstX = 0
  lastX = (selfX + 6) \ 10
  if lastX > 11 then lastX = 11
  firstY = (selfY - 6) \ 10
  if firstY < 0 then firstY = 0
  lastY = (selfY + 6) \ 10
  if lastY > 11 then lastY = 11
  for bucketY = firstY to lastY
    for bucketX = firstX to lastX
      bucket = bucketY * 12 + bucketX
      for seen = junctionBucket(bucket) to junctionBucket(bucket + 1) - 1
        dx = junctionX(seen) - selfX
        dy = junctionY(seen) - selfY
        if dx >= -6 and dx <= 6 and dy >= -6 and dy <= 6 then
          seenOwner = station(junctionX(seen), junctionY(seen), 1)
          if seenOwner >= 0 and seenOwner <> junctionOwner(seen) then
            junctionOwner(seen) = seenOwner
            junctionLinked(seen) = 0
            if seenOwner = team then junctionLinked(seen) = 1
          end if
          junctionSeen(seen) = tick + 1
          junctionGround(seen) = owner(junctionX(seen), junctionY(seen))
        end if
      next seen
      for seen = extractorBucket(bucket) to extractorBucket(bucket + 1) - 1
        dx = extractorX(seen) - selfX
        dy = extractorY(seen) - selfY
        if dx >= -6 and dx <= 6 and dy >= -6 and dy <= 6 then
          stock = station(extractorX(seen), extractorY(seen), 3)
          if stock < 0 then stock = 0
          extractorStock(seen) = stock
          extractorGround(seen) = owner(extractorX(seen), extractorY(seen))
          extractorSeen(seen) = tick + 1
        end if
      next seen
    next bucketX
  next bucketY
end sub

sub seeCogs()
  ' Lists the tiles of other visible Cogs, which block movement.
  otherCount = 0
  for seat = 0 to 31
    if seat <> mySeat then
      otherX = cog(seat, 0)
      if otherX >= 0 then
        others(otherCount) = (cog(seat, 1) + 1) * 122 + otherX + 1
        otherCount = otherCount + 1
      end if
    end if
  next seat
end sub

sub checkOccupied(occupiedTile)
  occupied = 0
  for otherIndex = 0 to otherCount - 1
    if others(otherIndex) = occupiedTile then
      occupied = 1
      exit sub
    end if
  next otherIndex
end sub

sub aim(aimTile, aimKind, aimIndex)
  ' Kinds: 0 gear, 1 hub, 2 junction, 3 extractor.
  target = aimTile
  targetKind = aimKind
  targetIndex = aimIndex
end sub

sub nearestFriend(safeOnly)
  ' Finds the closest friendly hub or owned junction, and how far friendly
  ' ground probably is. Only junctions last seen on our ground are safe.
  friendTile = hubTile
  friendKind = 1
  friendIndex = -1
  dx = selfX - hubX
  if dx < 0 then dx = -dx
  dy = selfY - hubY
  if dy < 0 then dy = -dy
  friendDistance = dx + dy
  edgeDistance = friendDistance - 12
  for friend = 0 to junctionCount - 1
    if junctionLinked(friend) = 1 then
      dx = junctionX(friend) - selfX
      if dx < 0 then dx = -dx
      dy = junctionY(friend) - selfY
      if dy < 0 then dy = -dy
      distance = dx + dy
      if junctionGround(friend) = team and tick + 1 - junctionSeen(friend) < 300 then
        if distance - 2 < edgeDistance then edgeDistance = distance - 2
      else
        if safeOnly = 1 then distance = 1000000
        distance = distance + 8
      end if
      if distance < friendDistance then
        friendDistance = distance
        friendTile = junctionTile(friend)
        friendKind = 2
        friendIndex = friend
      end if
    end if
  next friend
  if edgeDistance < 0 then edgeDistance = 0
end sub

sub checkSafety()
  ' Retreats when health would not last the walk back to friendly ground.
  retreat = 0
  ground = owner(selfX, selfY)
  if ground = team then exit sub
  nearestFriend(1)
  drain = 1
  if ground > 0 then drain = 2
  freeSteps = energy \ 4
  pace = 2
  if tick mod 200 >= 100 then pace = 4
  travel = edgeDistance * 5 \ 4
  if travel > freeSteps then travel = freeSteps + (travel - freeSteps) * pace
  if health <= travel * drain + 15 then retreat = 1
end sub

sub startSearch()
  ' Searches from the target toward this Cog, so every reached tile knows
  ' its next step. Queues hold f and f + 2 for unit steps and Manhattan h.
  searchId = searchId + 1
  searchTarget = target
  searchFailed = 0
  searchMark(target) = searchId
  searchStep(target) = 0
  searchCost(target) = 0
  frontBase = 0
  backBase = 14884
  frontHead = 0
  frontTail = 1
  backTail = 0
  searchQueue(0) = target
end sub

sub searchMore()
  goalY = here \ 122
  goalX = here - goalY * 122
  budget = searchBudget
  do while searchMark(here) <> searchId
    if budget <= 0 then exit do
    if frontHead >= frontTail then
      if backTail = 0 then
        searchFailed = 1
        exit do
      end if
      swapBase = frontBase
      frontBase = backBase
      backBase = swapBase
      frontHead = 0
      frontTail = backTail
      backTail = 0
    end if
    node = searchQueue(frontBase + frontHead)
    frontHead = frontHead + 1
    budget = budget - 1
    nodeY = node \ 122
    nodeX = node - nodeY * 122
    cost = searchCost(node) + 1
    probe = node - 122
    if passable(probe) = 1 then
      if searchMark(probe) <> searchId then
        searchMark(probe) = searchId
        searchStep(probe) = 3
        searchCost(probe) = cost
        if nodeY > goalY then
          searchQueue(frontBase + frontTail) = probe
          frontTail = frontTail + 1
        else
          searchQueue(backBase + backTail) = probe
          backTail = backTail + 1
        end if
      end if
    end if
    probe = node + 1
    if passable(probe) = 1 then
      if searchMark(probe) <> searchId then
        searchMark(probe) = searchId
        searchStep(probe) = 4
        searchCost(probe) = cost
        if nodeX < goalX then
          searchQueue(frontBase + frontTail) = probe
          frontTail = frontTail + 1
        else
          searchQueue(backBase + backTail) = probe
          backTail = backTail + 1
        end if
      end if
    end if
    probe = node + 122
    if passable(probe) = 1 then
      if searchMark(probe) <> searchId then
        searchMark(probe) = searchId
        searchStep(probe) = 1
        searchCost(probe) = cost
        if nodeY < goalY then
          searchQueue(frontBase + frontTail) = probe
          frontTail = frontTail + 1
        else
          searchQueue(backBase + backTail) = probe
          backTail = backTail + 1
        end if
      end if
    end if
    probe = node - 1
    if passable(probe) = 1 then
      if searchMark(probe) <> searchId then
        searchMark(probe) = searchId
        searchStep(probe) = 2
        searchCost(probe) = cost
        if nodeX > goalX then
          searchQueue(frontBase + frontTail) = probe
          frontTail = frontTail + 1
        else
          searchQueue(backBase + backTail) = probe
          backTail = backTail + 1
        end if
      end if
    end if
  loop
end sub

sub wander()
  ' Takes a random free step to break deadlocks.
  randomState = (randomState * 1103515245 + 12345) and 2147483647
  firstTurn = (randomState \ 65536) mod 4
  for turn = 0 to 3
    direction = (firstTurn + turn) mod 4 + 1
    probe = here + stepOffset(direction)
    if passable(probe) = 1 then
      checkOccupied(probe)
      if occupied = 0 then
        move = direction
        exit sub
      end if
    end if
  next turn
end sub

sub stepGreedy()
  ' Moves closer by Manhattan distance while the search is unfinished.
  targetY = target \ 122
  targetX = target - targetY * 122
  dx = selfX + 1 - targetX
  if dx < 0 then dx = -dx
  dy = selfY + 1 - targetY
  if dy < 0 then dy = -dy
  bestCost = dx + dy
  for direction = 1 to 4
    probe = here + stepOffset(direction)
    if passable(probe) = 1 then
      probeY = probe \ 122
      dx = probe - probeY * 122 - targetX
      if dx < 0 then dx = -dx
      dy = probeY - targetY
      if dy < 0 then dy = -dy
      if dx + dy < bestCost then
        checkOccupied(probe)
        if occupied = 0 then
          move = direction
          bestCost = dx + dy
        end if
      end if
    end if
  next direction
end sub

sub moveToward()
  ' Follows the search toward target; stepping into a station uses it.
  move = 0
  if target < 0 or target = here then exit sub
  if energy < 4 then exit sub
  if stuck >= 3 then
    wander()
    exit sub
  end if
  if target <> searchTarget then startSearch()
  if searchMark(here) <> searchId then searchMore()
  if searchFailed = 1 then exit sub
  if searchMark(here) <> searchId then
    stepGreedy()
    exit sub
  end if
  direction = searchStep(here)
  if here + stepOffset(direction) = target then
    move = direction
    exit sub
  end if
  checkOccupied(here + stepOffset(direction))
  if occupied = 0 then
    move = direction
    exit sub
  end if
  ' Blocked: take another step that is no farther, or sometimes wander.
  bestStep = 0
  bestCost = searchCost(here) + 1
  for direction = 1 to 4
    probe = here + stepOffset(direction)
    if passable(probe) = 1 then
      if searchMark(probe) = searchId then
        if searchCost(probe) < bestCost then
          checkOccupied(probe)
          if occupied = 0 then
            bestStep = direction
            bestCost = searchCost(probe)
          end if
        end if
      end if
    end if
  next direction
  if bestStep > 0 then
    move = bestStep
  else
    randomState = (randomState * 1103515245 + 12345) and 2147483647
    if (randomState \ 65536) mod 2 = 0 then wander()
  end if
end sub

sub pickJunction()
  ' Nearest neutral junction we can capture, favoring this aligner's sector.
  heavyWork = heavyWork + 1
  chosen = -1
  bestCost = 1000000
  for candidate = 0 to junctionCount - 1
    candidateOwner = junctionOwner(candidate)
    usable = 0
    if candidateOwner = 0 then usable = 1
    if candidateOwner <> 0 and candidateOwner <> team then
      if tick + 1 - junctionSeen(candidate) > 300 then usable = 2
    end if
    spotGround = junctionGround(candidate)
    if spotGround <> 0 and spotGround <> team then
      if tick + 1 - junctionSeen(candidate) <= 300 then usable = 0
    end if
    if usable > 0 and junctionSkip(candidate) <= tick then
      dx = junctionX(candidate) - selfX
      if dx < 0 then dx = -dx
      dy = junctionY(candidate) - selfY
      if dy < 0 then dy = -dy
      cost = dx + dy
      if usable = 2 then cost = cost + 25
      if junctionSector(teamIndex * junctionCount + candidate) <> alignerIndex then cost = cost + 20
      if candidate = targetJunction then cost = cost - 5
      if cost < bestCost then
        reach = 0
        if (junctionHubs(candidate) and teamMask) <> 0 then
          reach = 1
        else
          for near = alignStart(candidate) to alignStart(candidate + 1) - 1
            if junctionLinked(alignList(near)) = 1 then
              reach = 1
              exit for
            end if
          next near
        end if
        if reach = 1 then
          chosen = candidate
          bestCost = cost
        end if
      end if
    end if
  next candidate
end sub

sub pickEnemy()
  ' Nearest known enemy junction, else the stalest junction away from home.
  heavyWork = heavyWork + 1
  chosen = -1
  bestCost = 1000000
  for candidate = 0 to junctionCount - 1
    candidateOwner = junctionOwner(candidate)
    if candidateOwner <> 0 and candidateOwner <> team and junctionSkip(candidate) <= tick then
      dx = junctionX(candidate) - selfX
      if dx < 0 then dx = -dx
      dy = junctionY(candidate) - selfY
      if dy < 0 then dy = -dy
      cost = dx + dy
      dx = junctionX(candidate) - hubX
      if dx < 0 then dx = -dx
      dy = junctionY(candidate) - hubY
      if dy < 0 then dy = -dy
      cost = cost + (dx + dy) \ 2
      if candidate = targetJunction then cost = cost - 5
      if cost < bestCost then
        chosen = candidate
        bestCost = cost
      end if
    end if
  next candidate
  if chosen >= 0 then exit sub
  for candidate = 0 to junctionCount - 1
    if junctionOwner(candidate) <> team and junctionSkip(candidate) <= tick then
      if junctionSeen(candidate) = 0 or tick + 1 - junctionSeen(candidate) > 400 then
        dx = junctionX(candidate) - selfX
        if dx < 0 then dx = -dx
        dy = junctionY(candidate) - selfY
        if dy < 0 then dy = -dy
        cost = dx + dy
        dx = junctionX(candidate) - hubX
        if dx < 0 then dx = -dx
        dy = junctionY(candidate) - hubY
        if dy < 0 then dy = -dy
        cost = cost - (dx + dy) \ 2
        if cost < bestCost then
          chosen = candidate
          bestCost = cost
        end if
      end if
    end if
  next candidate
end sub

sub pickPatrol()
  ' Revisits the linked junction seen longest ago.
  chosen = -1
  bestCost = 1000000
  for candidate = 0 to junctionCount - 1
    if junctionLinked(candidate) = 1 then
      dx = junctionX(candidate) - selfX
      if dx < 0 then dx = -dx
      dy = junctionY(candidate) - selfY
      if dy < 0 then dy = -dy
      cost = junctionSeen(candidate) + 4 * (dx + dy)
      if cost < bestCost then
        chosen = candidate
        bestCost = cost
      end if
    end if
  next candidate
end sub

sub pickExtractor()
  ' Mines this seat's element unless the bank is long on it.
  heavyWork = heavyWork + 1
  lowest = 0
  for element = 1 to 3
    if bank(element) < bank(lowest) then lowest = element
  next element
  wanted = minerElement
  if bank(wanted) >= bank(lowest) + 20 then wanted = lowest
  targetExtractor = -1
  bestCost = 1000000
  for candidate = 0 to extractorCount - 1
    if extractorElement(candidate) = wanted then
      spotGround = extractorGround(candidate)
      if spotGround <> 0 and spotGround <> team then
        if tick + 1 - extractorSeen(candidate) <= 300 then spotGround = -1
      end if
      if extractorStock(candidate) > 0 and extractorSkip(candidate) <= tick and spotGround >= 0 then
        dx = extractorX(candidate) - selfX
        if dx < 0 then dx = -dx
        dy = extractorY(candidate) - selfY
        if dy < 0 then dy = -dy
        cost = dx + dy
        dx = extractorX(candidate) - hubX
        if dx < 0 then dx = -dx
        dy = extractorY(candidate) - hubY
        if dy < 0 then dy = -dy
        cost = cost + (dx + dy) \ 2
        if dx + dy > 30 then cost = cost + (dx + dy - 30) * 2
        if cost < bestCost then
          targetExtractor = candidate
          bestCost = cost
        end if
      end if
    end if
  next candidate
end sub

sub planMiner()
  full = 40
  if role <> 1 then full = 4
  if carried >= full then delivering = 1
  if carried = 0 and delivering = 1 then
    delivering = 0
    targetExtractor = -1
  end if
  if delivering = 1 then
    nearestFriend(0)
    aim(friendTile, friendKind, friendIndex)
    exit sub
  end if
  needPick = 0
  if targetExtractor < 0 then
    needPick = 1
  else
    if extractorStock(targetExtractor) = 0 or extractorSkip(targetExtractor) > tick then needPick = 1
  end if
  if needPick = 1 then pickExtractor()
  if targetExtractor >= 0 then
    aim(extractorTile(targetExtractor), 3, targetExtractor)
  elseif carried > 0 then
    delivering = 1
    nearestFriend(0)
    aim(friendTile, friendKind, friendIndex)
  end if
end sub

sub planHearts()
  ' Aligners and the scrambler load hearts at the hub, then spend them.
  heartCap = 3
  if tick >= 150 and desiredRole = 2 then heartCap = 5
  if hearts = 0 then loading = 1
  if loading = 1 then
    if hearts >= heartCap then loading = 0
    if heartFailed = 1 and hearts > 0 then loading = 0
  end if
  if loading = 1 then
    if poolEmpty = 0 or craftable = 1 then
      aim(hubTile, 1, -1)
      exit sub
    end if
    if hearts > 0 then loading = 0
  end if
  if loading = 0 then
    ' Keep a valid target and only re-pick every fifth tick.
    chosen = -1
    if targetJunction >= 0 and (tick + seatSlot) mod 5 <> 0 then
      if junctionSkip(targetJunction) <= tick then
        if desiredRole = 2 and junctionOwner(targetJunction) = 0 then chosen = targetJunction
        if desiredRole = 3 and junctionOwner(targetJunction) <> 0 and junctionOwner(targetJunction) <> team then chosen = targetJunction
      end if
    end if
    if chosen < 0 then
      if desiredRole = 2 then
        pickJunction()
      else
        pickEnemy()
      end if
    end if
    if chosen >= 0 then
      targetJunction = chosen
      aim(junctionTile(chosen), 2, chosen)
      exit sub
    end if
  end if
  pickPatrol()
  if chosen >= 0 then aim(junctionTile(chosen), 2, chosen)
end sub

' Every tick: read the Cog, remember what is visible, choose, then act.
mySeat = self(0)
tick = self(1)
selfX = self(2)
selfY = self(3)
role = self(4)
health = self(5)
energy = self(6)
hearts = self(7)
team = self(8)
teamIndex = team - 1
teamMask = teamBit(teamIndex)
hubX = 29 + 60 * (teamIndex mod 2)
hubY = 29 + 60 * (teamIndex \ 2)
hubTile = (hubY + 1) * 122 + hubX + 1
here = (selfY + 1) * 122 + selfX + 1
seatSlot = mySeat mod 8
carried = cargo(0) + cargo(1) + cargo(2) + cargo(3)
poorest = bank(0)
for element = 1 to 3
  if bank(element) < poorest then poorest = bank(element)
next element
' Crafting keeps a reserve so every seat can still buy gear after dying.
craftable = 0
if poorest >= 19 then craftable = 1
' Two miners turn aligner and scrambler while the bank has hearts to spare.
if seatSlot = 5 or seatSlot = 6 then
  if poorest >= 80 then extraAligner = 1
  if poorest < 15 or carried > 0 then extraAligner = 0
end if
desiredRole = seatRole(seatSlot)
alignerIndex = seatAligner(seatSlot)
if extraAligner = 1 then
  desiredRole = 2
  if seatSlot = 6 then desiredRole = 3
end if
minerElement = (seatSlot + 1) mod 4

if started = 0 then
  for stockIndex = 0 to extractorCount - 1
    extractorStock(stockIndex) = 100
  next stockIndex
  started = 1
  searchTarget = -1
  targetJunction = -1
  targetExtractor = -1
  lastBumpJunction = -1
  lastBumpExtractor = -1
  randomState = mySeat * 7919 + 17
end if

heavyWork = 0
observe()
seeCogs()

' Learn from last tick's bump.
heartFailed = 0
if lastEnergy >= 4 then
  if lastBumpHub = 1 and hearts <= lastHearts then
    heartFailed = 1
    if lastCraftable = 0 then poolEmpty = 1
  end if
  if lastBumpJunction >= 0 and hearts >= lastHearts and desiredRole <> 1 then
    junctionSkip(lastBumpJunction) = tick + 150
  end if
  if lastBumpExtractor >= 0 and carried <= lastCarried then
    extractorSkip(lastBumpExtractor) = tick + 60
  end if
end if
if here = lastHere and lastMoved = 1 then
  stuck = stuck + 1
else
  stuck = 0
end if

aim(-1, 0, -1)
if role <> desiredRole then
  missing = -1
  for element = 0 to 3
    if bank(element) < gearCost(desiredRole * 4 + element) then missing = element
  next element
  if carried > 0 then
    delivering = 1
    planMiner()
  elseif missing < 0 then
    aim(hubTile + 4 * 122 + gearOffset(desiredRole), 0, -1)
  else
    ' The bank cannot pay for gear: carry the missing element by hand.
    minerElement = missing
    if targetExtractor >= 0 then
      if extractorElement(targetExtractor) <> missing then targetExtractor = -1
    end if
    planMiner()
  end if
else
  checkSafety()
  if retreat = 1 then
    aim(friendTile, friendKind, friendIndex)
  elseif desiredRole = 1 then
    planMiner()
  else
    planHearts()
  end if
  ' Only the scrambler works on enemy ground; others drop the job and leave.
  nearTarget = 0
  if target >= 0 then
    targetY = target \ 122
    dx = target - targetY * 122 - 1 - selfX
    if dx < 0 then dx = -dx
    dy = targetY - 1 - selfY
    if dy < 0 then dy = -dy
    if dx + dy <= 12 then nearTarget = 1
  end if
  if retreat = 0 and nearTarget = 1 and ground > 0 and ground <> team and desiredRole <> 3 then
    if targetKind = 2 then junctionSkip(targetIndex) = tick + 400
    if targetKind = 3 then extractorSkip(targetIndex) = tick + 400
    if targetKind >= 2 then
      nearestFriend(1)
      aim(friendTile, friendKind, friendIndex)
    end if
  end if
end if

searchBudget = 200 - 80 * heavyWork
moveToward()
if searchFailed = 1 then
  if targetKind = 2 then junctionSkip(targetIndex) = tick + 300
  if targetKind = 3 then extractorSkip(targetIndex) = tick + 300
  searchTarget = -1
  searchFailed = 0
  wander()
end if
act(move)

lastBumpHub = 0
lastBumpJunction = -1
lastBumpExtractor = -1
lastMoved = 0
if move > 0 then
  if here + stepOffset(move) = target then
    if targetKind = 1 then lastBumpHub = 1
    if targetKind = 2 then lastBumpJunction = targetIndex
    if targetKind = 3 then lastBumpExtractor = targetIndex
  else
    lastMoved = 1
  end if
end if
lastHere = here
lastHearts = hearts
lastCarried = carried
lastEnergy = energy
lastCraftable = craftable
