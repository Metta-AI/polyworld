import
  std/[json, os, sets, strutils],
  jsony,
  ../content

const
  Template = staticRead(
    currentSourcePath().parentDir / "hero_stats_template.html"
  )
  Portraits = [1, 13, 16, 17, 2, 3, 11, 12, 6, 14]
  Assets = [
    ("logo", "themes/gota/gota_logo.png", "logo.png"),
    ("font", "fonts/Rubik-Regular.ttf", "Rubik-Regular.ttf"),
    ("bold", "fonts/Rubik-Bold.ttf", "Rubik-Bold.ttf"),
    ("xp", "icons/experience.png", "experience.png"),
    ("gold", "icons/gold.png", "gold.png"),
    ("kills", "icons/kills.png", "kills.png"),
    ("hero", "icons/champion.png", "champion.png")
  ]

proc slug(name: string): string =
  ## Creates a filename and fragment identifier for a hero.
  name.toLowerAscii.replace(" ", "-")

proc scopeSummary(scope, appearances: JsonNode, version = ""): JsonNode =
  ## Reduces source appearances to hero totals and level distributions.
  let heroes = newJArray()
  var
    games: HashSet[string]
    minutes = 0.0
  for appearance in appearances:
    if version.len > 0 and appearance["game_version"].getStr != version:
      continue
    let id = appearance["id"].getStr
    if id notin games:
      games.incl(id)
      minutes += appearance["minutes"].getFloat
  for hero in scope["heroes"]:
    let row = hero.copy()
    var bins: array[10, int]
    row.delete("players")
    row.delete("policies")
    for appearance in appearances:
      if appearance["hero"].getStr != hero["hero"].getStr or
        (version.len > 0 and appearance["game_version"].getStr != version):
          continue
      let index = clamp((appearance["level"].getInt - 1) div 2, 0, 9)
      inc bins[index]
    row["level_bins"] = %bins
    heroes.add(row)
  result = %*{"games": games.len, "heroes": heroes,
    "avg_minutes": minutes / max(1, games.len).float64}

proc heroSummary*(summary, appearances: JsonNode): JsonNode =
  ## Prepares aggregate-only data with no individual games or players.
  result = scopeSummary(summary, appearances)
  for field in ["start", "end", "verified_games", "hero_appearances",
      "fixed_faction_lineups"]:
    result[field] = summary[field].copy()
  result["excluded_count"] = %summary["excluded"].len
  result["versions"] = newJArray()
  for version in summary["versions"]:
    let scope = scopeSummary(version, appearances, version["version"].getStr)
    scope["version"] = version["version"].copy()
    result["versions"].add(scope)

proc renderHeroStats*(summary, appearances: JsonNode): string =
  ## Builds a static hero explorer using relative artwork and font paths.
  let catalog = newJObject()
  for class in HeroClass:
    let spec = class.heroSpec
    catalog[spec.name] = %*{"name": spec.name, "role": spec.role,
      "slug": slug(spec.name),
      "portrait": "hero_assets/" & slug(spec.name) & ".png"}
  let payload = %*{"summary": heroSummary(summary, appearances),
    "catalog": catalog}
  result = Template.replace("@@data@@", payload.toJson.multiReplace(
    ("<", "\\u003c"), ("&", "\\u0026")))
  for (key, source, target) in Assets:
    result = result.replace("@@" & key & "@@", "hero_assets/" & target)

proc writeHeroStats*(path: string, summary, appearances: JsonNode,
    dataRoot: string) =
  ## Writes a static report and its adjacent portable asset folder.
  let assets = path.parentDir / "hero_assets"
  createDir(assets)
  for (key, source, target) in Assets:
    copyFile(dataRoot / source, assets / target)
  for class in HeroClass:
    copyFile(
      dataRoot / "characters/modular_chars" / ("character.preset_" &
        $Portraits[class.ord] & ".profile.png"),
      assets / (slug(class.heroSpec.name) & ".png")
    )
  writeFile(path & ".tmp", renderHeroStats(summary, appearances))
  moveFile(path & ".tmp", path)
