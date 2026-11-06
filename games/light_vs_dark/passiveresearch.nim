## Pure passive modifiers. Spell unlocks/casting belong to a later, separate system.
import fixxy, content

proc passiveUnitStats*(player: int32, kind: UnitKind,
    levels: array[ResearchKind, int32]): UnitStats =
  result = unitOf(player, kind)
  result.armor += ResearchArmorPerTier * levels[RunedPlating]
  if kind == ArcherUnit:
    result.piercing += ResearchDamagePerTier * levels[KeenflightArrows]
  if kind in {SoldierUnit, KnightUnit, ClericUnit, MageUnit}:
    result.basic += ResearchDamagePerTier * levels[TemperedEdges]

proc passiveMoveSpeed*(player: int32, kind: UnitKind,
    levels: array[ResearchKind, int32]): Fixed =
  result = FixedOne / fixed(max(1'i32, unitOf(player, kind).stepTicks))
  if kind == KnightUnit:
    result = result * fixed(100 + ResearchSpeedPercentPerTier *
      levels[WindrunnerTraining]) / fixed(100)
