import std/[dom, strutils]

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

proc openDetails(element: Element): bool {.importcpp: "#.open".}
  ## Reads the native disclosure state.

proc setOpen(element: Element, value: bool) {.importcpp: "#.open = #".}
  ## Restores the native disclosure state.

let
  prefix = "gota-report-" & $document.body.getAttribute("data-run") & "-"
  savedScroll = readSaved(prefix & "scroll")

for element in document.querySelectorAll("details"):
  let detail = element
  detail.setOpen(readSaved(prefix & $detail.id) == "true")
  detail.addEventListener("toggle", proc(event: Event) =
    ## Preserves expanded match details across manual reloads.
    let detail = Element(event.currentTarget)
    save(prefix & $detail.id, $detail.openDetails()))

proc saveScroll(event: Event) =
  ## Saves position only after restoring the initial viewport.
  save(prefix & "scroll", $window.pageYOffset)

discard window.setTimeout(proc() =
  ## Restores scroll after the page layout and expanded details exist.
  if savedScroll.len > 0:
    try:
      window.scrollTo(0, parseInt(savedScroll))
    except ValueError:
      discard
  window.addEventListener("scroll", saveScroll)
  window.addEventListener("pagehide", saveScroll), 0)
