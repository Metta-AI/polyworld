## Run with `nim r experiments/gota_room/room.nim`.
## Uses the real GotA renderer, controls, and simulation in a small combat test room.

import ../../examples/gods_of_the_arena/[game, graphics, sim]

initializeOptions()
options.playerSlot = 1
options.pauseOnStart = false
options.speed = 1
run = newTestGame()
discard runGraphics()
