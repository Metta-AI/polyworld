if projectName() == "gota_worker":
  switch("define", "coworld")
  switch("define", "headless")
  switch("define", "fastXpWorker")
else:
  # Observatory and its signed artifact URLs require HTTPS.
  switch("define", "ssl")
