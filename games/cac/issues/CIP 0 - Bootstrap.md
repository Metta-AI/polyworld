Check this: [@Build and run Polyworld locally](thread://01a0583c-d923-7030-82f5-440d868c133d?hostId=local).
We want to build a new Polyworld game, this will be a card game called AWM (Archers Warriors Mages).

Each player picks a class: Archer, Warrior, or Mage.
- Each player has:
  - An in-game avatar of the class he picked.
  - 20 life
  - 0 total energy
  - A hand of cards, hidden from other players (initially 5 cards are drawn)
- Avatars are character from polyworld-data
- Each player is given a deck of 30 cards according to their class.
- For now, cards are just a Card object with a name, and an energy cost.
- For now, all three decks have a single card that does nothing.
  Archer: 30x 'Green' cards, 1 energy
  Warrior: 30x 'Red' cards, 2 energy
  Mage: 30x 'Blue' cards, 1 energy
  
Once classes are selected, the game begins.
Players take turns, first player is decided by chance.

When a turn begins:
- Total energy is increased by 1
- Energy is replenished.
- The player draws a card into his hand.

During the turn:
- Players can play cards.
- Played cards are just discarded for now.
- The turn ends when the player clicks an "Finish" button.
- After that, the turn passes to the next player.
- The game has no finish condition for now.

Architecture and design:
- This game must be programmed in nim using polyworld and treeform's ecosystem.
- Use assets from polyworld-data, use placeholders when needed.
- The cards, avatar, and board must be 3D.
- Main game code will go in `awm.nim`.
- Cards code will be separated in a `awm-base-set.nim` file, cards are coded because they will later have custom rules.
