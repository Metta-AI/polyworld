' Gods of the Arena moba-style hero harness for PufferLib training and
' league play. polyworld's examples/gods_of_the_arena/harness.nim is a
' native port that must stay identical; tests/test_gota_harness.nim there
' proves it tick by tick. Every tick the script writes a moba-style
' observation to obs() and applies ten action heads from act(). The
' policy fills act() where the METTA_DECISION marker sits: the training
' lane swaps in a chooseAction(obs, act) host call. The draft and ability
' levelling are hero.bas's scripted subs, unchanged. Integer arithmetic
' only: the training VM disables decimals. obs() alone holds 4392 cells,
' above the 4096 array cells a default hero VM allows.

dim obs(4391)
dim act(9)
dim castRange(4)
dim codeRank(9)
dim itemCost(22)
dim touched(1088)

' obs(0..4355) is a 33 x 33 grid of tiles around the hero, the full
' vision radius of 16 tiles, in four channels,
' obs(channel * 1089 + row * 33 + column). An object on the tile at offset
' (dx, dy) from the hero lands in column dx + 16, row dy + 16, both
' mirrored for team 1 so every hero sees its own base toward the same side.
'   Channel 0: 1 when the tile is walkable.
'   Channel 1: the occupant, highest rank first, ties keep the lower object:
'     0 none, 1 ally hero (self at the centre), 2 enemy hero, 3 ally creep,
'     4 enemy creep, 5 neutral, 6 ally structure, 7 enemy structure,
'     8 ally god, 9 enemy god. Rank: god, hero, structure, creep.
'   Channel 2: the occupant's hp * 10 \ max hp.
'   Channel 3: objects on the tile, at most 9.
'   Objects count while their hp is above zero, so towers and gods that
'   cannot be hit yet still show.
' obs(4356..4391) are self scalars: tile x and y (mirrored for team 1),
' level, hp * 10 \ max hp, mana * 10 \ max mana, gold \ 100 (at most 255),
' level, charges and cooldown seconds of ability slots 0..3, ability
' points, root, stun and silence seconds, team, a one-hot of class 0..9,
' deaths, in own spawn, and match minutes.
' act(0) and act(1) move dy and dx: bin - 3 steps of 3 tiles, mirrored
' like the grid. act(2) picks the target among attackable enemies within
' 8 tiles: 0 none, 1 the nearest of any kind, 2 the nearest hero,
' structure or god. act(3..6) cast ability slots 0..3. act(7) buys item
' 1..22 (0 none), act(8) uses inventory slot act(8) - 1 (0 none), and
' act(9) = 1 buys the hero back while dead. Each tick: buyback, use, buy,
' then cast, else move, else attack.

sub chooseHero()
  if draftTurnId <> selfId then
    exit sub
  end if
  bestClass = -1
  bestScore = -10000
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      role = heroRole(candidate)
      score = 100
      for player = 0 to draftPlayerCount() - 1
        if draftPlayerTeam(player) = selfTeam then
          picked = draftedClass(draftPlayerId(player))
          if picked >= 0 then
            if heroRole(picked) = role then
              score = score - 100
            end if
          end if
        end if
      next player
      if score > bestScore then
        bestScore = score
        bestClass = candidate
      end if
    end if
  next candidate
  if bestClass >= 0 then
    accepted = draftHero(bestClass)
  end if
end sub

sub learnAbilities()
  for upgrade = 1 to 4
    if abilityPoints() = 0 then
      exit sub
    end if
    if canLevelAbility(3) then
      accepted = levelAbility(3)
    elseif canLevelAbility(1) then
      accepted = levelAbility(1)
    elseif canLevelAbility(2) then
      accepted = levelAbility(2)
    elseif canLevelAbility(0) then
      accepted = levelAbility(0)
    else
      exit sub
    end if
  next upgrade
end sub

sub readObject(index)
  ' The caller placed the object inside the grid at (dx, dy).
  hp = objectHp(index)
  if hp <= 0 then
    exit sub
  end if
  kind = objectKind(index)
  team = objectTeam(index)
  cell = (dy + 16) * 33 + dx + 16
  if kind = 1 then
    code = 9
  elseif kind = 2 then
    code = 2
  elseif kind = 3 then
    code = 4
  elseif kind = 6 then
    code = 5
  else
    code = 7
  end if
  if team = selfTeam then
    code = code - 1
  end if
  if codeRank(code) > codeRank(obs(1089 + cell)) then
    obs(1089 + cell) = code
    health = 0
    maxHp = objectInfo(index, 2)
    if maxHp > 0 then
      health = hp * 10 \ maxHp
    end if
    if health > 10 then
      health = 10
    end if
    obs(2178 + cell) = health
  end if
  if obs(3267 + cell) = 0 then
    touched(touchedCount) = cell
    touchedCount = touchedCount + 1
  end if
  if obs(3267 + cell) < 9 then
    obs(3267 + cell) = obs(3267 + cell) + 1
  end if
  if team = selfTeam then
    exit sub
  end if
  if objectAlive(index) = 0 then
    exit sub
  end if
  distance = dx * dx + dy * dy
  if distance < enemyDistance then
    enemyDistance = distance
    enemyId = objectId(index)
    enemyX = x
    enemyY = y
  end if
  if kind <> 3 and kind <> 6 then
    if distance < priorityDistance then
      priorityDistance = distance
      priorityId = objectId(index)
      priorityX = x
      priorityY = y
    end if
  end if
end sub

sub prepareTables()
  ' Occupant ranks by code, and item prices from content.nim, which the
  ' BASIC API does not expose; polyworld's parity test checks them.
  codeRank(1) = 3
  codeRank(2) = 3
  codeRank(3) = 1
  codeRank(4) = 1
  codeRank(5) = 1
  codeRank(6) = 2
  codeRank(7) = 2
  codeRank(8) = 4
  codeRank(9) = 4
  itemCost(1) = 30
  itemCost(2) = 75
  itemCost(3) = 90
  itemCost(4) = 40
  itemCost(5) = 80
  itemCost(6) = 90
  itemCost(7) = 70
  itemCost(8) = 100
  itemCost(9) = 120
  itemCost(10) = 120
  itemCost(11) = 110
  itemCost(12) = 140
  itemCost(13) = 150
  itemCost(14) = 150
  itemCost(15) = 140
  itemCost(16) = 160
  itemCost(17) = 170
  itemCost(18) = 180
  itemCost(19) = 180
  itemCost(20) = 190
  itemCost(21) = 100
  itemCost(22) = 45
  tablesReady = 1
end sub

sub observe()
  ' Channel 0 is rewritten whole; channels 1..3 clear only last tick's cells.
  for i = 0 to touchedCount - 1
    cell = touched(i)
    obs(1089 + cell) = 0
    obs(2178 + cell) = 0
    obs(3267 + cell) = 0
  next i
  touchedCount = 0
  cell = 0
  tileY = selfY - side * 16
  for row = 0 to 32
    tileX = selfX - side * 16
    if tileY >= 0 and tileY < mapHeight then
      for column = 0 to 32
        if tileX >= 0 and tileX < mapWidth then
          obs(cell) = terrainWalkable(tileX, tileY)
        else
          obs(cell) = 0
        end if
        tileX = tileX + side
        cell = cell + 1
      next column
    else
      for column = 0 to 32
        obs(cell) = 0
        cell = cell + 1
      next column
    end if
    tileY = tileY + side
  next row
  enemyId = 0
  enemyDistance = 65
  priorityId = 0
  priorityDistance = 65
  objects = objectCount()
  for index = 0 to objects - 1
    x = objectX(index)
    dx = side * (x - selfX)
    if dx >= -16 and dx <= 16 then
      y = objectY(index)
      dy = side * (y - selfY)
      if dy >= -16 and dy <= 16 then
        readObject(index)
      end if
    end if
  next index
  if side = 1 then
    obs(4356) = selfX
    obs(4357) = selfY
  else
    obs(4356) = mapWidth - 1 - selfX
    obs(4357) = mapHeight - 1 - selfY
  end if
  obs(4358) = selfLevel
  obs(4359) = 0
  if selfMaxHp > 0 then
    obs(4359) = selfHp * 10 \ selfMaxHp
  end if
  obs(4360) = 0
  if selfMaxMana > 0 then
    obs(4360) = selfMana * 10 \ selfMaxMana
  end if
  obs(4361) = selfGold \ 100
  if obs(4361) > 255 then
    obs(4361) = 255
  end if
  for slot = 0 to 3
    obs(4362 + slot * 3) = abilityLevel(slot)
    obs(4363 + slot * 3) = abilityCharges(slot)
    obs(4364 + slot * 3) = abilityCooldown(slot) \ tickRate
  next slot
  obs(4374) = abilityPoints()
  obs(4375) = selfRootTicks \ tickRate
  obs(4376) = selfStunTicks \ tickRate
  obs(4377) = selfSilenceTicks \ tickRate
  obs(4378) = selfTeam
  for class = 0 to 9
    obs(4379 + class) = 0
    if selfClass = class then
      obs(4379 + class) = 1
    end if
  next class
  obs(4389) = selfDeaths
  obs(4390) = inOwnSpawn()
  obs(4391) = worldTick \ (tickRate * 60)
end sub

sub shop()
  if act(8) > 0 then
    itemSlot = act(8) - 1
    if itemId(itemSlot) <> 0 and itemCooldown(itemSlot) = 0 then
      accepted = useItem(itemSlot)
    end if
  end if
  if act(7) > 0 then
    if canShop() then
      if selfGold >= itemCost(act(7)) then
        accepted = buyItem(act(7))
      end if
    end if
  end if
end sub

sub castSpells()
  casted = 0
  for spellSlot = 0 to 3
    if act(3 + spellSlot) = 1 then
      if abilityLevel(spellSlot) > 0 and abilityCharges(spellSlot) > 0 then
        if abilityCooldown(spellSlot) = 0 and selfMana >= abilityManaCost(spellSlot) then
          accepted = 0
          healing = abilityHeal(spellSlot)
          restore = abilityRestore(spellSlot)
          damage = abilityDamage(spellSlot)
          if healing > 0 or restore > 0 then
            accepted = castTarget(spellSlot, selfId)
          elseif damage > 0 and bestId <> 0 then
            reach = castRange(spellSlot)
            if bestDistance <= reach * reach then
              if spellSlot >= 2 then
                accepted = castPoint(spellSlot, bestX, bestY)
              else
                accepted = castTarget(spellSlot, bestId)
              end if
            end if
          end if
          if accepted then
            casted = 1
            exit sub
          end if
        end if
      end if
    end if
  next spellSlot
end sub

sub move()
  moveY = act(0) - 3
  moveX = act(1) - 3
  if moveX = 0 and moveY = 0 then
    if bestId <> 0 then
      if selfTarget <> bestId then
        accepted = attackTarget(bestId)
      end if
    end if
    exit sub
  end if
  if selfRootTicks > 0 then
    exit sub
  end if
  goalX = selfX + side * moveX * 3
  goalY = selfY + side * moveY * 3
  ' The same fallbacks as hero.bas travel(): the goal, then 3 tiles off it.
  for attempt = 0 to 4
    tryX = goalX
    tryY = goalY
    if attempt = 1 then
      tryX = goalX + 3
    elseif attempt = 2 then
      tryX = goalX - 3
    elseif attempt = 3 then
      tryY = goalY + 3
    elseif attempt = 4 then
      tryY = goalY - 3
    end if
    if tryX < 1 then
      tryX = 1
    end if
    if tryY < 1 then
      tryY = 1
    end if
    if tryX > mapWidth - 2 then
      tryX = mapWidth - 2
    end if
    if tryY > mapHeight - 2 then
      tryY = mapHeight - 2
    end if
    if terrainWalkable(tryX, tryY) then
      accepted = walkTo(tryX, tryY)
      if accepted then
        exit sub
      end if
    end if
  next attempt
end sub

if drafting then
  chooseHero()
  end
end if
if tablesReady = 0 then
  prepareTables()
end if
side = 1 - selfTeam * 2
observe()
' METTA_DECISION

if selfHp <= 0 then
  if act(9) = 1 then
    price = buybackPrice()
    if price > 0 and selfGold >= price then
      accepted = buyback()
    end if
  end if
  initialized = 0
  end
end if
if selfChannelTicks > 0 or selfStunTicks > 0 then
  end
end if

if initialized = 0 then
  initialized = 1
  ' Cast reach in whole tiles per slot, rounded down from content.nim.
  castRange(0) = 0
  castRange(1) = 1
  castRange(2) = 2
  castRange(3) = 2
  if selfClass = 1 then
    castRange(0) = 7
    castRange(1) = 6
    castRange(2) = 6
    castRange(3) = 8
  elseif selfClass = 2 then
    castRange(1) = 5
    castRange(2) = 6
    castRange(3) = 7
  elseif selfClass = 3 then
    castRange(3) = 3
  elseif selfClass = 4 then
    castRange(3) = 5
  elseif selfClass = 6 then
    castRange(0) = 7
    castRange(1) = 6
    castRange(2) = 6
    castRange(3) = 7
  elseif selfClass = 7 then
    castRange(0) = 6
    castRange(1) = 6
    castRange(2) = 5
    castRange(3) = 6
  elseif selfClass = 8 then
    castRange(1) = 4
    castRange(2) = 4
    castRange(3) = 5
  end if
end if

learnAbilities()
shop()
' The chosen target for casts and attacks.
bestId = 0
if act(2) = 1 then
  bestId = enemyId
  bestX = enemyX
  bestY = enemyY
  bestDistance = enemyDistance
elseif act(2) = 2 then
  bestId = priorityId
  bestX = priorityX
  bestY = priorityY
  bestDistance = priorityDistance
end if
castSpells()
if casted = 0 then
  move()
end if
