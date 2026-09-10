import
  std/os,
  polyworld/assets,
  ../../tools/assetpacks, assets

proc main() =
  ## Builds CTA's browser assets without creating a graphics context.
  if paramCount() != 2:
    raise newException(AssetError, "Usage: pack_assets <data> <output>")
  discard packAssets(browserAssets(), paramStr(1), paramStr(2), logo = LogoPath)

main()
