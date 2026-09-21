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

proc heroCatalog*(): JsonNode =
  ## Reads hero identities and every learnable spell rank from live tuning.
  result = newJObject()
  for class in HeroClass:
    let
      spec = class.heroSpec
      abilities = newJArray()
    for slot in HeroAbilitySlot:
      let
        ability = heroAbility(class, slot)
        base = ability.abilitySpec
        ranks = newJArray()
        effect =
          case base.kind
          of Strike: "Damage"
          of Heal: "Healing"
          of Restore: "Mana restored"
      for rank in 1'i32 .. slot.abilityMaxLevel:
        let
          tuning = ability.abilitySpec(rank)
          amount =
            case tuning.kind
            of Strike: tuning.damage
            of Heal: tuning.heal
            of Restore: tuning.restore
        ranks.add %*{
          "rank": rank,
          "required_level": slot.abilityRequiredLevel(rank),
          "amount": amount,
          "mana_cost": tuning.manaCost
        }
      abilities.add %*{
        "slot": slot.ord,
        "key": ["Q", "W", "E", "R"][slot.ord],
        "name": base.name,
        "icon": "hero_assets/" & ability.abilityIconKey & ".png",
        "ultimate": slot == UltimateAbility,
        "effect": effect,
        "charges": base.charges,
        "cooldown_seconds": base.cooldownTicks.float64 / TickRate.float64,
        "recharge_seconds": base.rechargeTicks.float64 / TickRate.float64,
        "ranks": ranks
      }
    result[spec.name] = %*{"name": spec.name, "role": spec.role,
      "slug": slug(spec.name),
      "portrait": "hero_assets/" & slug(spec.name) & ".png",
      "abilities": abilities}

proc renderHeroStats*(summary, appearances: JsonNode): string =
  ## Builds a static hero explorer using relative artwork and font paths.
  let payload = %*{"summary": heroSummary(summary, appearances),
    "catalog": heroCatalog()}
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
  for ability in Ability:
    copyFile(
      dataRoot / "abilities" / (ability.abilitySpec.icon & ".png"),
      assets / (ability.abilityIconKey & ".png")
    )
  writeFile(path & ".tmp", renderHeroStats(summary, appearances))
  moveFile(path & ".tmp", path)
