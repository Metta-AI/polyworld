import
  std/[base64, os, strutils],
  tournaments

const
  DefaultSite* = Root.parentDir / "polyworld-buff"
  SiteUrl = "https://metta-ai.github.io/polyworld-buff/"
  StyleStart = "<style id=\"gota-site-style\">"
  DefaultStyles = staticRead(SourceDirectory / "standings.css")
  Assets* = [
    ("regular", "fonts/Rubik-Regular.ttf"),
    ("bold", "fonts/Rubik-Bold.ttf"), ("logo", "themes/gota/gota_logo.png"),
    ("victory", "icons/victory.png"), ("experience", "icons/experience.png"),
    ("chalice", "icons/chalice.png"), ("champion", "icons/champion.png"),
    ("stats", "icons/stats.png"), ("day", "icons/day.png")
  ]

proc validateSite*(siteRoot: string) =
  ## Requires an existing GotA site before replacing its standings page.
  if siteRoot.len > 0:
    for path in ["GOTA/index.html", "GOTA/site.css"]:
      require(fileExists(siteRoot / path), "Missing site file: " &
        siteRoot / path)

proc siteStyles*(siteRoot: string): string =
  ## Embeds the site's current stylesheet, with a bundled offline fallback.
  validateSite(siteRoot)
  try:
    let css = if siteRoot.len > 0:
      readFile(siteRoot / "GOTA/site.css") else: DefaultStyles
    result = StyleStart & "\n" & css & "</style>"
  except IOError as error:
    raise newException(TournamentError, "Cannot read site style: " & error.msg)

proc navigation*(): string =
  ## Uses the published GotA header and links that also work in offline files.
  result = "<!-- GOTA navigation. -->\n" &
    "<header class=\"site-header wrap\">\n" &
    "  <a class=\"site-brand\" href=\"" & SiteUrl & "\" " &
    "aria-label=\"Polyworld Buff home\">\n" &
    "    <img src=\"@@logo@@\" alt=\"Gods of the Arena\">\n  </a>\n" &
    "  <nav class=\"site-nav\" aria-label=\"GOTA pages\">\n"
  for (path, label) in [("index.html", "Game guide"),
      ("heros/", "Hero statistics"),
      ("standings/", "Player standings")]:
    result.add "    <a href=\"" & SiteUrl & "GOTA/" & path & "\"" &
      (if path == "standings/": " aria-current=\"page\"" else: "") &
      ">" & label & "</a>\n"
  result.add "    <a href=\"https://softmax.com/gods-of-the-arena/wiki/" &
    "game-guide\">Softmax wiki</a>\n  </nav>\n</header>\n" &
    "<!-- End GOTA navigation. -->"

proc tidyHtml*(html: string): string =
  ## Normalizes compiler whitespace before checking the generated page into Git.
  for line in html.splitLines():
    let trimmed = line.strip(leading = false, chars = {' ', '\t'})
    var indent = 0
    while indent < trimmed.len and trimmed[indent] in {' ', '\t'}:
      inc indent
    result.add(trimmed[0 ..< indent].replace("\t", "  "))
    result.add(trimmed[indent .. ^1] & "\n")
  result = result.strip(leading = false) & "\n"

proc updateSite*(html, dataRoot, siteRoot: string,
    controls = Controls()) =
  ## Atomically replaces the exact public standings path and copies its assets.
  if siteRoot.len == 0:
    return
  validateSite(siteRoot)
  var page = html
  try:
    for (_, path) in Assets:
      let
        bytes = readFile(dataRoot / path)
        mime = if path.endsWith(".ttf"): "font/ttf" else: "image/png"
        embedded = "data:" & mime & ";base64," & encode(bytes)
        destination = siteRoot / "GOTA/assets" / path
      require(embedded in page, "Missing embedded report asset: " & path)
      page = page.replace(embedded, "../assets/" & path)
      if not fileExists(destination) or readFile(destination) != bytes:
        saveBytes(destination, bytes, controls)
    let
      start = page.find(StyleStart)
      finish = page.find("</style>", start)
    require(start >= 0 and finish > start, "Missing shared report style")
    page = page[0 ..< start] &
      "<link rel=\"stylesheet\" href=\"../site.css\">" &
      page[finish + "</style>".len .. ^1]
    page = page.replace("href=\"" & SiteUrl & "GOTA/", "href=\"../")
    page = page.replace("href=\"" & SiteUrl & "\"", "href=\"../../\"")
    saveBytes(siteRoot / "GOTA/standings/index.html", tidyHtml(page), controls)
  except IOError, OSError:
    raise newException(TournamentError,
      "Cannot update site: " & getCurrentExceptionMsg())
