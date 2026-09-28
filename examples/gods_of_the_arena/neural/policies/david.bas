' David GOTANET1 observation and action glue using ordinary BASIC queries.
' Reusable glue and a synthetic example written for this API.
' This is not a submitted player policy and contains no learned coefficients.
' Coordinates and math cross the Q16.16 boundary explicitly.
dim nnData(1406)
dim nnObjects(24)
dim nnPopulated(24)
dim nnIds(24)
dim nnXs(24)
dim nnYs(24)
dim nnDistances(24)
dim nnWarnings(3)
dim nnWarningTicks(3)
dim nnWarningDistances(3)
dim nnAllowed(91)
dim nnWeights(48)
dim nnHeads(4)
dim nnGoals(15)
dim nnAllies(9)
DATA nnOffsets AS int32 = 0, 8, 33, 82, 86
DATA nnSizes AS int32 = 8, 25, 49, 4, 6
DATA nnDirectionsX AS fixed32 = _
  1.0, 0.9238739013671875, 0.7071075439453125, 0.3826904296875, _
  0.0, -0.3826904296875, -0.7071075439453125, -0.9238739013671875, _
  -1.0, -0.9238739013671875, -0.7071075439453125, -0.3826904296875, _
  0.0, 0.3826904296875, 0.7071075439453125, 0.9238739013671875
DATA nnDirectionsY AS fixed32 = _
  0.0, 0.3826904296875, 0.7071075439453125, 0.9238739013671875, _
  1.0, 0.9238739013671875, 0.7071075439453125, 0.3826904296875, _
  0.0, -0.3826904296875, -0.7071075439453125, -0.9238739013671875, _
  -1.0, -0.9238739013671875, -0.7071075439453125, -0.3826904296875
DATA nnWalkRings AS fixed32 = 2.0, 5.0, 12.0
DATA nnCastRings AS fixed32 = 0.5, 1.25, 2.5

DATA nnExponentials AS fixed32 = _
  1.0, 0.9844970703125, 0.96923828125, 0.9542083740234375, _
  0.9394073486328125, 0.9248504638671875, 0.9105072021484375, 0.896392822265625, _
  0.8824920654296875, 0.8688201904296875, 0.8553466796875, 0.8420867919921875, _
  0.8290252685546875, 0.8161773681640625, 0.80352783203125, 0.7910614013671875, _
  0.7787933349609375, 0.7667236328125, 0.7548370361328125, 0.743133544921875, _
  0.7316131591796875, 0.72027587890625, 0.7091064453125, 0.6981201171875, _
  0.687286376953125, 0.6766357421875, 0.6661376953125, 0.65582275390625, _
  0.6456451416015625, 0.6356353759765625, 0.6257781982421875, 0.6160888671875, _
  0.606536865234375, 0.5971221923828125, 0.5878753662109375, 0.5787506103515625, _
  0.5697784423828125, 0.560943603515625, 0.55224609375, 0.5436859130859375, _
  0.5352630615234375, 0.5269622802734375, 0.518798828125, 0.5107574462890625, _
  0.502838134765625, 0.4950408935546875, 0.48736572265625, 0.4798126220703125, _
  0.4723663330078125, 0.4650421142578125, 0.4578399658203125, 0.4507293701171875, _
  0.4437408447265625, 0.4368743896484375, 0.4300994873046875, 0.423431396484375, _
  0.4168548583984375, 0.410400390625, 0.4040374755859375, 0.39776611328125, _
  0.3916015625, 0.385528564453125, 0.3795623779296875, 0.3736724853515625, _
  0.3678741455078125, 0.3621826171875, 0.3565673828125, 0.3510284423828125, _
  0.3455963134765625, 0.340240478515625, 0.3349609375, 0.3297576904296875, _
  0.32464599609375, 0.3196258544921875, 0.314666748046875, 0.309783935546875, _
  0.3049774169921875, 0.3002471923828125, 0.29559326171875, 0.291015625, _
  0.2864990234375, 0.2820587158203125, 0.2776947021484375, 0.2733917236328125, _
  0.2691497802734375, 0.2649688720703125, 0.2608642578125, 0.2568206787109375, _
  0.252838134765625, 0.2489166259765625, 0.24505615234375, 0.2412567138671875, _
  0.237518310546875, 0.2338409423828125, 0.2302093505859375, 0.2266387939453125, _
  0.2231292724609375, 0.21966552734375, 0.2162628173828125, 0.2129058837890625, _
  0.2096099853515625, 0.20635986328125, 0.203155517578125, 0.20001220703125, _
  0.1969146728515625, 0.1938629150390625, 0.19085693359375, 0.187896728515625, _
  0.1849822998046875, 0.1821136474609375, 0.179290771484375, 0.176513671875, _
  0.17376708984375, 0.17108154296875, 0.168426513671875, 0.1658172607421875, _
  0.163238525390625, 0.1607208251953125, 0.1582183837890625, 0.1557769775390625, _
  0.153350830078125, 0.150970458984375, 0.1486358642578125, 0.146331787109375, _
  0.1440582275390625, 0.1418304443359375, 0.1396331787109375, 0.1374664306640625, _
  0.1353302001953125, 0.13323974609375, 0.13116455078125, 0.1291351318359375, _
  0.12713623046875, 0.1251678466796875, 0.12322998046875, 0.121307373046875, _
  0.1194305419921875, 0.117584228515625, 0.115753173828125, 0.1139678955078125, _
  0.1121978759765625, 0.1104583740234375, 0.1087493896484375, 0.1070556640625, _
  0.1053924560546875, 0.103759765625, 0.1021575927734375, 0.1005706787109375, _
  0.0990142822265625, 0.09747314453125, 0.0959625244140625, 0.094482421875, _
  0.093017578125, 0.0915679931640625, 0.09014892578125, 0.0887603759765625, _
  0.087371826171875, 0.086029052734375, 0.084686279296875, 0.0833740234375, _
  0.08209228515625, 0.080810546875, 0.079559326171875, 0.0783233642578125, _
  0.077117919921875, 0.0759124755859375, 0.074737548828125, 0.073577880859375, _
  0.0724334716796875, 0.071319580078125, 0.0702056884765625, 0.069122314453125, _
  0.06805419921875, 0.0670013427734375, 0.0659637451171875, 0.06494140625, _
  0.063934326171875, 0.0629425048828125, 0.0619659423828125, 0.061004638671875, _
  0.06005859375, 0.0591278076171875, 0.0582122802734375, 0.05731201171875, _
  0.0564117431640625, 0.0555419921875, 0.0546875, 0.0538330078125, _
  0.0529937744140625, 0.0521697998046875, 0.051361083984375, 0.050567626953125, _
  0.0497894287109375, 0.04901123046875, 0.048248291015625, 0.0475006103515625, _
  0.0467681884765625, 0.046051025390625, 0.0453338623046875, 0.0446319580078125, _
  0.0439300537109375, 0.0432586669921875, 0.0425872802734375, 0.04193115234375, _
  0.0412750244140625, 0.0406341552734375, 0.040008544921875, 0.0393829345703125, _
  0.0387725830078125, 0.038177490234375, 0.0375823974609375, 0.0370025634765625, _
  0.0364227294921875, 0.035858154296875, 0.035308837890625, 0.034759521484375, _
  0.0342254638671875, 0.03369140625, 0.033172607421875, 0.03265380859375, _
  0.0321502685546875, 0.031646728515625, 0.031158447265625, 0.030670166015625, _
  0.0301971435546875, 0.02972412109375, 0.029266357421875, 0.02880859375, _
  0.0283660888671875, 0.027923583984375, 0.027496337890625, 0.027069091796875, _
  0.026641845703125, 0.0262298583984375, 0.0258331298828125, 0.025421142578125, _
  0.0250396728515625, 0.0246429443359375, 0.024261474609375, 0.023895263671875, _
  0.0235137939453125, 0.0231475830078125, 0.022796630859375, 0.0224456787109375, _
  0.0220947265625, 0.0217437744140625, 0.0214080810546875, 0.021087646484375, _
  0.020751953125, 0.0204315185546875, 0.020111083984375, 0.019805908203125, _
  0.019500732421875, 0.019195556640625, 0.018890380859375, 0.0186004638671875, _
  0.018310546875, 0.018035888671875, 0.0177459716796875, 0.0174713134765625, _
  0.0172119140625, 0.016937255859375, 0.0166778564453125, 0.01641845703125, _
  0.0161590576171875, 0.0159149169921875, 0.0156707763671875, 0.0154266357421875, _
  0.0151824951171875, 0.01495361328125, 0.01470947265625, 0.014495849609375, _
  0.0142669677734375, 0.0140380859375, 0.013824462890625, 0.01361083984375, _
  0.013397216796875, 0.0131988525390625, 0.0129852294921875, 0.012786865234375, _
  0.0125885009765625, 0.01239013671875, 0.01220703125, 0.0120086669921875, _
  0.0118255615234375, 0.0116424560546875, 0.0114593505859375, 0.01129150390625, _
  0.0111083984375, 0.0109405517578125, 0.010772705078125, 0.0106048583984375, _
  0.01043701171875, 0.0102691650390625, 0.0101165771484375, 0.0099639892578125, _
  0.009796142578125, 0.0096588134765625, 0.0095062255859375, 0.0093536376953125, _
  0.00921630859375, 0.009063720703125, 0.0089263916015625, 0.0087890625, _
  0.0086517333984375, 0.008514404296875, 0.008392333984375, 0.0082550048828125, _
  0.0081329345703125, 0.00799560546875, 0.00787353515625, 0.00775146484375, _
  0.00762939453125, 0.0075225830078125, 0.0074005126953125, 0.0072784423828125, _
  0.007171630859375, 0.0070648193359375, 0.0069580078125, 0.0068511962890625, _
  0.006744384765625, 0.0066375732421875, 0.00653076171875, 0.0064239501953125, _
  0.0063323974609375, 0.0062255859375, 0.006134033203125, 0.00604248046875, _
  0.005950927734375, 0.005859375, 0.005767822265625, 0.00567626953125, _
  0.005584716796875, 0.0054931640625, 0.0054168701171875, 0.0053253173828125, _
  0.0052490234375, 0.0051727294921875, 0.0050811767578125, 0.0050048828125, _
  0.0049285888671875, 0.004852294921875, 0.0047760009765625, 0.00469970703125, _
  0.0046234130859375, 0.0045623779296875, 0.004486083984375, 0.004425048828125, _
  0.0043487548828125, 0.0042877197265625, 0.00421142578125, 0.004150390625, _
  0.00408935546875, 0.0040283203125, 0.00396728515625, 0.00390625, _
  0.00384521484375, 0.0037841796875, 0.00372314453125, 0.003662109375, _
  0.00360107421875, 0.0035552978515625, 0.0034942626953125, 0.003448486328125, _
  0.003387451171875, 0.0033416748046875, 0.0032806396484375, 0.00323486328125, _
  0.0031890869140625, 0.0031280517578125, 0.003082275390625, 0.0030364990234375, _
  0.00299072265625, 0.0029449462890625, 0.002899169921875, 0.0028533935546875, _
  0.0028076171875, 0.0027618408203125, 0.002716064453125, 0.002685546875, _
  0.0026397705078125, 0.002593994140625, 0.0025634765625, 0.0025177001953125, _
  0.002471923828125, 0.00244140625, 0.0023956298828125, 0.0023651123046875, _
  0.0023345947265625, 0.002288818359375, 0.00225830078125, 0.002227783203125, _
  0.0021820068359375, 0.0021514892578125, 0.0021209716796875, 0.0020904541015625, _
  0.0020599365234375, 0.0020294189453125, 0.0019989013671875, 0.0019683837890625, _
  0.0019378662109375, 0.0019073486328125, 0.0018768310546875, 0.0018463134765625, _
  0.0018157958984375, 0.0017852783203125, 0.0017547607421875, 0.0017242431640625, _
  0.001708984375, 0.001678466796875, 0.00164794921875, 0.0016326904296875, _
  0.0016021728515625, 0.0015716552734375, 0.001556396484375, 0.00152587890625, _
  0.0015106201171875, 0.0014801025390625, 0.0014495849609375, 0.001434326171875, _
  0.0014190673828125, 0.0013885498046875, 0.001373291015625, 0.0013427734375, _
  0.0013275146484375, 0.001312255859375, 0.00128173828125, 0.0012664794921875, _
  0.001251220703125, 0.001220703125, 0.0012054443359375, 0.001190185546875, _
  0.0011749267578125, 0.00115966796875, 0.001129150390625, 0.0011138916015625, _
  0.0010986328125, 0.0010833740234375, 0.001068115234375, 0.0010528564453125, _
  0.00103759765625, 0.0010223388671875, 0.001007080078125, 0.0009918212890625, _
  0.0009765625, 0.0009613037109375, 0.000946044921875, 0.0009307861328125, _
  0.00091552734375, 0.0009002685546875, 0.000885009765625, 0.0008697509765625, _
  0.0008544921875, 0.0008392333984375, 0.000823974609375, 0.000823974609375, _
  0.0008087158203125, 0.00079345703125, 0.0007781982421875, 0.000762939453125, _
  0.000762939453125, 0.0007476806640625, 0.000732421875, 0.0007171630859375, _
  0.0007171630859375, 0.000701904296875, 0.0006866455078125, 0.00067138671875, _
  0.00067138671875, 0.0006561279296875, 0.000640869140625, 0.000640869140625, _
  0.0006256103515625, 0.0006103515625, 0.0006103515625, 0.0005950927734375, _
  0.0005950927734375, 0.000579833984375, 0.0005645751953125, 0.0005645751953125, _
  0.00054931640625, 0.00054931640625, 0.0005340576171875, 0.0005340576171875, _
  0.000518798828125, 0.000518798828125, 0.0005035400390625, 0.00048828125, _
  0.00048828125, 0.0004730224609375, 0.0004730224609375, 0.0004730224609375, _
  0.000457763671875, 0.000457763671875, 0.0004425048828125, 0.0004425048828125, _
  0.00042724609375, 0.00042724609375, 0.0004119873046875, 0.0004119873046875, _
  0.0004119873046875, 0.000396728515625, 0.000396728515625, 0.0003814697265625, _
  0.0003814697265625, 0.0003814697265625, 0.0003662109375, 0.0003662109375, _
  0.0003509521484375, 0.0003509521484375, 0.0003509521484375, 0.000335693359375, _
  0.000335693359375

sub nnClamp(low, high)
  if nnValue < low then
    nnValue = low
  elseif nnValue > high then
    nnValue = high
  end if
end sub

sub nnRoot(value)
  nnValue = 0.0
  if value <= 0.0 then
    exit sub
  end if
  nnValue = 1.0
  while nnValue * nnValue < value
    nnValue = nnValue * 2.0
  wend
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
  nnValue = (nnValue + value / nnValue) / 2.0
end sub

sub nnExp(value)
  nnValue = 0.0
  if value <= -16.0 then
    exit sub
  end if
  nnFactor = 1.0
  if value < -8.0 then
    value = value + 8.0
    nnFactor = 0.0003354626
  end if
  nnExpPosition = -value * 64.0
  nnExpIndex = floor(nnExpPosition)
  nnFraction = nnExpPosition - nnExpIndex
  nnValue = nnExponentials(nnExpIndex)
  if nnExpIndex < 512 then
    nnValue = nnValue + nnFraction * (nnExponentials(nnExpIndex + 1) - nnValue)
  end if
  nnValue = nnValue * nnFactor
end sub

sub nnFloor(value)
  nnInteger = floor(value)
end sub

sub nnRatio(nnNumerator, nnDenominator)
  ' Normalize nonnegative int32 counters before crossing into Q16.16.
  if nnDenominator <= 0 then
    nnDenominator = 1
  end if
  if nnNumerator < 0 then
    nnNumerator = 0
  end if
  nnWhole = nnNumerator \ nnDenominator
  nnRemainder = nnNumerator mod nnDenominator
  nnFraction = 0.0
  nnBit = 0.5
  for nnRatioI = 1 to 16
    if nnRemainder >= nnDenominator - nnRemainder then
      nnRemainder = nnRemainder - (nnDenominator - nnRemainder)
      nnFraction = nnFraction + nnBit
    else
      nnRemainder = nnRemainder * 2
    end if
    nnBit = nnBit / 2.0
  next nnRatioI
  if nnRemainder >= nnDenominator - nnRemainder then
    nnFraction = nnFraction + 0.0000152587890625
  end if
  nnValue = nnWhole + nnFraction
end sub

sub nnInitialize()
  if nnInitialized then
    exit sub
  end if
  nnAllyCount = 0
  for nnA = 0 to draftPlayerCount() - 1
    if draftPlayerTeam(nnA) = selfTeam then
      nnAllies(nnAllyCount) = draftPlayerId(nnA)
      nnAllyCount = nnAllyCount + 1
    end if
  next nnA
  nnState = blobCreate()
  nnSeed = matchInfo(2) + selfId * 7919
  nnPeriod = 4
  nnSampling = 1
  nnMask = 1
  nnTemperature = 1.0
  nnGoals(0) = 1.0
  nnInitialized = 1
end sub

sub nnObserve()
  nnData(30) = 0.0
  nnData(31) = 0.0
  nnData(32) = 0.0
  nnData(33) = 0.0
  nnData(34) = 0.0
  nnData(35) = 0.0
  nnData(36) = 0.0
  nnData(37) = 0.0
  nnData(38) = 0.0
  nnData(39) = 0.0
  nnData(40) = 0.0
  nnData(41) = 0.0
  nnData(42) = 0.0
  nnData(43) = 0.0
  nnData(44) = 0.0
  nnSelfX = selfInfo(0)
  nnSelfY = selfInfo(1)
  nnSide = 1 - selfTeam * 2
  nnOrigin = matchInfo(5)
  nnAttackRange = selfInfo(15)
  nnData(0) = -(selfHp > 0)
  nnValue = selfHp / selfMaxHp
  nnClamp(0, 1)
  nnData(1) = nnValue
  nnValue = selfMana / selfMaxMana
  nnClamp(0, 1)
  nnData(2) = nnValue
  nnData(3) = selfMaxHp / 2000.0
  nnData(4) = selfMaxMana / 1000.0
  nnRatio(selfGold, 1000)
  nnData(5) = nnValue
  nnData(6) = selfLevel / 20.0
  nnValue = selfInfo(2) / selfInfo(3)
  nnClamp(0, 1)
  nnData(7) = nnValue
  nnRatio(selfInfo(4), 20000)
  nnData(8) = nnValue
  nnData(9) = nnSelfX * nnSide / 64.0
  nnData(10) = nnSelfY * nnSide / 64.0
  nnData(11) = selfTeam
  nnRatio(matchInfo(0), matchInfo(1))
  nnClamp(0, 1)
  nnData(12) = nnValue
  nnValue = selfAttackCooldown / 48.0
  nnClamp(0, 2)
  nnData(13) = nnValue
  nnData(14) = nnAttackRange / 10.0
  nnData(15) = selfAttackDamage / 200.0
  nnData(16) = selfInfo(16) * tickRate / 5.0
  nnData(17) = -(selfTarget <> 0)
  nnValue = selfStunTicks / 72.0
  nnClamp(0, 2)
  nnData(18) = nnValue
  nnValue = selfRootTicks / 72.0
  nnClamp(0, 2)
  nnData(19) = nnValue
  nnValue = selfSilenceTicks / 72.0
  nnClamp(0, 2)
  nnData(20) = nnValue
  nnValue = selfChannelTicks / 72.0
  nnClamp(0, 2)
  nnData(21) = nnValue
  nnValue = selfPortalCooldown / 1440.0
  nnClamp(0, 2)
  nnData(22) = nnValue
  nnValue = selfRespawnTicks / 1440.0
  nnClamp(0, 2)
  nnData(23) = nnValue
  nnData(24) = selfInfo(9) / 4.0
  nnData(25) = -selfInfo(7)
  nnData(26) = -selfInfo(8)
  nnData(27) = selfDeaths / 10.0
  nnData(28) = -(lastActionError() <> 0)
  nnData(29) = -(buybackPrice() > 0 and selfGold >= buybackPrice())
  nnData(30 + selfClass) = 1.0
  nnData(40 + selfInfo(6)) = 1.0
  nnValue = selfInfo(13) * nnSide * 10.0
  nnClamp(-4, 4)
  nnData(45) = nnValue
  nnValue = selfInfo(14) * nnSide * 10.0
  nnClamp(-4, 4)
  nnData(46) = nnValue
  nnData(47) = -selfInfo(5)
  for nnA = 0 to 3
    nnBase = 48 + nnA * 16
    nnData(nnBase + 11) = 0.0
    nnData(nnBase + 12) = 0.0
    nnData(nnBase + 13) = 0.0
    nnData(nnBase + 14) = 0.0
    nnData(nnBase + 0) = abilityLevel(nnA) / abilityMaxLevel(nnA)
    nnData(nnBase + 1) = -(abilityLevel(nnA) > 0)
    nnValue = abilityCooldown(nnA) / 240.0
    nnClamp(0, 2)
    nnData(nnBase + 2) = nnValue
    nnData(nnBase + 3) = abilityCharges(nnA) / 3.0
    nnValue = abilityRecharge(nnA) / 240.0
    nnClamp(0, 2)
    nnData(nnBase + 4) = nnValue
    nnData(nnBase + 5) = abilityManaCost(nnA) / 200.0
    nnData(nnBase + 6) = -(selfHp > 0 and abilityLevel(nnA) > 0 and abilityCooldown(nnA) = 0 and abilityCharges(nnA) > 0 and selfMana >= abilityManaCost(nnA) and selfSilenceTicks = 0)
    nnData(nnBase + 7) = abilityDamage(nnA) / 300.0
    nnData(nnBase + 8) = abilityHeal(nnA) / 300.0
    nnData(nnBase + 9) = abilityRestore(nnA) / 200.0
    nnData(nnBase + 10) = abilityInfo(nnA, 0) / 10.0
    nnData(nnBase + 11 + abilityInfo(nnA, 1)) = 1.0
    nnData(nnBase + 15) = abilityInfo(nnA, 2) / 3.0
  next nnA
  for nnI = 0 to 5
    nnBase = 112 + nnI * 25
    nnData(nnBase + 0) = 0.0
    nnData(nnBase + 1) = 0.0
    nnData(nnBase + 2) = 0.0
    nnData(nnBase + 3) = 0.0
    nnData(nnBase + 4) = 0.0
    nnData(nnBase + 5) = 0.0
    nnData(nnBase + 6) = 0.0
    nnData(nnBase + 7) = 0.0
    nnData(nnBase + 8) = 0.0
    nnData(nnBase + 9) = 0.0
    nnData(nnBase + 10) = 0.0
    nnData(nnBase + 11) = 0.0
    nnData(nnBase + 12) = 0.0
    nnData(nnBase + 13) = 0.0
    nnData(nnBase + 14) = 0.0
    nnData(nnBase + 15) = 0.0
    nnData(nnBase + 16) = 0.0
    nnData(nnBase + 17) = 0.0
    nnData(nnBase + 18) = 0.0
    nnData(nnBase + 19) = 0.0
    nnData(nnBase + 20) = 0.0
    nnData(nnBase + 21) = 0.0
    nnData(nnBase + 22) = 0.0
    nnData(nnBase + itemId(nnI)) = 1.0
    nnData(nnBase + 23) = itemCount(nnI) / 4.0
    nnValue = itemCooldown(nnI) / 240.0
    nnClamp(0, 2)
    nnData(nnBase + 24) = nnValue
  next nnI
  for nnS = 0 to 24
    nnObjects(nnS) = -1
    nnIds(nnS) = 0
    nnDistances(nnS) = 32767.0
  next nnS
  nnOwnAlive = 0
  nnEnemyVisible = 0
  nnOwnLevels = 0
  nnEnemyLevels = 0
  for nnI = 0 to objectCount() - 1
    nnId = objectId(nnI)
    nnKind = objectKind(nnI)
    nnTeam = objectTeam(nnI)
    nnAlive = objectInfo(nnI, 3)
    nnX = objectInfo(nnI, 0)
    nnY = objectInfo(nnI, 1)
    nnDx = (nnX - nnSelfX) / 16.0
    nnDy = (nnY - nnSelfY) / 16.0
    nnDistance = nnDx * nnDx + nnDy * nnDy
    nnSlot = -1
    nnStart = -1
    nnLast = -1
    if nnKind = 1 then
      nnSlot = 17
      if nnTeam <> selfTeam then
        nnSlot = 18
      end if
    elseif nnKind = 2 then
      nnRoster = nnId - 100
      if nnTeam = selfTeam then
        nnOwnLevels = nnOwnLevels + objectLevel(nnI)
        if nnAlive then
          nnOwnAlive = nnOwnAlive + 1
          nnSlot = nnRoster mod 5 + 1
          if nnRoster mod 5 > (selfId - 100) mod 5 then
            nnSlot = nnSlot - 1
          end if
          if nnId = selfId then
            nnSlot = 0
          end if
        end if
      else
        nnEnemyVisible = nnEnemyVisible + 1
        nnEnemyLevels = nnEnemyLevels + objectLevel(nnI)
        nnSlot = 5 + nnRoster mod 5
      end if
    elseif nnKind = 3 and nnAlive then
      nnStart = 10
      nnLast = 16
    elseif nnKind = 6 and nnAlive then
      nnStart = 21
      nnLast = 24
    elseif (nnKind = 4 or nnKind = 5) and objectHp(nnI) > 0 then
      if nnTeam <> selfTeam then
        nnStart = 20
        nnLast = 20
      elseif nnKind = 4 then
        nnDx = (nnX - selfInfo(17)) / 16.0
        nnDy = (nnY - selfInfo(18)) / 16.0
        nnDistance = nnDx * nnDx + nnDy * nnDy
        nnStart = 19
        nnLast = 19
      end if
    end if
    if nnStart >= 0 then
      for nnS = nnStart to nnLast
        if nnDistance < nnDistances(nnS) or (nnDistance = nnDistances(nnS) and nnId < nnIds(nnS)) then
          for nnJ = nnLast to nnS + 1 step -1
            nnObjects(nnJ) = nnObjects(nnJ - 1)
            nnIds(nnJ) = nnIds(nnJ - 1)
            nnDistances(nnJ) = nnDistances(nnJ - 1)
          next nnJ
          nnSlot = nnS
          exit for
        end if
      next nnS
    end if
    if nnSlot >= 0 then
      nnObjects(nnSlot) = nnI
      nnIds(nnSlot) = nnId
      nnDistances(nnSlot) = nnDistance
    end if
  next nnI
  for nnS = 0 to 24
    nnI = nnObjects(nnS)
    nnBase = 262 + nnS * 40
    if nnI < 0 and nnPopulated(nnS) then
      nnData(nnBase + 0) = 0.0
      nnData(nnBase + 1) = 0.0
      nnData(nnBase + 2) = 0.0
      nnData(nnBase + 3) = 0.0
      nnData(nnBase + 4) = 0.0
      nnData(nnBase + 5) = 0.0
      nnData(nnBase + 6) = 0.0
      nnData(nnBase + 7) = 0.0
      nnData(nnBase + 8) = 0.0
      nnData(nnBase + 9) = 0.0
      nnData(nnBase + 10) = 0.0
      nnData(nnBase + 11) = 0.0
      nnData(nnBase + 12) = 0.0
      nnData(nnBase + 13) = 0.0
      nnData(nnBase + 14) = 0.0
      nnData(nnBase + 15) = 0.0
      nnData(nnBase + 16) = 0.0
      nnData(nnBase + 17) = 0.0
      nnData(nnBase + 18) = 0.0
      nnData(nnBase + 19) = 0.0
      nnData(nnBase + 20) = 0.0
      nnData(nnBase + 21) = 0.0
      nnData(nnBase + 22) = 0.0
      nnData(nnBase + 23) = 0.0
      nnData(nnBase + 24) = 0.0
      nnData(nnBase + 25) = 0.0
      nnData(nnBase + 26) = 0.0
      nnData(nnBase + 27) = 0.0
      nnData(nnBase + 28) = 0.0
      nnData(nnBase + 29) = 0.0
      nnData(nnBase + 30) = 0.0
      nnData(nnBase + 31) = 0.0
      nnData(nnBase + 32) = 0.0
      nnData(nnBase + 33) = 0.0
      nnData(nnBase + 34) = 0.0
      nnData(nnBase + 35) = 0.0
      nnData(nnBase + 36) = 0.0
      nnData(nnBase + 37) = 0.0
      nnData(nnBase + 38) = 0.0
      nnData(nnBase + 39) = 0.0
      nnPopulated(nnS) = 0
    end if
    if nnI >= 0 then
      nnPopulated(nnS) = 1
      nnData(nnBase + 7) = 0.0
      nnData(nnBase + 8) = 0.0
      nnData(nnBase + 9) = 0.0
      nnData(nnBase + 10) = 0.0
      nnData(nnBase + 11) = 0.0
      nnData(nnBase + 12) = 0.0
      nnData(nnBase + 29) = 0.0
      nnData(nnBase + 30) = 0.0
      nnData(nnBase + 31) = 0.0
      nnData(nnBase + 32) = 0.0
      nnData(nnBase + 33) = 0.0
      nnData(nnBase + 34) = 0.0
      nnData(nnBase + 35) = 0.0
      nnData(nnBase + 36) = 0.0
      nnData(nnBase + 37) = 0.0
      nnData(nnBase + 38) = 0.0
      nnData(nnBase + 39) = 0.0
      nnXs(nnS) = objectInfo(nnI, 0)
      nnYs(nnS) = objectInfo(nnI, 1)
      nnDx = (nnXs(nnS) - nnSelfX) * nnSide / 16.0
      nnDy = (nnYs(nnS) - nnSelfY) * nnSide / 16.0
      nnRoot(nnDx * nnDx + nnDy * nnDy)
      nnDistance = nnValue
      nnHp = objectHp(nnI)
      if nnHp < 0 then
        nnHp = 0
      end if
      nnMaxHp = objectInfo(nnI, 2)
      nnTarget = objectTarget(nnI)
      nnKind = objectKind(nnI)
      nnTeam = objectTeam(nnI)
      nnData(nnBase + 0) = 1.0
      nnValue = nnDx
      nnClamp(-4, 4)
      nnData(nnBase + 1) = nnValue
      nnValue = nnDy
      nnClamp(-4, 4)
      nnData(nnBase + 2) = nnValue
      nnValue = nnDistance
      nnClamp(0, 8)
      nnData(nnBase + 3) = nnValue
      nnValue = nnHp / nnMaxHp
      nnClamp(0, 1)
      nnData(nnBase + 4) = nnValue
      nnData(nnBase + 5) = nnHp / 2000.0
      nnData(nnBase + 6) = 0.0
      nnData(nnBase + 13) = -objectInfo(nnI, 3)
      nnData(nnBase + 14) = objectLevel(nnI) / 20.0
      nnData(nnBase + 15) = objectMana(nnI) / 1000.0
      nnData(nnBase + 16) = -(nnTarget <> 0 and nnTarget = selfId)
      nnData(nnBase + 17) = -(objectId(nnI) <> 0 and objectId(nnI) = selfTarget)
      nnData(nnBase + 18) = 0.0
      nnValue = objectStunTicks(nnI) / 72.0
      nnClamp(0, 2)
      nnData(nnBase + 19) = nnValue
      nnValue = objectRootTicks(nnI) / 72.0
      nnClamp(0, 2)
      nnData(nnBase + 20) = nnValue
      nnValue = objectSilenceTicks(nnI) / 72.0
      nnClamp(0, 2)
      nnData(nnBase + 21) = nnValue
      nnValue = objectInfo(nnI, 6) * nnSide * 10.0
      nnClamp(-4, 4)
      nnData(nnBase + 22) = nnValue
      nnValue = objectInfo(nnI, 7) * nnSide * 10.0
      nnClamp(-4, 4)
      nnData(nnBase + 23) = nnValue
      nnData(nnBase + 24) = objectInfo(nnI, 4) * nnSide
      nnData(nnBase + 25) = objectInfo(nnI, 5) * nnSide
      nnData(nnBase + 26) = -(nnDistance <= nnAttackRange / 16.0)
      nnData(nnBase + 27) = -(nnHp > 0 and nnHp <= selfAttackDamage)
      nnData(nnBase + 28) = objectReturning(nnI)
      nnData(nnBase + 6 + nnKind) = 1.0
      if nnTeam <> 2 then
        nnData(nnBase + 6) = -1.0
        if nnTeam = selfTeam then
          nnData(nnBase + 6) = 1.0
        end if
      end if
      for nnA = 0 to nnAllyCount - 1
        if nnTarget <> 0 and nnTarget = nnAllies(nnA) then
          nnData(nnBase + 18) = 1.0
        end if
      next nnA
      if nnKind = 3 then
        nnData(nnBase + 29) = objectClass(nnI)
      elseif nnKind = 6 then
        nnData(nnBase + 29) = objectClass(nnI) / 3.0
      elseif nnKind = 2 then
        nnData(nnBase + 30 + objectClass(nnI)) = 1.0
      end if
    end if
  next nnS
  for nnS = 0 to 3
    nnWarnings(nnS) = -1
    nnWarningTicks(nnS) = 2147483647
    nnWarningDistances(nnS) = 32767.0
  next nnS
  for nnI = 0 to spellCount() - 1
    nnImpact = spellImpactTick(nnI)
    nnDx = (spellInfo(nnI, 0) - nnSelfX) / 16.0
    nnDy = (spellInfo(nnI, 1) - nnSelfY) / 16.0
    nnDistance = nnDx * nnDx + nnDy * nnDy
    for nnS = 0 to 3
      if nnImpact < nnWarningTicks(nnS) or (nnImpact = nnWarningTicks(nnS) and nnDistance < nnWarningDistances(nnS)) then
        for nnJ = 3 to nnS + 1 step -1
          nnWarnings(nnJ) = nnWarnings(nnJ - 1)
          nnWarningTicks(nnJ) = nnWarningTicks(nnJ - 1)
          nnWarningDistances(nnJ) = nnWarningDistances(nnJ - 1)
        next nnJ
        nnWarnings(nnS) = nnI
        nnWarningTicks(nnS) = nnImpact
        nnWarningDistances(nnS) = nnDistance
        exit for
      end if
    next nnS
  next nnI
  for nnS = 0 to 3
    nnI = nnWarnings(nnS)
    nnBase = 1262 + nnS * 8
    nnData(nnBase + 0) = 0.0
    nnData(nnBase + 1) = 0.0
    nnData(nnBase + 2) = 0.0
    nnData(nnBase + 3) = 0.0
    nnData(nnBase + 4) = 0.0
    nnData(nnBase + 5) = 0.0
    nnData(nnBase + 6) = 0.0
    nnData(nnBase + 7) = 0.0
    if nnI >= 0 then
      nnData(nnBase) = 1.0
      nnValue = (spellInfo(nnI, 0) - nnSelfX) * nnSide / 16.0
      nnClamp(-4, 4)
      nnData(nnBase + 1) = nnValue
      nnValue = (spellInfo(nnI, 1) - nnSelfY) * nnSide / 16.0
      nnClamp(-4, 4)
      nnData(nnBase + 2) = nnValue
      nnRoot(nnWarningDistances(nnS))
      nnClamp(0, 8)
      nnData(nnBase + 3) = nnValue
      nnValue = (nnWarningTicks(nnS) - worldTick) / 72.0
      nnClamp(0, 4)
      nnData(nnBase + 4) = nnValue
      nnData(nnBase + 5) = -spellInfo(nnI, 2)
      nnData(nnBase + 6) = -spellInfo(nnI, 3)
      nnData(nnBase + 7) = spellAbility(nnI) / 40.0
    end if
  next nnS
  nnData(1294) = nnData(946)
  nnData(1295) = nnData(955)
  for nnS = 0 to 3
    nnTotal = matchInfo(9 + nnS * 2)
    if nnTotal > 0 then
      nnData(1296 + nnS) = matchInfo(8 + nnS * 2) / nnTotal
    end if
  next nnS
  nnData(1300) = -1.0
  if nnIds(18) <> 0 then
    nnData(1300) = nnData(986)
  end if
  nnData(1301) = nnOwnAlive / 5.0
  nnData(1302) = nnEnemyVisible / 5.0
  nnData(1303) = matchInfo(3) / matchInfo(4)
  nnData(1304) = nnOwnLevels / 50.0
  nnData(1305) = nnEnemyLevels / 50.0
  nnRatio(selfInfo(10), 5000)
  nnData(1306) = nnValue
  nnData(1307) = selfInfo(11) / 10.0
  nnData(1308) = selfInfo(12) / 10.0
  nnFloor(nnSelfX + nnOrigin)
  nnCenterX = nnInteger
  nnFloor(nnSelfY + nnOrigin)
  nnCenterY = nnInteger
  nnBase = 1310
  nnTerrainY = nnCenterY - 8 * nnSide
  for nnRow = 0 to 8
    nnTerrainX = nnCenterX - 8 * nnSide
    for nnCol = 0 to 8
      nnData(nnBase) = terrainWalkableAt(nnTerrainX, nnTerrainY, selfLayer)
      nnTerrainX = nnTerrainX + 2 * nnSide
      nnBase = nnBase + 1
    next nnCol
    nnTerrainY = nnTerrainY + 2 * nnSide
  next nnRow
  for nnI = 0 to 15
    nnData(1391 + nnI) = nnGoals(nnI)
  next nnI
end sub

sub nnChoose()
  for nnI = 0 to 91
    nnAllowed(nnI) = 1
  next nnI
  if nnMask then
    nnAllowed(3) = 0
    nnAllowed(4) = 0
    for nnA = 0 to 3
      if abilityInfo(nnA, 1) = 0 or abilityInfo(nnA, 3) <> 0 then
        nnAllowed(4) = 1
      end if
    next nnA
    for nnS = 0 to 24
      nnAllowed(8 + nnS) = -(nnIds(nnS) <> 0)
      if nnIds(nnS) <> 0 then
        nnBase = 262 + nnS * 40
        if nnS <> 0 and nnData(nnBase + 6) <> 1.0 and nnData(nnBase + 28) = 0 then
          nnAttackable = nnData(nnBase + 13)
          if nnData(nnBase + 7) or nnData(nnBase + 10) or nnData(nnBase + 11) then
            nnAttackable = nnData(nnBase + 5) > 0
          end if
          if nnAttackable then
            nnAllowed(3) = 1
          end if
          if nnData(nnBase + 13) then
            nnAllowed(4) = 1
          end if
        end if
      end if
    next nnS
  end if
  for nnH = 0 to 4
    nnBase = nnOffsets(nnH)
    nnCount = nnSizes(nnH)
    nnBest = -1
    for nnI = 0 to nnCount - 1
      if nnAllowed(nnBase + nnI) then
        if nnBest < 0 then
          nnBest = nnI
        elseif nnResult(nnBase + nnI) > nnResult(nnBase + nnBest) then
          nnBest = nnI
        end if
      end if
    next nnI
    if nnBest < 0 then
      nnBest = 0
    end if
    if nnSampling then
      nnTop = nnResult(nnBase + nnBest)
      nnTotal = 0.0
      for nnI = 0 to nnCount - 1
        nnWeights(nnI) = 0.0
        if nnAllowed(nnBase + nnI) then
          nnDelta = nnResult(nnBase + nnI) / 2.0 - nnTop / 2.0
          nnValue = 0.0
          if nnDelta > -8.0 * nnTemperature then
            nnExp(nnDelta * 2.0 / nnTemperature)
          end if
          nnWeights(nnI) = nnValue
          nnTotal = nnTotal + nnValue
        end if
      next nnI
      nnSeed = nnSeed * 1664525 + 1013904223
      nnDraw = (nnSeed and 32767) / 16384.0 / 2.0 * nnTotal
      nnSum = 0.0
      for nnI = 0 to nnCount - 1
        nnSum = nnSum + nnWeights(nnI)
        if nnDraw < nnSum then
          nnBest = nnI
          exit for
        end if
      next nnI
    end if
    nnHeads(nnH) = nnBest
  next nnH
end sub

sub nnDispatch()
  nnVerb = nnHeads(0)
  nnTarget = nnHeads(1)
  nnPoint = nnHeads(2)
  nnX = nnSelfX
  nnY = nnSelfY
  if nnVerb = 5 or nnVerb = 7 then
    if nnIds(nnTarget) = 0 then
      exit sub
    end if
    nnX = nnXs(nnTarget)
    nnY = nnYs(nnTarget)
  end if
  if nnPoint > 0 then
    nnRing = (nnPoint - 1) \ 16
    nnDirection = (nnPoint - 1) mod 16
    nnRadius = nnWalkRings(nnRing)
    if nnVerb = 5 or nnVerb = 7 then
      nnRadius = nnCastRings(nnRing)
    end if
    nnX = nnX + nnDirectionsX(nnDirection) * nnRadius * nnSide
    nnY = nnY + nnDirectionsY(nnDirection) * nnRadius * nnSide
  end if
  nnValue = nnX + nnOrigin - 0.5
  nnClamp(0, matchInfo(6) - 1)
  nnX = nnValue
  nnValue = nnY + nnOrigin - 0.5
  nnClamp(0, matchInfo(6) - 1)
  nnY = nnValue
  if nnVerb = 1 or nnVerb = 2 then
    nnFloor(nnX + 0.5)
    nnX = nnInteger
    nnFloor(nnY + 0.5)
    nnY = nnInteger
    if nnVerb = 1 then
      walkTo(nnX, nnY)
    else
      attackMove(nnX, nnY)
    end if
  elseif nnVerb = 3 then
    if nnTarget <> 0 and nnIds(nnTarget) <> 0 then
      attackTarget(nnIds(nnTarget))
    end if
  elseif nnVerb = 4 then
    if nnIds(nnTarget) <> 0 then
      castTarget(nnHeads(3), nnIds(nnTarget))
    end if
  elseif nnVerb = 5 then
    castPoint(nnHeads(3), nnX, nnY)
  elseif nnVerb = 6 then
    useItem(nnHeads(4))
  elseif nnVerb = 7 then
    useItemAt(nnHeads(4), nnX, nnY)
  end if
end sub

sub nnStep()
  nnInitialize()
  if selfHp <= 0 then
    blobClear(nnState)
    nnNextTick = 0
    exit sub
  end if
  if worldTick < nnNextTick then
    exit sub
  end if
  nnNextTick = worldTick + nnPeriod
  nnObserve()
  nnResult = nn_david("model.bin", nnState, nnData)
  nnChoose()
  nnDispatch()
end sub

' Example policy.
if drafting then
  for nnI = 0 to 9
    if heroAvailable(nnI) then
      draftHero(nnI)
      end
    end if
  next nnI
  end
end if
nnStep()
