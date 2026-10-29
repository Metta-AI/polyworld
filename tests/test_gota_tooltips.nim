import
  std/strutils,
  ../examples/gods_of_the_arena/[content, tooltips]

echo "Hover cards describe only the selected rank."
for ability in Ability:
  for rank in 0'i32 .. ability.abilitySpec.slot.abilityMaxLevel:
    let
      card = abilityDetails(ability, rank)
      spec = ability.abilitySpec(rank)
    doAssert card.title == spec.name
    doAssert card.description.len > 0
    if rank == 0:
      doAssert card.subtitle.startsWith("Not learned")
    else:
      doAssert card.subtitle.startsWith("Rank " & $rank & " /")
    if spec.damage > 0:
      doAssert ("Enemy damage", $spec.damage) in card.rows
    if spec.heal > 0:
      doAssert ("Healing", $spec.heal & " HP") in card.rows

echo "All inventory items explain their real effects."
for item in HealthPotion .. Item.high:
  let card = itemDetails(item)
  doAssert card.title == item.itemSpec.name
  doAssert card.description.len > 0
  doAssert card.rows.len > 0
doAssert "takes damage" in itemDetails(HealthPotion).description
doAssert "current attack target" in itemDetails(PoisonPotion).description
doAssert "Stuns and roots" in itemDetails(PortalScroll).description
doAssert ("Stun", "0.5s") in abilityDetails(FirebrandSword, 4).rows
doAssert ("Healing", "375 HP") in abilityDetails(HealingBloom, 4).rows
