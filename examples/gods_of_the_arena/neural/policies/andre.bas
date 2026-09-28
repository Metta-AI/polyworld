' Andre PufferNet helpers. BASIC owns observations, timing and sampling.
dim andreData(44)
dim andreWeights(10)
DATA andreExponentials AS fixed32 = _
  1.0, 0.9394073486328125, 0.8824920654296875, 0.8290252685546875, _
  0.7787933349609375, 0.7316131591796875, 0.687286376953125, 0.6456451416015625, _
  0.606536865234375, 0.5697784423828125, 0.5352630615234375, 0.502838134765625, _
  0.4723663330078125, 0.4437408447265625, 0.4168548583984375, 0.3916015625, _
  0.3678741455078125, 0.3455963134765625, 0.32464599609375, 0.3049774169921875, _
  0.2864990234375, 0.2691497802734375, 0.252838134765625, 0.237518310546875, _
  0.2231292724609375, 0.2096099853515625, 0.1969146728515625, 0.1849822998046875, _
  0.17376708984375, 0.163238525390625, 0.153350830078125, 0.1440582275390625, _
  0.1353302001953125, 0.12713623046875, 0.1194305419921875, 0.1121978759765625, _
  0.1053924560546875, 0.0990142822265625, 0.093017578125, 0.087371826171875, _
  0.08209228515625, 0.077117919921875, 0.0724334716796875, 0.06805419921875, _
  0.063934326171875, 0.06005859375, 0.0564117431640625, 0.0529937744140625, _
  0.0497894287109375, 0.0467681884765625, 0.0439300537109375, 0.0412750244140625, _
  0.0387725830078125, 0.0364227294921875, 0.0342254638671875, 0.0321502685546875, _
  0.0301971435546875, 0.0283660888671875, 0.026641845703125, 0.0250396728515625, _
  0.0235137939453125, 0.0220947265625, 0.020751953125, 0.019500732421875, _
  0.018310546875, 0.0172119140625, 0.0161590576171875, 0.0151824951171875, _
  0.0142669677734375, 0.013397216796875, 0.0125885009765625, 0.0118255615234375, _
  0.0111083984375, 0.01043701171875, 0.009796142578125, 0.00921630859375, _
  0.0086517333984375, 0.0081329345703125, 0.00762939453125, 0.007171630859375, _
  0.006744384765625, 0.0063323974609375, 0.005950927734375, 0.005584716796875, _
  0.0052490234375, 0.0049285888671875, 0.0046234130859375, 0.0043487548828125, _
  0.00408935546875, 0.00384521484375, 0.00360107421875, 0.003387451171875, _
  0.0031890869140625, 0.00299072265625, 0.0028076171875, 0.0026397705078125, _
  0.002471923828125, 0.0023345947265625, 0.0021820068359375, 0.0020599365234375, _
  0.0019378662109375, 0.0018157958984375, 0.001708984375, 0.0016021728515625, _
  0.0015106201171875, 0.0014190673828125, 0.0013275146484375, 0.001251220703125, _
  0.0011749267578125, 0.0010986328125, 0.00103759765625, 0.0009765625, _
  0.00091552734375, 0.0008544921875, 0.0008087158203125, 0.000762939453125, _
  0.0007171630859375, 0.00067138671875, 0.0006256103515625, 0.0005950927734375, _
  0.00054931640625, 0.000518798828125, 0.00048828125, 0.000457763671875, _
  0.00042724609375, 0.0004119873046875, 0.0003814697265625, 0.0003509521484375, _
  0.000335693359375, 0.0003204345703125, 0.0002899169921875, 0.000274658203125, _
  0.0002593994140625, 0.000244140625, 0.0002288818359375, 0.000213623046875, _
  0.0001983642578125, 0.0001983642578125, 0.00018310546875, 0.0001678466796875, _
  0.000152587890625, 0.000152587890625, 0.0001373291015625, 0.0001373291015625, _
  0.0001220703125, 0.0001220703125, 0.0001068115234375, 0.0001068115234375, _
  9.1552734375e-05, 9.1552734375e-05, 9.1552734375e-05, 7.62939453125e-05, _
  7.62939453125e-05, 7.62939453125e-05, 6.103515625e-05, 6.103515625e-05, _
  6.103515625e-05, 6.103515625e-05, 4.57763671875e-05, 4.57763671875e-05, _
  4.57763671875e-05, 4.57763671875e-05, 4.57763671875e-05, 3.0517578125e-05, _
  3.0517578125e-05, 3.0517578125e-05, 3.0517578125e-05, 3.0517578125e-05, _
  3.0517578125e-05, 3.0517578125e-05, 3.0517578125e-05, 1.52587890625e-05, _
  1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, _
  1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, _
  1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, _
  1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, 1.52587890625e-05, _
  1.52587890625e-05, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0, 0.0, 0.0, 0.0, _
  0.0

sub andreExp(andreArgument)
  ' Interpolate exp(x) for -16 <= x <= 0 at Q16.16 precision.
  andreValue = 0.0
  if andreArgument < -16.0 then
    exit sub
  end if
  if andreArgument >= 0.0 then
    andreValue = 1.0
    exit sub
  end if
  andrePosition = -andreArgument * 16.0
  andreIndex = floor(andrePosition)
  if andreIndex >= 256 then
    exit sub
  end if
  andreFraction = andrePosition - andreIndex
  andreValue = andreExponentials(andreIndex) + andreFraction * (andreExponentials(andreIndex + 1) - andreExponentials(andreIndex))
end sub

sub andreChoose()
  andreAction = 0
  for andreI = 1 to 10
    if andreResult(andreI) > andreResult(andreAction) then
      andreAction = andreI
    end if
  next andreI
  if andreTemperature <= 0 then
    exit sub
  end if
  andreTop = andreResult(andreAction)
  andreTotal = 0.0
  for andreI = 0 to 10
    andreHalf = andreResult(andreI) / 2.0 - andreTop / 2.0
    andreValue = 0.0
    if andreHalf >= -8.0 * andreTemperature then
      andreExp(andreHalf * 2.0 / andreTemperature)
    end if
    andreWeights(andreI) = andreValue
    andreTotal = andreTotal + andreValue
  next andreI
  andreSeed = andreSeed * 1664525 + 1013904223
  andreDraw = (andreSeed and 32767) / 16384.0 / 2.0 * andreTotal
  andreCumulative = 0.0
  for andreI = 0 to 10
    andreCumulative = andreCumulative + andreWeights(andreI)
    if andreDraw < andreCumulative then
      andreAction = andreI
      exit sub
    end if
  next andreI
end sub

sub andreAdvance()
  ' Advance from the previous captured features before the hero thinks.
  if drafting then
    exit sub
  end if
  if andreInitialized = 0 then
    andreState = blobCreate()
    andrePeriod = 24
    andreTemperature = 1.0
    andreSeed = matchInfo(2) + selfId * 7919
    for andreI = 0 to draftPlayerCount() - 1
      if draftPlayerId(andreI) = selfId then
        andreData(40 + andreI mod 5) = 1.0
      end if
    next andreI
    andreInitialized = 1
  end if
  if worldTick < andreNextTick then
    exit sub
  end if
  andreNextTick = worldTick + andrePeriod
  andreResult = andre_nn("weights.bin", andreState, andreData)
  andreChoose()
end sub

sub andreCapture()
  ' The lockstep bridge stores features even when the held action is unchanged.
  for andreI = 0 to 39
    andreFeature = f(andreI)
    if andreFeature > 100 then
      andreFeature = 100
    end if
    if andreFeature < -100 then
      andreFeature = -100
    end if
    andreData(andreI) = andreFeature / 100.0
  next andreI
end sub

' Example policy.
dim f(40)
andreAdvance()
if drafting then
  for candidate = 0 to 9
    if heroAvailable(candidate) then
      draftHero(candidate)
      end
    end if
  next candidate
  end
end if
if selfHp <= 0 then
  end
end if
f(0) = selfHp * 100 \ selfMaxHp
f(39) = decision * 9
andreCapture()
decision = andreAction
' The real converted hero keeps all eleven macro behaviours in its BASIC.
if decision = 1 then
  walkTo(selfX, selfY)
else
  attackMove(selfX, selfY)
end if
