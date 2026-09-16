import
  benchy,
  ../rocks

for index in 0 .. PresetNames.high:
  let settings = preset(index)
  timeIt PresetNames[index]:
    let geometry = generate(settings)
    keep geometry
