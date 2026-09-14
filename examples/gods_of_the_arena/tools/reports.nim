import
  std/[base64, json, os, strutils],
  jsony,
  tournaments, sites

const
  BrowserPath {.strdefine.} = Root / "tmp/gota/tools/report.js"
  BrowserCode = staticRead(BrowserPath)
  Template = staticRead(SourceDirectory / "report.html")

proc escape*(value: string): string =
  ## Escapes text and attribute values before inserting them into HTML.
  value.multiReplace(("&", "&amp;"), ("<", "&lt;"), (">", "&gt;"),
    ("\"", "&quot;"), ("'", "&#39;"))

proc number(value: float64): string =
  ## Formats compact human-readable values with up to two decimal places.
  result = formatFloat(value, ffDecimal, 2)
  result.trimZeros()
  var position = result.find('.')
  if position < 0:
    position = result.len
  let start = if result.startsWith("-"): 1 else: 0
  position -= 3
  while position > start:
    result.insert(",", position)
    position -= 3

proc number(value: JsonNode): string =
  ## Marks missing observations with an em dash.
  if value == nil or value.kind == JNull: "—"
  else: number(value.getFloat)

proc standings(panel, rows: JsonNode): string =
  ## Renders one escaped table of policy averages and displayed ranks.
  result = "<div class=scroll><table><thead><tr><th>Rank</th>" &
    "<th>Policy</th><th>Games</th><th>" &
    (if panel["ladder"].getStr == "wins": "Win %" else: "Avg XP") &
    "</th><th>Move</th></tr></thead><tbody>"
  for row in rows:
    let
      value = if panel["ladder"].getStr == "wins" and
        row["value"].kind != JNull: number(row["value"].getFloat * 100) & "%"
        else: number(row["value"])
      movement = row["movement"]
      change = movement.getInt
      color = if change > 0: "up" elif change < 0: "down" else: "muted"
      mark = if movement.kind == JNull: "—" elif change > 0: "↑" & $change
        elif change < 0: "↓" & $(-change) else: "·"
    result.add "<tr><td>" & number(row["rank"]) &
      (if row["tied"].getBool: "<span class=tie> =</span>" else: "") &
      "</td><td class=policy title=\"" & escape(row["id"].getStr) & "\">" &
      escape(row["name"].getStr) & "<small>" &
      escape(row["version"].getStr) & "</small></td><td>" &
      number(row["appearances"]) & "</td><td>" & value & "</td>" &
      "<td class=" & color & ">" & mark & "</td></tr>"
  result.add "</tbody></table></div>"

proc panelHtml(panel: JsonNode): string =
  ## Renders standings with compact stability numbers below the ranking.
  let
    id = panel["id"].getStr
    ladder = panel["ladder"].getStr
    icon = case ladder
      of "wins": "victory"
      of "score": "experience"
      else: "chalice"
  result = "<article class=\"panel ladder\" id=\"panel-" & id &
    "\"><div class=ladder-head><img src=\"@@" & icon &
    "@@\" alt=\"\"><div><h3>" & panel["title"].getStr &
    "</h3><span class=note>" & number(panel["completed"]) & " / " &
    number(panel["target"]) & " games complete" &
    (if panel["target"].getInt == 0: " · Not selected" else: "") &
    "</span></div></div>"
  result.add standings(panel, panel["rows"])
  result.add "<p class=ladder-stability>Stability: " &
    number(panel["stability"]["score"]) & " · Streak: " &
    number(panel["stability"]["run"]) & "</p></article>"

proc playersHtml(rows: JsonNode): string =
  ## Shows every policy's outcomes, economy and combat in one scrollable table.
  const Columns = [
    ("games", "Games"), ("wins", "Wins"), ("losses", "Losses"),
    ("timeouts", "Timeouts"), ("win_rate", "Win %"),
    ("avg_gold", "Avg gold"), ("avg_xp", "Avg XP"),
    ("avg_level", "Avg level"), ("avg_kills", "Avg kills"),
    ("avg_deaths", "Avg deaths"), ("avg_assists", "Avg assists"),
    ("kda", "KDA ratio"), ("avg_tower_kills", "Avg tower kills"),
    ("avg_last_hits", "Avg last hits"),
    ("avg_banked_gold", "Avg unspent gold"), ("avg_minutes", "Avg minutes"),
    ("mixed", "Mixed games"), ("mono", "Mono games"),
    ("stats_games", "Stats games")
  ]
  result = "<section class=\"panel players\" id=players>" &
    "<h2>Player statistics</h2><p class=note>Both formats combined. " &
    "One appearance per policy per game; mono teams average their five " &
    "heroes first. Gold and XP are lifetime earnings. " &
    "Last hits are footman kills. " &
    "KDA = (kills + assists) / max(1, deaths).</p>" &
    "<div class=scroll tabindex=0 role=region " &
    "aria-label=\"Player statistics, scroll horizontally for more columns\">" &
    "<table id=player-stats><thead><tr><th scope=col>Player</th>" &
    "<th scope=col>Policy</th>"
  for (_, label) in Columns:
    result.add "<th scope=col>" & label & "</th>"
  result.add "</tr></thead><tbody>"
  for row in rows:
    result.add "<tr><th scope=row>" & escape(row["name"].getStr) &
      "</th><td class=policy title=\"" & escape(row["id"].getStr) & "\">" &
      escape(row["version"].getStr) & "</td>"
    for (field, _) in Columns:
      result.add "<td>" & number(row[field]) & "</td>"
    result.add "</tr>"
  result.add "</tbody></table></div>"
  for row in rows:
    if row["stats_games"].getInt < row["games"].getInt:
      result.add "<p class=note>Replay statistics are still being collected. " &
        "Stats games shows coverage for combat, gold and level averages; " &
        "XP and outcomes include every completed game.</p>"
      break
  result.add "</section>"

proc render*(summary: JsonNode, dataRoot: string, siteRoot = ""): string =
  ## Embeds real GotA assets and Nim-generated browser code in one HTML file.
  let
    percent = 100.0 * summary["completed"].getInt.float64 /
      max(1, summary["target"].getInt).float64
    interval = summary["settings"]["check_every"].getInt
    status = escape(summary["status"].getStr)
  var body = navigation() & "<main class=wrap>" &
    "<section class=\"panel run-panel\" aria-label=\"Tournament progress\">" &
    "<div class=run-head><div><div class=kicker>Tournament report</div>" &
    "<h1>" & escape(summary["run"].getStr) & "</h1></div>" &
    "<span class=\"badge " & status & "\">" & status & "</span></div>" &
    "<div class=between><strong>" & number(summary["completed"]) & " / " &
    number(summary["target"]) & " games complete</strong><span class=muted>" &
    number(percent) & "%</span></div><div class=progress role=progressbar " &
    "aria-label=\"Games completed\" aria-valuemin=0 aria-valuemax=\"" &
    $summary["target"].getInt & "\" aria-valuenow=\"" &
    $summary["completed"].getInt & "\"><div style=\"width:" &
    formatFloat(percent, ffDecimal, 2) & "%\"></div></div><div class=counts>"
  for field in ["queued", "running", "failed"]:
    body.add "<span><b>" & number(summary[field]) & "</b> " & field & "</span>"
  body.add "</div>"
  if summary["included"].getInt < summary["completed"].getInt:
    body.add "<p class=note>" & number(summary["included"]) &
      " completed games are included in standings; later results are " &
      "saved while earlier games finish.</p>"
  if summary["error"].getStr.len > 0:
    body.add "<p class=error>" & escape(summary["error"].getStr) & "</p>"
  body.add "</section><div class=facts>"
  for (icon, value, label) in [
    ("champion", $summary["roster"].len, "Frozen policy versions"),
    ("stats", "6 leaderboards", "Three ladders per team format"),
    ("day", $interval, "Games per stability checkpoint, per format")
  ]:
    body.add "<div class=\"panel fact\"><img src=\"@@" & icon &
      "@@\" alt=\"\"><div><b>" & value & "</b><small>" & label &
      "</small></div></div>"
  body.add "</div><nav aria-label=\"Report sections\"><a href=#mixed>Mixed " &
    "teams</a><a href=#mono>Mono teams</a><a href=#players>Player statistics" &
    "</a></nav>"
  for kind in Formats:
    body.add "<section id=" & kind & "><div class=format-head>" &
      "<div class=kicker>" & (if kind == "mixed": "One policy per hero"
        else: "One policy per team") & "</div><h2>" &
      capitalizeAscii(kind) & " teams · 5 v 5</h2><p>" &
      (if kind == "mixed": "Ten distinct policies with balanced sampling."
        else: "Five heroes per policy. XP is averaged across the team.") &
      "</p></div><div class=ladders>"
    for panel in summary["panels"]:
      if panel["format"].getStr == kind:
        body.add panelHtml(panel)
    body.add "</div></section>"
  body.add playersHtml(summary["players"])
  body.add "<footer>Game release " &
    escape(summary["release"]["version"].getStr) & " · " &
    escape(summary["release"]["id"].getStr) & " · Sampling seed " &
    $summary["settings"]["seed"].getInt & " · Run " &
    escape(summary["id"].getStr) & ". Reports and exports are rebuilt " &
    "from saved game results.</footer></main>"
  result = Template.replace("@@body@@", body)
  result = result.replace("@@site-style@@", siteStyles(siteRoot))
  for (key, path) in Assets:
    require(fileExists(dataRoot / path), "Missing report asset: " & path)
    let mime = if path.endsWith(".ttf"): "font/ttf" else: "image/png"
    result = result.replace("@@" & key & "@@", "data:" & mime &
      ";base64," & encode(readFile(dataRoot / path)))
  result = result.replace("@@id@@", escape(summary["id"].getStr))
  result = result.replace("@@title@@", escape(summary["run"].getStr))
  result = result.replace("@@status@@", status)
  result = result.replace("@@script@@", BrowserCode)
  result = result.replace("@@data@@", summary.toJson.multiReplace(
    ("<", "\\u003c"), ("&", "\\u0026")))

proc csvValue(row: JsonNode, field: string): string =
  ## Quotes CSV fields including names containing commas and line breaks.
  let value = row[field]
  result = if value.kind == JString: value.getStr
    elif value.kind == JNull: "" else: $value
  result = "\"" & result.replace("\"", "\"\"") & "\""

proc publish*(directory: string, run: JsonNode, records: seq[JsonNode],
    status: string, dataRoot: string, error = "", controls = Controls()) =
  ## Atomically publishes JSON, HTML, and leaderboard and player CSV exports.
  let summary = summarize(run, records, status, error)
  saveJson(directory / "summary.json", summary, controls)
  let html = render(summary, dataRoot, controls.siteRoot)
  saveBytes(directory / "report.html", html, controls)
  const Fields = ["rank", "name", "version", "id", "appearances",
    "value", "tied", "movement"]
  for panel in summary["panels"]:
    var csv = Fields.join(",") & "\n"
    for row in panel["rows"]:
      var values: seq[string]
      for field in Fields:
        values.add(csvValue(row, field))
      csv.add(values.join(",") & "\n")
    saveBytes(directory / "exports" / (panel["id"].getStr & ".csv"), csv,
      controls)
  var fields: seq[string]
  for field, value in summary["players"][0]:
    fields.add(field)
  var csv = fields.join(",") & "\n"
  for row in summary["players"]:
    var values: seq[string]
    for field in fields:
      values.add(csvValue(row, field))
    csv.add(values.join(",") & "\n")
  saveBytes(directory / "exports/players.csv", csv, controls)
  updateSite(html, dataRoot, controls.siteRoot, controls)
  echo status, ": ", summary["completed"].getInt, "/",
    summary["target"].getInt, " complete, ", summary["running"].getInt,
    " running, ", summary["failed"].getInt, " failed"
