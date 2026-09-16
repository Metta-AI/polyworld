import
  benchy,
  polyworld/rockgen

for index in 0 .. PresetNames.high:
  let settings = preset(index)
  timeIt PresetNames[index]:
    let geometry = generateGeometry(settings)
    keep geometry
