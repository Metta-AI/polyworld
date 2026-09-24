' Gods of the Arena 2026.9.21.3 compatibility layer.
' Draft a balanced roster, spend ability points, buy back, and keep the
' previously trained neural clock relative to the start of combat.
dim draftF(31)
sub chooseHero()
  if draftTurnId <> selfId then
    exit sub
  end if
  for draftClass = 0 to 9
    draftF(draftClass) = heroAvailable(draftClass)
    draftF(10 + draftClass) = 0
    draftF(20 + draftClass) = 0
  next draftClass
  draftAllyCount = 0
  draftEnemyCount = 0
  for draftPlayer = 0 to draftPlayerCount() - 1
    draftPicked = draftedClass(draftPlayerId(draftPlayer))
    if draftPicked >= 0 then
      if draftPlayerTeam(draftPlayer) = selfTeam then
        draftF(10 + draftPicked) = 1
        draftAllyCount = draftAllyCount + 1
      else
        draftF(20 + draftPicked) = 1
        draftEnemyCount = draftEnemyCount + 1
      end if
    end if
  next draftPlayer
  draftF(30) = draftAllyCount / 5
  draftF(31) = draftEnemyCount / 5
  draftBestClass = -1
  draftBestScore = -2147483647
  if draftF(0) then
    draftScore = -0.252276
    draftScore = draftScore + draftF(0) * -0.252276
    draftScore = draftScore + draftF(1) * 0.208388
    draftScore = draftScore + draftF(2) * 0.165655
    draftScore = draftScore + draftF(3) * -0.077038
    draftScore = draftScore + draftF(4) * -0.307499
    draftScore = draftScore + draftF(5) * 0.393190
    draftScore = draftScore + draftF(6) * -0.041722
    draftScore = draftScore + draftF(7) * -0.247450
    draftScore = draftScore + draftF(8) * -0.267264
    draftScore = draftScore + draftF(9) * 0.060881
    draftScore = draftScore + draftF(11) * -0.056464
    draftScore = draftScore + draftF(12) * -0.558547
    draftScore = draftScore + draftF(13) * 0.238349
    draftScore = draftScore + draftF(14) * 0.148874
    draftScore = draftScore + draftF(15) * -0.351042
    draftScore = draftScore + draftF(16) * 0.022783
    draftScore = draftScore + draftF(17) * 0.133934
    draftScore = draftScore + draftF(18) * -0.148994
    draftScore = draftScore + draftF(19) * -0.127461
    draftScore = draftScore + draftF(21) * -0.404200
    draftScore = draftScore + draftF(22) * 0.140616
    draftScore = draftScore + draftF(23) * -0.413587
    draftScore = draftScore + draftF(24) * -0.093651
    draftScore = draftScore + draftF(25) * -0.294424
    draftScore = draftScore + draftF(26) * -0.233337
    draftScore = draftScore + draftF(27) * -0.138760
    draftScore = draftScore + draftF(28) * 0.163981
    draftScore = draftScore + draftF(29) * -0.185696
    draftScore = draftScore + draftF(30) * -0.139714
    draftScore = draftScore + draftF(31) * -0.291812
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 0
    end if
  end if
  if draftF(1) then
    draftScore = 0.220766
    draftScore = draftScore + draftF(0) * 0.252661
    draftScore = draftScore + draftF(1) * 0.220766
    draftScore = draftScore + draftF(2) * -0.066995
    draftScore = draftScore + draftF(3) * 0.046584
    draftScore = draftScore + draftF(4) * -0.074833
    draftScore = draftScore + draftF(5) * 0.282953
    draftScore = draftScore + draftF(6) * -0.316809
    draftScore = draftScore + draftF(7) * 0.260309
    draftScore = draftScore + draftF(8) * 0.498069
    draftScore = draftScore + draftF(9) * 0.607530
    draftScore = draftScore + draftF(10) * -0.054461
    draftScore = draftScore + draftF(12) * 0.185443
    draftScore = draftScore + draftF(13) * 0.307806
    draftScore = draftScore + draftF(14) * 0.073798
    draftScore = draftScore + draftF(15) * 0.095548
    draftScore = draftScore + draftF(16) * -0.624112
    draftScore = draftScore + draftF(17) * -0.128341
    draftScore = draftScore + draftF(18) * 0.116202
    draftScore = draftScore + draftF(19) * -0.113738
    draftScore = draftScore + draftF(20) * 0.022566
    draftScore = draftScore + draftF(22) * 0.102318
    draftScore = draftScore + draftF(23) * -0.133625
    draftScore = draftScore + draftF(24) * 0.221801
    draftScore = draftScore + draftF(25) * -0.157735
    draftScore = draftScore + draftF(26) * 1.161687
    draftScore = draftScore + draftF(27) * 0.088798
    draftScore = draftScore + draftF(28) * -0.393505
    draftScore = draftScore + draftF(29) * -0.273026
    draftScore = draftScore + draftF(30) * -0.028371
    draftScore = draftScore + draftF(31) * 0.127856
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 1
    end if
  end if
  if draftF(2) then
    draftScore = 0.306957
    draftScore = draftScore + draftF(0) * 0.160424
    draftScore = draftScore + draftF(1) * -0.457565
    draftScore = draftScore + draftF(2) * 0.306957
    draftScore = draftScore + draftF(3) * -0.351070
    draftScore = draftScore + draftF(4) * 0.501679
    draftScore = draftScore + draftF(5) * 0.772043
    draftScore = draftScore + draftF(6) * -0.220549
    draftScore = draftScore + draftF(7) * -0.161796
    draftScore = draftScore + draftF(8) * 0.448017
    draftScore = draftScore + draftF(9) * -0.150996
    draftScore = draftScore + draftF(10) * 0.136125
    draftScore = draftScore + draftF(11) * 0.178068
    draftScore = draftScore + draftF(13) * 0.247534
    draftScore = draftScore + draftF(14) * -0.188988
    draftScore = draftScore + draftF(15) * -0.238955
    draftScore = draftScore + draftF(16) * 0.883443
    draftScore = draftScore + draftF(17) * 0.034082
    draftScore = draftScore + draftF(18) * 0.088084
    draftScore = draftScore + draftF(20) * 0.010408
    draftScore = draftScore + draftF(21) * 0.586454
    draftScore = draftScore + draftF(23) * 0.410493
    draftScore = draftScore + draftF(24) * -0.005734
    draftScore = draftScore + draftF(25) * -0.226131
    draftScore = draftScore + draftF(26) * -0.355937
    draftScore = draftScore + draftF(27) * 0.434671
    draftScore = draftScore + draftF(28) * -0.229144
    draftScore = draftScore + draftF(29) * 0.457953
    draftScore = draftScore + draftF(30) * 0.227879
    draftScore = draftScore + draftF(31) * 0.216607
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 2
    end if
  end if
  if draftF(3) then
    draftScore = -0.102972
    draftScore = draftScore + draftF(0) * 0.191406
    draftScore = draftScore + draftF(1) * -0.378401
    draftScore = draftScore + draftF(2) * -0.681596
    draftScore = draftScore + draftF(3) * -0.102972
    draftScore = draftScore + draftF(4) * 0.400384
    draftScore = draftScore + draftF(5) * -0.198847
    draftScore = draftScore + draftF(6) * -0.095249
    draftScore = draftScore + draftF(7) * -0.499520
    draftScore = draftScore + draftF(8) * 0.154836
    draftScore = draftScore + draftF(9) * 0.124309
    draftScore = draftScore + draftF(10) * -0.098351
    draftScore = draftScore + draftF(11) * 0.079512
    draftScore = draftScore + draftF(12) * 0.896409
    draftScore = draftScore + draftF(14) * -0.105452
    draftScore = draftScore + draftF(15) * -0.086497
    draftScore = draftScore + draftF(16) * -0.053812
    draftScore = draftScore + draftF(17) * 0.204039
    draftScore = draftScore + draftF(18) * -0.676251
    draftScore = draftScore + draftF(19) * 0.027087
    draftScore = draftScore + draftF(20) * -0.196028
    draftScore = draftScore + draftF(21) * 0.195917
    draftScore = draftScore + draftF(22) * -0.317785
    draftScore = draftScore + draftF(24) * -0.397904
    draftScore = draftScore + draftF(25) * 0.182371
    draftScore = draftScore + draftF(26) * 0.046089
    draftScore = draftScore + draftF(27) * 0.192509
    draftScore = draftScore + draftF(28) * 0.418443
    draftScore = draftScore + draftF(29) * -0.254368
    draftScore = draftScore + draftF(30) * 0.037337
    draftScore = draftScore + draftF(31) * -0.026151
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 3
    end if
  end if
  if draftF(4) then
    draftScore = -0.279421
    draftScore = draftScore + draftF(0) * -0.615030
    draftScore = draftScore + draftF(1) * 0.124070
    draftScore = draftScore + draftF(2) * -0.215150
    draftScore = draftScore + draftF(3) * -0.227015
    draftScore = draftScore + draftF(4) * -0.279421
    draftScore = draftScore + draftF(5) * -0.805966
    draftScore = draftScore + draftF(6) * -0.051813
    draftScore = draftScore + draftF(7) * 0.012569
    draftScore = draftScore + draftF(8) * -0.390292
    draftScore = draftScore + draftF(9) * -0.465863
    draftScore = draftScore + draftF(10) * 0.349372
    draftScore = draftScore + draftF(11) * 0.302593
    draftScore = draftScore + draftF(12) * -0.114656
    draftScore = draftScore + draftF(13) * -0.015071
    draftScore = draftScore + draftF(15) * 0.281769
    draftScore = draftScore + draftF(16) * -0.040930
    draftScore = draftScore + draftF(17) * 0.011989
    draftScore = draftScore + draftF(18) * -0.098396
    draftScore = draftScore + draftF(19) * -0.247384
    draftScore = draftScore + draftF(20) * -0.013763
    draftScore = draftScore + draftF(21) * -0.706084
    draftScore = draftScore + draftF(22) * 0.050385
    draftScore = draftScore + draftF(23) * -0.037334
    draftScore = draftScore + draftF(25) * 0.244777
    draftScore = draftScore + draftF(26) * -0.186678
    draftScore = draftScore + draftF(27) * -0.303979
    draftScore = draftScore + draftF(28) * 0.209267
    draftScore = draftScore + draftF(29) * 0.433826
    draftScore = draftScore + draftF(30) * 0.085857
    draftScore = draftScore + draftF(31) * -0.061916
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 4
    end if
  end if
  if draftF(5) then
    draftScore = -0.242457
    draftScore = draftScore + draftF(0) * -0.232312
    draftScore = draftScore + draftF(1) * -0.183645
    draftScore = draftScore + draftF(2) * -0.270940
    draftScore = draftScore + draftF(3) * -0.249030
    draftScore = draftScore + draftF(4) * -0.064811
    draftScore = draftScore + draftF(5) * -0.242457
    draftScore = draftScore + draftF(6) * -0.040038
    draftScore = draftScore + draftF(7) * -0.037761
    draftScore = draftScore + draftF(8) * -0.901328
    draftScore = draftScore + draftF(9) * 0.027995
    draftScore = draftScore + draftF(10) * -0.392084
    draftScore = draftScore + draftF(11) * -0.497526
    draftScore = draftScore + draftF(12) * 0.312257
    draftScore = draftScore + draftF(13) * 0.104801
    draftScore = draftScore + draftF(14) * -0.183950
    draftScore = draftScore + draftF(16) * 0.045312
    draftScore = draftScore + draftF(17) * 0.127481
    draftScore = draftScore + draftF(18) * 0.460752
    draftScore = draftScore + draftF(19) * -0.051012
    draftScore = draftScore + draftF(20) * 0.381939
    draftScore = draftScore + draftF(21) * 0.438713
    draftScore = draftScore + draftF(22) * -0.283774
    draftScore = draftScore + draftF(23) * -0.098228
    draftScore = draftScore + draftF(24) * 0.006305
    draftScore = draftScore + draftF(26) * -0.247731
    draftScore = draftScore + draftF(27) * -0.332176
    draftScore = draftScore + draftF(28) * 0.198120
    draftScore = draftScore + draftF(29) * -0.219440
    draftScore = draftScore + draftF(30) * -0.014794
    draftScore = draftScore + draftF(31) * -0.031255
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 5
    end if
  end if
  if draftF(6) then
    draftScore = 0.714471
    draftScore = draftScore + draftF(0) * 0.727924
    draftScore = draftScore + draftF(1) * 0.905780
    draftScore = draftScore + draftF(2) * 0.451952
    draftScore = draftScore + draftF(3) * 0.593039
    draftScore = draftScore + draftF(4) * 0.580693
    draftScore = draftScore + draftF(5) * 0.784972
    draftScore = draftScore + draftF(6) * 0.714471
    draftScore = draftScore + draftF(7) * 0.539523
    draftScore = draftScore + draftF(8) * 0.567051
    draftScore = draftScore + draftF(9) * 0.609534
    draftScore = draftScore + draftF(10) * 0.213345
    draftScore = draftScore + draftF(11) * -0.291630
    draftScore = draftScore + draftF(12) * 0.069507
    draftScore = draftScore + draftF(14) * 0.103936
    draftScore = draftScore + draftF(15) * 0.023463
    draftScore = draftScore + draftF(17) * 0.043553
    draftScore = draftScore + draftF(18) * 0.061384
    draftScore = draftScore + draftF(19) * 0.061384
    draftScore = draftScore + draftF(20) * -0.226798
    draftScore = draftScore + draftF(21) * 0.100322
    draftScore = draftScore + draftF(22) * 0.193012
    draftScore = draftScore + draftF(23) * 0.121433
    draftScore = draftScore + draftF(24) * 0.029843
    draftScore = draftScore + draftF(25) * -0.093964
    draftScore = draftScore + draftF(27) * 0.131395
    draftScore = draftScore + draftF(28) * 0.086036
    draftScore = draftScore + draftF(29) * 0.043553
    draftScore = draftScore + draftF(30) * 0.056989
    draftScore = draftScore + draftF(31) * 0.076966
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 6
    end if
  end if
  if draftF(7) then
    draftScore = 0.092192
    draftScore = draftScore + draftF(0) * 0.168151
    draftScore = draftScore + draftF(1) * -0.445483
    draftScore = draftScore + draftF(2) * -0.279111
    draftScore = draftScore + draftF(3) * 0.122942
    draftScore = draftScore + draftF(4) * -0.494774
    draftScore = draftScore + draftF(5) * -0.299634
    draftScore = draftScore + draftF(6) * -0.131236
    draftScore = draftScore + draftF(7) * 0.092192
    draftScore = draftScore + draftF(8) * 0.164071
    draftScore = draftScore + draftF(9) * -0.176015
    draftScore = draftScore + draftF(10) * 0.002602
    draftScore = draftScore + draftF(11) * 0.310725
    draftScore = draftScore + draftF(12) * -0.538125
    draftScore = draftScore + draftF(13) * 0.274210
    draftScore = draftScore + draftF(14) * 0.488313
    draftScore = draftScore + draftF(15) * -0.038538
    draftScore = draftScore + draftF(16) * 0.069213
    draftScore = draftScore + draftF(18) * 0.434066
    draftScore = draftScore + draftF(19) * 0.183095
    draftScore = draftScore + draftF(20) * -0.078561
    draftScore = draftScore + draftF(21) * 0.226950
    draftScore = draftScore + draftF(22) * 0.909428
    draftScore = draftScore + draftF(23) * -0.304960
    draftScore = draftScore + draftF(24) * 0.098653
    draftScore = draftScore + draftF(25) * 0.430365
    draftScore = draftScore + draftF(26) * 0.154216
    draftScore = draftScore + draftF(28) * -0.505944
    draftScore = draftScore + draftF(29) * 0.085113
    draftScore = draftScore + draftF(30) * 0.237112
    draftScore = draftScore + draftF(31) * 0.203052
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 7
    end if
  end if
  if draftF(8) then
    draftScore = 0.041381
    draftScore = draftScore + draftF(0) * -0.294455
    draftScore = draftScore + draftF(1) * 0.111733
    draftScore = draftScore + draftF(2) * 0.787697
    draftScore = draftScore + draftF(3) * 0.595129
    draftScore = draftScore + draftF(4) * 0.080587
    draftScore = draftScore + draftF(5) * -0.130948
    draftScore = draftScore + draftF(6) * 0.222401
    draftScore = draftScore + draftF(7) * 0.450339
    draftScore = draftScore + draftF(8) * 0.041381
    draftScore = draftScore + draftF(9) * -0.138733
    draftScore = draftScore + draftF(10) * -0.194858
    draftScore = draftScore + draftF(11) * 0.316302
    draftScore = draftScore + draftF(12) * -0.090298
    draftScore = draftScore + draftF(13) * -1.080760
    draftScore = draftScore + draftF(14) * -0.178166
    draftScore = draftScore + draftF(15) * -0.011497
    draftScore = draftScore + draftF(16) * -0.011433
    draftScore = draftScore + draftF(17) * -0.360402
    draftScore = draftScore + draftF(19) * 0.268030
    draftScore = draftScore + draftF(20) * 0.530694
    draftScore = draftScore + draftF(21) * -0.386654
    draftScore = draftScore + draftF(22) * -0.656018
    draftScore = draftScore + draftF(23) * 0.527012
    draftScore = draftScore + draftF(24) * 0.138960
    draftScore = draftScore + draftF(25) * 0.183827
    draftScore = draftScore + draftF(26) * -0.169586
    draftScore = draftScore + draftF(27) * -0.048555
    draftScore = draftScore + draftF(29) * -0.087915
    draftScore = draftScore + draftF(30) * -0.268616
    draftScore = draftScore + draftF(31) * 0.006353
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 8
    end if
  end if
  if draftF(9) then
    draftScore = -0.498641
    draftScore = draftScore + draftF(0) * -0.106492
    draftScore = draftScore + draftF(1) * -0.105644
    draftScore = draftScore + draftF(2) * -0.198469
    draftScore = draftScore + draftF(3) * -0.350568
    draftScore = draftScore + draftF(4) * -0.342004
    draftScore = draftScore + draftF(5) * -0.555305
    draftScore = draftScore + draftF(6) * -0.039455
    draftScore = draftScore + draftF(7) * -0.408405
    draftScore = draftScore + draftF(8) * -0.314541
    draftScore = draftScore + draftF(9) * -0.498641
    draftScore = draftScore + draftF(10) * 0.038310
    draftScore = draftScore + draftF(11) * -0.341580
    draftScore = draftScore + draftF(12) * -0.161989
    draftScore = draftScore + draftF(13) * -0.076870
    draftScore = draftScore + draftF(14) * -0.158366
    draftScore = draftScore + draftF(15) * 0.325749
    draftScore = draftScore + draftF(16) * -0.290464
    draftScore = draftScore + draftF(17) * -0.066335
    draftScore = draftScore + draftF(18) * -0.236848
    draftScore = draftScore + draftF(20) * -0.430459
    draftScore = draftScore + draftF(21) * -0.051418
    draftScore = draftScore + draftF(22) * -0.138183
    draftScore = draftScore + draftF(23) * -0.071204
    draftScore = draftScore + draftF(24) * 0.001728
    draftScore = draftScore + draftF(25) * -0.269085
    draftScore = draftScore + draftF(26) * -0.168722
    draftScore = draftScore + draftF(27) * -0.023902
    draftScore = draftScore + draftF(28) * 0.052747
    draftScore = draftScore + draftF(30) * -0.193678
    draftScore = draftScore + draftF(31) * -0.219699
    if draftScore > draftBestScore then
      draftBestScore = draftScore
      draftBestClass = 9
    end if
  end if
  if draftBestClass >= 0 then
    draftHero(draftBestClass)
  end if
end sub

if drafting then
  chooseHero()
  end
end if

if battleStarted = 0 then
  battleStartTick = worldTick
  battleStarted = 1
end if
battleTick = worldTick - battleStartTick

if selfHp <= 0 then
  buybackCost = buybackPrice()
  if buybackCost > 0 and selfGold >= buybackCost then
    buyback()
  end if
  end
end if

' Spend every currently legal point. The trained actor favors W, then E/Q;
' take the ultimate whenever its level gate opens.
for upgrade = 1 to 4
  if canLevelAbility(3) then
    levelAbility(3)
  elseif canLevelAbility(1) then
    levelAbility(1)
  elseif canLevelAbility(2) then
    levelAbility(2)
  elseif canLevelAbility(0) then
    levelAbility(0)
  end if
next upgrade

dim f(27)
bestId = 0
bestDistance = 2147483647
objectiveId = 0
objectiveKind = 0
siegeThreatId = 0
siegeThreatHp = 2147483647
objectiveDistance = 2147483647
heroId = 0
heroDistance = 2147483647
enemyX = selfX
enemyY = selfY
enemyHp = 0
enemyKind = 0
enemyAttackTarget = 0
routeOpeningX = 71
routeOpeningY = 12
if selfTeam = 1 then
  routeOpeningX = 45
  routeOpeningY = 104
end if
routeGroupCount = 0
if selfTeam = 0 then
  gateHomeX = 105
  gateHomeY = 10
else
  gateHomeX = 10
  gateHomeY = 105
end if
gateThreatDistance = 2147483647
gateThreatSeen = 0
gateThreatX = gateHomeX
reserveHome = 0
allyCount = 0
allyX = 0
allyY = 0
maxAllyDistance = 0
index = 0
while index < objectCount()
  if objectAlive(index) then
    if objectTeam(index) = selfTeam and objectKind(index) = 1 then
      reserveHome = 1
      reserveHomeId = objectId(index)
      reserveX = objectX(index)
      reserveY = objectY(index)
    end if
    if objectTeam(index) = selfTeam and objectKind(index) = 2 then
      allyCount = allyCount + 1
      routeDx = objectX(index) - routeOpeningX
      routeDy = objectY(index) - routeOpeningY
      if routeDx * routeDx + routeDy * routeDy <= 16 then
        routeGroupCount = routeGroupCount + 1
      end if
      allyX = allyX + objectX(index)
      allyY = allyY + objectY(index)
      dx = objectX(index) - selfX
      dy = objectY(index) - selfY
      distance = dx * dx + dy * dy
      if distance > maxAllyDistance then
        maxAllyDistance = distance
      end if
    end if
    if objectTeam(index) <> selfTeam then
      if battleTick < 1000 and (objectKind(index) = 2 or objectKind(index) = 3) then
        gateDx = objectX(index) - gateHomeX
        gateDy = objectY(index) - gateHomeY
        gateDistance = gateDx * gateDx + gateDy * gateDy
        if gateDistance < gateThreatDistance then
          gateThreatDistance = gateDistance
          gateThreatSeen = 1
          gateThreatX = objectX(index)
        end if
      end if
      dx = objectX(index) - selfX
      dy = objectY(index) - selfY
      distance = dx * dx + dy * dy
      if distance < bestDistance then
        bestDistance = distance
        bestId = objectId(index)
        enemyX = objectX(index)
        enemyY = objectY(index)
        enemyHp = objectHp(index)
        enemyKind = objectKind(index)
        enemyAttackTarget = objectTarget(index)
      end if
      if objectKind(index) = 2 and objectTarget(index) = selfId then
        siegeRange = selfAttackRange \ 1000
        if distance * 3600 <= siegeRange * siegeRange and objectHp(index) < siegeThreatHp then
          siegeThreatId = objectId(index)
          siegeThreatHp = objectHp(index)
        end if
      end if
      if objectKind(index) = 1 or objectKind(index) = 4 then
        if distance < objectiveDistance then
          objectiveDistance = distance
          objectiveId = objectId(index)
          objectiveKind = objectKind(index)
        end if
      end if
      if objectKind(index) = 2 and distance < heroDistance then
        heroDistance = distance
        heroId = objectId(index)
        ringHeroX = objectX(index)
        ringHeroY = objectY(index)
        ringHeroTarget = objectTarget(index)
      end if
    end if
  end if
  index = index + 1
wend
if allyCount > 0 then
  allyX = allyX \ allyCount
  allyY = allyY \ allyCount
else
  allyX = selfX
  allyY = selfY
end if
f(0) = selfHp * 100 \ selfMaxHp
f(1) = 0
if selfMaxMana > 0 then
  f(1) = selfMana * 100 \ selfMaxMana
end if
f(2) = maxAllyDistance \ 100
f(3) = selfLevel * 5
f(4) = allyX - selfX
f(5) = allyY - selfY
f(6) = enemyX - selfX
f(7) = enemyY - selfY
f(8) = enemyHp \ 10
f(9) = enemyKind * 25
if selfTeam = 1 then
  f(4) = 0 - f(4)
  f(5) = 0 - f(5)
  f(6) = 0 - f(6)
  f(7) = 0 - f(7)
end if
f(10) = battleTick \ 288
f(11) = abilityCharges(0) * 25
f(12) = abilityCharges(1) * 25
f(13) = abilityCharges(2) * 25
f(14) = abilityCharges(3) * 25
f(15 + selfClass) = 100
f(25) = battleTick \ 16
if battleTick < 1000 and gateThreatSeen = 1 then
  gateEarlyThreatX = gateThreatX
  gateEarlyThreatSeen = 1
end if
f(26) = 0
if gateEarlyThreatSeen = 1 then
  f(26) = gateEarlyThreatX - gateHomeX
  if selfTeam = 1 then
    f(26) = 0 - f(26)
  end if
end if
index = 0
while index < 27
  if f(index) > 100 then
    f(index) = 100
  end if
  if f(index) < -100 then
    f(index) = -100
  end if
  index = index + 1
wend
dim h(16)
neuralActionCountdown = neuralActionCountdown - 1
if neuralActionCountdown <= 0 then
  neuralActionCountdown = 4
h(0) = 18208 + f(0) * (263) + f(1) * (222) + f(2) * (-62) + f(3) * (-8) + f(4) * (156) + f(5) * (176) + f(6) * (-660) + f(7) * (470) + f(8) * (178) + f(9) * (648) + f(10) * (309) + f(11) * (38) + f(12) * (78) + f(13) * (-150) + f(14) * (200) + f(15) * (5) + f(16) * (-491) + f(17) * (183) + f(18) * (-26) + f(19) * (311) + f(20) * (646) + f(21) * (80) + f(22) * (544) + f(23) * (39) + f(24) * (255)
if h(0) < 0 then
  h(0) = 0
end if
h(1) = 18392 + f(0) * (126) + f(1) * (-23) + f(2) * (117) + f(3) * (-25) + f(4) * (585) + f(5) * (-305) + f(6) * (-320) + f(7) * (118) + f(8) * (235) + f(9) * (32) + f(10) * (21) + f(11) * (-234) + f(12) * (656) + f(13) * (93) + f(14) * (602) + f(15) * (414) + f(16) * (439) + f(17) * (243) + f(18) * (243) + f(19) * (-340) + f(20) * (187) + f(21) * (-78) + f(22) * (72) + f(23) * (-522) + f(24) * (315)
if h(1) < 0 then
  h(1) = 0
end if
h(2) = 3752 + f(0) * (-346) + f(1) * (10) + f(2) * (-181) + f(3) * (180) + f(4) * (64) + f(5) * (725) + f(6) * (-25) + f(7) * (71) + f(8) * (104) + f(9) * (-523) + f(10) * (-232) + f(11) * (-80) + f(12) * (-27) + f(13) * (-30) + f(14) * (-313) + f(15) * (-350) + f(16) * (-320) + f(17) * (-11) + f(18) * (493) + f(19) * (-48) + f(20) * (-128) + f(21) * (182) + f(22) * (-73) + f(23) * (-520) + f(24) * (-23)
if h(2) < 0 then
  h(2) = 0
end if
h(3) = 19627 + f(0) * (190) + f(1) * (158) + f(2) * (-294) + f(3) * (61) + f(4) * (-155) + f(5) * (-122) + f(6) * (280) + f(7) * (-28) + f(8) * (-22) + f(9) * (396) + f(10) * (438) + f(11) * (38) + f(12) * (385) + f(13) * (238) + f(14) * (-15) + f(15) * (-727) + f(16) * (119) + f(17) * (363) + f(18) * (-197) + f(19) * (-128) + f(20) * (-135) + f(21) * (-497) + f(22) * (121) + f(23) * (-12) + f(24) * (-15)
if h(3) < 0 then
  h(3) = 0
end if
h(4) = 18521 + f(0) * (431) + f(1) * (-81) + f(2) * (108) + f(3) * (-107) + f(4) * (178) + f(5) * (-317) + f(6) * (-339) + f(7) * (286) + f(8) * (230) + f(9) * (-103) + f(10) * (-293) + f(11) * (-141) + f(12) * (714) + f(13) * (388) + f(14) * (-197) + f(15) * (-213) + f(16) * (109) + f(17) * (384) + f(18) * (214) + f(19) * (562) + f(20) * (195) + f(21) * (323) + f(22) * (25) + f(23) * (668) + f(24) * (-158)
if h(4) < 0 then
  h(4) = 0
end if
h(5) = 18435 + f(0) * (360) + f(1) * (159) + f(2) * (398) + f(3) * (339) + f(4) * (-52) + f(5) * (-357) + f(6) * (-172) + f(7) * (110) + f(8) * (-22) + f(9) * (646) + f(10) * (125) + f(11) * (-453) + f(12) * (-365) + f(13) * (177) + f(14) * (230) + f(15) * (-367) + f(16) * (408) + f(17) * (465) + f(18) * (703) + f(19) * (61) + f(20) * (136) + f(21) * (543) + f(22) * (41) + f(23) * (-54) + f(24) * (54)
if h(5) < 0 then
  h(5) = 0
end if
h(6) = 23325 + f(0) * (122) + f(1) * (-158) + f(2) * (-130) + f(3) * (204) + f(4) * (-64) + f(5) * (-508) + f(6) * (639) + f(7) * (551) + f(8) * (299) + f(9) * (239) + f(10) * (-38) + f(11) * (-406) + f(12) * (-41) + f(13) * (-158) + f(14) * (-309) + f(15) * (353) + f(16) * (131) + f(17) * (-140) + f(18) * (-48) + f(19) * (244) + f(20) * (161) + f(21) * (174) + f(22) * (-9) + f(23) * (91) + f(24) * (715)
if h(6) < 0 then
  h(6) = 0
end if
h(7) = 19286 + f(0) * (-90) + f(1) * (489) + f(2) * (349) + f(3) * (361) + f(4) * (116) + f(5) * (-315) + f(6) * (-91) + f(7) * (-101) + f(8) * (238) + f(9) * (-164) + f(10) * (238) + f(11) * (-133) + f(12) * (125) + f(13) * (458) + f(14) * (371) + f(15) * (3) + f(16) * (30) + f(17) * (203) + f(18) * (-106) + f(19) * (482) + f(20) * (-345) + f(21) * (302) + f(22) * (932) + f(23) * (147) + f(24) * (505)
if h(7) < 0 then
  h(7) = 0
end if
h(8) = 18159 + f(0) * (101) + f(1) * (49) + f(2) * (180) + f(3) * (-178) + f(4) * (-311) + f(5) * (502) + f(6) * (-51) + f(7) * (361) + f(8) * (179) + f(9) * (638) + f(10) * (-61) + f(11) * (240) + f(12) * (314) + f(13) * (248) + f(14) * (-8) + f(15) * (483) + f(16) * (730) + f(17) * (314) + f(18) * (155) + f(19) * (291) + f(20) * (-257) + f(21) * (241) + f(22) * (543) + f(23) * (9) + f(24) * (-66)
if h(8) < 0 then
  h(8) = 0
end if
h(9) = 19073 + f(0) * (411) + f(1) * (470) + f(2) * (170) + f(3) * (61) + f(4) * (50) + f(5) * (-20) + f(6) * (-192) + f(7) * (-211) + f(8) * (60) + f(9) * (68) + f(10) * (-32) + f(11) * (-109) + f(12) * (-126) + f(13) * (-404) + f(14) * (49) + f(15) * (543) + f(16) * (-90) + f(17) * (554) + f(18) * (445) + f(19) * (341) + f(20) * (-324) + f(21) * (-471) + f(22) * (-27) + f(23) * (378) + f(24) * (114)
if h(9) < 0 then
  h(9) = 0
end if
h(10) = 18190 + f(0) * (861) + f(1) * (381) + f(2) * (130) + f(3) * (413) + f(4) * (-252) + f(5) * (152) + f(6) * (159) + f(7) * (421) + f(8) * (-140) + f(9) * (-151) + f(10) * (669) + f(11) * (-70) + f(12) * (515) + f(13) * (338) + f(14) * (102) + f(15) * (453) + f(16) * (-71) + f(17) * (383) + f(18) * (255) + f(19) * (-158) + f(20) * (195) + f(21) * (441) + f(22) * (133) + f(23) * (189) + f(24) * (264)
if h(10) < 0 then
  h(10) = 0
end if
h(11) = 19629 + f(0) * (82) + f(1) * (-702) + f(2) * (275) + f(3) * (91) + f(4) * (-190) + f(5) * (47) + f(6) * (-505) + f(7) * (-288) + f(8) * (-299) + f(9) * (-56) + f(10) * (716) + f(11) * (-16) + f(12) * (78) + f(13) * (18) + f(14) * (95) + f(15) * (6) + f(16) * (302) + f(17) * (-370) + f(18) * (419) + f(19) * (284) + f(20) * (2) + f(21) * (-157) + f(22) * (129) + f(23) * (332) + f(24) * (261)
if h(11) < 0 then
  h(11) = 0
end if
h(12) = 19929 + f(0) * (-187) + f(1) * (342) + f(2) * (-126) + f(3) * (-271) + f(4) * (-109) + f(5) * (-323) + f(6) * (149) + f(7) * (43) + f(8) * (-690) + f(9) * (236) + f(10) * (-95) + f(11) * (383) + f(12) * (276) + f(13) * (62) + f(14) * (485) + f(15) * (215) + f(16) * (-249) + f(17) * (-34) + f(18) * (413) + f(19) * (130) + f(20) * (137) + f(21) * (562) + f(22) * (61) + f(23) * (214) + f(24) * (123)
if h(12) < 0 then
  h(12) = 0
end if
h(13) = 21374 + f(0) * (-49) + f(1) * (121) + f(2) * (69) + f(3) * (190) + f(4) * (856) + f(5) * (44) + f(6) * (-31) + f(7) * (-132) + f(8) * (-120) + f(9) * (458) + f(10) * (407) + f(11) * (-483) + f(12) * (6) + f(13) * (396) + f(14) * (-271) + f(15) * (452) + f(16) * (40) + f(17) * (-47) + f(18) * (-98) + f(19) * (-226) + f(20) * (-24) + f(21) * (342) + f(22) * (192) + f(23) * (508) + f(24) * (-284)
if h(13) < 0 then
  h(13) = 0
end if
h(14) = 18212 + f(0) * (432) + f(1) * (481) + f(2) * (400) + f(3) * (-699) + f(4) * (108) + f(5) * (103) + f(6) * (-31) + f(7) * (-289) + f(8) * (548) + f(9) * (208) + f(10) * (338) + f(11) * (67) + f(12) * (157) + f(13) * (80) + f(14) * (-99) + f(15) * (-136) + f(16) * (179) + f(17) * (-206) + f(18) * (274) + f(19) * (-139) + f(20) * (86) + f(21) * (412) + f(22) * (33) + f(23) * (278) + f(24) * (594)
if h(14) < 0 then
  h(14) = 0
end if
h(15) = 18656 + f(0) * (651) + f(1) * (160) + f(2) * (-271) + f(3) * (341) + f(4) * (228) + f(5) * (-548) + f(6) * (-380) + f(7) * (170) + f(8) * (260) + f(9) * (78) + f(10) * (188) + f(11) * (579) + f(12) * (-65) + f(13) * (58) + f(14) * (-197) + f(15) * (173) + f(16) * (208) + f(17) * (-353) + f(18) * (354) + f(19) * (-48) + f(20) * (-264) + f(21) * (293) + f(22) * (413) + f(23) * (-53) + f(24) * (-198)
if h(15) < 0 then
  h(15) = 0
end if
decision = 0
bestScore = -2147483647
score = 387878561 + h(0) * (-128) + h(1) * (-127) + h(2) * (-9) + h(3) * (-160) + h(4) * (-125) + h(5) * (-151) + h(6) * (-198) + h(7) * (-129) + h(8) * (-126) + h(9) * (-140) + h(10) * (-111) + h(11) * (-199) + h(12) * (-146) + h(13) * (-192) + h(14) * (-125) + h(15) * (-129)
if score > bestScore then
  bestScore = score
  decision = 0
end if
score = 8621915 + h(0) * (113) + h(1) * (102) + h(2) * (10) + h(3) * (106) + h(4) * (96) + h(5) * (110) + h(6) * (83) + h(7) * (86) + h(8) * (101) + h(9) * (96) + h(10) * (95) + h(11) * (62) + h(12) * (124) + h(13) * (115) + h(14) * (101) + h(15) * (103)
if score > bestScore then
  bestScore = score
  decision = 1
end if
score = 9365853 + h(0) * (114) + h(1) * (122) + h(2) * (25) + h(3) * (121) + h(4) * (105) + h(5) * (113) + h(6) * (104) + h(7) * (113) + h(8) * (112) + h(9) * (113) + h(10) * (102) + h(11) * (86) + h(12) * (104) + h(13) * (132) + h(14) * (98) + h(15) * (113)
if score > bestScore then
  bestScore = score
  decision = 2
end if
score = 10032520 + h(0) * (124) + h(1) * (135) + h(2) * (-1) + h(3) * (134) + h(4) * (118) + h(5) * (129) + h(6) * (105) + h(7) * (120) + h(8) * (110) + h(9) * (115) + h(10) * (108) + h(11) * (65) + h(12) * (116) + h(13) * (119) + h(14) * (124) + h(15) * (124)
if score > bestScore then
  bestScore = score
  decision = 3
end if
score = 10514535 + h(0) * (111) + h(1) * (115) + h(2) * (18) + h(3) * (135) + h(4) * (112) + h(5) * (136) + h(6) * (94) + h(7) * (112) + h(8) * (107) + h(9) * (125) + h(10) * (98) + h(11) * (77) + h(12) * (105) + h(13) * (139) + h(14) * (114) + h(15) * (111)
if score > bestScore then
  bestScore = score
  decision = 4
end if
score = 10182099 + h(0) * (118) + h(1) * (123) + h(2) * (-6) + h(3) * (122) + h(4) * (94) + h(5) * (112) + h(6) * (107) + h(7) * (125) + h(8) * (116) + h(9) * (113) + h(10) * (102) + h(11) * (68) + h(12) * (107) + h(13) * (137) + h(14) * (113) + h(15) * (113)
if score > bestScore then
  bestScore = score
  decision = 5
end if
score = 9061429 + h(0) * (102) + h(1) * (104) + h(2) * (17) + h(3) * (120) + h(4) * (107) + h(5) * (107) + h(6) * (99) + h(7) * (105) + h(8) * (107) + h(9) * (108) + h(10) * (94) + h(11) * (94) + h(12) * (107) + h(13) * (134) + h(14) * (96) + h(15) * (112)
if score > bestScore then
  bestScore = score
  decision = 6
end if
score = 10778495 + h(0) * (127) + h(1) * (114) + h(2) * (43) + h(3) * (132) + h(4) * (111) + h(5) * (125) + h(6) * (106) + h(7) * (120) + h(8) * (132) + h(9) * (123) + h(10) * (118) + h(11) * (89) + h(12) * (113) + h(13) * (133) + h(14) * (117) + h(15) * (131)
if score > bestScore then
  bestScore = score
  decision = 7
end if
score = 9785349 + h(0) * (112) + h(1) * (119) + h(2) * (1) + h(3) * (125) + h(4) * (110) + h(5) * (130) + h(6) * (105) + h(7) * (116) + h(8) * (115) + h(9) * (109) + h(10) * (102) + h(11) * (95) + h(12) * (107) + h(13) * (142) + h(14) * (105) + h(15) * (115)
if score > bestScore then
  bestScore = score
  decision = 8
end if
score = 387767339 + h(0) * (-137) + h(1) * (-135) + h(2) * (-16) + h(3) * (-166) + h(4) * (-133) + h(5) * (-152) + h(6) * (-209) + h(7) * (-142) + h(8) * (-122) + h(9) * (-142) + h(10) * (-121) + h(11) * (-185) + h(12) * (-152) + h(13) * (-198) + h(14) * (-139) + h(15) * (-141)
if score > bestScore then
  bestScore = score
  decision = 9
end if
score = 9125238 + h(0) * (115) + h(1) * (113) + h(2) * (36) + h(3) * (104) + h(4) * (98) + h(5) * (120) + h(6) * (76) + h(7) * (94) + h(8) * (107) + h(9) * (122) + h(10) * (97) + h(11) * (66) + h(12) * (133) + h(13) * (122) + h(14) * (107) + h(15) * (112)
if score > bestScore then
  bestScore = score
  decision = 10
end if
score = 9920025 + h(0) * (107) + h(1) * (128) + h(2) * (-22) + h(3) * (122) + h(4) * (105) + h(5) * (128) + h(6) * (116) + h(7) * (113) + h(8) * (113) + h(9) * (109) + h(10) * (99) + h(11) * (103) + h(12) * (97) + h(13) * (152) + h(14) * (108) + h(15) * (119)
if score > bestScore then
  bestScore = score
  decision = 11
end if
score = 9813639 + h(0) * (116) + h(1) * (134) + h(2) * (8) + h(3) * (128) + h(4) * (110) + h(5) * (125) + h(6) * (89) + h(7) * (117) + h(8) * (109) + h(9) * (106) + h(10) * (100) + h(11) * (83) + h(12) * (115) + h(13) * (114) + h(14) * (114) + h(15) * (111)
if score > bestScore then
  bestScore = score
  decision = 12
end if
score = 11515426 + h(0) * (125) + h(1) * (129) + h(2) * (-7) + h(3) * (136) + h(4) * (117) + h(5) * (137) + h(6) * (124) + h(7) * (118) + h(8) * (119) + h(9) * (119) + h(10) * (108) + h(11) * (83) + h(12) * (129) + h(13) * (149) + h(14) * (122) + h(15) * (130)
if score > bestScore then
  bestScore = score
  decision = 13
end if
score = 9815518 + h(0) * (120) + h(1) * (121) + h(2) * (-14) + h(3) * (127) + h(4) * (100) + h(5) * (106) + h(6) * (113) + h(7) * (117) + h(8) * (110) + h(9) * (112) + h(10) * (106) + h(11) * (76) + h(12) * (119) + h(13) * (129) + h(14) * (112) + h(15) * (106)
if score > bestScore then
  bestScore = score
  decision = 14
end if
score = 11022095 + h(0) * (119) + h(1) * (118) + h(2) * (-26) + h(3) * (137) + h(4) * (124) + h(5) * (135) + h(6) * (105) + h(7) * (124) + h(8) * (123) + h(9) * (129) + h(10) * (114) + h(11) * (132) + h(12) * (121) + h(13) * (145) + h(14) * (113) + h(15) * (121)
if score > bestScore then
  bestScore = score
  decision = 15
end if
score = 10193590 + h(0) * (122) + h(1) * (97) + h(2) * (-11) + h(3) * (122) + h(4) * (110) + h(5) * (109) + h(6) * (97) + h(7) * (118) + h(8) * (112) + h(9) * (106) + h(10) * (111) + h(11) * (73) + h(12) * (133) + h(13) * (130) + h(14) * (112) + h(15) * (123)
if score > bestScore then
  bestScore = score
  decision = 16
end if
score = 10897366 + h(0) * (133) + h(1) * (140) + h(2) * (12) + h(3) * (135) + h(4) * (112) + h(5) * (131) + h(6) * (116) + h(7) * (125) + h(8) * (125) + h(9) * (129) + h(10) * (114) + h(11) * (121) + h(12) * (106) + h(13) * (153) + h(14) * (120) + h(15) * (119)
if score > bestScore then
  bestScore = score
  decision = 17
end if
end if
if decision = 18 then
  combatDecision = 8
else
combatDecision = decision
end if
objectiveBuild = 0
if decision >= 9 then
  combatDecision = decision - 9
  objectiveBuild = 1
end if

routeFallback = 0
if combatDecision = 2 or (combatDecision = 8 and bestId = 0) then
  if (objectiveId = 0 or objectiveDistance > 300) and (heroId = 0 or heroDistance > 700) then
    routeFallback = 1
  end if
end if
routeDx = selfX - routeOpeningX
routeDy = selfY - routeOpeningY
if battleTick < 3500 and routeFallback and routeGroupCount >= 3 then
  if routeDx * routeDx + routeDy * routeDy <= 16 then
    groupDeparture = 1
  end if
end if

if combatDecision = 8 then
  if objectiveId <> 0 and objectiveDistance <= 300 then
    attackTarget(objectiveId)
  else
    if heroId <> 0 and heroDistance <= 700 then
      attackTarget(heroId)
    else
      if bestId <> 0 then
        attackTarget(bestId)
      else
        if selfTeam = 0 then
          if battleTick < 3500 and groupDeparture = 0 then
            walkTo(71, 12)
          else
            if battleTick < 4500 then
              walkTo(9, 33)
            else
              walkTo(11, 106)
            end if
          end if
        else
          if battleTick < 3500 and groupDeparture = 0 then
            walkTo(45, 104)
          else
            if battleTick < 4500 then
              walkTo(107, 83)
            else
              walkTo(105, 10)
            end if
          end if
        end if
      end if
    end if
  end if
else
  if bestId <> 0 then
    attackTarget(bestId)
  else
    walkTo(64, 64)
  end if
end if
if selfClass = 7 and heroId <> 0 and ringHeroTarget = selfId then
  if heroDistance > 25 and heroDistance <= 49 then
    castPoint(3, (selfX + ringHeroX) \ 2, (selfY + ringHeroY) \ 2)
  end if
end if
hasHeal = 0
elixirCount = 0
hasMana = 0
hasPoison = 0
hasGear = 0
hasDagger = 0
hasSword = 0
hasArmor = 0
hasAxe = 0
hasBook = 0
emptySlot = 0
slot = 0
while slot < 6
  id = itemId(slot)
  if id = 0 then
    emptySlot = 1
  end if
  if id = 1 or id = 2 then
    hasHeal = 1
    if selfHp * 5 < selfMaxHp * 3 and itemCooldown(slot) = 0 then
      useItem(slot)
    end if
  end if
  if id = 2 then
    elixirCount = elixirCount + itemCount(slot)
  end if
  if id = 3 or id = 22 then
    hasMana = 1
    if objectiveBuild = 0 and selfMana * 5 < selfMaxMana * 2 and itemCooldown(slot) = 0 then
      useItem(slot)
    end if
  end if
  if id = 4 then
    hasPoison = 1
    if objectiveBuild = 0 and bestId <> 0 then
      useItem(slot)
    end if
  end if
  if id >= 5 and id <= 20 then
    hasGear = 1
  end if
  if id = 11 then
    hasDagger = 1
  end if
  if id = 13 then
    hasSword = 1
  end if
  if id = 16 then
    hasArmor = 1
  end if
  if id = 18 then
    hasAxe = 1
  end if
  if id = 20 then
    hasBook = 1
  end if
  slot = slot + 1
wend
if canShop() then
' Stock immediate healing after the opening build. Damage interrupts
' ordinary potion recovery, and a full six-slot pack cannot buy a cure.
if selfClass = 2 and selfLevel >= 4 and elixirCount < 3 then
  if selfGold >= 75 and (elixirCount > 0 or emptySlot <> 0) then
    buyItem(2)
    hasHeal = 1
  end if
end if
if selfHp * 2 < selfMaxHp and hasHeal = 0 then
  if selfGold >= 50 then
    buyItem(2)
  end if
  if selfGold >= 30 then
    buyItem(1)
  end if
end if
if objectiveBuild = 0 then
if selfMaxMana > 0 then
  if selfMana * 2 < selfMaxMana and hasMana = 0 then
    if selfGold >= 45 then
      buyItem(22)
    end if
  end if
end if
if bestId <> 0 and hasPoison = 0 then
  if selfGold >= 40 then
    buyItem(4)
  end if
end if
if emptySlot <> 0 then
  melee = 0
  ranged = 0
  magic = 0
  if selfClass = 0 or selfClass = 4 or selfClass = 5 or selfClass = 9 then
    melee = 1
  end if
  if selfClass = 1 or selfClass = 6 then
    ranged = 1
  end if
  if selfClass = 2 or selfClass = 3 or selfClass = 7 or selfClass = 8 then
    magic = 1
  end if
  if melee = 1 then
    if hasGear = 0 and selfGold >= 70 then
      buyItem(7)
    end if
    if selfGold >= 80 then
      buyItem(5)
    end if
    if selfGold >= 110 then
      buyItem(11)
    end if
    if selfGold >= 150 then
      buyItem(13)
    end if
    if selfGold >= 180 then
      buyItem(18)
    end if
  end if
  if ranged = 1 then
    if hasGear = 0 and selfGold >= 100 then
      buyItem(8)
    end if
    if selfGold >= 150 then
      buyItem(14)
    end if
    if selfGold >= 180 then
      buyItem(19)
    end if
  end if
  if magic = 1 then
    if hasGear = 0 and selfGold >= 140 then
      buyItem(12)
    end if
    if selfGold >= 120 then
      buyItem(10)
    end if
    if selfGold >= 170 then
      buyItem(17)
    end if
    if selfGold >= 190 then
      buyItem(20)
    end if
  end if
  if selfGold >= 90 then
    buyItem(6)
  end if
  if selfGold >= 120 then
    buyItem(9)
  end if
end if
else
  if emptySlot <> 0 then
    if hasDagger = 0 and selfGold >= 110 then
      buyItem(11)
    end if
    if hasSword = 0 and selfGold >= 150 then
      buyItem(13)
    end if
    if hasArmor = 0 and selfGold >= 160 then
      buyItem(16)
    end if
    if hasAxe = 0 and selfGold >= 180 then
      buyItem(18)
    end if
    if hasBook = 0 and selfGold >= 190 then
      buyItem(20)
    end if
  end if
end if
end if
if combatDecision = 1 then
  if selfTeam = 0 then
    walkTo(mapWidth - 10, 10)
  else
    walkTo(10, mapHeight - 10)
  end if
end if
if combatDecision = 2 then
  if objectiveId <> 0 and objectiveDistance <= 300 then
    attackTarget(objectiveId)
  else
    if heroId <> 0 and heroDistance <= 700 then
      attackTarget(heroId)
    else
      if selfTeam = 0 then
        if battleTick < 3500 and groupDeparture = 0 then
          walkTo(71, 12)
        else
          if battleTick < 4500 then
            walkTo(9, 33)
          else
            walkTo(11, 106)
          end if
        end if
      else
        if battleTick < 3500 and groupDeparture = 0 then
          walkTo(45, 104)
        else
          if battleTick < 4500 then
            walkTo(107, 83)
          else
            walkTo(105, 10)
          end if
        end if
      end if
    end if
  end if
end if
if combatDecision >= 3 and combatDecision <= 6 then
  if bestId <> 0 then
    castTarget(combatDecision - 3, bestId)
  else
    castTarget(combatDecision - 3, selfId)
  end if
end if
if combatDecision = 7 then
  walkTo(allyX, allyY)
end if

if decision = 18 and (bestId = 0 or bestDistance > 64) then
  specialistX = mapWidth - 1 - gateHomeX
  specialistY = gateHomeY
  specialistDx = selfX - specialistX
  specialistDy = selfY - specialistY
  if specialistDx * specialistDx + specialistDy * specialistDy <= 64 then
    perimeterStage = 1
  end if
  if perimeterStage <> 0 then
    specialistY = mapHeight - 1 - gateHomeY
  end if
  walkTo(specialistX, specialistY)
end if

if (combatDecision = 2 or combatDecision = 8) and objectiveKind = 4 and objectiveDistance <= 300 and siegeThreatId <> 0 then
  attackTarget(siegeThreatId)
end if

if reserveHome <> 0 then
  reserveGuards = 0
  reserveGuardCritical = 0
  reserveNearest = 1
  reserveDx = selfX - reserveX
  reserveDy = selfY - reserveY
  reserveDistance = reserveDx * reserveDx + reserveDy * reserveDy
  reserveTarget = 0
  reserveTargetDistance = 401
  reserveDirect = 0
  reserveDirectDistance = 401
  reserveHero = 0
  reserveHeroDistance = 401
  reserveFinish = 0
  reserveIndex = 0
  while reserveIndex < objectCount()
    reserveDx = objectX(reserveIndex) - reserveX
    reserveDy = objectY(reserveIndex) - reserveY
    reserveObjectHome = reserveDx * reserveDx + reserveDy * reserveDy
    if objectTeam(reserveIndex) = selfTeam then
      if objectKind(reserveIndex) = 4 and objectHp(reserveIndex) > 0 and reserveObjectHome <= 100 then
        reserveGuards = reserveGuards + 1
        if objectHp(reserveIndex) <= 780 then
          reserveGuardCritical = 1
        end if
      end if
      if objectKind(reserveIndex) = 2 and objectAlive(reserveIndex) and reserveObjectHome < reserveDistance then
        reserveNearest = 0
      end if
    else
      if objectAlive(reserveIndex) then
        if (objectKind(reserveIndex) = 2 or objectKind(reserveIndex) = 3) and reserveObjectHome < reserveDirectDistance then
          if objectTarget(reserveIndex) = reserveHomeId then
            reserveDirect = objectId(reserveIndex)
            reserveDirectDistance = reserveObjectHome
          end if
        end if
        if objectKind(reserveIndex) = 2 and reserveObjectHome < reserveHeroDistance then
          reserveHero = objectId(reserveIndex)
          reserveHeroDistance = reserveObjectHome
        end if
        if (objectKind(reserveIndex) = 2 or objectKind(reserveIndex) = 3) and reserveObjectHome < reserveTargetDistance then
          reserveTargetDistance = reserveObjectHome
          reserveTarget = objectId(reserveIndex)
        end if
        if objectKind(reserveIndex) = 1 and objectHp(reserveIndex) <= selfAttackDamage then
          reserveDx = objectX(reserveIndex) - selfX
          reserveDy = objectY(reserveIndex) - selfY
          reserveRange = selfAttackRange \ 1000
          if (reserveDx * reserveDx + reserveDy * reserveDy) * 3600 <= reserveRange * reserveRange then
            reserveFinish = 1
          end if
        end if
      end if
    end if
    reserveIndex = reserveIndex + 1
  wend
  if reserveHero <> 0 then
    reserveTarget = reserveHero
  end if
  if reserveDirect <> 0 then
    reserveTarget = reserveDirect
  end if
  if (reserveGuards <= 1 or (reserveGuardCritical <> 0 and reserveDistance <= 900)) and reserveNearest <> 0 and reserveFinish = 0 then
    if reserveDistance <= 400 and reserveTarget <> 0 then
      attackTarget(reserveTarget)
    else
      walkTo(reserveX, reserveY)
    end if
  end if
end if

if recoveryInitialized <> 0 and selfAttacksLanded > recoveryLastHit then
  walkTo(selfX, selfY)
end if
recoveryLastHit = selfAttacksLanded
recoveryInitialized = 1
