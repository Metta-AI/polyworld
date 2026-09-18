import
  std/os,
  polyworld/assets,
  ../../tools/assetpacks, assets

proc main() =
  ## Builds GOTA's browser assets without creating a graphics context.
  if paramCount() != 2:
    raise newException(AssetError, "Usage: pack_assets <data> <output>")
  let packed = packAssets(
    browserAssets(), paramStr(1), paramStr(2), logo = LogoPath)
  var bytes = 0
  for file in packed:
    bytes += file.bytes
  const WebAssetBudget = 20 * 1024 * 1024
  if bytes > WebAssetBudget:
    raise newException(
      AssetError,
      "GOTA browser assets exceed 20 MiB: " & $(bytes div 1024) & " KiB")

main()
