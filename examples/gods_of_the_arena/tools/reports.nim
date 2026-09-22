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

proc number(value: float64, places = 2): string =
  ## Formats compact human-readable values with the requested precision.
  result = formatFloat(value, ffDecimal, places)
  result.trimZeros()
  var position = result.find('.')
  if position < 0:
    position = result.len
  let start = if result.startsWith("-"): 1 else: 0
  position -= 3
  while position > start:
    result.insert(",", position)
    position -= 3

proc number(value: int): string =
  ## Formats game counts and checkpoint values with the same grouping.
  number(value.float64, 0)

proc number(value: JsonNode, places = 2): string =
  ## Marks missing observations with an em dash.
  if value == nil or value.kind == JNull: "—"
  else: number(value.getFloat, places)

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
        else: number(row["value"], 0)
      movement = row["movement"]
      change = movement.getInt
      color = if change > 0: "up" elif change < 0: "down" else: "muted"
      mark = if movement.kind == JNull: "—" elif change > 0: "↑" & $change
        elif change < 0: "↓" & $(-change) else: "·"
    result.add "<tr><td>" & number(row["rank"]) &
      (if row["tied"].getBool: "<span class=tie> =</span>" else: "") &
      "</td><td class=policy title=\"" & escape(row["id"].getStr) & "\">" &
      escape(row["name"].getStr) &
      "<small class=policy-version title=\"" &
      escape(row["version"].getStr) & "\">" &
      escape(row["version"].getStr) & "</small></td><td>" &
      number(row["appearances"]) & "</td><td>" & value & "</td>" &
      "<td class=" & color & ">" & mark & "</td></tr>"
  result.add "</tbody></table></div>"

proc stabilityChart(panel: JsonNode, interval: int): string =
  ## Plots observed rank changes, excluding the first checkpoint's baseline.
  var checkpoints: seq[JsonNode]
  for checkpoint in panel["history"]:
    if checkpoint["score"].kind != JNull:
      checkpoints.add(checkpoint)
  if checkpoints.len == 0:
    return "<p class=\"note stability-empty\">Swap history starts after " &
      number(interval * 2) & " games.</p>"
  let
    first = checkpoints[0]["games"].getInt
    last = checkpoints[^1]["games"].getInt
    maximum = max(1, panel["rows"].len).float64
  var
    points: seq[string]
    markers = ""
  for i, checkpoint in checkpoints:
    let
      games = checkpoint["games"].getInt
      swaps = checkpoint["score"].getInt
      x = if last == first: 180.0
        else: 4.0 + 352.0 * (games - first).float64 / (last - first).float64
      y = 44.0 - 40.0 * swaps.float64 / maximum
      label = number(games) & " games: " & number(swaps) & " player swaps"
      latest = i == checkpoints.high
    points.add(number(x) & "," & number(y))
    markers.add "<circle class=\"swap-point" &
      (if latest and swaps == 0: " stable" else: "") & "\" cx=\"" &
      number(x) & "\" cy=\"" & number(y) & "\" r=\"" &
      (if latest: "3" else: "2") & "\" data-games=\"" & $games &
      "\" data-swaps=\"" & $swaps & "\"><title>" & label &
      "</title></circle>"
  result = "<svg class=stability-chart viewBox=\"0 0 360 48\" " &
    "role=img aria-label=\"Player swaps every " & $interval &
    " games\"><title>Player swaps every " & $interval &
    " games. Each point compares ranks with the previous checkpoint." &
    "</title><path class=swap-baseline d=\"M4 44H356\"/>" &
    "<polyline class=swap-line points=\"" & points.join(" ") & "\"/>" &
    markers & "</svg><div class=stability-axis><span>Every " &
    number(interval) & " games</span><span>" & number(first) &
    (if last > first: "–" & number(last) else: "") & " games</span></div>"

proc panelHtml(panel: JsonNode, interval: int): string =
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
    number(panel["stability"]["score"]) & " player swaps · Streak: " &
    number(panel["stability"]["run"].getInt * interval) & " games</p>" &
    stabilityChart(panel, interval) & "</article>"

proc playersHtml(rows: JsonNode): string =
  ## Groups each player's statistics into compact pairs without nested scrolling.
  const Columns = [
    ("name", "Player"), ("games", "Games"), ("win_rate", "Win rate"),
    ("avg_xp", "XP / level"), ("kda", "K / D / A"),
    ("avg_gold", "Gold earned"), ("avg_last_hits", "Objectives"),
    ("xpm", "GPM / XPM")
  ]
  proc cell(field, label, primary, secondary: string,
      row: JsonNode, color = ""): string =
    ## Keeps visible labels and sortable raw values beside each grouped stat.
    let value = if row[field].kind == JNull: "" else: $row[field]
    result = "<td data-label=\"" & label & "\" data-value=\"" &
      escape(value) & "\"><span class=\"stat-main " & color & "\">" &
      primary & "</span><small class=stat-sub>" & secondary & "</small></td>"

  result = "<section class=\"panel players\" id=players>" &
    "<div class=players-heading><h2>Player statistics</h2>" &
    "<span class=note>Both formats · Per-player averages</span></div>" &
    "<table id=player-stats aria-label=\"Player statistics\">" &
    "<thead><tr>"
  for (field, label) in Columns:
    result.add "<th scope=col aria-sort=none><button type=button " &
      "data-sort=\"" & field & "\">" & label &
      " <span class=sort-mark aria-hidden=true>↕</span></button></th>"
  result.add "</tr></thead><tbody>"
  for row in rows:
    let
      rate = row["win_rate"]
      color = if rate.kind == JNull: "muted"
        elif rate.getFloat >= 50: "stat-win" else: "stat-loss"
      wins = number(rate, 1) & (if rate.kind == JNull: "" else: "%")
      outcomes = number(row["wins"]) & "W / " &
        number(row["losses"]) & "L / " & number(row{"draws"}) &
        "D / " & number(row["timeouts"]) & "T"
      bar = "<span class=win-track aria-hidden=true><i style=\"width:" &
        number(rate.getFloat, 2) & "%\"></i></span>"
    result.add "<tr data-policy=\"" & escape(row["id"].getStr) &
      "\"><th scope=row data-value=\"" & escape(row["name"].getStr) &
      "\" title=\"" & escape(row["id"].getStr) & "\">" &
      "<span class=stat-main>" & escape(row["name"].getStr) &
      "</span><small class=\"stat-sub policy-version\" title=\"" &
      escape(row["version"].getStr) & "\">" &
      escape(row["version"].getStr) &
      "</small></th>"
    result.add cell("games", "Games", number(row["games"]),
      number(row["mixed"]) & " / " & number(row["mono"]),
      row)
    result.add cell("win_rate", "Win rate", wins & bar, outcomes, row, color)
    result.add cell("avg_xp", "XP / level", number(row["avg_xp"], 0),
      "Lv " & number(row["avg_level"], 1) & " / " &
      number(row["max_level"]) & " max", row, "stat-xp")
    result.add cell("kda", "K / D / A", number(row["avg_kills"], 1) &
      " / " & number(row["avg_deaths"], 1) & " / " &
      number(row["avg_assists"], 1), number(row["kda"]) & " KDA ratio", row)
    result.add cell("avg_gold", "Gold earned", number(row["avg_gold"], 0),
      number(row["avg_banked_gold"], 0) & " unspent", row, "stat-gold")
    result.add cell("avg_last_hits", "Objectives",
      number(row["avg_last_hits"], 1) & " LH",
      number(row["avg_tower_kills"], 1) & " towers", row)
    result.add cell("xpm", "GPM / XPM", number(row["gpm"], 0) &
      " / " & number(row["xpm"], 0),
      number(row["avg_minutes"], 1) & " min / game", row)
    result.add "</tr>"
  result.add "</tbody></table><div class=players-notes>" &
    "<p class=note>Games: mixed / mono. Level: average / max. " &
    "LH: last hits. W / L / D / T: wins / losses / draws / timeouts.</p>" &
    "<details><summary>Stat definitions</summary><p class=note>" &
    "Mono games average five heroes. Max level is the highest hero level " &
    "reached. Last hits are footman kills. Gold and XP are lifetime " &
    "earnings. K / D / A are separate averages; " &
    "KDA ratio = total kills + assists, divided by max(1, total deaths). " &
    "GPM and XPM divide earnings by simulated minutes. " &
    "Click a column heading to sort.</p></details>"
  for row in rows:
    if row["stats_games"].getInt < row["games"].getInt:
      result.add "<p class=note>Replay statistics are still being collected. " &
        "XP and outcomes include every completed game. Replay coverage: "
      var coverage: seq[string]
      for player in rows:
        coverage.add(escape(player["name"].getStr) & " " &
          number(player["stats_games"]) & "/" & number(player["games"]))
      result.add coverage.join(" · ") & ".</p>"
      break
  result.add "</div></section>"

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
        body.add panelHtml(panel, interval)
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
