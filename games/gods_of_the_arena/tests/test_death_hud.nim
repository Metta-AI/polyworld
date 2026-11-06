## Pure authoritative countdown formatting, independent of render time.
import ../[content, sim, deathhud]

doAssert respawnCountdown(0) == "0:00"
doAssert respawnCountdown(1) == "0:01"
doAssert respawnCountdown(TickRate - 1) == "0:01"
doAssert respawnCountdown(TickRate) == "0:01"
doAssert respawnCountdown(TickRate + 1) == "0:02"
doAssert respawnCountdown(35 * TickRate) == "0:35"
doAssert respawnCountdown(60 * TickRate) == "1:00"
doAssert respawnCountdown(65 * TickRate + 1) == "1:06"
doAssert respawnCountdown(-1) == "0:00"
echo "Death HUD countdown boundaries passed"

block:
  # Packed index 1 is a blue hero in stable seat 9, not hero id/index 1.
  let hero = Hero(id: 109, slot: 4, team: BlueTeam, state: Dying,
    hp: 0, deaths: 12, deathTicks: 25 * TickRate)
  let other = Hero(id: 104, slot: 3, team: RedTeam, state: Marching, hp: 100)
  let world = World(phase: Playing, heroes: @[other, hero])
  doAssert deathHudText(world, 2, false) == "DEAD 0:35"
  doAssert deathHudText(world, 1, false) == ""
  doAssert deathHudText(world, 0, false) == ""
  doAssert deathHudText(world, -1, false) == ""
  doAssert deathHudText(world, 3, false) == ""
  doAssert deathHudText(world, 2, true) == "", "Replay/watch cannot own a hero"
  doAssert deathHudText(world, 2, false, spectator = true) == ""
  world.phase = Drafting
  doAssert deathHudText(world, 2, false) == ""
  world.phase = Playing
  # Repeated rendered frames and unconsumed network time cannot reduce ticks.
  for frame in 0 ..< 100:
    doAssert deathHudText(world, 2, false) == "DEAD 0:35"
  inc hero.deathTicks
  doAssert deathHudText(world, 2, false) == "DEAD 0:35"
  hero.deathTicks = 60 * TickRate - 1
  doAssert deathHudText(world, 2, false) == "DEAD 0:01"
  hero.deathTicks = 60 * TickRate
  doAssert deathHudText(world, 2, false) == "DEAD 0:00"
  hero.state = Marching
  doAssert deathHudText(world, 2, false) == "", "Revival retires banner immediately"
  hero.state = Dying
  hero.deathTicks = 25 * TickRate
  hero.gold = 1200
  doAssert world.applyBuyback(hero.id)
  doAssert deathHudText(world, 2, false) == "", "Authoritative buyback retires banner"
echo "Death HUD ownership, phase, authority and revival passed"
