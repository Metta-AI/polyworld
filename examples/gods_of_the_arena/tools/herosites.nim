import std/[os, osproc, streams, tempfiles]

const Root = currentSourcePath().parentDir.parentDir.parentDir.parentDir

type HeroSiteError* = object of CatchableError

proc defaultHeroSite*(): string =
  ## Finds the website checkout beside Polyworld or through its environment.
  result = getEnv("POLYWORLD_BUFF")
  if result.len > 0:
    return
  result = Root.parentDir / "polyworld-buff"
  if not dirExists(result):
    result = ""

proc checkHeroSite*(site: string) =
  ## Validates the website tools before downloading or rebuilding a report.
  if site.len == 0:
    return
  for path in ["tools/update_hero_stats.nim", "GOTA/site.css"]:
    if not fileExists(site / path):
      raise newException(HeroSiteError, "Missing website file: " & site / path)
  if findExe("nim").len == 0:
    raise newException(HeroSiteError, "Nim is required to update the website")

proc updateHeroSite*(source, site: string) =
  ## Uses the website's own layout for both its page and the local report.
  if site.len == 0:
    return
  checkHeroSite(site)
  let directory = createTempDir("gota-hero-site-", "")
  try:
    let process = startProcess(
      findExe("nim"),
      workingDir = absolutePath(site),
      args = ["r", "--hints:off", "--out:" & directory / "update",
        "--nimcache:" & directory / "cache", "tools/update_hero_stats.nim",
        absolutePath(source), "--refresh-source"],
      options = {poStdErrToStdOut}
    )
    try:
      let
        output = process.outputStream.readAll()
        code = process.waitForExit()
      if code != 0:
        raise newException(HeroSiteError, "Website update failed:\n" & output)
      stdout.write(output)
    finally:
      process.close()
  except OSError, IOError:
    raise newException(HeroSiteError,
      "Website update failed: " & getCurrentExceptionMsg())
  finally:
    removeDir(directory)
