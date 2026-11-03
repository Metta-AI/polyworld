import std/[algorithm, dom, math, strutils]

proc readSaved(key: string): string =
  ## Reads optional session state without preventing offline rendering.
  try:
    result = $window.sessionStorage.getItem(key.cstring)
  except:
    result = ""

proc save(key, value: string) =
  ## Saves report controls when the browser permits local session storage.
  try:
    window.sessionStorage.setItem(key.cstring, value.cstring)
  except:
    discard

proc sortPlayers(table: Element, field: string, ascending: bool) =
  ## Reorders existing player rows using raw values, with missing stats last.
  let
    headers = table.querySelectorAll("thead th")
    body = table.querySelector("tbody")
  var column = 0
  for i, header in headers:
    let
      button = header.querySelector("button")
      selected = $button.getAttribute("data-sort") == field
    header.setAttribute("aria-sort", (if not selected: "none"
      elif ascending: "ascending" else: "descending").cstring)
    button.querySelector(".sort-mark").textContent =
      (if not selected: "↕" elif ascending: "↑" else: "↓").cstring
    if selected:
      column = i
  var rows: seq[Element]
  for row in body.querySelectorAll("tr"):
    rows.add(row)
  rows.sort(proc(a, b: Element): int =
    ## Uses policy identifiers to keep ties deterministic in either direction.
    let
      left = $a.children[column].getAttribute("data-value")
      right = $b.children[column].getAttribute("data-value")
    if left.len == 0 or right.len == 0:
      result = cmp(left.len == 0, right.len == 0)
    else:
      result = if field == "name": cmp(left.toLowerAscii, right.toLowerAscii)
        else: cmp(parseFloat(left), parseFloat(right))
      if not ascending:
        result = -result
    if result == 0:
      result = cmp($a.getAttribute("data-policy"),
        $b.getAttribute("data-policy")))
  for row in rows:
    body.appendChild(row)

proc installSorting(table: Element, prefix: string) =
  ## Restores manual sorting and binds keyboard-accessible column buttons.
  if table == nil:
    return
  for button in table.querySelectorAll("thead button"):
    button.addEventListener("click", proc(event: Event) =
      ## Toggles the clicked column and remembers it across manual refreshes.
      let
        selected = Element(event.currentTarget)
        field = $selected.getAttribute("data-sort")
        order = $selected.parentNode.getAttribute("aria-sort")
        ascending = if order == "none": field == "name"
          else: order == "descending"
      sortPlayers(table, field, ascending)
      save(prefix & "sort", field)
      save(prefix & "ascending", $ascending))
  let
    savedField = readSaved(prefix & "sort")
    field = if savedField.len > 0: savedField else: "avg_xp"
  for button in table.querySelectorAll("thead button"):
    if $button.getAttribute("data-sort") == field:
      sortPlayers(table, field, readSaved(prefix & "ascending") == "true")
      break

let
  prefix = "gota-report-" & $document.body.getAttribute("data-run") & "-"
  savedScroll = readSaved(prefix & "scroll")

installSorting(document.getElementById("player-stats"), prefix)

proc saveScroll(event: Event) =
  ## Saves a whole-pixel position after restoring the initial viewport.
  save(prefix & "scroll", $int(floor(window.pageYOffset.float64)))

discard window.setTimeout(proc() =
  ## Restores scroll after the page layout exists.
  if savedScroll.len > 0:
    try:
      window.scrollTo(0, parseInt(savedScroll))
    except ValueError:
      discard
  window.addEventListener("scroll", saveScroll)
  window.addEventListener("pagehide", saveScroll), 0)
