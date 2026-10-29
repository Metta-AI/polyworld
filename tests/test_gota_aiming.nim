import ../examples/gods_of_the_arena/[aiming, maps, sim]

echo "Missed clicks choose the nearest living visible target of the right team."
let
  world = World()
  enemy = Hero(id: 100, team: BlueTeam, hp: 100,
    position: WorldPoint(x: WorldScale))
  ally = Hero(id: 101, team: RedTeam, hp: 100,
    position: WorldPoint(x: WorldScale div 2))
world.heroes = @[enemy, ally]
for team in Team:
  world.teamVisible[team.ord] = newSeq[uint8](mapTiles() * mapTiles())
  for cell in world.teamVisible[team.ord].mitems:
    cell = 255
doAssert world.nearbyTarget(RedTeam, WorldPoint()) == enemy.id
doAssert world.nearbyTarget(RedTeam, WorldPoint(), healing = true) == ally.id
enemy.position.x = 2 * WorldScale
doAssert world.nearbyTarget(RedTeam, WorldPoint()) == enemy.id
inc enemy.position.x
doAssert world.nearbyTarget(RedTeam, WorldPoint()) == 0
enemy.position.x = WorldScale
enemy.hp = 0
doAssert world.nearbyTarget(RedTeam, WorldPoint()) == 0
enemy.hp = 100
for cell in world.teamVisible[RedTeam.ord].mitems:
  cell = 0
doAssert world.nearbyTarget(RedTeam, WorldPoint()) == 0
echo "Nearby click checks passed."
