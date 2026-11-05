## Stages the card illustrations for the browser build, already cropped to
## the face's art window. The game crops every illustration to that window
## when it loads it (cropToArtWindow), so the full-size originals would
## only make the download several times larger. tools/build_web.sh runs it:
## nim r tools/stage_card_art.nim SOURCE_ART_DIR STAGED_ART_DIR
import std/os
import pixie
import ../src/ui/cardfaces

proc stageCardArt*(source, destination: string): int =
  ## Writes every PNG in source cropped to the art window, and copies the
  ## other files (the placeholder SVG) unchanged. Returns the PNGs staged.
  createDir(destination)
  for kind, path in walkDir(source):
    if kind != pcFile:
      continue
    let target = destination / path.extractFilename
    if path.splitFile.ext == ".png":
      cropToArtWindow(readImage(path)).writeFile(target)
      inc result
    else:
      copyFile(path, target)

when isMainModule:
  let params = commandLineParams()
  if params.len != 2:
    quit("Usage: stage_card_art SOURCE_ART_DIR STAGED_ART_DIR")
  echo "Staged ", stageCardArt(params[0], params[1]),
    " card illustrations in ", params[1]
