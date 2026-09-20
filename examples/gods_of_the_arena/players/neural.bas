' Minimal neural-player boundary. The host replaces METTA_DECISION with its action callback.
dim f(8)
f(0) = selfHp * 100 / selfMaxHp
f(1) = 0
if selfMaxMana > 0 then
  f(1) = selfMana * 100 / selfMaxMana
end if
f(2) = selfLevel * 5
f(3) = selfX
f(4) = selfY
f(5) = worldTick / 288
f(6) = selfGold / 10
f(7) = selfClass * 10
index = 0
while index < 8
  if f(index) > 100 then
    f(index) = 100
  end if
  if f(index) < -100 then
    f(index) = -100
  end if
  index = index + 1
wend
' METTA_DECISION
if decision = 0 then
  walkTo(selfX, selfY)
end if
if decision = 1 then
  walkTo(selfX - 8, selfY)
end if
if decision = 2 then
  walkTo(selfX + 8, selfY)
end if
if decision >= 3 and decision <= 6 then
  castTarget(decision - 3, selfId)
end if
if decision = 7 then
  buyItem(2)
end if
