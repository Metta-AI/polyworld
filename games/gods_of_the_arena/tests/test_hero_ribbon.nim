## Production HUD placement must reserve only occupied hero cards.
include ../ui

run = Game(world: World(phase: Playing, heroes: @[
  Hero(id: 104, team: RedTeam, slot: 3),
  Hero(id: 109, team: BlueTeam, slot: 4)
]))
let layout = initGameUiLayout(vec2(1920, 1080))
let placed = placeChrome(layout)
doAssert placed.heroes.size == vec2(258, 142),
  "1v1 ribbon must fit two 100px cards, 34px versus gap and 12px outer padding, not ten seats: " & $placed.heroes.size
doAssert placed.heroes.origin.x == 831

let cards = placed.heroes.heroPanels(1, 1)
doAssert run.world.heroes[0].heroCardIndex == 0,
  "Stable red slot 3 is the first occupied red card"
doAssert run.world.heroes[1].heroCardIndex == 5,
  "Stable blue slot 4 is the first occupied blue card"
doAssert cards[0].name.origin.x == placed.heroes.origin.x + 12
doAssert cards[5].name.origin.x == placed.heroes.origin.x + 146
doAssert cards[5].mana.origin.x + cards[5].mana.size.x ==
  placed.heroes.origin.x + placed.heroes.size.x - 12

block:
  let narrow = initGameUiLayout(vec2(1600, 1080))
  doAssert placeChrome(narrow).score.origin.y == narrow.margin,
    "Sparse ribbon must not reserve the full-roster score collision space"
let uiSource = readFile("games/gods_of_the_arena/ui.nim")
doAssert "heroesPanel.origin + vec2(532, 57)" notin uiSource,
  "Versus must follow the occupied red/blue divider rather than full-roster coordinates"

doAssert "let nameWidth = heroes[0].name.size.x" notin uiSource,
  "Blue-only matches must still fit names to an occupied card"

for scenario in [
  (red: @[3], blue: @[4], width: 258),
  (red: @[4], blue: @[1, 4], width: 362),
  (red: @[2], blue: newSeq[int](), width: 158),
  (red: newSeq[int](), blue: @[0, 2, 4], width: 366),
  (red: @[0, 1, 2, 3, 4], blue: @[0, 1, 2, 3, 4], width: 1090)
]:
  # Interleave teams and reverse their packed order to catch index/seat confusion.
  run.world.heroes.setLen(0)
  for slot in countdown(4, 0):
    for team in Team:
      let slots = if team == RedTeam: scenario.red else: scenario.blue
      if slot in slots:
        run.world.heroes.add Hero(id: int32(100 + team.ord * 5 + slot),
          team: team, slot: slot, hp: int32(30 + slot), maxHp: 100)
  for viewport in [vec2(1600, 1080), vec2(1920, 1080), vec2(2560, 1440)]:
    let
      frame = initGameUiLayout(viewport)
      hud = placeChrome(frame)
      plate = hud.heroes
      cells = plate.heroPanels(scenario.red.len, scenario.blue.len)
      vs = plate.heroVersusPanel(scenario.red.len)
    doAssert plate.size == vec2(scenario.width.float32, 142)
    doAssert plate.origin.x == floor((viewport.x - plate.size.x) / 2)
    var used: array[10, bool]
    for packedIndex, hero in run.world.heroes:
      let
        cardIndex = hero.heroCardIndex
        cell = cells[cardIndex]
        slots = if hero.team == RedTeam: scenario.red else: scenario.blue
        rank = slots.find(hero.slot)
        teamStart = if hero.team == RedTeam: plate.origin.x + 12
                    else: vs.origin.x + vs.size.x + 4
      doAssert cardIndex == hero.team.ord * 5 + rank
      doAssert not used[cardIndex]
      used[cardIndex] = true
      doAssert cell.name.origin.x == teamStart + rank.float32 * 104
      doAssert cell.name.size == vec2(100, 18)
      doAssert cell.hp.size == vec2(100, 16)
      doAssert cell.mana.size == cell.hp.size
      for target in [cell.portrait, cell.name, cell.hp, cell.mana]:
        doAssert target.origin.x >= plate.origin.x
        doAssert target.origin.x + target.size.x <= plate.origin.x + plate.size.x
        doAssert target.contains(target.origin + target.size / 2)
      if hero.team == RedTeam:
        doAssert cell.name.origin.x + cell.name.size.x <= vs.origin.x - 4
      else:
        doAssert cell.name.origin.x >= vs.origin.x + vs.size.x + 4
      # The same entity goes to portrait selection and meters regardless of rank.
      var primary = 0'i32
      var picked: seq[int32]
      var follow = false
      selectHeroCard(primary, picked, follow, hero.id, false)
      doAssert primary == hero.id and picked == @[hero.id] and follow
      doAssert run.world.heroes[packedIndex].hp == int32(30 + hero.slot)
    for i, usedCard in used:
      if not usedCard:
        doAssert cells[i].portrait.size == vec2(0)
        doAssert cells[i].name.size == vec2(0)
    # No invisible ten-seat hit reservation outside the compact plate.
    doAssert not mouseOverPanels(plate.origin - vec2(1, -70), frame, [plate])
    doAssert mouseOverPanels(plate.origin + plate.size / 2, frame, [plate])
    if scenario.width == 1090:
      doAssert plate.size == PanelHeroes
      doAssert vs.origin == plate.origin + vec2(532, 57)
      doAssert frame.scorePanel() == hud.score
      doAssert plate.heroPanels() == cells
    echo "PASS ", scenario.red.len, "v", scenario.blue.len,
      " at ", viewport, " width=", plate.size.x

doAssert "heroesPanel.heroPanels(counts[RedTeam], counts[BlueTeam])" in uiSource
doAssert "heroes[hero.heroCardIndex]" in uiSource
doAssert "fittedNames[slot]" in uiSource

echo "Sparse hero ribbon placement, team mapping, selection and hit bounds passed"
