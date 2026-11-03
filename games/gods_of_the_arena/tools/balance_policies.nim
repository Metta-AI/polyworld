import
  std/strutils,
  ../content,
  balances

const
  SupportMarker = "' Balance support decisions."
  SupportRoutine = """sub supportSpells()
  supportCast = 0
  if selfSilenceTicks > 0 then
    exit sub
  end if
  supportTarget = selfId
  supportMissing = selfMaxHp - selfHp
  if selfClass = DruidWarden then
    for supportIndex = 0 to objectCount() - 1
      if objectKind(supportIndex) = 2 and objectTeam(supportIndex) = selfTeam then
        if objectAlive(supportIndex) then
          supportDx = objectX(supportIndex) - selfX
          supportDy = objectY(supportIndex) - selfY
          ' Both Druid heals reach four tiles; leave a tenth-tile margin.
          if supportDx * supportDx + supportDy * supportDy <= 15.21 then
            supportClass = objectClass(supportIndex)
            supportMax = supportBaseHp(supportClass)
            supportMax = supportMax + (objectLevel(supportIndex) - 1) * supportHpGrowth(supportClass)
            for supportItemSlot = 0 to 5
              supportMax = supportMax + supportItemHp(objectItemId(supportIndex, supportItemSlot))
            next supportItemSlot
            supportNeed = supportMax - objectHp(supportIndex)
            if supportNeed > supportMissing then
              supportTarget = objectId(supportIndex)
              supportMissing = supportNeed
            end if
          end if
        end if
      end if
    next supportIndex
  end if
  for supportSlot = 0 to 3
    if abilityLevel(supportSlot) > 0 and abilityCooldown(supportSlot) = 0 then
      if abilityCharges(supportSlot) > 0 and selfMana >= abilityManaCost(supportSlot) then
        supportId = 0
        supportRestore = abilityRestore(supportSlot)
        supportHeal = abilityHeal(supportSlot)
        if supportRestore > 0 then
          if selfMaxMana - selfMana >= supportRestore then
            supportId = selfId
          end if
        elseif selfClass = DruidWarden and supportHeal > 0 then
          if supportSlot = 1 or supportSlot = 2 then
            if supportMissing >= supportHeal / 2 then
              supportId = supportTarget
            end if
          elseif selfMaxHp - selfHp >= supportHeal / 2 then
            supportId = selfId
          end if
        end if
        if supportId <> 0 then
          if castTarget(supportSlot, supportId) then
            supportCast = 1
            exit sub
          end if
        end if
      end if
    end if
  next supportSlot
end sub

"""

proc supportPolicy*(source, tuning: string): string =
  ## Repairs khors support decisions using the experiment's public stats.
  require(SupportMarker notin source, "Support fixes are already applied")
  let
    declarations = "dim owned(22)\n"
    think = "learnAbilities()\nobserve()\neconomy()\n"
    heal = "if selfMaxHp - selfHp >= abilityHeal(slot) \\ 2 then"
  for marker in [declarations, think, heal]:
    require(source.count(marker) == 1,
      "Unsupported policy layout near: " & marker)
  # Public health and item stats avoid guessing wounds from past observations.
  var header = SupportMarker & "\n" &
    "dim supportBaseHp(9)\ndim supportHpGrowth(9)\n" &
    "dim supportItemHp(" & $Item.high.ord & ")\n" &
    "if supportInitialized = 0 then\n  supportInitialized = 1\n"
  for hero, name in HeroNames:
    for (field, arrayName) in [
      ("baseHitPoints", "supportBaseHp"),
      ("hitPointsPerLevel", "supportHpGrowth")
    ]:
      header.add "  " & arrayName & "(" & $hero & ") = " &
        $tuning.value(Lever(anchor: "name: \"" & name & "\"",
          field: field)) & "\n"
  for item in Item:
    let spec = item.itemSpec
    if spec.maxHp > 0:
      header.add "  supportItemHp(" & $item.ord & ") = " &
        $tuning.value(Lever(anchor: "name: \"" & spec.name & "\"",
          field: "maxHp")) & "\n"
  header.add "end if\n\n" & SupportRoutine
  result = source.replace(declarations, declarations & header)
  result = result.replace(think, think &
    "supportSpells()\nif supportCast then\n  end\nend if\n")
  # Druid healing is handled before retreat and enemy-target early returns.
  result = result.replace(heal,
    "if selfClass <> DruidWarden and selfMaxHp - selfHp >= abilityHeal(slot) \\ 2 then")
