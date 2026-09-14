import std/[dom, math, strutils]

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

let
  prefix = "gota-report-" & $document.body.getAttribute("data-run") & "-"
  savedScroll = readSaved(prefix & "scroll")

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
