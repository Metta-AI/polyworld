Let's define two card types:
1- Minions: a minion has power and toughness, it can also have "rules" that have effects when played, it then remains in the board.
2- Spells: a spell has "rules" that have effects when played, it is then discarded.

I have drafted the types for cards, base types for rules and targeting, conforming the idea of a simple DSL to write cards. I have also designed three cards, once for each class.

1. I have made changes and expanded the card's design, correct compiler errors and fill in the code gaps.
2. Make the three cards work, keeping the current design intention.
3. A rule is a composite object that provides both ruletext and its execution program via their `text` and `run` methods. Our two main rules will be `damage` and `bounce` for this iteration, both accept a `Target`.
4. A target is another composite object that provides both ruletext and choice with its `text` and `choose` methods. Running `choose` allows the player to select a target with the programmed restrictions, `Choice` is not written, should return a valid choice or a `Canceled` value.

Implement the three cards.
