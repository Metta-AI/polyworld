import std/[os, osproc, strutils]

const
  Sources = currentSourcePath().parentDir
  Root = Sources.parentDir.parentDir.parentDir
  Destination = Root / "tmp/gota/tools"

proc compile(arguments: seq[string]) =
  ## Invokes the installed Nim compiler with explicit paths and flags.
  let compiler = findExe("nim")
  if compiler.len == 0:
    raise newException(IOError, "Nim is not on PATH")
  var command = quoteShell(compiler)
  for argument in arguments:
    command.add(" " & quoteShell(argument))
  if execCmd(command) != 0:
    quit(1)

createDir(Destination)
compile(@["js", "-o:" & Destination / "report.js", Sources / "report.nim"])
compile(@["check", Sources / "tournament.nim"])
compile(@["c", "-o:" & Destination / "tournament", Sources / "tournament.nim"])
compile(@["check", Sources / "inspect_players.nim"])
compile(@["c", "-d:release", "-o:" & Destination / "inspect_players",
  Sources / "inspect_players.nim"])
compile(@["check", Sources / "fast_tournament.nim"])
compile(@["c", "-o:" & Destination / "fast_tournament",
  Sources / "fast_tournament.nim"])
compile(@["check", Sources / "inspect_fast.nim"])
compile(@["c", "-d:release", "-o:" & Destination / "inspect_fast",
  Sources / "inspect_fast.nim"])
echo "Runner: ", Destination / "tournament"
echo "Fast XP runner: ", Destination / "fast_tournament"
