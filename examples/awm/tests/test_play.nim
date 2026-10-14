## The table state the duel and the multiplayer table share: what the human
## is in the middle of doing, with no window and no scene.
import std/[options, unittest]
import vmath
import ../src/play, ../src/core/[bots, sim], ../src/scene/table,
  ../src/vfx/vfxrenderer

let twoWays = Card(name: "Two Ways", energyCost: 0, kind: Spell,
  rules: rules(choose(
    rules(damage(1, target({kind: {Hero}}))),
    rules(damage(2, target({kind: {Hero}}))))))

proc poses(player, count: int): seq[CardPose] =
  for _ in 0 ..< count:
    result.add CardPose()

proc origin(player: int): CardPose = CardPose()

proc feet(player: int): Vec3 = vec3(0, 0, 0)

proc shown(player: int): bool = true

proc flatTable(): TableLayout =
  ## Every card at the origin: the choose screen needs somewhere for the
  ## cast spell to fly from, not a real table.
  TableLayout(handPoses: poses, boardPoses: poses, deckPose: origin,
    discardPose: origin, spellPose: origin, heroPosition: feet,
    handVisible: shown)

suite "offering a card's options":
  proc offered(): (TablePlay, GameState) =
    ## A new match, as a mode starts one, with the choice open.
    var game = newGame(Archer, Mage, 7)
    game.players[game.currentPlayer].hand = @[twoWays]
    var play = initTablePlay(1)
    play.resetTable()
    play.pendingCard = twoWays
    play.pendingCardIndex = 0
    play.pendingTargeting = true
    play.pendingChoices = game.availableChoices(0)
    (play, game)

  test "a table that has just been reset holds no option":
    var play = initTablePlay(1)
    play.resetTable()
    check play.choosePicked.isNone

  test "the first card of a match waits for its player":
    # It used to take the first branch by itself: a reset table started out
    # holding option 0, as if the player had already clicked it.
    var (play, game) = offered()
    check play.choosing
    let player = game.currentPlayer
    for time in [0.1'f32, 1.0, 10.0]:
      play.updateChoosing(game, flatTable(), hovered = -1, pick = false,
        cancel = false, time = time)
      check play.choosing
      check play.choosePicked.isNone
      check game.players[player].hand.len == 1
      check game.players[1 - player].life == StartingLife

  test "clicking a branch takes it once its animation has played":
    var (play, game) = offered()
    let player = game.currentPlayer
    play.updateChoosing(game, flatTable(), hovered = 1, pick = true,
      cancel = false, time = 1.0)
    check play.choosePicked == some(1)
    # The card is still in hand while the pick plays.
    check game.players[player].hand.len == 1
    play.updateChoosing(game, flatTable(), hovered = -1, pick = false,
      cancel = false, time = 1.0 + ChoosePickSeconds)
    check play.choosePicked.isNone
    # That branch's own target is asked for next, not resolved blind.
    check play.pendingTargeting
    check play.pendingPicks == @[optionChoice(1)]
    check game.players[player].hand.len == 1

  test "canceling puts the card back without paying":
    var (play, game) = offered()
    let player = game.currentPlayer
    play.updateChoosing(game, flatTable(), hovered = -1, pick = false,
      cancel = true, time = 1.0)
    check not play.choosing
    check not play.pendingTargeting
    check play.pendingPicks.len == 0
    check game.players[player].hand.len == 1
    check game.players[player].energy == game.players[player].totalEnergy

suite "the end of a match":
  test "a lethal attack finishes its lunge and the table settles":
    var game = newGame(Warrior, Mage, 11)
    let
      me = game.currentPlayer
      enemy = 1 - me
    game.players[enemy].life = 3
    game.players[me].board = @[MinionState(id: 1, owner: me,
      card: baseCardNamed("Bear"), currentToughness: 2, canAttack: true)]
    game.nextMinionId = 2
    var
      play = initTablePlay(1)
      clock = initBotClock()
      time = 0'f32
    play.resetTable()
    play.startAttack(game, flatTable(), @[1], heroChoice(enemy))
    for _ in 0 ..< 600:
      let dt = 1'f32 / 60
      time += dt
      play.animations.advanceAnimations(dt)
      play.discardFlights.advanceAnimations(dt)
      play.activeVfx.advance(dt)
      discard play.updateBots(game, flatTable(), [nil.BotVm, nil.BotVm],
        clock, proc(): bool = true, dt)
      play.presentVisualEvents(game, flatTable(), time)
    check game.gameOver
    check game.winner == me
    # The duel shows the result only once the lunge is over and all is still.
    check not play.attackActive
    check play.presentationIdle(game)
