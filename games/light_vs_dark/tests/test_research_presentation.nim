import std/[unittest, strutils]
import vmath
import polyworld/gameuis
import ../researchpresentation
import ../[content, sim, maps]

suite "Authoritative research HUD data":
  test "research coverage tooltips and explicit temporary icon keys":
    let w = newWorld(generateMap(DefaultSeed), TickRate * 600)
    let card = w.researchCard(0, NoEntity, TemperedEdges)
    when declared(researchDetails):
      let detail = researchDetails(TemperedEdges, 0, card, true)
      check "Soldier, Knight, Cleric and Mage" in detail.description
      check "Temporary icon" in detail.subtitle
      check "buildings" in researchDetails(RunedPlating, 0, card, false).description
      check "base" in researchDetails(WindrunnerTraining, 0, card, false).description
    else:
      check false # missing content-backed research tooltip
  test "selected live stats reflect player research including fixed-point speed":
    let w = newWorld(generateMap(DefaultSeed), TickRate * 600)
    when declared(selectedResearchStats):
      let before = w.selectedResearchStats(0, KnightUnit)
      w.players[0].researchLevels[TemperedEdges] = 2
      w.players[0].researchLevels[RunedPlating] = 3
      w.players[0].researchLevels[WindrunnerTraining] = 3
      let after = w.selectedResearchStats(0, KnightUnit)
      check after != before
      check after[0] == "Basic: " & $(unitOf(0, KnightUnit).basic + 4)
      check after[2] == "Armor: " & $(unitOf(0, KnightUnit).armor + 6)
      check after[3] != before[3]
    else:
      check false # missing effective selected-unit display

suite "Research command presentation":
  test "next tier uses Roman level and max never offers a fourth":
    var card = ResearchCard(name: "Runed Plating", level: 0)
    check card.researchTitle == "Runed Plating I"
    card.level = 1
    check card.researchTitle == "Runed Plating II"
    card.level = 2
    check card.researchTitle == "Runed Plating III"
    card.level = 3
    check card.researchTitle == "Runed Plating III"
    check card.researchStatus == "MAX LEVEL"
    check not card.researchEnabled

  test "busy and pending commands disable while keeping cost and remaining time":
    var card = ResearchCard(name: "Example", allowed: true,
      gold: 600, wood: 200, ticks: 600, ticksRemaining: 300)
    check card.researchEnabled
    check card.researchCost(30) == "600g  200w  20s"
    card.active = true
    check not card.researchEnabled
    check card.researchStatus == "RESEARCHING"
    check card.researchProgress == 0.5'f32
    check card.researchTiming(30) == "10s left"
    card.active = false
    card.queued = true
    check card.researchStatus == "QUEUED"
    check not card.researchEnabled
    card.queued = false
    card.allowed = false
    card.reason = "Need resources"
    check card.researchStatus == "Need resources"
    check not card.researchEnabled

  test "three research cards fit within the existing command panel":
    let panel = GameUiPanel(origin: vec2(100, 50), size: vec2(318, 160))
    let slots = researchPanels(panel)
    for slot in slots:
      check slot.origin.x >= panel.origin.x
      check slot.origin.y >= panel.origin.y
      check slot.origin.x + slot.size.x <= panel.origin.x + panel.size.x
      check slot.origin.y + slot.size.y <= panel.origin.y + panel.size.y
      check slot.size.x >= 96
    check slots[0].origin.x + slots[0].size.x < slots[1].origin.x
